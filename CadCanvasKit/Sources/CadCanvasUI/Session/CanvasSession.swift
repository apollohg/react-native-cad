import Foundation
import Observation
import CadCanvasCore

public enum CanvasTool: String, CaseIterable, Codable, Sendable {
    case select
    case line
    case rectangle
    case arch
    case freehand
    case text
    case eraser
}

public struct CanvasTextStyle: Codable, Hashable, Sendable {
    public var font: CanvasFont
    public var color: CanvasColor

    public init(font: CanvasFont, color: CanvasColor) {
        self.font = font
        self.color = color
    }

    public static let `default` = CanvasTextStyle(
        font: .init(familyName: "Helvetica", pointSize: 14),
        color: .black
    )

    public func validate() throws {
        try font.validate()
        try color.validate()
    }
}

@MainActor
@Observable
public final class CanvasSession {
    public private(set) var document: CanvasDocument
    public private(set) var viewport: CanvasViewport
    public var selectedElementID: UUID?
    public var hiddenDimensionKeys: Set<DimensionKey>
    public private(set) var activeTool: CanvasTool
    package private(set) var mostRecentStyleTool: CanvasTool
    public private(set) var strokeStyle: CanvasStyle
    public private(set) var inkConfiguration: CanvasInkConfiguration
    public private(set) var textStyle: CanvasTextStyle
    public private(set) var snapConfiguration: SnapConfiguration
    public private(set) var configuration: CanvasConfiguration = .default
    public private(set) var documentReplacementGeneration: CanvasGeneration
    public private(set) var presentationRevision: CanvasGeneration
    package private(set) var preview: CanvasInteractionPreview?
    package private(set) var dimensionPreviewElement: CanvasElement?
    package private(set) var dimensionPresentationRevision: CanvasGeneration
    package private(set) var committedFreehandHandoff: CanvasCommittedFreehandHandoff?
    @ObservationIgnored public var onDocumentChange: ((CanvasDocument) -> Void)?
    @ObservationIgnored public var onDiagnostic: ((CanvasDiagnostic) -> Void)?

    private var history: CanvasHistory
    private var previousTool: CanvasTool?
    private var lastNonEraserTool: CanvasTool

    public var canUndo: Bool {
        configuration.allows(.history) && preview == nil && document.revision < UInt64.max - 1 && history.canUndo
    }

    public var canRedo: Bool {
        configuration.allows(.history) && preview == nil && document.revision < UInt64.max - 1 && history.canRedo
    }

    package var presentationDocument: CanvasDocument {
        guard let element = dimensionPreviewElement else { return document }
        var candidate = document
        if let index = candidate.elements.firstIndex(where: { $0.id == element.id }) {
            candidate.elements[index] = element
        } else {
            candidate.elements.append(element)
        }
        return candidate
    }

    var activeFreehandPreviewPoints: [CanvasPoint]? {
        guard case .freehand(let draft) = preview?.payload else { return nil }
        return draft.samples.map(\.point)
    }

    public convenience init() {
        self.init(viewport: try! .identity(size: .init(width: 1024, height: 768)))
    }

    public convenience init(configuration: CanvasConfiguration) throws {
        self.init()
        try setConfiguration(configuration)
    }

    public func setConfiguration(_ configuration: CanvasConfiguration) throws {
        try configuration.validate()
        guard configuration != self.configuration else { return }
        let capabilitiesChanged = configuration.enabledTools != self.configuration.enabledTools
            || configuration.enabledFeatures != self.configuration.enabledFeatures
        self.configuration = configuration
        if capabilitiesChanged {
            preview = nil
            clearDimensionPreview()
            presentationRevision.advance()
            if !configuration.allows(.select) { selectedElementID = nil }
            if !configuration.allows(activeTool) {
                activeTool = CanvasTool.allCases.first { configuration.allows($0) } ?? .select
            }
            if !configuration.allows(mostRecentStyleTool) {
                mostRecentStyleTool = CanvasTool.allCases.first {
                    $0 != .select && $0 != .eraser && configuration.allows($0)
                } ?? activeTool
            }
            if let previousTool, !configuration.allows(previousTool) { self.previousTool = nil }
            if !configuration.allows(lastNonEraserTool) { lastNonEraserTool = activeTool }
        }
    }

    public init(viewport: CanvasViewport) {
        document = .empty()
        self.viewport = viewport
        selectedElementID = nil
        hiddenDimensionKeys = []
        activeTool = .select
        mostRecentStyleTool = .freehand
        strokeStyle = .default
        inkConfiguration = .default
        textStyle = .default
        snapConfiguration = .init(screenThreshold: 8, gridSpacing: 10, snapToGrid: false)
        documentReplacementGeneration = .zero
        presentationRevision = .zero
        preview = nil
        dimensionPreviewElement = nil
        dimensionPresentationRevision = .zero
        committedFreehandHandoff = nil
        history = CanvasHistory()
        previousTool = nil
        lastNonEraserTool = .select
    }

    public convenience init(document: CanvasDocument) throws {
        try self.init(
            document: document,
            viewport: .identity(size: .init(width: 1024, height: 768))
        )
    }

    public init(document: CanvasDocument, viewport: CanvasViewport) throws {
        try document.validate()
        self.document = document
        self.viewport = viewport
        selectedElementID = nil
        hiddenDimensionKeys = []
        activeTool = .select
        mostRecentStyleTool = .freehand
        strokeStyle = .default
        inkConfiguration = .default
        textStyle = .default
        snapConfiguration = .init(screenThreshold: 8, gridSpacing: 10, snapToGrid: false)
        documentReplacementGeneration = .zero
        presentationRevision = .zero
        preview = nil
        dimensionPreviewElement = nil
        dimensionPresentationRevision = .zero
        committedFreehandHandoff = nil
        history = CanvasHistory()
        previousTool = nil
        lastNonEraserTool = .select
    }

    public func selectTool(_ tool: CanvasTool) {
        guard configuration.allows(tool), tool != activeTool else { return }
        previousTool = activeTool
        activeTool = tool
        if tool != .eraser {
            lastNonEraserTool = tool
        }
        if tool != .select, tool != .eraser {
            mostRecentStyleTool = tool
        }
    }

    package func selectPreviousTool() {
        guard let previousTool, configuration.allows(previousTool), previousTool != activeTool else { return }
        let current = activeTool
        activeTool = previousTool
        self.previousTool = current
        if activeTool != .eraser {
            lastNonEraserTool = activeTool
        }
        if activeTool != .select, activeTool != .eraser {
            mostRecentStyleTool = activeTool
        }
    }

    package func toggleEraser() {
        selectTool(activeTool == .eraser ? lastNonEraserTool : .eraser)
    }

    public func perform(_ command: CanvasCommand) throws {
        try requireNoActivePreview()
        try requireRevisionReservedForUndo()

        var candidateDocument = document
        var candidateHistory = history
        try candidateHistory.perform(command, on: &candidateDocument)
        document = candidateDocument
        history = candidateHistory
        committedFreehandHandoff = nil
        reconcileSelection()
        notifyDocumentChange()
    }

    public func undo() throws {
        try requireNoActivePreview()
        guard canUndo else {
            return
        }

        var candidateDocument = document
        var candidateHistory = history
        try candidateHistory.undo(on: &candidateDocument)
        document = candidateDocument
        history = candidateHistory
        committedFreehandHandoff = nil
        reconcileSelection()
        notifyDocumentChange()
    }

    public func redo() throws {
        try requireNoActivePreview()
        guard canRedo else {
            return
        }

        var candidateDocument = document
        var candidateHistory = history
        try candidateHistory.redo(on: &candidateDocument)
        document = candidateDocument
        history = candidateHistory
        committedFreehandHandoff = nil
        reconcileSelection()
        notifyDocumentChange()
    }

    package func acquirePreview(_ kind: CanvasPreviewKind) throws -> CanvasPreviewToken {
        switch kind {
        case .freehand:
            guard configuration.allows(.freehand) else { throw CanvasSessionError.featureDisabled }
        case .text:
            guard configuration.allows(.text) else { throw CanvasSessionError.featureDisabled }
        case .erasing:
            guard configuration.allows(.eraser) else { throw CanvasSessionError.featureDisabled }
        case .editing:
            guard configuration.allows(.select),
                  configuration.allows(.selectionMovement) || configuration.allows(.selectionResizing) else {
                throw CanvasSessionError.featureDisabled
            }
        case .inserting:
            break
        }
        guard preview == nil else {
            throw CanvasPreviewError.previewAlreadyActive
        }
        try requireRevisionReservedForUndo()

        let originalElement: CanvasElement?
        switch kind {
        case .editing(let elementID):
            originalElement = try element(id: elementID)
        case .inserting(let elementID), .freehand(let elementID):
            guard !document.elements.contains(where: { $0.id == elementID }) else {
                throw CanvasPreviewError.duplicateElement(elementID)
            }
            originalElement = nil
        case .text(let elementID):
            if let elementID {
                let existing = try element(id: elementID)
                guard case .text = existing.geometry else {
                    throw CanvasPreviewError.invalidPayload
                }
                originalElement = existing
            } else {
                originalElement = nil
            }
        case .erasing:
            originalElement = nil
        }

        let token = CanvasPreviewToken()
        preview = CanvasInteractionPreview(
            token: token,
            kind: kind,
            originalElement: originalElement,
            payload: nil,
            predictedInkSamples: [],
            revision: .zero
        )
        presentationRevision.advance()
        return token
    }

    package func updatePreview(
        _ payload: CanvasPreviewPayload,
        token: CanvasPreviewToken
    ) throws {
        guard var preview, preview.token == token else {
            throw CanvasPreviewError.invalidOwner
        }
        try validate(payload, for: preview.kind)
        preview.payload = payload
        preview.revision.advance()
        self.preview = preview
        if case .element(let element) = payload {
            dimensionPreviewElement = element
            dimensionPresentationRevision.advance()
        }
        presentationRevision.advance()
    }

    package func appendFreehandPreview(
        id: UUID,
        style: CanvasStyle,
        points: [CanvasPoint],
        token: CanvasPreviewToken
    ) throws {
        try appendFreehandInkPreview(
            id: id,
            style: style,
            confirmed: points.map { CanvasInkSample(point: $0, pressure: 1) },
            predicted: [],
            pressureEnabled: false,
            widthMode: .canvasScaled,
            token: token
        )
    }

    package func appendFreehandInkPreview(
        id: UUID,
        style: CanvasStyle,
        confirmed: [CanvasInkSample],
        predicted: [CanvasInkSample],
        pressureEnabled: Bool,
        widthMode: CanvasInkWidthMode = .canvasScaled,
        token: CanvasPreviewToken
    ) throws {
        guard var preview, preview.token == token else {
            throw CanvasPreviewError.invalidOwner
        }
        guard case .freehand(let elementID) = preview.kind,
              elementID == id,
              !confirmed.isEmpty,
              (confirmed + predicted).allSatisfy({ sample in
                  sample.point.x.isFinite && sample.point.y.isFinite
                      && sample.pressure.isFinite && (0 ... 1).contains(sample.pressure)
              }) else {
            throw CanvasPreviewError.invalidPayload
        }
        try style.validate()

        self.preview = nil
        switch preview.payload {
        case .freehand(let draft):
            guard draft.id == id, draft.style == style,
                  draft.pressureEnabled == pressureEnabled,
                  draft.widthMode == widthMode else {
                self.preview = preview
                throw CanvasPreviewError.invalidPayload
            }
            draft.append(confirmed)
            preview.payload = .freehand(draft)
        case nil:
            let draft = CanvasFreehandDraft(
                id: id,
                style: style,
                pressureEnabled: pressureEnabled,
                widthMode: widthMode
            )
            draft.append(confirmed)
            preview.payload = .freehand(draft)
        case .element, .erasedElementIDs:
            self.preview = preview
            throw CanvasPreviewError.invalidPayload
        }
        preview.predictedInkSamples = predicted
        preview.revision.advance()
        self.preview = preview
        presentationRevision.advance()
    }

    package func commitPreview(token: CanvasPreviewToken) throws {
        guard let preview, preview.token == token else {
            throw CanvasPreviewError.invalidOwner
        }
        guard let command = try command(for: preview) else {
            self.preview = nil
            clearDimensionPreview()
            presentationRevision.advance()
            return
        }
        let committedDraft: CanvasFreehandDraft?
        if case .freehand(let draft) = preview.payload {
            committedDraft = draft
        } else {
            committedDraft = nil
        }
        var candidateDocument = document
        var candidateHistory = history
        if committedDraft != nil,
           case .insert(let element, let index) = command {
            try candidateHistory.performPrevalidatedFreehandInsertion(
                element,
                at: index,
                on: &candidateDocument
            )
        } else {
            try candidateHistory.perform(command, on: &candidateDocument)
        }
        document = candidateDocument
        history = candidateHistory
        if let committedDraft,
           let documentIndex = document.elements.firstIndex(where: { $0.id == committedDraft.id }) {
            let element = document.elements[documentIndex]
            committedFreehandHandoff = CanvasCommittedFreehandHandoff(
                documentRevision: document.revision,
                documentIndex: documentIndex,
                elementID: element.id,
                contentRevision: element.contentRevision,
                draft: committedDraft
            )
        } else {
            committedFreehandHandoff = nil
        }
        self.preview = nil
        clearDimensionPreview()
        presentationRevision.advance()
        reconcileSelection()
        notifyDocumentChange()
    }

    package func cancelPreview(token: CanvasPreviewToken) throws {
        guard let preview, preview.token == token else {
            throw CanvasPreviewError.invalidOwner
        }
        self.preview = nil
        clearDimensionPreview()
        presentationRevision.advance()
    }

    public func replaceDocument(_ document: CanvasDocument) throws {
        try document.validate()

        documentReplacementGeneration.advance()
        presentationRevision.advance()
        self.document = document
        history.removeAll()
        committedFreehandHandoff = nil
        preview = nil
        clearDimensionPreview()
        selectedElementID = nil
        hiddenDimensionKeys.removeAll()
        notifyDocumentChange()
    }

    public func setStrokeStyle(_ style: CanvasStyle) throws {
        try style.validate()
        strokeStyle = style
    }

    public func setInkConfiguration(_ configuration: CanvasInkConfiguration) {
        inkConfiguration = configuration
    }

    public func setTextStyle(_ style: CanvasTextStyle) throws {
        try style.validate()
        textStyle = style
    }

    public func setSnapConfiguration(_ configuration: SnapConfiguration) throws {
        try configuration.validate()
        snapConfiguration = configuration
    }

    package var effectiveSnapConfiguration: SnapConfiguration {
        var result = snapConfiguration
        result.isEnabled = result.isEnabled && configuration.allows(.snapping)
        return result
    }

    public func setViewport(_ viewport: CanvasViewport) {
        self.viewport = viewport
    }

    public func setViewportSize(_ size: CanvasSize) throws {
        let viewport = try CanvasViewport(
            zoom: viewport.zoom,
            translation: viewport.translation,
            viewportSize: size
        )
        setViewport(viewport)
    }

    private func requireNoActivePreview() throws {
        guard preview == nil else {
            throw CanvasPreviewError.previewAlreadyActive
        }
    }

    private func clearDimensionPreview() {
        guard dimensionPreviewElement != nil else { return }
        dimensionPreviewElement = nil
        dimensionPresentationRevision.advance()
    }

    private func requireRevisionReservedForUndo(in document: CanvasDocument? = nil) throws {
        let revision = document?.revision ?? self.document.revision
        // Reserve one revision for this commit and one for its immediately advertised undo.
        guard revision < UInt64.max - 2 else {
            throw CanvasSessionError.revisionExhausted
        }
    }

    private func reconcileSelection() {
        guard let selectedElementID,
              !document.elements.contains(where: { $0.id == selectedElementID }) else {
            return
        }
        self.selectedElementID = nil
    }

    private func notifyDocumentChange() {
        onDocumentChange?(document)
    }

    private func element(id: UUID) throws -> CanvasElement {
        guard let element = document.elements.first(where: { $0.id == id }) else {
            throw CanvasPreviewError.elementNotFound(id)
        }
        return element
    }

    private func validate(
        _ payload: CanvasPreviewPayload,
        for kind: CanvasPreviewKind
    ) throws {
        switch (kind, payload) {
        case (.editing(let elementID), .element(let element)):
            guard element.id == elementID else { throw CanvasPreviewError.invalidPayload }
        case (.inserting(let elementID), .element(let element)):
            guard element.id == elementID else { throw CanvasPreviewError.invalidPayload }
        case (.freehand(let elementID), .freehand(let draft)):
            guard draft.id == elementID,
                  !document.elements.contains(where: { $0.id == draft.id }),
                  !draft.samples.isEmpty else {
                throw CanvasPreviewError.invalidPayload
            }
            try draft.style.validate()
            return
        case (.text(let elementID), .element(let element)):
            guard case .text = element.geometry else {
                throw CanvasPreviewError.invalidPayload
            }
            if let elementID {
                guard element.id == elementID else { throw CanvasPreviewError.invalidPayload }
            } else {
                guard !document.elements.contains(where: { $0.id == element.id }) else {
                    throw CanvasPreviewError.duplicateElement(element.id)
                }
            }
        case (.erasing, .erasedElementIDs(let ids)):
            var seen: Set<UUID> = []
            guard ids.allSatisfy({ id in
                seen.insert(id).inserted
                    && document.elements.contains(where: { $0.id == id })
            }) else {
                throw CanvasPreviewError.invalidPayload
            }
            return
        default:
            throw CanvasPreviewError.invalidPayload
        }

        guard let previewElement = payload.materializedElement else {
            throw CanvasPreviewError.invalidPayload
        }
        if case .inserting = kind, !configuration.allows(CanvasTool.tool(for: previewElement.geometry)) {
            throw CanvasSessionError.featureDisabled
        }
        var candidate = document
        if let index = candidate.elements.firstIndex(where: { $0.id == previewElement.id }) {
            candidate.elements[index] = previewElement
        } else {
            candidate.elements.append(previewElement)
        }
        try candidate.validate()
    }

    private func command(for preview: CanvasInteractionPreview) throws -> CanvasCommand? {
        guard let payload = preview.payload else { return nil }
        if case .erasedElementIDs(let ids) = payload {
            return ids.isEmpty ? nil : .removeMany(ids: ids)
        }
        guard let previewElement = payload.materializedElement else {
            throw CanvasPreviewError.invalidPayload
        }
        guard let original = preview.originalElement else {
            return .insert(previewElement, at: document.elements.endIndex)
        }
        let geometryChanged = original.geometry != previewElement.geometry
        let styleChanged = original.style != previewElement.style
        guard !geometryChanged || !styleChanged else {
            throw CanvasPreviewError.invalidPayload
        }
        if geometryChanged {
            if case .text(let text) = previewElement.geometry {
                return .setText(id: original.id, text)
            }
            return .setGeometry(id: original.id, previewElement.geometry)
        }
        if styleChanged {
            return .setStyle(id: original.id, previewElement.style)
        }
        return nil
    }
}

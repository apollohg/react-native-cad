import Foundation
import DrawCanvasCore

private struct CanvasScalarInterval {
    let lower: Double
    let upper: Double

    static func exact(_ value: Double) -> Self? {
        guard value.isFinite else { return nil }
        return Self(lower: value, upper: value)
    }

    static func enclosingRounded(_ value: Double) -> Self? {
        guard value.isFinite,
              value.nextDown.isFinite,
              value.nextUp.isFinite else {
            return nil
        }
        return Self(lower: value.nextDown, upper: value.nextUp)
    }

    var containsZero: Bool {
        lower <= 0 && upper >= 0
    }

    var isExactZero: Bool {
        lower == 0 && upper == 0
    }

    func adding(_ other: Self) -> Self? {
        if isExactZero { return other }
        if other.isExactZero { return self }
        return Self.enclosing(lower + other.lower, upper + other.upper)
    }

    func subtracting(_ other: Self) -> Self? {
        if lower == upper,
           other.lower == other.upper,
           lower == other.lower {
            return Self.exact(0)
        }
        return Self.enclosing(lower - other.upper, upper - other.lower)
    }

    func multiplied(by other: Self) -> Self? {
        if isExactZero || other.isExactZero { return Self.exact(0) }
        let products = [
            lower * other.lower,
            lower * other.upper,
            upper * other.lower,
            upper * other.upper,
        ]
        guard products.allSatisfy(\.isFinite),
              let minimum = products.min(),
              let maximum = products.max() else {
            return nil
        }
        return Self.enclosing(minimum, maximum)
    }

    func divided(by other: Self) -> Self? {
        guard !other.containsZero else { return nil }
        let quotients = [
            lower / other.lower,
            lower / other.upper,
            upper / other.lower,
            upper / other.upper,
        ]
        guard quotients.allSatisfy(\.isFinite),
              let minimum = quotients.min(),
              let maximum = quotients.max() else {
            return nil
        }
        return Self.enclosing(minimum, maximum)
    }

    func intersectingUnitInterval() -> Self? {
        let intersection = Self(lower: max(0, lower), upper: min(1, upper))
        return intersection.lower <= intersection.upper ? intersection : nil
    }

    func intersecting(_ other: Self) -> Self? {
        let intersection = Self(
            lower: max(lower, other.lower),
            upper: min(upper, other.upper)
        )
        return intersection.lower <= intersection.upper ? intersection : nil
    }

    func rescaled(
        by positiveScale: Double,
        clampedTo finiteHull: Self
    ) -> Self? {
        guard positiveScale.isFinite, positiveScale > 0 else { return nil }
        let scaledLower = lower * positiveScale
        let scaledUpper = upper * positiveScale
        guard !scaledLower.isNaN, !scaledUpper.isNaN else { return nil }

        let enclosingLower = scaledLower.isFinite
            ? max(finiteHull.lower, scaledLower.nextDown)
            : finiteHull.lower
        let enclosingUpper = scaledUpper.isFinite
            ? min(finiteHull.upper, scaledUpper.nextUp)
            : finiteHull.upper
        guard enclosingLower.isFinite,
              enclosingUpper.isFinite,
              enclosingLower <= enclosingUpper else {
            return nil
        }
        return Self(lower: enclosingLower, upper: enclosingUpper)
    }

    private static func enclosing(_ lower: Double, _ upper: Double) -> Self? {
        guard lower.isFinite,
              upper.isFinite,
              lower.nextDown.isFinite,
              upper.nextUp.isFinite else {
            return nil
        }
        return Self(lower: lower.nextDown, upper: upper.nextUp)
    }
}

@MainActor
final class CanvasScenePreparer {
    private struct CommittedRenderContent: Equatable {
        let geometry: CanvasGeometry
        let style: CanvasStyle

        init(element: CanvasElement) {
            geometry = element.geometry
            style = element.style
        }
    }

    private enum PendingInkMutation {
        case full(
            ink: CanvasPreparedInk,
            confirmed: [CanvasInkSample],
            predicted: [CanvasInkSample],
            isFinalized: Bool
        )
        case incremental(
            ink: CanvasPreparedInk,
            candidate: CanvasPreparedInk.IncrementalCandidate
        )

        var ink: CanvasPreparedInk {
            switch self {
            case .full(let ink, _, _, _), .incremental(let ink, _):
                return ink
            }
        }
    }

    private static let maximumGridLineCount = 10_000
    private static let maximumPreparedInkSampleCount = 1_000_000

    private var geometryCache: [CanvasRenderKey: CanvasPreparedGeometry] = [:]
    private var previewInkCache: [UUID: CanvasPreparedInk] = [:]
    private var committedRenderContent: [CanvasRenderKey: CommittedRenderContent] = [:]
    private var lastPreparedDocumentRevision: UInt64?
    private var lastPreparedReplacementGeneration: RecognitionGeneration?
    private var committedSnapshot: CanvasCommittedPreparedSnapshot?
    private(set) var statistics = CanvasScenePreparationStatistics()
    private(set) var lastPresentation: CanvasPreparedPresentation?

    func prepare(
        document: CanvasDocument,
        preview: CanvasRenderPreview?,
        viewport: CanvasViewport,
        selectedElementID: UUID?,
        editingTextIDs: Set<UUID>,
        guides: [SnapGuide],
        gridSpacing: Double,
        theme: CanvasThemeSnapshot,
        documentReplacementGeneration: RecognitionGeneration = .zero,
        viewportRenderPhase: CanvasViewportRenderPhase = .settled,
        committedFreehandHandoff: CanvasCommittedFreehandHandoff? = nil
    ) throws -> CanvasPreparedPresentation {
        try validate(viewport)
        let visibleRect = try validatedVisibleRect(for: viewport)
        let gridPlan: CanvasGridPlan
        do {
            gridPlan = theme.showsGrid ? try CanvasGridPlanner.plan(
                visibleRect: visibleRect,
                baseSpacing: gridSpacing,
                maximumLineCount: Self.maximumGridLineCount
            ) : CanvasGridPlan(baseSpacing: gridSpacing, visualSpacing: gridSpacing, verticalCoordinates: [], horizontalCoordinates: [])
        } catch {
            throw CanvasScenePreparationError.invalidGrid
        }
        let committedGeneration = CanvasCommittedGeneration(
            documentRevision: document.revision,
            replacementGeneration: documentReplacementGeneration
        )
        let preparationKey = CanvasCommittedPreparationKey(
            generation: committedGeneration,
            viewport: viewport,
            theme: theme,
            selectedElementID: selectedElementID,
            editingTextIDs: editingTextIDs
        )
        if let committedSnapshot,
           committedSnapshot.key == preparationKey,
           let preview,
           preview.canReuseCommittedSnapshot,
           let draft = preview.freehandDraft,
           !committedSnapshot.elementIDs.contains(draft.id) {
            return try prepareFreehandInsertion(
                snapshot: committedSnapshot,
                draft: draft,
                preview: preview,
                viewport: viewport,
                selectedElementID: selectedElementID,
                guides: guides,
                gridPlan: gridPlan,
                visibleRect: visibleRect,
                theme: theme,
                viewportRenderPhase: viewportRenderPhase
            )
        }

        try validateUniqueElementIDs(in: document)

        let replacementChanged = lastPreparedReplacementGeneration.map {
            $0 != documentReplacementGeneration
        } ?? false
        var candidateCache = replacementChanged ? [:] : geometryCache
        var candidatePreviewInkCache = replacementChanged ? [:] : previewInkCache
        var candidateStatistics = statistics
        var pendingInkMutations: [PendingInkMutation] = []
        var retainedPreviewInkIDs = Set<UUID>()
        var preparedGeometry: [CanvasPreparedGeometry] = []
        var textDescriptors: [CanvasTextDescriptor] = []
        var selectionBounds: CanvasRect?
        var rebuiltRenderKeys = Set<CanvasRenderKey>()
        let composedElements = composedElements(document: document, preview: preview)
        let documentRevisionChanged = lastPreparedDocumentRevision != document.revision
        let documentContentChanged = documentRevisionChanged || replacementChanged
        let candidateCommittedRenderContent = documentContentChanged
            ? committedRenderContentSnapshot(for: document)
            : committedRenderContent

        for composed in composedElements {
            if case .committed = composed.renderKey {
                candidateStatistics.committedElementVisitCount += 1
            }
            let element = composed.element
            let isSelected = element.id == selectedElementID

            if case .text(let text) = element.geometry {
                guard isValid(text.frame) else {
                    throw CanvasScenePreparationError.invalidGeometryBounds
                }
                let isEditing = editingTextIDs.contains(element.id)
                if !isEditing {
                    guard isVisible(
                        bounds: text.frame,
                        lineWidth: 0,
                        selected: isSelected,
                        in: visibleRect,
                        viewport: viewport,
                        theme: theme
                    ) else {
                        continue
                    }
                }
                textDescriptors.append(CanvasTextDescriptor(
                    id: element.id,
                    contentRevision: element.contentRevision,
                    frame: text.frame,
                    text: text.text,
                    font: text.font,
                    color: text.color,
                    isSelected: isSelected,
                    isEditing: isEditing,
                    previewGeneration: composed.previewGeneration,
                    viewport: viewport,
                    theme: theme
                ))
                continue
            }

            let prepared: CanvasPreparedGeometry
            if let cached = candidateCache[composed.renderKey],
               canReuse(
                   composed.renderKey,
                   documentRevisionChanged: documentContentChanged,
                   candidateCommittedRenderContent: candidateCommittedRenderContent
               ) {
                prepared = cached
            } else {
                if let promoted = try promotedFreehandGeometry(
                    for: element,
                    renderKey: composed.renderKey,
                    document: document,
                    handoff: committedFreehandHandoff,
                    pendingInkMutations: &pendingInkMutations
                ) {
                    prepared = promoted.geometry
                    candidateStatistics.incrementalFreehandCommitCount += 1
                    candidateStatistics.incrementalFreehandCommitEvaluatedSpanCount +=
                        promoted.evaluatedSpanCount
                } else {
                    prepared = try buildGeometry(
                        for: element,
                        renderKey: composed.renderKey,
                        previewInkCache: &candidatePreviewInkCache,
                        pendingInkMutations: &pendingInkMutations
                    )
                }
                candidateCache[composed.renderKey] = prepared
                rebuiltRenderKeys.insert(composed.renderKey)
                candidateStatistics.geometryBuildCount += 1
                candidateStatistics.boundsBuildCount += 1
            }
            if composed.previewGeneration != nil,
               case .ink(let ink) = prepared.path {
                candidatePreviewInkCache[element.id] = ink
                retainedPreviewInkIDs.insert(element.id)
            }

            guard isVisible(
                bounds: prepared.bounds,
                lineWidth: prepared.style.lineWidth,
                maximumWidthFactor: maximumWidthFactor(for: prepared),
                selected: isSelected,
                in: visibleRect,
                viewport: viewport,
                theme: theme
            ) else {
                continue
            }
            if isSelected {
                selectionBounds = try self.selectionBounds(
                    for: prepared,
                    viewport: viewport
                )
            }
            preparedGeometry.append(prepared)
        }

        if let draft = preview?.freehandDraft,
           !document.elements.contains(where: { $0.id == draft.id }) {
            let predicted = preview?.predictedInkSamples ?? []
            guard draft.preparedInk.pressureEnabled == draft.pressureEnabled,
                  draft.preparedInk.widthMode == draft.widthMode,
                  draft.preparedInk.confirmedSamples.count <= draft.samples.count else {
                throw CanvasInkCurveError.invalidInput
            }
            let confirmedSuffix = Array(
                draft.samples.dropFirst(draft.preparedInk.confirmedSamples.count)
            )
            let incrementalCandidate: CanvasPreparedInk.IncrementalCandidate
            do {
                incrementalCandidate = try draft.preparedInk.makeIncrementalCandidate(
                    appendingConfirmed: confirmedSuffix,
                    predicted: predicted,
                    isFinalized: false
                )
            } catch CanvasInkCurveError.outputLimitExceeded {
                throw CanvasInkCurveError.outputLimitExceeded
            } catch {
                throw CanvasScenePreparationError.invalidGeometryBounds
            }
            let bounds = incrementalCandidate.confirmedBounds
            pendingInkMutations.append(.incremental(
                ink: draft.preparedInk,
                candidate: incrementalCandidate
            ))
            let prepared = CanvasPreparedGeometry(
                id: draft.id,
                renderKey: .preview(id: draft.id, generation: preview?.generation ?? .zero),
                path: .ink(draft.preparedInk),
                bounds: bounds,
                style: draft.style
            )
            candidatePreviewInkCache[draft.id] = draft.preparedInk
            retainedPreviewInkIDs.insert(draft.id)
            let isSelected = draft.id == selectedElementID
            if isVisible(
                bounds: bounds,
                lineWidth: draft.style.lineWidth,
                maximumWidthFactor: maximumWidthFactor(for: prepared),
                selected: isSelected,
                in: visibleRect,
                viewport: viewport,
                theme: theme
            ) {
                if isSelected {
                    selectionBounds = try self.selectionBounds(
                        for: prepared,
                        viewport: viewport
                    )
                }
                preparedGeometry.append(prepared)
            }
        }

        var committedItems: [CanvasCommittedItem] = []
        committedItems.reserveCapacity(document.elements.count)
        for (documentIndex, element) in document.elements.enumerated() {
            candidateStatistics.committedElementVisitCount += 1
            if case .text = element.geometry { continue }
            let renderKey = CanvasRenderKey.committed(
                id: element.id,
                contentRevision: element.contentRevision
            )
            let prepared: CanvasPreparedGeometry
            if let cached = candidateCache[renderKey],
               rebuiltRenderKeys.contains(renderKey) || canReuse(
                   renderKey,
                   documentRevisionChanged: documentContentChanged,
                   candidateCommittedRenderContent: candidateCommittedRenderContent
               ) {
                prepared = cached
            } else {
                var isolatedPreviewInkCache: [UUID: CanvasPreparedInk] = [:]
                prepared = try buildGeometry(
                    for: element,
                    renderKey: renderKey,
                    previewInkCache: &isolatedPreviewInkCache,
                    pendingInkMutations: &pendingInkMutations
                )
                candidateCache[renderKey] = prepared
                rebuiltRenderKeys.insert(renderKey)
                candidateStatistics.geometryBuildCount += 1
                candidateStatistics.boundsBuildCount += 1
            }
            committedItems.append(CanvasCommittedItem(
                documentIndex: documentIndex,
                geometry: prepared,
                paintedBounds: try paintedBounds(for: prepared)
            ))
        }

        let committedReplacement: CanvasCommittedReplacement?
        if let preview,
           preview.replacingElementID != nil,
           let replacementElement = preview.element,
           case .text = replacementElement.geometry {
            committedReplacement = nil
        } else if let preview,
                  let replacingElementID = preview.replacingElementID,
                  let replacementElement = preview.element,
                  let original = committedItems.first(where: {
                      $0.geometry.id == replacingElementID
                  }),
                  let replacementGeometry = candidateCache[.preview(
                      id: replacementElement.id,
                      generation: preview.generation
                  )] {
            committedReplacement = CanvasCommittedReplacement(
                documentIndex: original.documentIndex,
                originalGeometry: original.geometry,
                originalPaintedBounds: original.paintedBounds,
                replacementGeometry: replacementGeometry,
                replacementPaintedBounds: try paintedBounds(for: replacementGeometry)
            )
        } else {
            committedReplacement = nil
        }

        let retainedKeys = retainedCacheKeys(document: document, preview: preview)
        candidateCache = candidateCache.filter { retainedKeys.contains($0.key) }
        candidatePreviewInkCache = candidatePreviewInkCache.filter {
            retainedPreviewInkIDs.contains($0.key)
        }
        candidateStatistics.cachedGeometryCount = candidateCache.count

        let committedPresentation = CanvasCommittedPresentation(
            generation: committedGeneration,
            items: committedItems,
            replacement: committedReplacement
        )
        let committedGeometry = preparedGeometry.filter {
            if case .committed = $0.renderKey { return true }
            return false
        }
        let dynamicGeometry = preparedGeometry.filter {
            if case .preview = $0.renderKey { return true }
            return false
        }
        let elementIDs = Set(document.elements.map(\.id))
        let snapshotIsReusable = preview == nil || (
            preview?.canReuseCommittedSnapshot == true
                && preview?.freehandDraft.map { !elementIDs.contains($0.id) } == true
        )
        let candidateCommittedSnapshot = snapshotIsReusable
            ? CanvasCommittedPreparedSnapshot(
                key: preparationKey,
                visibleGeometry: committedGeometry,
                textDescriptors: textDescriptors.filter { $0.previewGeneration == nil },
                committed: committedPresentation,
                selectionBounds: selectedElementID.map { elementIDs.contains($0) } == true
                    ? selectionBounds
                    : nil,
                elementIDs: elementIDs
            )
            : nil
        let presentation = CanvasPreparedPresentation(
            scene: CanvasPreparedScene(
                committedGeometry: committedGeometry,
                dynamicGeometry: dynamicGeometry,
                orderedGeometry: preparedGeometry,
                gridLines: gridLines(from: gridPlan, visibleRect: visibleRect),
                selectionBounds: selectionBounds,
                guides: guides.filter(isFinite),
                viewport: viewport,
                theme: theme,
                previewGeneration: preview?.generation
            ),
            textDescriptors: textDescriptors,
            committed: committedPresentation,
            committedSnapshot: candidateCommittedSnapshot,
            viewportRenderPhase: viewportRenderPhase
        )

        var pendingInkIdentities = Set<ObjectIdentifier>()
        for pendingMutation in pendingInkMutations {
            guard pendingInkIdentities.insert(ObjectIdentifier(pendingMutation.ink)).inserted else {
                throw CanvasInkCurveError.invalidInput
            }
            if case .full(let ink, let confirmed, _, _) = pendingMutation,
               !canApply(
                   confirmed: confirmed,
                   to: ink,
                   pressureEnabled: ink.pressureEnabled,
                   widthMode: ink.widthMode
               ) {
                throw CanvasInkCurveError.invalidInput
            }
        }
        for pendingMutation in pendingInkMutations {
            let applied: Bool
            switch pendingMutation {
            case .full(let ink, let confirmed, let predicted, let isFinalized):
                applied = ink.apply(
                    confirmed: confirmed,
                    predicted: predicted,
                    isFinalized: isFinalized
                )
            case .incremental(let ink, let candidate):
                applied = ink.apply(candidate)
            }
            guard applied else {
                throw CanvasInkCurveError.invalidInput
            }
        }
        geometryCache = candidateCache
        previewInkCache = candidatePreviewInkCache
        committedRenderContent = candidateCommittedRenderContent
        lastPreparedDocumentRevision = document.revision
        lastPreparedReplacementGeneration = documentReplacementGeneration
        committedSnapshot = candidateCommittedSnapshot
        statistics = candidateStatistics
        lastPresentation = presentation
        return presentation
    }
}

private extension CanvasScenePreparer {
    func prepareFreehandInsertion(
        snapshot: CanvasCommittedPreparedSnapshot,
        draft: CanvasFreehandDraft,
        preview: CanvasRenderPreview,
        viewport: CanvasViewport,
        selectedElementID: UUID?,
        guides: [SnapGuide],
        gridPlan: CanvasGridPlan,
        visibleRect: CanvasRect,
        theme: CanvasThemeSnapshot,
        viewportRenderPhase: CanvasViewportRenderPhase
    ) throws -> CanvasPreparedPresentation {
        let predicted = preview.predictedInkSamples
        guard draft.preparedInk.pressureEnabled == draft.pressureEnabled,
              draft.preparedInk.widthMode == draft.widthMode,
              draft.preparedInk.confirmedSamples.count <= draft.samples.count else {
            throw CanvasInkCurveError.invalidInput
        }
        let confirmedSuffix = Array(
            draft.samples.dropFirst(draft.preparedInk.confirmedSamples.count)
        )
        let candidate: CanvasPreparedInk.IncrementalCandidate
        do {
            candidate = try draft.preparedInk.makeIncrementalCandidate(
                appendingConfirmed: confirmedSuffix,
                predicted: predicted,
                isFinalized: false
            )
        } catch CanvasInkCurveError.outputLimitExceeded {
            throw CanvasInkCurveError.outputLimitExceeded
        } catch {
            throw CanvasScenePreparationError.invalidGeometryBounds
        }

        let geometry = CanvasPreparedGeometry(
            id: draft.id,
            renderKey: .preview(id: draft.id, generation: preview.generation),
            path: .ink(draft.preparedInk),
            bounds: candidate.confirmedBounds,
            style: draft.style
        )
        var selectionBounds = snapshot.selectionBounds
        var dynamicGeometry: [CanvasPreparedGeometry] = []
        let isSelected = draft.id == selectedElementID
        if isVisible(
            bounds: geometry.bounds,
            lineWidth: geometry.style.lineWidth,
            maximumWidthFactor: maximumWidthFactor(for: geometry),
            selected: isSelected,
            in: visibleRect,
            viewport: viewport,
            theme: theme
        ) {
            if isSelected {
                selectionBounds = try self.selectionBounds(
                    for: geometry,
                    viewport: viewport
                )
            }
            dynamicGeometry.append(geometry)
        }

        let presentation = CanvasPreparedPresentation(
            scene: CanvasPreparedScene(
                committedGeometry: snapshot.visibleGeometry,
                dynamicGeometry: dynamicGeometry,
                gridLines: gridLines(from: gridPlan, visibleRect: visibleRect),
                selectionBounds: selectionBounds,
                guides: guides.filter(isFinite),
                viewport: viewport,
                theme: theme,
                previewGeneration: preview.generation
            ),
            textDescriptors: snapshot.textDescriptors,
            committed: snapshot.committed,
            committedSnapshot: snapshot,
            viewportRenderPhase: viewportRenderPhase
        )

        guard draft.preparedInk.apply(candidate) else {
            throw CanvasInkCurveError.invalidInput
        }
        previewInkCache = [draft.id: draft.preparedInk]
        lastPreparedDocumentRevision = snapshot.key.generation.documentRevision
        lastPreparedReplacementGeneration = snapshot.key.generation.replacementGeneration
        committedSnapshot = snapshot
        lastPresentation = presentation
        return presentation
    }

    struct ComposedElement {
        let element: CanvasElement
        let renderKey: CanvasRenderKey
        let previewGeneration: RecognitionGeneration?
    }

    private func committedRenderContentSnapshot(
        for document: CanvasDocument
    ) -> [CanvasRenderKey: CommittedRenderContent] {
        var snapshot: [CanvasRenderKey: CommittedRenderContent] = [:]
        snapshot.reserveCapacity(document.elements.count)
        for element in document.elements {
            if case .text = element.geometry {
                continue
            }
            let key = CanvasRenderKey.committed(
                id: element.id,
                contentRevision: element.contentRevision
            )
            snapshot[key] = CommittedRenderContent(element: element)
        }
        return snapshot
    }

    func validateUniqueElementIDs(in document: CanvasDocument) throws {
        var elementIDs = Set<UUID>()
        for (index, element) in document.elements.enumerated() {
            guard elementIDs.insert(element.id).inserted else {
                throw CanvasValidationError(
                    field: "elements[\(index)].id",
                    reason: "must be unique"
                )
            }
        }
    }

    private func canReuse(
        _ renderKey: CanvasRenderKey,
        documentRevisionChanged: Bool,
        candidateCommittedRenderContent: [CanvasRenderKey: CommittedRenderContent]
    ) -> Bool {
        guard documentRevisionChanged,
              case .committed = renderKey else {
            return true
        }
        return committedRenderContent[renderKey] == candidateCommittedRenderContent[renderKey]
    }

    func validate(_ viewport: CanvasViewport) throws {
        guard viewport.zoom.isFinite,
              viewport.zoom.isNormal,
              viewport.zoom > 0,
              viewport.translation.x.isFinite,
              viewport.translation.y.isFinite,
              viewport.viewportSize.width.isFinite,
              viewport.viewportSize.height.isFinite,
              viewport.viewportSize.width >= 0,
              viewport.viewportSize.height >= 0 else {
            throw CanvasScenePreparationError.invalidViewport
        }
    }

    func paintedBounds(for geometry: CanvasPreparedGeometry) throws -> CanvasRect {
        let expansion = geometry.style.lineWidth * maximumWidthFactor(for: geometry) / 2
        let bounds = CanvasRect(
            x: geometry.bounds.x - expansion,
            y: geometry.bounds.y - expansion,
            width: geometry.bounds.width + expansion * 2,
            height: geometry.bounds.height + expansion * 2
        )
        guard isValid(bounds) else {
            throw CanvasScenePreparationError.invalidGeometryBounds
        }
        return bounds
    }

    func validatedVisibleRect(for viewport: CanvasViewport) throws -> CanvasRect {
        let visibleRect = viewport.visibleCanvasRect
        guard visibleRect.isFinite,
              visibleRect.width >= 0,
              visibleRect.height >= 0,
              visibleRect.maxX.isFinite,
              visibleRect.maxY.isFinite else {
            throw CanvasScenePreparationError.invalidVisibleRect
        }
        return visibleRect
    }

    func composedElements(
        document: CanvasDocument,
        preview: CanvasRenderPreview?
    ) -> [ComposedElement] {
        var result: [ComposedElement] = []
        result.reserveCapacity(document.elements.count + (preview?.replacingElementID == nil ? 1 : 0))

        for committed in document.elements where !(preview?.hiddenElementIDs.contains(committed.id) ?? false) {
            if let preview,
               preview.replacingElementID == committed.id,
               let previewElement = preview.element {
                result.append(ComposedElement(
                    element: previewElement,
                    renderKey: .preview(id: previewElement.id, generation: preview.generation),
                    previewGeneration: preview.generation
                ))
            } else {
                result.append(ComposedElement(
                    element: committed,
                    renderKey: .committed(
                        id: committed.id,
                        contentRevision: committed.contentRevision
                    ),
                    previewGeneration: nil
                ))
            }
        }

        if let preview,
           preview.replacingElementID == nil,
           let previewElement = preview.element,
           !document.elements.contains(where: { $0.id == previewElement.id }) {
            result.append(ComposedElement(
                element: previewElement,
                renderKey: .preview(id: previewElement.id, generation: preview.generation),
                previewGeneration: preview.generation
            ))
        }
        return result
    }

    func retainedCacheKeys(
        document: CanvasDocument,
        preview: CanvasRenderPreview?
    ) -> Set<CanvasRenderKey> {
        var keys = Set(document.elements.compactMap { element -> CanvasRenderKey? in
            guard case .text = element.geometry else {
                return .committed(id: element.id, contentRevision: element.contentRevision)
            }
            return nil
        })
        if let previewElement = preview?.element,
           case .text = previewElement.geometry {
            return keys
        } else if let preview,
                  let previewElement = preview.element {
            keys.insert(.preview(id: previewElement.id, generation: preview.generation))
        }
        return keys
    }

    private func buildGeometry(
        for element: CanvasElement,
        renderKey: CanvasRenderKey,
        previewInkCache: inout [UUID: CanvasPreparedInk],
        pendingInkMutations: inout [PendingInkMutation]
    ) throws -> CanvasPreparedGeometry {
        let path: CanvasPreparedPath
        if case .freehand(let freehand) = element.geometry {
            let isFinalized: Bool
            switch renderKey {
            case .committed:
                isFinalized = true
            case .preview:
                isFinalized = false
            }
            if let retained = previewInkCache[element.id],
               canApply(
                   confirmed: freehand.samples,
                   to: retained,
                   pressureEnabled: freehand.pressureEnabled,
                   widthMode: freehand.widthMode
               ) {
                pendingInkMutations.append(.full(
                    ink: retained,
                    confirmed: freehand.samples,
                    predicted: [],
                    isFinalized: isFinalized
                ))
                path = .ink(retained)
            } else {
                let ink = CanvasPreparedInk(
                    confirmedSamples: freehand.samples,
                    predictedSamples: [],
                    pressureEnabled: freehand.pressureEnabled,
                    widthMode: freehand.widthMode,
                    isFinalized: isFinalized
                )
                if case .preview = renderKey {
                    previewInkCache[element.id] = ink
                }
                path = .ink(ink)
            }
        } else {
            if case .preview = renderKey {
                previewInkCache.removeValue(forKey: element.id)
            }
            path = .immutable(element.geometry.renderPath)
        }
        return CanvasPreparedGeometry(
            id: element.id,
            renderKey: renderKey,
            path: path,
            bounds: try preparedBounds(for: element.geometry),
            style: element.style
        )
    }

    private func promotedFreehandGeometry(
        for element: CanvasElement,
        renderKey: CanvasRenderKey,
        document: CanvasDocument,
        handoff: CanvasCommittedFreehandHandoff?,
        pendingInkMutations: inout [PendingInkMutation]
    ) throws -> (geometry: CanvasPreparedGeometry, evaluatedSpanCount: Int)? {
        guard let handoff,
              case .committed = renderKey,
              document.revision == handoff.documentRevision,
              document.elements.indices.contains(handoff.documentIndex),
              document.elements[handoff.documentIndex].id == element.id,
              element.id == handoff.elementID,
              element.contentRevision == handoff.contentRevision,
              element.id == handoff.draft.id,
              element.style == handoff.draft.style,
              case .freehand(let stroke) = element.geometry,
              stroke.pressureEnabled == handoff.draft.pressureEnabled,
              stroke.widthMode == handoff.draft.widthMode,
              stroke.samples.count == handoff.draft.samples.count,
              handoff.draft.preparedInk.confirmedSamples.count <= stroke.samples.count else {
            return nil
        }
        let suffix = Array(
            handoff.draft.samples.dropFirst(handoff.draft.preparedInk.confirmedSamples.count)
        )
        let candidate = try handoff.draft.preparedInk.makeIncrementalCandidate(
            appendingConfirmed: suffix,
            predicted: [],
            isFinalized: true
        )
        pendingInkMutations.append(.incremental(
            ink: handoff.draft.preparedInk,
            candidate: candidate
        ))
        return (
            CanvasPreparedGeometry(
                id: element.id,
                renderKey: renderKey,
                path: .ink(handoff.draft.preparedInk),
                bounds: candidate.confirmedBounds,
                style: element.style
            ),
            candidate.evaluatedSpanCount
        )
    }

    func canApply(
        confirmed: [CanvasInkSample],
        to ink: CanvasPreparedInk,
        pressureEnabled: Bool,
        widthMode: CanvasInkWidthMode
    ) -> Bool {
        ink.pressureEnabled == pressureEnabled
            && ink.widthMode == widthMode
            && ink.confirmedSamples.count <= confirmed.count
            && zip(ink.confirmedSamples, confirmed).allSatisfy { $0.0 == $0.1 }
    }

    func preparedBounds(for geometry: CanvasGeometry) throws -> CanvasRect {
        let bounds: CanvasRect
        if case .freehand(let stroke) = geometry {
            bounds = try preparedInkBounds(for: stroke)
        } else {
            bounds = geometry.bounds
        }
        guard isValid(bounds) else {
            throw CanvasScenePreparationError.invalidGeometryBounds
        }
        return bounds
    }

    func preparedInkBounds(for stroke: CanvasInkStroke) throws -> CanvasRect {
        do {
            if stroke.samples.count > Self.maximumPreparedInkSampleCount {
                _ = try CanvasInkCurve.flatten(stroke: stroke, maximumError: 1)
            }
            return try CanvasInkCurve.bounds(stroke: stroke)
        } catch CanvasInkCurveError.invalidInput {
            throw CanvasScenePreparationError.invalidGeometryBounds
        }
    }

    func selectionBounds(
        for geometry: CanvasPreparedGeometry,
        viewport: CanvasViewport
    ) throws -> CanvasRect {
        guard case .ink(let ink) = geometry.path else { return geometry.bounds }
        do {
            return try CanvasInkCurve.paintedBounds(
                centerlineBounds: geometry.bounds,
                lineWidth: geometry.style.lineWidth,
                viewportZoom: viewport.zoom,
                pressureEnabled: ink.pressureEnabled,
                widthMode: ink.widthMode
            )
        } catch {
            throw CanvasScenePreparationError.invalidGeometryBounds
        }
    }

    func conservativeControlBounds(for path: CanvasPath) -> CanvasRect? {
        var points: [CanvasPoint] = []
        for command in path.commands {
            switch command {
            case .move(let point), .line(let point):
                points.append(point)
            case .quad(let control, let end):
                points.append(control)
                points.append(end)
            case .cubic(let control1, let control2, let end):
                points.append(control1)
                points.append(control2)
                points.append(end)
            case .close:
                break
            }
        }
        guard let first = points.first else {
            return CanvasRect(x: 0, y: 0, width: 0, height: 0)
        }
        guard points.allSatisfy(isFinite) else { return nil }
        let minX = points.lazy.map(\.x).min() ?? first.x
        let maxX = points.lazy.map(\.x).max() ?? first.x
        let minY = points.lazy.map(\.y).min() ?? first.y
        let maxY = points.lazy.map(\.y).max() ?? first.y
        guard let width = enclosingExtent(from: minX, through: maxX),
              let height = enclosingExtent(from: minY, through: maxY) else {
            return nil
        }
        return CanvasRect(x: minX, y: minY, width: width, height: height)
    }

    func exactBounds(for path: CanvasPath) -> CanvasRect? {
        var points: [CanvasPoint] = []
        var currentPoint: CanvasPoint?
        var subpathStart: CanvasPoint?

        for command in path.commands {
            switch command {
            case .move(let point):
                points.append(point)
                currentPoint = point
                subpathStart = point

            case .line(let end):
                if let currentPoint {
                    points.append(currentPoint)
                }
                points.append(end)
                currentPoint = end
                if subpathStart == nil {
                    subpathStart = end
                }

            case .quad(let control, let end):
                guard let start = currentPoint else { return nil }
                points.append(start)
                points.append(end)
                guard let parameters = quadraticExtremumIntervals(
                    start: start,
                    control: control,
                    end: end
                ) else {
                    return nil
                }
                for parameter in parameters {
                    guard let bounds = quadraticPointBounds(
                        start: start,
                        control: control,
                        end: end,
                        at: parameter
                    ) else {
                        return nil
                    }
                    append(bounds, to: &points)
                }
                currentPoint = end

            case .cubic(let control1, let control2, let end):
                guard let start = currentPoint else { return nil }
                points.append(start)
                points.append(end)
                guard let parameters = cubicExtremumIntervals(
                    start: start,
                    control1: control1,
                    control2: control2,
                    end: end
                ) else {
                    return nil
                }
                for parameter in parameters {
                    guard let bounds = cubicPointBounds(
                        start: start,
                        control1: control1,
                        control2: control2,
                        end: end,
                        at: parameter
                    ) else {
                        return nil
                    }
                    append(bounds, to: &points)
                }
                currentPoint = end

            case .close:
                if let currentPoint {
                    points.append(currentPoint)
                }
                if let subpathStart {
                    points.append(subpathStart)
                    currentPoint = subpathStart
                }
            }
        }

        guard let first = points.first else {
            return CanvasRect(x: 0, y: 0, width: 0, height: 0)
        }
        guard points.allSatisfy(isFinite) else { return nil }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        guard let width = enclosingExtent(from: minX, through: maxX),
              let height = enclosingExtent(from: minY, through: maxY) else {
            return nil
        }
        let bounds = CanvasRect(
            x: minX,
            y: minY,
            width: width,
            height: height
        )
        return isValid(bounds) ? bounds : nil
    }

    func enclosingExtent(from minimum: Double, through maximum: Double) -> Double? {
        guard minimum.isFinite, maximum.isFinite, minimum <= maximum else { return nil }
        var extent = maximum - minimum
        guard extent.isFinite, extent >= 0 else { return nil }
        if minimum + extent < maximum {
            extent = extent.nextUp
        }
        guard extent.isFinite, minimum + extent >= maximum else { return nil }
        return extent
    }

    func quadraticExtremumIntervals(
        start: CanvasPoint,
        control: CanvasPoint,
        end: CanvasPoint
    ) -> [CanvasScalarInterval]? {
        guard let xIntervals = quadraticExtremumIntervals(
            start: start.x,
            control: control.x,
            end: end.x
        ), let yIntervals = quadraticExtremumIntervals(
            start: start.y,
            control: control.y,
            end: end.y
        ) else {
            return nil
        }
        return xIntervals + yIntervals
    }

    func quadraticExtremumIntervals(
        start: Double,
        control: Double,
        end: Double
    ) -> [CanvasScalarInterval]? {
        if start == control, control == end { return [] }
        guard let normalized = normalizedIntervals(for: [start, control, end]),
              let derivativeStart = normalized.values[1].subtracting(normalized.values[0]),
              let derivativeEnd = normalized.values[2].subtracting(normalized.values[1]) else {
            return nil
        }
        if derivativeStart.lower > 0, derivativeEnd.lower > 0 { return [] }
        if derivativeStart.upper < 0, derivativeEnd.upper < 0 { return [] }

        guard let twiceControl = normalized.values[1].multiplied(
            by: CanvasScalarInterval.exact(2)!
        ), let denominator = normalized.values[0]
            .subtracting(twiceControl)?
            .adding(normalized.values[2]) else {
            return nil
        }
        if denominator.containsZero { return nil }
        guard let numerator = normalized.values[0].subtracting(normalized.values[1]),
              let quotient = numerator.divided(by: denominator) else {
            return nil
        }
        return quotient.intersectingUnitInterval().map { [$0] } ?? []
    }

    func quadraticPointBounds(
        start: CanvasPoint,
        control: CanvasPoint,
        end: CanvasPoint,
        at parameter: CanvasScalarInterval
    ) -> (x: CanvasScalarInterval, y: CanvasScalarInterval)? {
        guard let x = bezierCoordinateBounds(
            controls: [start.x, control.x, end.x],
            at: parameter
        ), let y = bezierCoordinateBounds(
            controls: [start.y, control.y, end.y],
            at: parameter
        ) else {
            return nil
        }
        return (x, y)
    }

    func cubicExtremumIntervals(
        start: CanvasPoint,
        control1: CanvasPoint,
        control2: CanvasPoint,
        end: CanvasPoint
    ) -> [CanvasScalarInterval]? {
        guard let xIntervals = cubicExtremumIntervals(
            controls: [start.x, control1.x, control2.x, end.x]
        ), let yIntervals = cubicExtremumIntervals(
            controls: [start.y, control1.y, control2.y, end.y]
        ) else {
            return nil
        }
        return xIntervals + yIntervals
    }

    func cubicExtremumIntervals(controls: [Double]) -> [CanvasScalarInterval]? {
        guard controls.count == 4 else { return nil }
        if controls.dropFirst().allSatisfy({ $0 == controls[0] }) { return [] }
        guard let normalized = normalizedIntervals(for: controls),
              let firstDifference = normalized.values[1].subtracting(normalized.values[0]),
              let secondDifference = normalized.values[2].subtracting(normalized.values[1]),
              let thirdDifference = normalized.values[3].subtracting(normalized.values[2]),
              let three = CanvasScalarInterval.exact(3),
              let first = firstDifference.multiplied(by: three),
              let second = secondDifference.multiplied(by: three),
              let third = thirdDifference.multiplied(by: three) else {
            return nil
        }
        var budget = 256
        return isolateQuadraticBezierZeros(
            controls: [first, second, third],
            lowerParameter: 0,
            upperParameter: 1,
            remainingDepth: 40,
            budget: &budget
        )
    }

    func isolateQuadraticBezierZeros(
        controls: [CanvasScalarInterval],
        lowerParameter: Double,
        upperParameter: Double,
        remainingDepth: Int,
        budget: inout Int
    ) -> [CanvasScalarInterval] {
        guard controls.count == 3 else { return [] }
        if controls.allSatisfy({ $0.lower > 0 })
            || controls.allSatisfy({ $0.upper < 0 }) {
            return []
        }
        if lowerParameter == 0,
           controls[0].isExactZero,
           (controls.dropFirst().allSatisfy({ $0.lower > 0 })
               || controls.dropFirst().allSatisfy({ $0.upper < 0 })) {
            return []
        }
        if upperParameter == 1,
           controls[2].isExactZero,
           (controls.dropLast().allSatisfy({ $0.lower > 0 })
               || controls.dropLast().allSatisfy({ $0.upper < 0 })) {
            return []
        }
        let parameterInterval = CanvasScalarInterval(
            lower: lowerParameter,
            upper: upperParameter
        )
        guard remainingDepth > 0, budget > 0 else { return [parameterInterval] }
        let middleParameter = lowerParameter + ((upperParameter - lowerParameter) / 2)
        guard middleParameter > lowerParameter, middleParameter < upperParameter,
              let first = intervalMidpoint(controls[0], controls[1]),
              let second = intervalMidpoint(controls[1], controls[2]),
              let center = intervalMidpoint(first, second) else {
            return [parameterInterval]
        }
        budget -= 1
        return isolateQuadraticBezierZeros(
            controls: [controls[0], first, center],
            lowerParameter: lowerParameter,
            upperParameter: middleParameter,
            remainingDepth: remainingDepth - 1,
            budget: &budget
        ) + isolateQuadraticBezierZeros(
            controls: [center, second, controls[2]],
            lowerParameter: middleParameter,
            upperParameter: upperParameter,
            remainingDepth: remainingDepth - 1,
            budget: &budget
        )
    }

    func cubicPointBounds(
        start: CanvasPoint,
        control1: CanvasPoint,
        control2: CanvasPoint,
        end: CanvasPoint,
        at parameter: CanvasScalarInterval
    ) -> (x: CanvasScalarInterval, y: CanvasScalarInterval)? {
        guard let x = bezierCoordinateBounds(
            controls: [start.x, control1.x, control2.x, end.x],
            at: parameter
        ), let y = bezierCoordinateBounds(
            controls: [start.y, control1.y, control2.y, end.y],
            at: parameter
        ) else {
            return nil
        }
        return (x, y)
    }

    func bezierCoordinateBounds(
        controls: [Double],
        at parameter: CanvasScalarInterval
    ) -> CanvasScalarInterval? {
        guard let normalized = normalizedIntervals(for: controls),
              let one = CanvasScalarInterval.exact(1),
              let remaining = one.subtracting(parameter),
              let minimumControl = controls.min(),
              let maximumControl = controls.max() else {
            return nil
        }
        var level = normalized.values
        while level.count > 1 {
            var next: [CanvasScalarInterval] = []
            next.reserveCapacity(level.count - 1)
            for index in 0..<(level.count - 1) {
                guard let first = level[index].multiplied(by: remaining),
                      let second = level[index + 1].multiplied(by: parameter),
                      let value = first.adding(second) else {
                    return nil
                }
                next.append(value)
            }
            level = next
        }
        let normalizedHull = CanvasScalarInterval(
            lower: normalized.values.lazy.map(\.lower).min() ?? 0,
            upper: normalized.values.lazy.map(\.upper).max() ?? 0
        )
        let finiteHull = CanvasScalarInterval(
            lower: minimumControl,
            upper: maximumControl
        )
        guard let bounded = level[0].intersecting(normalizedHull) else { return nil }
        return bounded.rescaled(by: normalized.scale, clampedTo: finiteHull)
    }

    func normalizedIntervals(
        for values: [Double]
    ) -> (scale: Double, values: [CanvasScalarInterval])? {
        guard values.allSatisfy(\.isFinite) else { return nil }
        let maximumMagnitude = values.lazy.map(\.magnitude).max() ?? 0
        let scale: Double
        if maximumMagnitude == 0 {
            scale = 1
        } else {
            scale = maximumMagnitude.binade
        }
        guard scale.isFinite, scale > 0 else { return nil }
        var intervals: [CanvasScalarInterval] = []
        intervals.reserveCapacity(values.count)
        for value in values {
            let normalized = value / scale
            let interval: CanvasScalarInterval?
            if normalized * scale == value {
                interval = CanvasScalarInterval.exact(normalized)
            } else {
                interval = CanvasScalarInterval.enclosingRounded(normalized)
            }
            guard let interval else { return nil }
            intervals.append(interval)
        }
        return (scale, intervals)
    }

    func intervalMidpoint(
        _ first: CanvasScalarInterval,
        _ second: CanvasScalarInterval
    ) -> CanvasScalarInterval? {
        guard let half = CanvasScalarInterval.exact(0.5),
              let sum = first.adding(second) else {
            return nil
        }
        return sum.multiplied(by: half)
    }

    func append(
        _ bounds: (x: CanvasScalarInterval, y: CanvasScalarInterval),
        to points: inout [CanvasPoint]
    ) {
        points.append(CanvasPoint(x: bounds.x.lower, y: bounds.y.lower))
        points.append(CanvasPoint(x: bounds.x.upper, y: bounds.y.upper))
    }

    func gridLines(
        from plan: CanvasGridPlan,
        visibleRect: CanvasRect
    ) -> [CanvasPreparedGridLine] {
        func tier(_ coordinate: Double) -> CanvasGridTier {
            if coordinate == 0 { return .axis }
            let index = (coordinate / plan.visualSpacing).rounded()
            let majorInterval = 5.0
            return index.truncatingRemainder(dividingBy: majorInterval) == 0 ? .major : .minor
        }
        return plan.verticalCoordinates.map { coordinate in
            CanvasPreparedGridLine(
                start: .init(x: coordinate, y: visibleRect.minY),
                end: .init(x: coordinate, y: visibleRect.maxY),
                tier: tier(coordinate)
            )
        } + plan.horizontalCoordinates.map { coordinate in
            CanvasPreparedGridLine(
                start: .init(x: visibleRect.minX, y: coordinate),
                end: .init(x: visibleRect.maxX, y: coordinate),
                tier: tier(coordinate)
            )
        }
    }

    func isVisible(
        bounds: CanvasRect,
        lineWidth: Double,
        maximumWidthFactor: Double = 1,
        selected: Bool,
        in visibleRect: CanvasRect,
        viewport: CanvasViewport,
        theme: CanvasThemeSnapshot
    ) -> Bool {
        guard isValid(bounds) else { return false }

        var paintedExtent = positiveFinite(lineWidth)
            * positiveFinite(maximumWidthFactor)
            / 2
            / viewport.zoom
        if selected {
            paintedExtent = max(
                paintedExtent,
                positiveFinite(theme.selectionLineWidth) / 2 / viewport.zoom,
                positiveFinite(theme.handleSize) / 2 / viewport.zoom
            )
        }
        guard let expandedVisibleRect = expanded(visibleRect, by: paintedExtent) else {
            return false
        }
        return intersects(bounds, expandedVisibleRect)
    }

    func maximumWidthFactor(for geometry: CanvasPreparedGeometry) -> Double {
        guard case .ink(let ink) = geometry.path else { return 1 }
        return CanvasInkCurve.maximumWidthFactor(pressureEnabled: ink.pressureEnabled)
    }

    func positiveFinite(_ value: Double) -> Double {
        value.isFinite && value > 0 ? value : 0
    }

    func isValid(_ rect: CanvasRect) -> Bool {
        rect.isFinite
            && rect.width >= 0
            && rect.height >= 0
            && rect.maxX.isFinite
            && rect.maxY.isFinite
    }

    func expanded(_ rect: CanvasRect, by amount: Double) -> CanvasRect? {
        guard isValid(rect), amount.isFinite, amount >= 0 else { return nil }
        let minX = rect.minX - amount
        let maxX = rect.maxX + amount
        let minY = rect.minY - amount
        let maxY = rect.maxY + amount
        let expanded = CanvasRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
        return isValid(expanded) ? expanded : nil
    }

    func intersects(_ lhs: CanvasRect, _ rhs: CanvasRect) -> Bool {
        lhs.maxX >= rhs.minX
            && lhs.minX <= rhs.maxX
            && lhs.maxY >= rhs.minY
            && lhs.minY <= rhs.maxY
    }

    func isFinite(_ guide: SnapGuide) -> Bool {
        switch guide {
        case .vertical(let canvasX):
            canvasX.isFinite
        case .horizontal(let canvasY):
            canvasY.isFinite
        }
    }

    func isFinite(_ point: CanvasPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }
}

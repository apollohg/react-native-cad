import UIKit
import DrawCanvasCore

@MainActor
final class CanvasTextCoordinator: NSObject, UITextViewDelegate, @MainActor UIIndirectScribbleInteractionDelegate {
    typealias ElementIdentifier = String

    private let session: CanvasSession
    private let layoutEngine = CanvasTextLayoutEngine()
    private let snapConfigurationOverride: SnapConfiguration?

    private var effectiveSnapConfiguration: SnapConfiguration {
        var configuration = snapConfigurationOverride ?? session.snapConfiguration
        configuration.isEnabled = configuration.isEnabled && session.configuration.allows(.snapping)
        return configuration
    }
    private let makeElementID: () -> UUID
    private weak var hostView: UIView?
    private var overlays: [UUID: UITextView] = [:]
    private var activeEditingIDs: Set<UUID> = []
    private var dirtyEditingIDs: Set<UUID> = []
    private var transientEditingStrings: [UUID: String] = [:]
    private var newlyCreatedIDs: Set<UUID> = []
    private var editStates: [UUID: CanvasTextEditState] = [:]
    private var focusedElementID: UUID?
    private var dragStates: [UUID: CanvasTextDragState] = [:]
    private var isFinishingEditingSessions = false
    var onEditingStateChange: ((Bool) -> Void)?

    private(set) var scribbleInteraction: UIIndirectScribbleInteraction<CanvasTextCoordinator>?
    private(set) var isDismantled = false

    init(
        session: CanvasSession,
        snapConfiguration: SnapConfiguration? = nil,
        makeElementID: @escaping () -> UUID = UUID.init
    ) {
        self.session = session
        snapConfigurationOverride = snapConfiguration
        self.makeElementID = makeElementID
        super.init()
    }

    func install(on hostView: UIView) {
        if self.hostView !== hostView {
            let finishedAllEdits = finishEditingSessions()
            removeInstalledUI(preservingEditingState: !finishedAllEdits)
            self.hostView = hostView
        }
        isDismantled = false
        if scribbleInteraction == nil {
            let interaction = UIIndirectScribbleInteraction(delegate: self)
            hostView.addInteraction(interaction)
            scribbleInteraction = interaction
        }
        update()
    }

    func update() {
        let descriptors = session.presentationDocument.elements.compactMap { element -> CanvasTextDescriptor? in
            guard case .text(let text) = element.geometry else { return nil }
            return CanvasTextDescriptor(
                id: element.id,
                contentRevision: element.contentRevision,
                frame: text.frame,
                text: text.text,
                font: text.font,
                color: text.color,
                isSelected: session.selectedElementID == element.id,
                isEditing: activeEditingIDs.contains(element.id),
                previewGeneration: nil,
                viewport: session.viewport,
                theme: CanvasTheme.default.renderSnapshot
            )
        }
        update(descriptors: descriptors)
    }

    func update(descriptors: [CanvasTextDescriptor]) {
        guard !isDismantled else { return }
        discardStaleEditingStates()
        finishEditingForInactiveTool()
        let currentIDs = Set(descriptors.map(\.id))

        for id in Set(overlays.keys).subtracting(currentIDs) {
            removeOverlay(id: id)
        }

        for descriptor in descriptors {
            let view = overlays[descriptor.id] ?? makeOverlay(for: descriptor.id)
            if view.superview !== hostView {
                hostView?.addSubview(view)
            } else {
                hostView?.bringSubviewToFront(view)
            }
            let text = CanvasText(
                frame: descriptor.frame,
                text: descriptor.text,
                font: descriptor.font,
                color: descriptor.color
            )
            let element = CanvasElement(
                id: descriptor.id,
                contentRevision: descriptor.contentRevision,
                geometry: .text(text)
            )
            configure(view, element: element, text: text)
        }
    }

    func finishEditingForInactiveTool() {
        if session.activeTool != .text || !session.configuration.allows(.text) {
            _ = finishEditingSessions()
        }
    }

    func dismantle() {
        guard !isDismantled else { return }
        _ = finishEditingSessions()
        removeInstalledUI()
        hostView = nil
        activeEditingIDs.removeAll()
        notifyEditingStateChange()
        dirtyEditingIDs.removeAll()
        transientEditingStrings.removeAll()
        newlyCreatedIDs.removeAll()
        editStates.removeAll()
        focusedElementID = nil
        dragStates.removeAll()
        isDismantled = true
    }

    func cancelEditingSessions() {
        let states = editStates
        for (id, state) in states {
            do {
                try session.cancelPreview(token: state.token)
            } catch {
                overlays[id]?.resignFirstResponder()
                continue
            }
            overlays[id]?.resignFirstResponder()
        }
        for id in states.keys {
            clearEditingState(id: id)
        }
        update()
    }

    func overlayView(for id: UUID) -> UITextView? {
        overlays[id]
    }

    func containsOverlayView(_ view: UIView?) -> Bool {
        var candidate = view
        while let current = candidate {
            if overlays.values.contains(where: { $0 === current }) {
                return true
            }
            candidate = current.superview
        }
        return false
    }

    func identifier(for id: UUID) -> String {
        id.uuidString
    }

    func elementID(for identifier: String) -> UUID? {
        UUID(uuidString: identifier)
    }

    func hitTest(screenPoint: CGPoint, screenTolerance: CGFloat = 0) -> UUID? {
        guard let canvasPoint = canvasPoint(from: screenPoint),
              screenTolerance.isFinite, screenTolerance >= 0,
              validViewport,
              let tolerance = finiteDouble(screenTolerance / CGFloat(session.viewport.zoom)) else {
            return nil
        }
        return session.presentationDocument.elements.reversed().first { element in
            guard case .text = element.geometry else { return false }
            return element.geometry.hitTest(
                canvasPoint,
                tolerance: tolerance,
                textBounds: element.bounds
            )
        }?.id
    }

    @discardableResult
    func createText(atScreenPoint screenPoint: CGPoint, focus: Bool = true) -> UUID? {
        guard let canvasPoint = canvasPoint(from: screenPoint) else { return nil }
        return createText(atCanvasPoint: canvasPoint, focus: focus)
    }

    @discardableResult
    func createText(atCanvasPoint canvasPoint: CanvasPoint, focus: Bool = true) -> UUID? {
        guard session.configuration.allows(.text), finite(canvasPoint), validViewport,
              session.document.revision < UInt64.max - 2 else {
            return nil
        }
        let snap = SnapEngine.snap(
            point: canvasPoint,
            excluding: nil,
            elements: session.document.elements,
            viewport: session.viewport,
            configuration: effectiveSnapConfiguration
        )
        guard finite(snap.point) else { return nil }

        let id = makeUniqueElementID()
        let width = defaultTextWidth
        guard let frame = layoutEngine.measure(
            text: "",
            font: session.textStyle.font,
            origin: snap.point,
            width: width
        ) else {
            return nil
        }
        let text = CanvasText(
            frame: frame,
            text: "",
            font: session.textStyle.font,
            color: session.textStyle.color
        )
        let element = CanvasElement(id: id, geometry: .text(text))
        do {
            let token = try session.acquirePreview(.text(elementID: nil))
            try session.updatePreview(.element(element), token: token)
            editStates[id] = CanvasTextEditState(
                token: token,
                replacementGeneration: session.documentReplacementGeneration,
                original: nil,
                draft: text
            )
        } catch {
            return nil
        }
        newlyCreatedIDs.insert(id)
        session.selectedElementID = id
        update()
        if focus { focusElement(id) }
        return id
    }

    func handleTextToolTap(atCanvasPoint canvasPoint: CanvasPoint) {
        guard finite(canvasPoint), validViewport else { return }
        let screen = session.viewport.screenPoint(fromCanvas: canvasPoint)
        guard finite(screen),
              let x = finiteCGFloat(screen.x),
              let y = finiteCGFloat(screen.y) else {
            return
        }
        if let id = hitTest(screenPoint: CGPoint(x: x, y: y)) {
            focusElement(id)
        } else {
            _ = createText(atCanvasPoint: canvasPoint)
        }
    }

    @discardableResult
    func moveElement(id: UUID, toScreenPoint screenPoint: CGPoint) -> Bool {
        guard let endpoint = canvasPoint(from: screenPoint) else { return false }
        return moveElement(id: id, toCanvasPoint: endpoint)
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        guard let id = id(for: textView), beginEditing(id: id) else { return }
        activeEditingIDs.insert(id)
        notifyEditingStateChange()
        transientEditingStrings[id] = textView.text ?? ""
        focusedElementID = id
        session.selectedElementID = id
    }

    func textViewDidChange(_ textView: UITextView) {
        guard let id = id(for: textView), activeEditingIDs.contains(id) else { return }
        _ = updateEdit(id: id, text: textView.text ?? "")
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        guard let id = id(for: textView) else { return }
        finishEditing(id: id, text: textView.text ?? "")
    }

    func indirectScribbleInteraction(
        _ interaction: any UIInteraction,
        requestElementsIn rect: CGRect,
        completion: @escaping ([String]) -> Void
    ) {
        guard session.activeTool == .text && session.configuration.allows(.text), finite(rect) else {
            completion([])
            return
        }
        var identifiers = session.presentationDocument.elements.compactMap { element -> String? in
            guard case .text = element.geometry,
                  let frame = scribbleFrame(for: element),
                  frame.intersects(rect) else {
                return nil
            }
            return identifier(for: element.id)
        }

        if identifiers.isEmpty, session.activeTool == .text && session.configuration.allows(.text) {
            let point = CGPoint(x: rect.midX, y: rect.midY)
            if let id = createText(atScreenPoint: point, focus: false) {
                identifiers = [identifier(for: id)]
            }
        }
        completion(identifiers)
    }

    func indirectScribbleInteraction(
        _ interaction: any UIInteraction,
        isElementFocused elementIdentifier: String
    ) -> Bool {
        guard session.activeTool == .text && session.configuration.allows(.text),
              let id = elementID(for: elementIdentifier) else { return false }
        return focusedElementID == id || overlays[id]?.isFirstResponder == true
    }

    func indirectScribbleInteraction(
        _ interaction: any UIInteraction,
        frameForElement elementIdentifier: String
    ) -> CGRect {
        guard session.activeTool == .text && session.configuration.allows(.text),
              let id = elementID(for: elementIdentifier),
              let element = element(id: id),
              let frame = scribbleFrame(for: element) else {
            return .null
        }
        return frame
    }

    func indirectScribbleInteraction(
        _ interaction: any UIInteraction,
        focusElementIfNeeded elementIdentifier: String,
        referencePoint focusReferencePoint: CGPoint,
        completion: @escaping ((any UIResponder & UITextInput)?) -> Void
    ) {
        guard session.activeTool == .text && session.configuration.allows(.text),
              let id = elementID(for: elementIdentifier), element(id: id) != nil else {
            completion(nil)
            return
        }
        update()
        focusElement(id)
        completion(overlays[id])
    }

    func indirectScribbleInteraction(
        _ interaction: any UIInteraction,
        willBeginWritingInElement elementIdentifier: String
    ) {
        guard session.activeTool == .text && session.configuration.allows(.text),
              let id = elementID(for: elementIdentifier) else { return }
        focusElement(id)
    }

    func indirectScribbleInteraction(
        _ interaction: any UIInteraction,
        didFinishWritingInElement elementIdentifier: String
    ) {
        guard session.activeTool == .text && session.configuration.allows(.text),
              let id = elementID(for: elementIdentifier),
              activeEditingIDs.contains(id),
              let view = overlays[id],
              let current = element(id: id),
              case .text(let text) = current.geometry else {
            return
        }
        let transient = view.text ?? ""
        transientEditingStrings[id] = transient
        if transient != text.text {
            dirtyEditingIDs.insert(id)
        }
        update()
    }
}

extension CanvasTextCoordinator {
    var defaultTextWidth: Double { 240 }

    var validViewport: Bool {
        let viewport = session.viewport
        return viewport.zoom.isFinite && viewport.zoom > 0
            && finite(viewport.translation)
            && viewport.viewportSize.width.isFinite
            && viewport.viewportSize.height.isFinite
            && viewport.viewportSize.width >= 0
            && viewport.viewportSize.height >= 0
    }

    func makeOverlay(for id: UUID) -> UITextView {
        let view = UITextView(frame: .zero)
        view.delegate = self
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.accessibilityIdentifier = identifier(for: id)
        let drag = UIPanGestureRecognizer(target: self, action: #selector(handleDrag(_:)))
        drag.maximumNumberOfTouches = 1
        drag.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        drag.cancelsTouchesInView = false
        view.addGestureRecognizer(drag)
        overlays[id] = view
        hostView?.addSubview(view)
        return view
    }

    func configure(_ view: UITextView, element: CanvasElement, text: CanvasText) {
        let isEditing = activeEditingIDs.contains(element.id)
        if isEditing {
            view.text = transientEditingStrings[element.id] ?? view.text ?? text.text
        } else {
            view.text = text.text
        }
        view.isUserInteractionEnabled = session.activeTool == .text && session.configuration.allows(.text)
        guard let frame = screenFrame(
            for: element,
            minimumEditingTarget: isEditing || text.text.isEmpty
        ),
              let screenPointSize = finiteDouble(text.font.pointSize * session.viewport.zoom),
              screenPointSize > 0 else {
            view.frame = .zero
            view.isHidden = true
            return
        }
        view.isHidden = false
        view.frame = frame
        let resolved = layoutEngine.resolvedFont(text.font)
        view.font = resolved.withSize(CGFloat(screenPointSize))
        view.textColor = uiColor(text.color)
    }

    func screenFrame(
        for element: CanvasElement,
        minimumEditingTarget: Bool = false
    ) -> CGRect? {
        guard validViewport else { return nil }
        let bounds = element.bounds
        guard bounds.isFinite, bounds.width >= 0, bounds.height >= 0 else { return nil }
        let origin = session.viewport.screenPoint(fromCanvas: .init(x: bounds.x, y: bounds.y))
        guard finite(origin),
              let x = finiteCGFloat(origin.x),
              let y = finiteCGFloat(origin.y),
              let transformedWidth = finiteCGFloat(bounds.width * session.viewport.zoom),
              let transformedHeight = finiteCGFloat(bounds.height * session.viewport.zoom),
              let width = finiteDimension(transformedWidth, minimum: minimumEditingTarget ? 44 : 0),
              let height = finiteDimension(transformedHeight, minimum: minimumEditingTarget ? 44 : 0),
              width >= 0, height >= 0 else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    func scribbleFrame(for element: CanvasElement) -> CGRect? {
        if let view = overlays[element.id], !view.isHidden, finite(view.frame) {
            return view.frame
        }
        guard case .text(let text) = element.geometry else { return nil }
        return screenFrame(for: element, minimumEditingTarget: text.text.isEmpty)
    }

    func canvasPoint(from screenPoint: CGPoint) -> CanvasPoint? {
        guard validViewport,
              let screenX = finiteDouble(screenPoint.x),
              let screenY = finiteDouble(screenPoint.y) else {
            return nil
        }
        let point = session.viewport.canvasPoint(fromScreen: .init(x: screenX, y: screenY))
        return finite(point) ? point : nil
    }

    func moveElement(id: UUID, toCanvasPoint endpoint: CanvasPoint) -> Bool {
        guard session.configuration.allows(.text), session.configuration.allows(.selectionMovement), finite(endpoint), validViewport,
              session.document.revision < UInt64.max - 2,
              let current = committedElement(id: id),
              case .text(var text) = current.geometry,
              current.contentRevision < UInt64.max - 1 else {
            return false
        }
        let snapped = SnapEngine.snap(
            point: endpoint,
            excluding: id,
            elements: session.document.elements,
            viewport: session.viewport,
            configuration: effectiveSnapConfiguration
        ).point
        guard finite(snapped) else { return false }
        if text.frame.x == snapped.x, text.frame.y == snapped.y { return true }
        text.frame.x = snapped.x
        text.frame.y = snapped.y
        do {
            let token = try session.acquirePreview(.text(elementID: id))
            try session.updatePreview(
                .element(CanvasElement(
                    id: id,
                    contentRevision: current.contentRevision,
                    geometry: .text(text),
                    style: current.style
                )),
                token: token
            )
            try session.commitPreview(token: token)
        } catch {
            return false
        }
        update()
        return true
    }

    func beginEditing(id: UUID) -> Bool {
        guard session.configuration.allows(.text) else { return false }
        if editStates[id] != nil { return true }
        guard let current = committedElement(id: id),
              case .text(let text) = current.geometry else {
            return false
        }
        do {
            let token = try session.acquirePreview(.text(elementID: id))
            editStates[id] = CanvasTextEditState(
                token: token,
                replacementGeneration: session.documentReplacementGeneration,
                original: text,
                draft: text
            )
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func updateEdit(id: UUID, text string: String) -> Bool {
        guard var edit = editStates[id],
              edit.replacementGeneration == session.documentReplacementGeneration,
              let source = element(id: id) else {
            return false
        }
        let width = edit.draft.frame.width > 0 ? edit.draft.frame.width : defaultTextWidth
        guard let frame = layoutEngine.measure(
            text: string,
            font: edit.draft.font,
            origin: .init(x: edit.draft.frame.x, y: edit.draft.frame.y),
            width: width
        ) else {
            return false
        }
        edit.draft.text = string
        edit.draft.frame = frame
        let element = CanvasElement(
            id: id,
            contentRevision: source.contentRevision,
            geometry: .text(edit.draft),
            style: source.style
        )
        do {
            try session.updatePreview(.element(element), token: edit.token)
        } catch {
            return false
        }
        editStates[id] = edit
        transientEditingStrings[id] = string
        if edit.original?.text != string {
            dirtyEditingIDs.insert(id)
        } else {
            dirtyEditingIDs.remove(id)
        }
        update()
        return true
    }

    func discardStaleEditingStates() {
        let staleIDs = editStates.compactMap { id, state in
            state.replacementGeneration == session.documentReplacementGeneration ? nil : id
        }
        for id in staleIDs {
            overlays[id]?.resignFirstResponder()
            clearEditingState(id: id)
        }
    }

    @discardableResult
    func finishEditing(id: UUID, text newText: String) -> Bool {
        guard var edit = editStates[id] else { return true }
        guard edit.replacementGeneration == session.documentReplacementGeneration else {
            clearEditingState(id: id)
            update()
            return true
        }
        if edit.draft.text != newText {
            guard updateEdit(id: id, text: newText), let refreshed = editStates[id] else {
                return false
            }
            edit = refreshed
        }

        if edit.original == nil, edit.draft.text.isEmpty {
            do {
                try session.cancelPreview(token: edit.token)
            } catch {
                return false
            }
            clearEditingState(id: id)
            update()
            return true
        }

        do {
            try session.commitPreview(token: edit.token)
        } catch {
            return false
        }
        clearEditingState(id: id)
        update()
        return true
    }

    func focusElement(_ id: UUID) {
        guard let view = overlays[id], beginEditing(id: id) else { return }
        activeEditingIDs.insert(id)
        notifyEditingStateChange()
        if transientEditingStrings[id] == nil,
           let current = element(id: id),
           case .text(let text) = current.geometry {
            transientEditingStrings[id] = text.text
        }
        focusedElementID = id
        session.selectedElementID = id
        _ = view.becomeFirstResponder()
    }

    func element(id: UUID) -> CanvasElement? {
        session.presentationDocument.elements.first { $0.id == id }
    }

    func committedElement(id: UUID) -> CanvasElement? {
        session.document.elements.first { $0.id == id }
    }

    func id(for textView: UITextView) -> UUID? {
        overlays.first { $0.value === textView }?.key
    }

    func makeUniqueElementID() -> UUID {
        var candidate = makeElementID()
        while session.document.elements.contains(where: { $0.id == candidate }) {
            candidate = UUID()
        }
        return candidate
    }

    func removeOverlay(id: UUID, preservingEditingState: Bool = false) {
        guard let view = overlays.removeValue(forKey: id) else { return }
        view.delegate = nil
        view.resignFirstResponder()
        view.removeFromSuperview()
        if !preservingEditingState {
            clearEditingState(id: id)
        }
        dragStates[id] = nil
    }

    func removeInstalledUI(preservingEditingState: Bool = false) {
        if let interaction = scribbleInteraction {
            hostView?.removeInteraction(interaction)
            scribbleInteraction = nil
        }
        for id in Array(overlays.keys) {
            removeOverlay(id: id, preservingEditingState: preservingEditingState)
        }
    }

    @objc func handleDrag(_ recognizer: UIPanGestureRecognizer) {
        guard session.activeTool == .text && session.configuration.allows(.text),
              let view = recognizer.view as? UITextView,
              let id = id(for: view),
              let hostView else {
            return
        }
        switch recognizer.state {
        case .began:
            guard !view.isFirstResponder else {
                recognizer.isEnabled = false
                recognizer.isEnabled = true
                return
            }
            guard let point = canvasPoint(from: recognizer.location(in: hostView)) else { return }
            _ = beginDrag(id: id, at: point)
        case .changed:
            guard let point = canvasPoint(from: recognizer.location(in: hostView)) else { return }
            _ = updateDrag(id: id, to: point)
        case .ended:
            guard let point = canvasPoint(from: recognizer.location(in: hostView)) else { return }
            _ = endDrag(id: id, at: point)
        case .cancelled, .failed:
            cancelDrag(id: id)
        default:
            break
        }
    }

    @discardableResult
    func finishEditingSessions() -> Bool {
        guard !isFinishingEditingSessions else { return false }
        isFinishingEditingSessions = true
        defer { isFinishingEditingSessions = false }
        var finishedAllEdits = true
        let endingIDs = activeEditingIDs.union(newlyCreatedIDs)
        for id in endingIDs {
            guard let view = overlays[id] else {
                finishedAllEdits = false
                continue
            }
            let finished = finishEditing(id: id, text: view.text ?? "")
            finishedAllEdits = finishedAllEdits && finished
            if finished { view.resignFirstResponder() }
        }
        return finishedAllEdits
    }

    func beginDrag(id: UUID, at point: CanvasPoint) -> Bool {
        guard session.configuration.allows(.text), session.configuration.allows(.selectionMovement) else { return false }
        guard finite(point), dragStates[id] == nil,
              let element = committedElement(id: id),
              case .text(let text) = element.geometry else {
            return false
        }
        do {
            let token = try session.acquirePreview(.text(elementID: id))
            dragStates[id] = CanvasTextDragState(
                token: token,
                replacementGeneration: session.documentReplacementGeneration,
                element: element,
                startFrame: text.frame,
                startCanvasPoint: point
            )
            return true
        } catch {
            return false
        }
    }

    func updateDrag(id: UUID, to point: CanvasPoint) -> Bool {
        guard session.configuration.allows(.text), session.configuration.allows(.selectionMovement) else { return false }
        guard finite(point), let drag = dragStates[id],
              drag.replacementGeneration == session.documentReplacementGeneration,
              case .text(var text) = drag.element.geometry else {
            return false
        }
        let delta = CanvasPoint(
            x: point.x - drag.startCanvasPoint.x,
            y: point.y - drag.startCanvasPoint.y
        )
        guard finite(delta) else { return false }
        let unsnapped = CanvasPoint(
            x: drag.startFrame.x + delta.x,
            y: drag.startFrame.y + delta.y
        )
        let snapped = SnapEngine.snap(
            point: unsnapped,
            excluding: id,
            elements: session.document.elements,
            viewport: session.viewport,
            configuration: effectiveSnapConfiguration
        ).point
        guard finite(snapped) else { return false }
        text.frame.x = snapped.x
        text.frame.y = snapped.y
        let previewElement = CanvasElement(
            id: id,
            contentRevision: drag.element.contentRevision,
            geometry: .text(text),
            style: drag.element.style
        )
        do {
            try session.updatePreview(.element(previewElement), token: drag.token)
        } catch {
            return false
        }
        update()
        return true
    }

    func endDrag(id: UUID, at point: CanvasPoint) -> Bool {
        guard let drag = dragStates[id], updateDrag(id: id, to: point) else { return false }
        do {
            try session.commitPreview(token: drag.token)
        } catch {
            return false
        }
        dragStates[id] = nil
        update()
        return true
    }

    func cancelDrag(id: UUID) {
        guard let drag = dragStates.removeValue(forKey: id) else { return }
        do {
            try session.cancelPreview(token: drag.token)
        } catch {
            return
        }
        update()
    }

    func clearEditingState(id: UUID) {
        activeEditingIDs.remove(id)
        notifyEditingStateChange()
        dirtyEditingIDs.remove(id)
        transientEditingStrings[id] = nil
        newlyCreatedIDs.remove(id)
        editStates[id] = nil
        if focusedElementID == id { focusedElementID = nil }
    }

    func uiColor(_ color: CanvasColor) -> UIColor {
        guard color.red.isFinite, color.green.isFinite, color.blue.isFinite, color.alpha.isFinite else {
            return .black
        }
        return UIColor(
            red: CGFloat(color.red),
            green: CGFloat(color.green),
            blue: CGFloat(color.blue),
            alpha: CGFloat(color.alpha)
        )
    }

    var isEditing: Bool {
        !activeEditingIDs.isEmpty
    }

    func notifyEditingStateChange() {
        onEditingStateChange?(isEditing)
    }
}

private struct CanvasTextDragState {
    let token: CanvasPreviewToken
    let replacementGeneration: CanvasGeneration
    let element: CanvasElement
    let startFrame: CanvasRect
    let startCanvasPoint: CanvasPoint
}

private func finite(_ point: CanvasPoint) -> Bool {
    point.x.isFinite && point.y.isFinite
}

private func finite(_ rect: CGRect) -> Bool {
    rect.origin.x.isFinite && rect.origin.y.isFinite
        && rect.size.width.isFinite && rect.size.height.isFinite
}

private func finiteDouble(_ value: CGFloat) -> Double? {
    let result = Double(value)
    return result.isFinite ? result : nil
}

private func finiteDouble(_ value: Double) -> Double? {
    value.isFinite ? value : nil
}

private func finiteCGFloat(_ value: Double) -> CGFloat? {
    let result = CGFloat(value)
    return result.isFinite ? result : nil
}

private func finiteDimension(_ value: CGFloat, minimum: CGFloat) -> CGFloat? {
    guard value.isFinite, minimum.isFinite, minimum >= 0 else { return nil }
    return max(value, minimum)
}

import SwiftUI
import UIKit
import CadCanvasCore

@MainActor
public struct CadCanvasView: UIViewRepresentable {
    @Environment(\.canvasTheme) private var theme
    private let session: CanvasSession
    private let recognizer: (any ShapeRecognizing)?
    private let renderer: any CanvasRenderer
    private let commandActions: CanvasCommandActions?
    private let pencilShortcutHandler: CanvasPencilShortcutHandler?

    public init(
        session: CanvasSession,
        recognizer: (any ShapeRecognizing)? = HeuristicShapeRecognizer(),
        renderer: (any CanvasRenderer)? = nil,
        rendererStatus: CanvasRendererStatus? = nil,
        pencilShortcutHandler: CanvasPencilShortcutHandler? = nil
    ) {
        self.session = session
        self.recognizer = recognizer
        self.renderer = renderer ?? AdaptiveCanvasRenderer(
            diagnosticHandler: { [weak session] diagnostic in
                session?.onDiagnostic?(diagnostic)
            },
            status: rendererStatus
        )
        self.pencilShortcutHandler = pencilShortcutHandler
        commandActions = nil
    }

    public init(
        commandActions: CanvasCommandActions,
        recognizer: (any ShapeRecognizing)? = HeuristicShapeRecognizer(),
        renderer: (any CanvasRenderer)? = nil,
        rendererStatus: CanvasRendererStatus? = nil,
        pencilShortcutHandler: CanvasPencilShortcutHandler? = nil
    ) {
        self.session = commandActions.session
        self.recognizer = recognizer
        self.renderer = renderer ?? AdaptiveCanvasRenderer(
            diagnosticHandler: { [weak session = commandActions.session] diagnostic in
                session?.onDiagnostic?(diagnostic)
            },
            status: rendererStatus
        )
        self.pencilShortcutHandler = pencilShortcutHandler
        self.commandActions = commandActions
    }

    public func makeCoordinator() -> CadCanvasCoordinator {
        let coordinator = CadCanvasCoordinator(
            session: session,
            recognizer: recognizer,
            renderer: renderer,
            theme: theme,
            pencilShortcutHandler: pencilShortcutHandler
        )
        coordinator.reconcileCommandActions(commandActions)
        return coordinator
    }

    public func makeUIView(context: Context) -> UIView {
        context.coordinator.makeHostView()
    }

    public func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.reconcileCommandActions(commandActions)
        context.coordinator.reconcilePencilShortcutHandler(pencilShortcutHandler)
        context.coordinator.update(theme: theme)
    }

    public static func dismantleUIView(_ uiView: UIView, coordinator: CadCanvasCoordinator) {
        coordinator.dismantle()
    }
}

enum RecognitionExecutor {
    nonisolated static func recognize(
        _ request: RecognitionRequest,
        with recognizer: any ShapeRecognizing
    ) async -> RecognitionResult? {
        guard !Task.isCancelled else { return nil }
        let sample = StrokeSample(points: request.points)
        let result = recognizer.recognize(sample)
        return Task.isCancelled ? nil : result
    }
}

@MainActor
public final class CadCanvasCoordinator {
    private let session: CanvasSession
    private let recognizer: (any ShapeRecognizing)?
    private let renderer: any CanvasRenderer
    private let displayReportingRenderer: (any CanvasDisplayReportingRenderer)?
    private let timestampedDisplayReportingRenderer: (
        any CanvasTimestampedDisplayReportingRenderer
    )?
    private let performanceSignposts: CanvasPerformanceSignposts
    private var theme: CanvasTheme
    private var observedConfiguration: CanvasConfiguration
    private let textCoordinator: CanvasTextCoordinator
    private let paletteActions: CanvasActions
    private let pencilPalettePresenter: any CanvasPencilPalettePresenting
    private let preparePresentation: (CanvasPresentationInput) throws -> CanvasPreparedPresentation
    private var reducer: CanvasInteractionReducer
    private var proposedElementID = UUID()
    private var transientPreview: CanvasElement?
    private var transientPreviewRevision = CanvasGeneration.zero
    private var snapGuides: [SnapGuide] = []
    private var eraserTargetID: UUID?
    private var recognitionTasks: [UUID: Task<Void, Never>] = [:]
    private var observedReplacementGeneration: CanvasGeneration
    private var observedViewport: CanvasViewport
    private var gestureCoordinator: CanvasGestureCoordinator?
    private var gestureDelegateProxy: CanvasGestureDelegateProxy?
    private var pencilHoverCoordinator: CanvasPencilHoverCoordinator?
    private var pencilShortcutCoordinator: CanvasPencilShortcutCoordinator?
    private var pencilShortcutHandler: CanvasPencilShortcutHandler?
    private var isPencilTransactionActive = false
    private weak var commandActions: CanvasCommandActions?
    private weak var hostView: CanvasHostView?
    private var lastCompletePresentation: CanvasPreparedPresentation?
    private var lastFailedPresentationRevision: CanvasGeneration?

    private(set) var isDismantled = false

    init(
        session: CanvasSession,
        recognizer: (any ShapeRecognizing)?,
        renderer: any CanvasRenderer,
        theme: CanvasTheme = .default,
        performanceSignposts: CanvasPerformanceSignposts = .shared,
        pencilShortcutHandler: CanvasPencilShortcutHandler? = nil,
        pencilPalettePresenter: (any CanvasPencilPalettePresenting)? = nil,
        preparePresentation: ((CanvasPresentationInput) throws -> CanvasPreparedPresentation)? = nil
    ) {
        self.session = session
        self.recognizer = recognizer
        self.renderer = renderer
        displayReportingRenderer = renderer as? any CanvasDisplayReportingRenderer
        timestampedDisplayReportingRenderer = renderer as? any CanvasTimestampedDisplayReportingRenderer
        self.performanceSignposts = performanceSignposts
        self.theme = theme
        observedConfiguration = session.configuration
        self.pencilShortcutHandler = pencilShortcutHandler
        paletteActions = CanvasActions(session: session)
        self.pencilPalettePresenter = pencilPalettePresenter
            ?? CanvasPencilPalettePresenter(diagnose: { [weak session] diagnostic in
                session?.onDiagnostic?(diagnostic)
            })
        if let preparePresentation {
            self.preparePresentation = preparePresentation
        } else {
            let preparer = CanvasPresentationPreparer()
            self.preparePresentation = { try preparer.prepare($0) }
        }
        textCoordinator = CanvasTextCoordinator(session: session)
        reducer = CanvasInteractionReducer(activeTool: session.activeTool)
        observedReplacementGeneration = session.documentReplacementGeneration
        observedViewport = session.viewport
        textCoordinator.onEditingStateChange = { [weak self] isEditing in
            self?.commandActions?.setTextEditing(isEditing)
        }
        self.pencilPalettePresenter.update(theme: theme)
    }

    func makeHostView() -> CanvasHostView {
        if let hostView { return hostView }
        isDismantled = false
        let renderView: UIView
        if let timestampedDisplayReportingRenderer {
            renderView = timestampedDisplayReportingRenderer.makeRenderView(
                displayCompletion: { [weak self] generation, presentedTime in
                    self?.performanceSignposts.completeDisplay(
                        through: generation,
                        at: presentedTime
                    )
                }
            )
        } else if let displayReportingRenderer {
            renderView = displayReportingRenderer.makeRenderView { [weak self] generation in
                self?.performanceSignposts.completeDisplay(
                    through: generation,
                    at: ProcessInfo.processInfo.systemUptime
                )
            }
        } else {
            renderView = renderer.makeRenderView()
        }
        let host = CanvasHostView(renderView: renderView)
        textCoordinator.install(on: host)
        host.sendPencil = { [weak self] phase, confirmed, predicted in
            self?.sendPencil(phase, confirmed: confirmed, predicted: predicted)
        }
        host.sendPencilCancelled = { [weak self] in
            self?.sendPencilCancelled()
        }
        host.didLayout = { [weak self] size in
            self?.updateViewportSize(size)
        }
        let gestures = CanvasGestureCoordinator(
            viewport: { [weak session] in
                session?.viewport ?? (try! .identity(size: .init(width: 0, height: 0)))
            },
            elements: { [weak session] in
                session?.document.elements ?? []
            },
            canManipulate: { [weak self] point in
                self?.canManipulate(at: point) ?? false
            },
            send: { [weak self] input in
                self?.receive(input)
            }
        )
        gestures.install(on: host)
        let delegateProxy = CanvasGestureDelegateProxy(
            gestureCoordinator: gestures,
            textCoordinator: textCoordinator
        )
        for recognizer in gestures.recognizers {
            recognizer.delegate = delegateProxy
        }
        gestureCoordinator = gestures
        gestureDelegateProxy = delegateProxy
        let hover = CanvasPencilHoverCoordinator { [weak self] screenPoint in
            self?.sendPencilHover(screenPoint)
        }
        hover.install(on: host)
        pencilHoverCoordinator = hover
        let shortcuts = CanvasPencilShortcutCoordinator(
            preferredAction: { UIPencilInteraction.preferredSqueezeAction },
            fallbackAnchor: { [weak host] in
                guard let host else { return CanvasPoint(x: 0, y: 0) }
                return CanvasPoint(
                    x: Double(host.bounds.midX),
                    y: Double(host.bounds.midY)
                )
            },
            isPencilTransactionActive: { [weak self] in
                self?.isPencilTransactionActive ?? false
            },
            send: { [weak self] context in
                self?.dispatchPencilShortcut(context)
            },
            diagnose: { [weak session] diagnostic in
                session?.onDiagnostic?(diagnostic)
            }
        )
        shortcuts.install(on: host)
        pencilShortcutCoordinator = shortcuts
        host.tintColor = theme.controlTint?.uiColor
        hostView = host
        observeSession()
        return host
    }

    func update() {
        guard !isDismantled, let hostView else { return }
        synchronizeExternalState()
        textCoordinator.finishEditingForInactiveTool()
        do {
            let presentation = try preparePresentation(presentationInput())
            lastCompletePresentation = presentation
            lastFailedPresentationRevision = nil
            if let presentationRenderer = renderer as? any CanvasPreparedPresentationRendering {
                presentationRenderer.update(presentation, in: hostView.renderView)
            } else {
                renderer.update(presentation.scene, in: hostView.renderView)
            }
            textCoordinator.update(descriptors: presentation.textDescriptors)
        } catch {
            performanceSignposts.cancelAll()
            if lastFailedPresentationRevision != session.presentationRevision {
                lastFailedPresentationRevision = session.presentationRevision
                session.onDiagnostic?(.scenePreparationFailed(
                    error as? CanvasScenePreparationError ?? .invalidGeometryBounds
                ))
            }
        }
    }

    func update(theme: CanvasTheme) {
        self.theme = theme
        pencilPalettePresenter.update(theme: theme)
        hostView?.tintColor = theme.controlTint?.uiColor
        update()
    }

    func receive(_ input: CanvasInput) {
        guard !isDismantled else { return }
        synchronizeExternalState()
        if case .tap(let point) = input, session.activeTool == .text, session.configuration.allows(.text) {
            textCoordinator.handleTextToolTap(atCanvasPoint: point)
            update()
            return
        }
        let previousPencilGeneration = input.isPencilBatch ? activePencilGeneration : nil
        let effects = reducer.reduce(input, in: context())
        apply(effects)
        if displayReportingRenderer != nil,
           input.isPencilBatch,
           let generation = activePencilGeneration,
           generation != previousPencilGeneration {
            performanceSignposts.begin(generation: generation)
        }
        if input.cancelsPencilLatency {
            performanceSignposts.cancelAll()
        }
        update()
    }

    func dismantle() {
        guard !isDismantled else { return }
        cancelRecognitionTasks()
        performanceSignposts.cancelAll()
        let effects = reducer.reduce(.cancel, in: context())
        apply(effects, allowRecognition: false)
        textCoordinator.dismantle()
        pencilPalettePresenter.dismiss()
        pencilShortcutCoordinator?.uninstall()
        pencilHoverCoordinator?.uninstall()
        if let hostView {
            (renderer as? any CanvasRenderDismantling)?.dismantleRenderView(hostView.renderView)
        }
        (renderer as? any CanvasRenderCacheResetting)?.resetDerivedRenderCaches()
        if let hostView, let gestureCoordinator {
            for recognizer in gestureCoordinator.recognizers {
                recognizer.delegate = nil
            }
            gestureCoordinator.uninstall()
            hostView.sendPencil = nil
            hostView.sendPencilCancelled = nil
            hostView.didLayout = nil
        }
        commandActions?.detach(from: self)
        commandActions = nil
        gestureDelegateProxy = nil
        gestureCoordinator = nil
        pencilHoverCoordinator = nil
        pencilShortcutCoordinator = nil
        pencilShortcutHandler = nil
        isPencilTransactionActive = false
        eraserTargetID = nil
        transientPreview = nil
        snapGuides = []
        isDismantled = true
    }

    func attachCommandActions(_ actions: CanvasCommandActions) {
        guard commandActions !== actions else { return }
        commandActions?.detach(from: self)
        commandActions = actions
        actions.setTextEditing(textCoordinator.isEditing)
    }

    func reconcileCommandActions(_ actions: CanvasCommandActions?) {
        if let actions {
            actions.attach(to: self)
        } else if let commandActions {
            commandActions.detach(from: self)
            self.commandActions = nil
        }
    }

    func reconcilePencilShortcutHandler(_ handler: CanvasPencilShortcutHandler?) {
        pencilShortcutHandler = handler
    }

    func detachCommandActions(_ actions: CanvasCommandActions) {
        guard commandActions === actions else { return }
        commandActions = nil
    }

    func cancelActiveInteraction() {
        guard !isDismantled else { return }
        cancelRecognitionTasks()
        performanceSignposts.cancelAll()
        pencilShortcutCoordinator?.cancelPendingAction()
        isPencilTransactionActive = false
        apply(reducer.reduce(.cancel, in: context()), allowRecognition: false)
        transientPreview = nil
        snapGuides = []
        textCoordinator.cancelEditingSessions()
        update()
    }

    func sendPencilHover(_ screenPoint: CGPoint?) {
        guard !isDismantled else { return }
        synchronizeExternalState()
        let previousTarget = eraserTargetID
        guard session.activeTool == .eraser else {
            if previousTarget != nil {
                apply(reducer.reduce(.pencilHover(nil), in: context()))
                update()
            }
            return
        }
        guard let screenPoint else {
            apply(reducer.reduce(.pencilHover(nil), in: context()))
            if eraserTargetID != previousTarget { update() }
            return
        }
        let screen = CanvasPoint(x: Double(screenPoint.x), y: Double(screenPoint.y))
        guard screen.x.isFinite, screen.y.isFinite else {
            apply(reducer.reduce(.pencilHover(nil), in: context()))
            if eraserTargetID != previousTarget { update() }
            return
        }
        let canvas = session.viewport.canvasPoint(fromScreen: screen)
        guard canvas.x.isFinite, canvas.y.isFinite else {
            apply(reducer.reduce(.pencilHover(nil), in: context()))
            if eraserTargetID != previousTarget { update() }
            return
        }
        apply(reducer.reduce(.pencilHover(canvas), in: context()))
        if eraserTargetID != previousTarget { update() }
    }

    func dispatchPencilShortcut(_ context: CanvasPencilShortcutContext) {
        synchronizeExternalState()
        guard session.configuration.allows(.pencilShortcuts) else { return }
        if context.action == .showColorPalette {
            let control: CanvasControl = session.mostRecentStyleTool == .text ? .textColor : .strokeColor
            guard session.configuration.shows(control) else { return }
        }
        if context.action == .showInkAttributes {
            let style = CanvasControlLayoutPolicy.styleSection(for: session.mostRecentStyleTool)
            guard CanvasControlLayoutPolicy.sections(for: session.mostRecentStyleTool, configuration: session.configuration)
                .contains(.style(style)) else { return }
        }
        if let pencilShortcutHandler,
           case .handled = pencilShortcutHandler(context) {
            pencilPalettePresenter.dismiss()
            return
        }

        switch context.action {
        case .switchEraser:
            session.toggleEraser()
        case .switchPreviousTool:
            session.selectPreviousTool()
        case .showColorPalette, .showInkAttributes, .showContextualPalette:
            guard let hostView else {
                session.onDiagnostic?(.pencilPalettePresentationUnavailable)
                return
            }
            pencilPalettePresenter.toggle(
                context.action,
                anchor: context.screenAnchor,
                hostView: hostView,
                actions: paletteActions,
                styleTool: session.mostRecentStyleTool
            )
        }
        update()
    }
}

private extension CadCanvasCoordinator {
    func context() -> CanvasInteractionContext {
        CanvasInteractionContext(
            documentID: session.document.id,
            viewport: session.viewport,
            elements: session.document.elements,
            selectedElementID: session.selectedElementID,
            proposedElementID: proposedElementID,
            documentReplacementGeneration: session.documentReplacementGeneration,
            documentRevision: session.document.revision,
            snapConfiguration: session.effectiveSnapConfiguration,
            strokeStyle: session.strokeStyle,
            inkConfiguration: session.inkConfiguration,
            recognitionEnabled: recognizer != nil && session.configuration.allows(.shapeRecognition),
            configuration: session.configuration
        )
    }

    func apply(_ effects: [CanvasEffect], allowRecognition: Bool = true) {
        for effect in effects {
            switch effect {
            case .setViewport(let viewport):
                session.setViewport(viewport)
                observedViewport = session.viewport
                eraserTargetID = nil
            case .select(let id):
                session.selectedElementID = id
            case .requestPreview(let kind):
                do {
                    let token = try session.acquirePreview(kind)
                    apply(reducer.reduce(.previewAcquired(token), in: context()))
                } catch {
                    apply(reducer.reduce(.previewRejected, in: context()))
                }
            case .updatePreview(let payload, let token):
                do {
                    try session.updatePreview(payload, token: token)
                } catch {
                    apply(reducer.reduce(.previewRejected, in: context()))
                }
            case .commitPreview(let token):
                do {
                    try session.commitPreview(token: token)
                    if session.document.elements.contains(where: { $0.id == proposedElementID }) {
                        proposedElementID = UUID()
                    }
                } catch {
                    cancelPreviewIfOwned(token)
                    apply(reducer.reduce(.previewRejected, in: context()))
                    return
                }
            case .cancelPreview(let token):
                do {
                    try session.cancelPreview(token: token)
                } catch {
                    apply(reducer.reduce(.previewRejected, in: context()))
                    return
                }
            case .perform(let command):
                do {
                    try session.perform(command)
                    if case .insert(let element, _) = command,
                       element.id == proposedElementID {
                        proposedElementID = UUID()
                    }
                } catch {
                    // The reducer preflights identity, revision capacity, and geometry. If the
                    // session still rejects a command, retain coordinator identity/state.
                }
            case .setTransientPreview(let element):
                transientPreview = element
                transientPreviewRevision.advance()
            case .appendFreehandPreview(let id, let style, let points, let token):
                do {
                    try session.appendFreehandPreview(
                        id: id,
                        style: style,
                        points: points,
                        token: token
                    )
                } catch {
                    apply(reducer.reduce(.previewRejected, in: context()))
                    return
                }
            case .appendFreehandInkPreview(
                let id,
                let style,
                let confirmed,
                let predicted,
                let pressureEnabled,
                let widthMode,
                let token
            ):
                do {
                    try session.appendFreehandInkPreview(
                        id: id,
                        style: style,
                        confirmed: confirmed,
                        predicted: predicted,
                        pressureEnabled: pressureEnabled,
                        widthMode: widthMode,
                        token: token
                    )
                } catch {
                    apply(reducer.reduce(.previewRejected, in: context()))
                    return
                }
            case .recognize(let request):
                if allowRecognition { beginRecognition(request) }
            case .setGuides(let guides):
                snapGuides = guides
            case .setEraserTarget(let id):
                eraserTargetID = id
            }
        }
    }

    func beginRecognition(_ request: RecognitionRequest) {
        guard session.configuration.allows(.shapeRecognition), let recognizer else { return }
        recognitionTasks[request.elementID]?.cancel()
        recognitionTasks[request.elementID] = Task { [weak self] in
            let result = await RecognitionExecutor.recognize(request, with: recognizer)
            guard !Task.isCancelled, let self, !self.isDismantled else { return }
            self.recognitionTasks[request.elementID] = nil
            self.receive(.recognitionCompleted(request: request, result: result))
        }
    }

    func cancelPreviewIfOwned(_ token: CanvasPreviewToken) {
        do {
            try session.cancelPreview(token: token)
        } catch {
            return
        }
    }

    func synchronizeExternalState() {
        if observedConfiguration != session.configuration {
            let capabilitiesChanged = observedConfiguration.enabledTools != session.configuration.enabledTools
                || observedConfiguration.enabledFeatures != session.configuration.enabledFeatures
            observedConfiguration = session.configuration
            pencilPalettePresenter.dismiss()
            if capabilitiesChanged {
                cancelRecognitionTasks()
                performanceSignposts.cancelAll()
                pencilShortcutCoordinator?.cancelPendingAction()
                isPencilTransactionActive = false
                apply(reducer.reduce(.cancel, in: context()), allowRecognition: false)
                textCoordinator.cancelEditingSessions()
                transientPreview = nil
                snapGuides = []
                eraserTargetID = nil
            }
        }
        if observedViewport != session.viewport {
            observedViewport = session.viewport
            eraserTargetID = nil
        }
        if observedReplacementGeneration != session.documentReplacementGeneration {
            observedReplacementGeneration = session.documentReplacementGeneration
            (renderer as? any CanvasRenderCacheResetting)?.resetDerivedRenderCaches()
            performanceSignposts.cancelAll()
            cancelRecognitionTasks()
            pencilShortcutCoordinator?.cancelPendingAction()
            pencilPalettePresenter.dismiss()
            apply(reducer.reduce(.cancel, in: context()), allowRecognition: false)
        }
        if reducer.activeTool != session.activeTool {
            cancelRecognitionTasks()
            apply(reducer.reduce(.toolChanged(session.activeTool), in: context()), allowRecognition: false)
        }
    }

    func cancelRecognitionTasks() {
        for task in recognitionTasks.values { task.cancel() }
        recognitionTasks.removeAll()
    }

    func presentationInput() -> CanvasPresentationInput {
        var snapshot = theme.renderSnapshot
        snapshot.showsGrid = session.configuration.allows(.grid)
        snapshot.showsSelectionHandles = session.configuration.allows(.selectionResizing)
        return CanvasPresentationInput(
            document: session.document,
            replacementGeneration: session.documentReplacementGeneration,
            presentationRevision: session.presentationRevision,
            preview: session.preview,
            transientPreview: transientPreview,
            transientPreviewRevision: transientPreviewRevision,
            viewport: session.viewport,
            selectedElementID: session.configuration.showsSelection ? session.selectedElementID : nil,
            guides: session.configuration.showsSnapGuides ? snapGuides : [],
            gridSpacing: session.snapConfiguration.gridSpacing,
            theme: snapshot,
            eraserTargetID: session.configuration.showsEraserTarget ? eraserTargetID : nil,
            viewportRenderPhase: viewportRenderPhase,
            committedFreehandHandoff: session.committedFreehandHandoff
        )
    }

    var viewportRenderPhase: CanvasViewportRenderPhase {
        switch reducer.state {
        case .panning, .pinching:
            .interactive
        default:
            .settled
        }
    }

    var activePencilGeneration: CanvasGeneration? {
        CanvasRenderPreview(session.preview)?.generation
            ?? transientPreview.map { _ in transientPreviewRevision }
    }

    func observeSession() {
        withObservationTracking {
            _ = session.document.revision
            _ = session.viewport
            _ = session.selectedElementID
            _ = session.activeTool
            _ = session.strokeStyle
            _ = session.inkConfiguration
            _ = session.textStyle
            _ = session.snapConfiguration
            _ = session.configuration
            _ = session.documentReplacementGeneration
            _ = session.presentationRevision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isDismantled else { return }
                self.update()
                self.observeSession()
            }
        }
    }

    func sendPencil(
        _ phase: CanvasPencilBatchPhase,
        confirmed: [CanvasPencilTouchSample],
        predicted: [CanvasPencilTouchSample]
    ) {
        let viewport = session.viewport
        guard viewport.zoom.isFinite, viewport.zoom > 0 else { return }
        if phase == .began {
            isPencilTransactionActive = true
        }
        func canvasSamples(_ samples: [CanvasPencilTouchSample]) -> [CanvasInkSample] {
            samples.compactMap { sample -> CanvasInkSample? in
                let screen = CanvasPoint(
                    x: Double(sample.location.x),
                    y: Double(sample.location.y)
                )
                guard screen.x.isFinite, screen.y.isFinite else { return nil }
                let canvas = viewport.canvasPoint(fromScreen: screen)
                guard canvas.x.isFinite, canvas.y.isFinite else { return nil }
                return CanvasInkSample(
                    point: canvas,
                    pressure: sample.normalizedPressure
                )
            }
        }
        let confirmedSamples = canvasSamples(confirmed)
        guard !confirmedSamples.isEmpty else {
            if phase == .ended {
                isPencilTransactionActive = false
                pencilShortcutCoordinator?.pencilTransactionDidFinish()
            }
            return
        }
        receive(.pencilSamples(
            phase: phase,
            confirmed: confirmedSamples,
            predicted: canvasSamples(predicted)
        ))
        if phase == .ended {
            isPencilTransactionActive = false
            pencilShortcutCoordinator?.pencilTransactionDidFinish()
        }
    }

    func sendPencilCancelled() {
        isPencilTransactionActive = false
        receive(.pencilCancelled)
        pencilShortcutCoordinator?.cancelPendingAction()
    }

    func canManipulate(at point: CanvasPoint) -> Bool {
        guard reducer.activeTool == .select else {
            return false
        }
        return reducer.canBeginManipulation(at: point, in: context())
    }

    func updateViewportSize(_ size: CGSize) {
        let canvasSize = CanvasSize(width: Double(size.width), height: Double(size.height))
        guard canvasSize.width.isFinite, canvasSize.height.isFinite,
              canvasSize.width >= 0, canvasSize.height >= 0,
              session.viewport.viewportSize != canvasSize else {
            return
        }
        try? session.setViewportSize(canvasSize)
        update()
    }
}

private extension CanvasInput {
    var isPencilBatch: Bool {
        if case .pencilSamples = self { return true }
        return false
    }

    var cancelsPencilLatency: Bool {
        switch self {
        case .pencilSamples(phase: .ended, confirmed: _, predicted: _),
             .pencilCancelled, .cancel, .toolChanged:
            true
        default:
            false
        }
    }
}

@MainActor
private final class CanvasGestureDelegateProxy: NSObject, UIGestureRecognizerDelegate {
    private weak var gestureCoordinator: CanvasGestureCoordinator?
    private weak var textCoordinator: CanvasTextCoordinator?

    init(
        gestureCoordinator: CanvasGestureCoordinator,
        textCoordinator: CanvasTextCoordinator
    ) {
        self.gestureCoordinator = gestureCoordinator
        self.textCoordinator = textCoordinator
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        !(textCoordinator?.containsOverlayView(touch.view) ?? false)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureCoordinator?.gestureRecognizerShouldBegin(gestureRecognizer) ?? false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureCoordinator?.gestureRecognizer(
            gestureRecognizer,
            shouldRecognizeSimultaneouslyWith: otherGestureRecognizer
        ) ?? false
    }
}

@MainActor
struct CanvasPencilTouchSample {
    private let identity: AnyObject
    let location: CGPoint
    let force: CGFloat
    let maximumPossibleForce: CGFloat

    init(
        identity: AnyObject,
        location: CGPoint,
        force: CGFloat = 0,
        maximumPossibleForce: CGFloat = 0
    ) {
        self.identity = identity
        self.location = location
        self.force = force
        self.maximumPossibleForce = maximumPossibleForce
    }

    var normalizedPressure: Double {
        guard force.isFinite, maximumPossibleForce.isFinite,
              maximumPossibleForce > 0 else { return 1 }
        return Double(min(1, max(0, force / maximumPossibleForce)))
    }

    func hasSameIdentity(as other: CanvasPencilTouchSample) -> Bool {
        identity === other.identity
    }
}

@MainActor
final class CanvasHostView: UIView {
    let renderView: UIView
    var sendPencil: ((
        CanvasPencilBatchPhase,
        [CanvasPencilTouchSample],
        [CanvasPencilTouchSample]
    ) -> Void)?
    var sendPencilCancelled: (() -> Void)?
    var didLayout: ((CGSize) -> Void)?
    init(renderView: UIView) {
        self.renderView = renderView
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        renderView.isUserInteractionEnabled = false
        addSubview(renderView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CanvasHostView does not support NSCoder initialization")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        renderView.frame = bounds
        didLayout?(bounds.size)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        deliver(touches, with: event, phase: .began)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        deliver(touches, with: event, phase: .moved)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        deliver(touches, with: event, phase: .ended)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard touches.contains(where: { $0.type == .pencil }) else { return }
        sendPencilCancelled?()
    }

    private func deliver(
        _ touches: Set<UITouch>,
        with event: UIEvent?,
        phase: CanvasPencilBatchPhase
    ) {
        for touch in touches where touch.type == .pencil {
            let primary = sample(from: touch)
            let coalesced = event?.coalescedTouches(for: touch)?.map(sample(from:)) ?? []
            let predicted = event?.predictedTouches(for: touch)?.map(sample(from:)) ?? []
            deliverPencilSamples(
                coalesced: coalesced,
                primary: primary,
                predicted: predicted,
                phase: phase
            )
        }
    }

    private func sample(from touch: UITouch) -> CanvasPencilTouchSample {
        CanvasPencilTouchSample(
            identity: touch,
            location: touch.location(in: self),
            force: touch.force,
            maximumPossibleForce: touch.maximumPossibleForce
        )
    }

    func deliverPencilSamples(
        coalesced: [CanvasPencilTouchSample],
        primary: CanvasPencilTouchSample,
        predicted: [CanvasPencilTouchSample] = [],
        phase: CanvasPencilBatchPhase
    ) {
        var samples = coalesced
        if samples.last?.hasSameIdentity(as: primary) != true {
            samples.append(primary)
        }
        sendPencil?(phase, samples, phase == .ended ? [] : predicted)
    }
}

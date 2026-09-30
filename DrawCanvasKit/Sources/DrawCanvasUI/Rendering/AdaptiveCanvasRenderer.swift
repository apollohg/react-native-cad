import UIKit

@MainActor
final class AdaptiveCanvasRenderer:
    CanvasTimestampedDisplayReportingRenderer,
    CanvasPreparedPresentationRendering,
    CanvasRenderCacheResetting,
    CanvasRenderDismantling
{
    fileprivate enum Backend {
        case metal
        case coreGraphics
    }

    private let metalFactory: (
        @escaping (MetalCanvasError, MetalFailurePermanence) -> Void
    ) throws -> any CanvasDisplayReportingRenderer
    private let coreGraphicsFactory: () -> any CanvasDisplayReportingRenderer
    private let diagnosticHandler: (CanvasDiagnostic) -> Void
    private let status: CanvasRendererStatus?

    private var metalRenderer: (any CanvasDisplayReportingRenderer)?
    private var coreGraphicsRenderer: (any CanvasDisplayReportingRenderer)?
    private var metalView: UIView?
    private var coreGraphicsView: UIView?
    private var renderView: AdaptiveCanvasRenderView?
    private var activeBackend = Backend.metal
    private var latestScene: CanvasPreparedScene?
    private var viewEpoch: UInt64 = 0
    private var didInitializeBackends = false

    convenience init(
        diagnosticHandler: @escaping (CanvasDiagnostic) -> Void = { _ in },
        status: CanvasRendererStatus? = nil
    ) {
        self.init(
            metalFactory: { failureHandler in
                try MetalCanvasRenderer(failureHandler: failureHandler)
            },
            coreGraphicsFactory: { CoreGraphicsCanvasRenderer() },
            diagnosticHandler: diagnosticHandler,
            status: status
        )
    }

    init(
        metalFactory: @escaping (
            @escaping (MetalCanvasError, MetalFailurePermanence) -> Void
        ) throws -> any CanvasDisplayReportingRenderer,
        coreGraphicsFactory: @escaping () -> any CanvasDisplayReportingRenderer,
        diagnosticHandler: @escaping (CanvasDiagnostic) -> Void = { _ in },
        status: CanvasRendererStatus? = nil
    ) {
        self.metalFactory = metalFactory
        self.coreGraphicsFactory = coreGraphicsFactory
        self.diagnosticHandler = diagnosticHandler
        self.status = status
    }

    func makeRenderView(
        displayCompletion: @escaping (RecognitionGeneration, TimeInterval) -> Void
    ) -> UIView {
        if let renderView, !renderView.isDismantled {
            renderView.setDisplayCompletion(displayCompletion)
            return renderView
        }

        initializeBackendsIfNeeded()
        viewEpoch &+= 1
        let epoch = viewEpoch
        let coreGraphicsRenderer = requireCoreGraphicsRenderer()
        let coreGraphicsView = makeBackendView(
            renderer: coreGraphicsRenderer,
            displayCompletion: { [weak self] generation, presentedTime in
                self?.reportDisplay(
                    generation,
                    at: presentedTime,
                    from: .coreGraphics,
                    epoch: epoch
                )
            }
        )
        let metalView = metalRenderer.map { metalRenderer in
            makeBackendView(
                renderer: metalRenderer,
                displayCompletion: { [weak self] generation, presentedTime in
                    self?.reportDisplay(
                        generation,
                        at: presentedTime,
                        from: .metal,
                        epoch: epoch
                    )
                }
            )
        }
        let container = AdaptiveCanvasRenderView(owner: self)
        container.setDisplayCompletion(displayCompletion)
        container.install(
            metalView: metalView,
            coreGraphicsView: coreGraphicsView,
            activeBackend: activeBackend
        )
        self.metalView = metalView
        self.coreGraphicsView = coreGraphicsView
        renderView = container

        if activeBackend == .coreGraphics, let metalView {
            (metalRenderer as? any CanvasRenderDismantling)?
                .dismantleRenderView(metalView)
        }
        return container
    }

    func update(_ scene: CanvasPreparedScene, in renderView: UIView) {
        guard let renderView = renderView as? AdaptiveCanvasRenderView,
              renderView.isOwned(by: self),
              self.renderView === renderView,
              !renderView.isDismantled else {
            return
        }
        latestScene = scene
        switch activeBackend {
        case .metal:
            guard let metalRenderer, let metalView else { return }
            metalRenderer.update(scene, in: metalView)
        case .coreGraphics:
            guard let coreGraphicsRenderer, let coreGraphicsView else { return }
            coreGraphicsRenderer.update(scene, in: coreGraphicsView)
        }
    }

    func update(_ presentation: CanvasPreparedPresentation, in renderView: UIView) {
        guard let renderView = renderView as? AdaptiveCanvasRenderView,
              renderView.isOwned(by: self),
              self.renderView === renderView,
              !renderView.isDismantled else {
            return
        }
        latestScene = presentation.scene
        switch activeBackend {
        case .metal:
            guard let metalRenderer, let metalView else { return }
            if let presentationRenderer = metalRenderer as? any CanvasPreparedPresentationRendering {
                presentationRenderer.update(presentation, in: metalView)
            } else {
                metalRenderer.update(presentation.scene, in: metalView)
            }
        case .coreGraphics:
            guard let coreGraphicsRenderer, let coreGraphicsView else { return }
            coreGraphicsRenderer.update(presentation.scene, in: coreGraphicsView)
        }
    }

    func resetDerivedRenderCaches() {
        (metalRenderer as? any CanvasRenderCacheResetting)?.resetDerivedRenderCaches()
        (coreGraphicsRenderer as? any CanvasRenderCacheResetting)?.resetDerivedRenderCaches()
    }

    func dismantleRenderView(_ renderView: UIView) {
        guard let renderView = renderView as? AdaptiveCanvasRenderView,
              renderView.isOwned(by: self),
              self.renderView === renderView else {
            return
        }
        viewEpoch &+= 1
        if let metalView {
            (metalRenderer as? any CanvasRenderDismantling)?
                .dismantleRenderView(metalView)
        }
        if let coreGraphicsView {
            (coreGraphicsRenderer as? any CanvasRenderDismantling)?
                .dismantleRenderView(coreGraphicsView)
        }
        renderView.dismantle()
        self.renderView = nil
        metalView = nil
        coreGraphicsView = nil
        latestScene = nil
    }
}

@MainActor
private extension AdaptiveCanvasRenderer {
    func makeBackendView(
        renderer: any CanvasDisplayReportingRenderer,
        displayCompletion: @escaping (RecognitionGeneration, TimeInterval) -> Void
    ) -> UIView {
        if let timestamped = renderer as? any CanvasTimestampedDisplayReportingRenderer {
            return timestamped.makeRenderView(displayCompletion: displayCompletion)
        }
        return renderer.makeRenderView { generation in
            displayCompletion(generation, ProcessInfo.processInfo.systemUptime)
        }
    }

    func initializeBackendsIfNeeded() {
        guard !didInitializeBackends else { return }
        didInitializeBackends = true
        coreGraphicsRenderer = coreGraphicsFactory()
        do {
            metalRenderer = try metalFactory { [weak self] error, permanence in
                self?.metalDidFail(error, permanence: permanence)
            }
            status?.update(.metal)
        } catch {
            if activeBackend == .metal {
                activeBackend = .coreGraphics
                status?.update(.coreGraphics(.initialization))
                diagnosticHandler(.rendererFallback(.initialization))
            }
        }
    }

    func requireCoreGraphicsRenderer() -> any CanvasDisplayReportingRenderer {
        if let coreGraphicsRenderer { return coreGraphicsRenderer }
        let renderer = coreGraphicsFactory()
        coreGraphicsRenderer = renderer
        return renderer
    }

    func metalDidFail(
        _: MetalCanvasError,
        permanence: MetalFailurePermanence
    ) {
        guard permanence == .permanent, activeBackend == .metal else { return }

        activeBackend = .coreGraphics
        status?.update(.coreGraphics(.permanentRuntime))
        renderView?.showCoreGraphics()
        if let metalView {
            (metalRenderer as? any CanvasRenderDismantling)?
                .dismantleRenderView(metalView)
        }
        if let latestScene, let coreGraphicsRenderer, let coreGraphicsView {
            coreGraphicsRenderer.update(latestScene, in: coreGraphicsView)
        }
        diagnosticHandler(.rendererFallback(.permanentRuntime))
    }

    private func reportDisplay(
        _ generation: RecognitionGeneration,
        at presentedTime: TimeInterval,
        from backend: Backend,
        epoch: UInt64
    ) {
        guard epoch == viewEpoch, backend == activeBackend else { return }
        renderView?.reportDisplay(generation, at: presentedTime)
    }
}

@MainActor
private final class AdaptiveCanvasRenderView: UIView {
    private weak var owner: AnyObject?
    private var displayCompletion: (RecognitionGeneration, TimeInterval) -> Void = { _, _ in }
    private(set) var isDismantled = false
    private weak var metalView: UIView?
    private weak var coreGraphicsView: UIView?

    init(owner: AnyObject) {
        self.owner = owner
        super.init(frame: .zero)
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AdaptiveCanvasRenderView does not support NSCoder initialization")
    }

    func isOwned(by candidate: AnyObject) -> Bool {
        owner === candidate
    }

    func setDisplayCompletion(
        _ displayCompletion: @escaping (RecognitionGeneration, TimeInterval) -> Void
    ) {
        self.displayCompletion = displayCompletion
    }

    func install(
        metalView: UIView?,
        coreGraphicsView: UIView,
        activeBackend: AdaptiveCanvasRenderer.Backend
    ) {
        if let metalView {
            addSubview(metalView)
            self.metalView = metalView
        }
        addSubview(coreGraphicsView)
        self.coreGraphicsView = coreGraphicsView
        switch activeBackend {
        case .metal:
            metalView?.isHidden = false
            coreGraphicsView.isHidden = true
        case .coreGraphics:
            metalView?.isHidden = true
            coreGraphicsView.isHidden = false
        }
    }

    func showCoreGraphics() {
        metalView?.isHidden = true
        coreGraphicsView?.isHidden = false
    }

    func reportDisplay(
        _ generation: RecognitionGeneration,
        at presentedTime: TimeInterval
    ) {
        guard !isDismantled else { return }
        displayCompletion(generation, presentedTime)
    }

    func dismantle() {
        guard !isDismantled else { return }
        isDismantled = true
        displayCompletion = { _, _ in }
        subviews.forEach { $0.removeFromSuperview() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for child in subviews {
            child.frame = bounds
        }
    }
}

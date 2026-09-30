import Metal
import QuartzCore
import UIKit

@MainActor
protocol MetalDisplayLinkControlling: AnyObject {
    var isPaused: Bool { get }
    var isInvalidated: Bool { get }
    var startCount: Int { get }
    var pauseCount: Int { get }
    var updateCallbackCount: Int { get }

    func start()
    func pause()
    func invalidate()
}

struct MetalDisplayLinkDiagnosticSnapshot: Equatable {
    let isPaused: Bool
    let isInvalidated: Bool
    let startCount: Int
    let pauseCount: Int
    let updateCallbackCount: Int
}

typealias MetalDisplayLinkFactory = (
    CAMetalLayer,
    @escaping (MetalDisplayLinkDrawable) -> Void
) -> any MetalDisplayLinkControlling

@MainActor
private final class LiveMetalDisplayLinkController: NSObject,
    MetalDisplayLinkControlling,
    @preconcurrency CAMetalDisplayLinkDelegate
{
    private let displayLink: CAMetalDisplayLink
    private let update: (MetalDisplayLinkDrawable) -> Void
    private(set) var isInvalidated = false
    private(set) var startCount = 0
    private(set) var pauseCount = 0
    private(set) var updateCallbackCount = 0

    var isPaused: Bool { displayLink.isPaused }

    init(
        metalLayer: CAMetalLayer,
        update: @escaping (MetalDisplayLinkDrawable) -> Void
    ) {
        displayLink = CAMetalDisplayLink(metalLayer: metalLayer)
        self.update = update
        super.init()
        displayLink.delegate = self
        displayLink.preferredFrameLatency = 1
        displayLink.isPaused = true
        displayLink.add(to: .main, forMode: .common)
    }

    func start() {
        guard !isInvalidated else { return }
        startCount += 1
        displayLink.isPaused = false
    }

    func pause() {
        guard !isInvalidated else { return }
        pauseCount += 1
        displayLink.isPaused = true
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        displayLink.delegate = nil
        displayLink.invalidate()
    }

    func metalDisplayLink(
        _ link: CAMetalDisplayLink,
        needsUpdate update: CAMetalDisplayLink.Update
    ) {
        updateCallbackCount += 1
        guard !isInvalidated else { return }
        let callbackTimestamp = CACurrentMediaTime()
        self.update(
            MetalDisplayLinkDrawable(
                update.drawable,
                callbackTimestamp: callbackTimestamp,
                targetTimestamp: update.targetTimestamp,
                targetPresentationTimestamp: update.targetPresentationTimestamp
            )
        )
    }
}

@MainActor
final class MetalCanvasRenderView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    private weak var owner: AnyObject?
    private let scheduler: MetalFrameScheduler
    private var displayLinkController: (any MetalDisplayLinkControlling)?
    private var displayCompletion: (RecognitionGeneration, TimeInterval) -> Void = { _, _ in }
    private(set) var isDismantled = false
    var beforeDisplayLinkUpdate: (() -> Void)?

    var metalLayer: CAMetalLayer {
        guard let metalLayer = layer as? CAMetalLayer else {
            preconditionFailure("MetalCanvasRenderView must use CAMetalLayer")
        }
        return metalLayer
    }

    init(
        frame: CGRect,
        device: any MTLDevice,
        scheduler: MetalFrameScheduler,
        owner: AnyObject,
        displayLinkFactory: MetalDisplayLinkFactory? = nil
    ) {
        self.scheduler = scheduler
        self.owner = owner
        super.init(frame: frame)

        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.contentsScale = contentScaleFactor
        metalLayer.actions = [
            "bounds": NSNull(),
            "contents": NSNull(),
            "position": NSNull(),
        ]
        isOpaque = true
        backgroundColor = .clear

        let factory = displayLinkFactory ?? { layer, update in
            LiveMetalDisplayLinkController(metalLayer: layer, update: update)
        }
        displayLinkController = factory(metalLayer) { [weak self] drawable in
            self?.consumeDisplayLinkDrawable(drawable)
        }
        scheduler.attach(to: self)
        updateDrawableSize()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("MetalCanvasRenderView does not support NSCoder initialization")
    }

    func isOwned(by candidate: AnyObject) -> Bool {
        owner === candidate
    }

    func setDisplayCompletion(
        _ completion: @escaping (RecognitionGeneration, TimeInterval) -> Void
    ) {
        displayCompletion = completion
    }

    func reportDisplay(
        of generation: RecognitionGeneration,
        at presentedTime: TimeInterval
    ) {
        guard !isDismantled else { return }
        displayCompletion(generation, presentedTime)
    }

    var frameDiagnosticSnapshot: MetalFrameDiagnosticSnapshot {
        scheduler.diagnosticSnapshot
    }

    var displayLinkDiagnosticSnapshot: MetalDisplayLinkDiagnosticSnapshot {
        MetalDisplayLinkDiagnosticSnapshot(
            isPaused: displayLinkController?.isPaused ?? true,
            isInvalidated: displayLinkController?.isInvalidated ?? true,
            startCount: displayLinkController?.startCount ?? 0,
            pauseCount: displayLinkController?.pauseCount ?? 0,
            updateCallbackCount: displayLinkController?.updateCallbackCount ?? 0
        )
    }

    func requestPresentationUpdates() {
        guard !isDismantled, window != nil else { return }
        if displayLinkController?.isPaused == true {
            displayLinkController?.start()
        }
    }

    func pausePresentationUpdates() {
        if displayLinkController?.isPaused == false {
            displayLinkController?.pause()
        }
    }

    func reconcilePresentationUpdates() {
        guard !isDismantled else { return }
        if window != nil, scheduler.needsDisplayLinkUpdates {
            requestPresentationUpdates()
        } else {
            pausePresentationUpdates()
        }
    }

    func schedulerDidInvalidate() {
        displayLinkController?.invalidate()
    }

    func dismantle() {
        guard !isDismantled else { return }
        isDismantled = true
        beforeDisplayLinkUpdate = nil
        scheduler.invalidate()
        displayLinkController?.invalidate()
        displayCompletion = { _, _ in }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard !isDismantled else { return }
        let isAttached = window != nil
        scheduler.renderViewAttachmentDidChange(self, isAttached: isAttached)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateDrawableSize()
    }
}

@MainActor
private extension MetalCanvasRenderView {
    func consumeDisplayLinkDrawable(_ drawable: MetalDisplayLinkDrawable) {
        guard !isDismantled, window != nil else { return }
        let hasPreUpdateHook = beforeDisplayLinkUpdate != nil
        beforeDisplayLinkUpdate?()
        let admittedDrawable = hasPreUpdateHook
            ? drawable.recordingAdmission(at: CACurrentMediaTime())
            : drawable
        scheduler.displayLinkDidUpdate(with: admittedDrawable, from: self)
        reconcilePresentationUpdates()
    }

    func updateDrawableSize() {
        let scale = window?.screen.scale ?? contentScaleFactor
        contentScaleFactor = scale
        metalLayer.contentsScale = scale
        let drawableSize = CGSize(
            width: bounds.width * scale,
            height: bounds.height * scale
        )
        guard drawableSize.width.isFinite,
              drawableSize.height.isFinite,
              drawableSize.width > 0,
              drawableSize.height > 0 else {
            return
        }
        metalLayer.drawableSize = drawableSize
        scheduler.drawableSizeDidChange(to: drawableSize)
    }
}

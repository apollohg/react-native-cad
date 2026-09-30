import Metal
import UIKit

@MainActor
final class MetalCanvasRenderer:
    CanvasTimestampedDisplayReportingRenderer,
    CanvasPreparedPresentationRendering,
    CanvasRenderCacheResetting,
    CanvasRenderDismantling
{
    private let device: any MTLDevice
    private let compiler = MetalSceneCompiler()
    private let schedulerFactory: @MainActor () -> MetalFrameScheduler
    private let failureHandler: (MetalCanvasError, MetalFailurePermanence) -> Void
    private var scheduler: MetalFrameScheduler?
    private var renderView: MetalCanvasRenderView?

    convenience init(
        failureHandler: @escaping (MetalCanvasError, MetalFailurePermanence) -> Void = { _, _ in }
    ) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalCanvasError.deviceUnavailable
        }
        try self.init(device: device, failureHandler: failureHandler)
    }

    convenience init(
        device: any MTLDevice,
        failureHandler: @escaping (MetalCanvasError, MetalFailurePermanence) -> Void = { _, _ in }
    ) throws {
        try self.init(
            device: device,
            schedulerFactory: { MetalFrameScheduler(device: device) },
            failureHandler: failureHandler
        )
    }

    init(
        device: any MTLDevice,
        schedulerFactory: @escaping @MainActor () -> MetalFrameScheduler,
        failureHandler: @escaping (MetalCanvasError, MetalFailurePermanence) -> Void = { _, _ in }
    ) throws {
        guard device.makeCommandQueue() != nil else {
            throw MetalCanvasError.deviceUnavailable
        }
        _ = try MetalPipelineLibrary(device: device)
        self.device = device
        self.schedulerFactory = schedulerFactory
        self.failureHandler = failureHandler
    }

    func makeRenderView(
        displayCompletion: @escaping (RecognitionGeneration, TimeInterval) -> Void
    ) -> UIView {
        if let renderView, !renderView.isDismantled {
            renderView.setDisplayCompletion(displayCompletion)
            return renderView
        }
        let scheduler = schedulerFactory()
        scheduler.delegate = self
        let view = MetalCanvasRenderView(
            frame: .zero,
            device: device,
            scheduler: scheduler,
            owner: self
        )
        view.setDisplayCompletion(displayCompletion)
        self.scheduler = scheduler
        renderView = view
        return view
    }

    func update(_ scene: CanvasPreparedScene, in renderView: UIView) {
        guard let renderView = renderView as? MetalCanvasRenderView,
              renderView.isOwned(by: self),
              !renderView.isDismantled,
              let scheduler else {
            return
        }
        do {
            scheduler.submit(
                try compiler.compile(
                    scene,
                    displayScale: Double(renderView.contentScaleFactor)
                ),
                to: renderView
            )
        } catch let error as MetalCanvasError {
            failureHandler(error, .permanent)
        } catch {
            failureHandler(.commandEncodingFailed, .permanent)
        }
    }

    func update(_ presentation: CanvasPreparedPresentation, in renderView: UIView) {
        guard let renderView = renderView as? MetalCanvasRenderView,
              renderView.isOwned(by: self),
              !renderView.isDismantled,
              let scheduler else {
            return
        }
        do {
            scheduler.submit(
                try compiler.compile(
                    presentation,
                    displayScale: Double(renderView.contentScaleFactor)
                ),
                to: renderView
            )
        } catch let error as MetalCanvasError {
            failureHandler(error, .permanent)
        } catch {
            failureHandler(.commandEncodingFailed, .permanent)
        }
    }

    func dismantleRenderView(_ renderView: UIView) {
        guard let renderView = renderView as? MetalCanvasRenderView,
              renderView.isOwned(by: self),
              self.renderView === renderView else {
            return
        }
        renderView.dismantle()
        compiler.resetDerivedRenderCaches()
        scheduler?.delegate = nil
        scheduler = nil
        self.renderView = nil
    }

    func resetDerivedRenderCaches() {
        compiler.resetDerivedRenderCaches()
        scheduler?.resetDerivedRenderCaches()
    }
}

extension MetalCanvasRenderer: MetalFrameSchedulerDelegate {
    func frameSchedulerDidPresent(
        _ generation: RecognitionGeneration,
        at presentedTime: TimeInterval
    ) {
        renderView?.reportDisplay(of: generation, at: presentedTime)
    }

    func frameSchedulerDidFail(
        _ error: MetalCanvasError,
        permanence: MetalFailurePermanence
    ) {
        failureHandler(error, permanence)
    }
}

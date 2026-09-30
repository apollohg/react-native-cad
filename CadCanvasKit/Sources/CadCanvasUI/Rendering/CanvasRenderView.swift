import UIKit

@MainActor
public final class CanvasRenderView: UIView {
    private let renderer: CoreGraphicsCanvasRenderer
    private let redrawAction: (() -> Void)?
    private let displayCompletion: (RecognitionGeneration, TimeInterval) -> Void
    private var completedPreviewGeneration: RecognitionGeneration?

    private(set) var latestScene: CanvasPreparedScene?
    private(set) var isRedrawScheduled = false

    init(
        renderer: CoreGraphicsCanvasRenderer,
        redrawAction: (() -> Void)? = nil,
        displayCompletion: @escaping (RecognitionGeneration, TimeInterval) -> Void = { _, _ in }
    ) {
        self.renderer = renderer
        self.redrawAction = redrawAction
        self.displayCompletion = displayCompletion
        super.init(frame: .zero)
        isOpaque = true
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CanvasRenderView does not support NSCoder initialization")
    }

    func enqueue(_ scene: CanvasPreparedScene) {
        latestScene = scene
        if scene.previewGeneration == nil {
            completedPreviewGeneration = nil
        }
        guard !isRedrawScheduled else {
            return
        }
        isRedrawScheduled = true
        if let redrawAction {
            redrawAction()
        } else {
            setNeedsDisplay()
        }
    }

    func isOwned(by renderer: CoreGraphicsCanvasRenderer) -> Bool {
        self.renderer === renderer
    }

    func completeDisplayPass() {
        isRedrawScheduled = false
    }

    public override func draw(_ rect: CGRect) {
        super.draw(rect)
        completeDisplayPass()
        guard let latestScene,
              let context = UIGraphicsGetCurrentContext() else {
            return
        }
        renderer.draw(
            scene: latestScene,
            in: context,
            bounds: bounds,
            displayScale: Double(contentScaleFactor)
        )
        if let generation = latestScene.previewGeneration,
           generation != completedPreviewGeneration {
            completedPreviewGeneration = generation
            displayCompletion(generation, ProcessInfo.processInfo.systemUptime)
        }
    }
}

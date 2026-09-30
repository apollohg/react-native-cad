import CadCanvasCore
import CadCanvasUI
import ExpoModulesCore
import Observation
import SwiftUI

@MainActor
@Observable
final class CADViewModel {
    let session = CanvasSession()
    let rendererStatus = CanvasRendererStatus()
    let actions: CanvasActions
    let commands: CanvasCommandActions
    var theme = CanvasTheme.default

    init() {
        actions = CanvasActions(session: session)
        commands = CanvasCommandActions(session: session)
    }

    var rendererName: String {
        switch rendererStatus.backend {
        case .initializing: "initializing"
        case .metal: "metal"
        case .coreGraphics: "coreGraphics"
        }
    }
}

@MainActor
private struct CADRootView: View {
    let model: CADViewModel
    let rendererChanged: (String) -> Void

    var body: some View {
        ZStack {
            CadCanvasView(commandActions: model.commands, rendererStatus: model.rendererStatus)
            DimensionOverlay(actions: model.actions)
        }
        .canvasTheme(model.theme)
        .onChange(of: model.rendererName, initial: true) { _, renderer in
            rendererChanged(renderer)
        }
    }
}

@MainActor
final class ReactNativeCADView: ExpoView {
    let model = CADViewModel()
    let onDocumentChange = EventDispatcher()
    let onError = EventDispatcher()
    let onRendererChange = EventDispatcher()
    var pendingOptions = "{}"
    var pendingTool: String?
    private var appliedOptions: String?
    private var appliedTool: String?
    private var host: UIHostingController<CADRootView>?

    required init(appContext: AppContext? = nil) {
        super.init(appContext: appContext)
        clipsToBounds = true
        model.session.onDocumentChange = { [weak self] document in
            self?.onDocumentChange([
                "documentID": document.id.uuidString,
                "revision": String(document.revision),
                "elementCount": document.elements.count,
            ])
        }
        model.session.onDiagnostic = { [weak self] diagnostic in
            self?.onError(["operation": "canvas", "message": String(describing: diagnostic)])
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            host?.willMove(toParent: nil)
            host?.view.removeFromSuperview()
            host?.removeFromParent()
            host = nil
            return
        }
        guard host == nil else { return }
        var responder: UIResponder? = next
        while let current = responder, !(current is UIViewController) { responder = current.next }
        guard let parent = responder as? UIViewController else { return }
        let controller = UIHostingController(rootView: CADRootView(model: model, rendererChanged: { [weak self] renderer in
            self?.onRendererChange(["renderer": renderer])
        }))
        parent.addChild(controller)
        controller.view.backgroundColor = .clear
        controller.view.frame = bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(controller.view)
        controller.didMove(toParent: parent)
        host = controller
    }

    func applyProps() {
        do {
            if appliedOptions != pendingOptions {
                let options = try CanvasJSONOptions.decode(pendingOptions)
                try options.apply(to: model.session)
                model.theme = options.theme
                appliedOptions = pendingOptions
            }
            if pendingTool != appliedTool {
                if let pendingTool {
                    guard let tool = CanvasTool(rawValue: pendingTool) else {
                        throw CanvasValidationError(field: "tool", reason: "unknown tool: \(pendingTool)")
                    }
                    model.session.selectTool(tool)
                }
                appliedTool = pendingTool
            }
        } catch {
            onError(["operation": "configure", "message": String(describing: error)])
        }
    }

    func documentJSON() async throws -> String {
        let document = model.session.document
        return try await Task.detached(priority: .userInitiated) {
            try CanvasDocumentCodec.encodeString(document)
        }.value
    }

    func loadDocument(_ json: String) async throws {
        let document = try await Task.detached(priority: .userInitiated) {
            try CanvasDocumentCodec.decode(json)
        }.value
        try model.session.replaceDocument(document)
    }

    func perform(_ command: String) throws -> Bool {
        switch command {
        case "undo": model.actions.undo()
        case "redo": model.actions.redo()
        case "clear": model.actions.clear()
        case "deleteSelection": model.actions.deleteSelection()
        case "duplicateSelection": model.actions.duplicateSelection()
        case "zoomToFit": model.actions.zoomToFit()
        default: throw CanvasValidationError(field: "command", reason: "unknown command: \(command)")
        }
    }
}

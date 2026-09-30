import ExpoModulesCore

public final class ReactNativeCADModule: Module {
    public func definition() -> ModuleDefinition {
        Name("ReactNativeCAD")
        View(ReactNativeCADView.self) {
            Events("onDocumentChange", "onError", "onRendererChange")
            Prop("optionsJSON", "{}") { (view, value: String) in view.pendingOptions = value }
            Prop("tool") { (view, value: String?) in view.pendingTool = value }
            OnViewDidUpdateProps { view in view.applyProps() }
            AsyncFunction("getDocument") { (view: ReactNativeCADView) async throws -> String in
                try await view.documentJSON()
            }
            AsyncFunction("loadDocument") { (view: ReactNativeCADView, json: String) async throws in
                try await view.loadDocument(json)
            }
            AsyncFunction("perform") { (view: ReactNativeCADView, command: String) async throws -> Bool in
                try await view.perform(command)
            }
            AsyncFunction("getRenderer") { (view: ReactNativeCADView) async -> String in
                await view.model.rendererName
            }
        }
    }
}

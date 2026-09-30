import SwiftUI
import DrawCanvasCore
import DrawCanvasUI

@main
@MainActor
struct DrawCanvasDemoApp: App {
    @State private var session: CanvasSession
    @State private var actions: CanvasActions
    @State private var commandActions: CanvasCommandActions
    @State private var rendererStatus: CanvasRendererStatus

    init() {
        let session = CanvasSession()
        _session = State(initialValue: session)
        _actions = State(initialValue: CanvasActions(session: session))
        _commandActions = State(initialValue: CanvasCommandActions(session: session))
        _rendererStatus = State(initialValue: CanvasRendererStatus())
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                session: session,
                actions: actions,
                commandActions: commandActions,
                rendererStatus: rendererStatus
            )
        }
        .commands {
            CanvasKeyboardCommands(actions: commandActions)
        }
    }
}

import SwiftUI
import Observation
import CadCanvasCore

@MainActor
@Observable
public final class CanvasCommandActions {
    public let session: CanvasSession
    public private(set) var isTextEditing = false

    @ObservationIgnored private let actions: CanvasActions
    @ObservationIgnored private let zoomFactor: Double
    @ObservationIgnored private weak var coordinator: CadCanvasCoordinator?

    public convenience init(
        session: CanvasSession,
        makeElementID: @escaping @MainActor () -> UUID = UUID.init
    ) {
        self.init(session: session, makeElementID: makeElementID, zoomFactor: 1.25)
    }

    init(
        session: CanvasSession,
        makeElementID: @escaping @MainActor () -> UUID = UUID.init,
        zoomFactor: Double
    ) {
        self.session = session
        actions = CanvasActions(session: session, makeElementID: makeElementID)
        self.zoomFactor = zoomFactor
    }

    public var canDeleteSelection: Bool { !isTextEditing && actions.canDeleteSelection }
    public var canDuplicateSelection: Bool { !isTextEditing && actions.canDuplicateSelection }
    public var canUndo: Bool { !isTextEditing && actions.canUndo }
    public var canRedo: Bool { !isTextEditing && actions.canRedo }

    @discardableResult
    public func deleteSelection() -> Bool {
        guard !isTextEditing else { return false }
        return actions.deleteSelection()
    }

    @discardableResult
    public func duplicateSelection() -> Bool {
        guard !isTextEditing else { return false }
        return actions.duplicateSelection()
    }

    @discardableResult
    public func undo() -> Bool {
        guard !isTextEditing else { return false }
        return actions.undo()
    }

    @discardableResult
    public func redo() -> Bool {
        guard !isTextEditing else { return false }
        return actions.redo()
    }

    @discardableResult
    public func zoomIn() -> Bool {
        guard zoomFactor.isFinite, zoomFactor > 1 else { return false }
        return zoom(by: zoomFactor)
    }

    @discardableResult
    public func zoomOut() -> Bool {
        guard zoomFactor.isFinite, zoomFactor > 1 else { return false }
        return zoom(by: 1 / zoomFactor)
    }

    @discardableResult
    public func zoomToFitOrReset() -> Bool {
        guard session.configuration.allows(.zooming) else { return false }
        if actions.zoomToFit() { return true }
        guard session.document.elements.isEmpty,
              valid(session.viewport.viewportSize) else {
            return false
        }
        guard let reset = try? CanvasViewport.identity(size: session.viewport.viewportSize) else {
            return false
        }
        guard reset != session.viewport else { return false }
        session.setViewport(reset)
        return true
    }

    @discardableResult
    public func escape() -> Bool {
        guard let coordinator, !coordinator.isDismantled else { return false }
        coordinator.cancelActiveInteraction()
        return true
    }

    func attach(to coordinator: CadCanvasCoordinator) {
        guard self.coordinator !== coordinator else { return }
        self.coordinator?.detachCommandActions(self)
        self.coordinator = coordinator
        coordinator.attachCommandActions(self)
    }

    func setTextEditing(_ isTextEditing: Bool) {
        self.isTextEditing = isTextEditing
    }

    func detach(from coordinator: CadCanvasCoordinator) {
        guard self.coordinator === coordinator else { return }
        self.coordinator = nil
        isTextEditing = false
    }
}

private extension CanvasCommandActions {
    func zoom(by factor: Double) -> Bool {
        guard session.configuration.allows(.zooming) else { return false }
        let viewport = session.viewport
        guard factor.isFinite, factor > 0, factor != 1,
              viewport.zoom.isFinite, viewport.zoom > 0,
              valid(viewport.translation), valid(viewport.viewportSize) else {
            return false
        }
        let center = CanvasPoint(
            x: viewport.viewportSize.width / 2,
            y: viewport.viewportSize.height / 2
        )
        guard valid(center) else { return false }
        guard let updated = try? viewport.zoomed(by: factor, anchoredAtScreen: center),
              valid(updated.translation), updated != viewport else { return false }
        session.setViewport(updated)
        return true
    }

    func valid(_ point: CanvasPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }

    func valid(_ size: CanvasSize) -> Bool {
        size.width.isFinite && size.height.isFinite
            && size.width >= 0 && size.height >= 0
    }
}

@MainActor
public struct CanvasKeyboardCommands: Commands {
    private let actions: CanvasCommandActions

    public init(actions: CanvasCommandActions) {
        self.actions = actions
    }

    public var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { actions.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!actions.canUndo)
            Button("Redo") { actions.redo() }
                .keyboardShortcut("z", modifiers: [.shift, .command])
                .disabled(!actions.canRedo)
        }
        CommandMenu("Canvas") {
            Button("Delete") { actions.deleteSelection() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(!actions.canDeleteSelection)
            Button("Duplicate") { actions.duplicateSelection() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(!actions.canDuplicateSelection)
            Divider()
            Button("Zoom In") { actions.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!actions.session.configuration.allows(.zooming))
            Button("Zoom Out") { actions.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!actions.session.configuration.allows(.zooming))
            Button("Zoom to Fit") { actions.zoomToFitOrReset() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(!actions.session.configuration.allows(.zooming))
            Divider()
            Button("Cancel") { actions.escape() }
                .keyboardShortcut(.escape, modifiers: [])
        }
    }
}

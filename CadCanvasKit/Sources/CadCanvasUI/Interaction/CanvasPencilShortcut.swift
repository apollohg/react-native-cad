import CadCanvasCore

public enum CanvasPencilShortcutAction: Equatable, Sendable {
    case switchEraser
    case switchPreviousTool
    case showColorPalette
    case showInkAttributes
    case showContextualPalette
}

public struct CanvasPencilShortcutContext: Equatable, Sendable {
    public let action: CanvasPencilShortcutAction
    public let screenAnchor: CanvasPoint

    public init(action: CanvasPencilShortcutAction, screenAnchor: CanvasPoint) {
        self.action = action
        self.screenAnchor = screenAnchor
    }
}

public enum CanvasPencilShortcutDisposition: Sendable {
    case handled
    case useDefault
}

public typealias CanvasPencilShortcutHandler = @MainActor (
    CanvasPencilShortcutContext
) -> CanvasPencilShortcutDisposition

public enum CanvasScenePreparationError: Error, Equatable, Sendable {
    case invalidViewport
    case invalidVisibleRect
    case invalidGrid
    case invalidGeometryBounds
}

public enum CanvasRendererFailure: Equatable, Sendable {
    case initialization
    case permanentRuntime
    case temporaryDrawableUnavailable
}

public enum CanvasDiagnostic: Error, Equatable, Sendable {
    case scenePreparationFailed(CanvasScenePreparationError)
    case rendererFallback(CanvasRendererFailure)
    case unknownPencilPreferredAction(Int)
    case pencilPalettePresentationUnavailable
}

import Observation

public enum CanvasRendererBackend: Equatable, Sendable {
    case initializing
    case metal
    case coreGraphics(CanvasRendererFailure)
}

@MainActor
@Observable
public final class CanvasRendererStatus {
    public private(set) var backend: CanvasRendererBackend

    public init(backend: CanvasRendererBackend = .initializing) {
        self.backend = backend
    }

    package func update(_ backend: CanvasRendererBackend) {
        self.backend = backend
    }
}

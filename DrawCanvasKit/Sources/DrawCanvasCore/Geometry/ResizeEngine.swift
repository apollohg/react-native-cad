public enum ResizeHandle: String, Codable, Hashable, Sendable {
    case topLeft
    case top
    case topRight
    case right
    case bottomRight
    case bottom
    case bottomLeft
    case left
}

public enum ResizeEngine {
    public static func resizedBounds(
        original: CanvasRect,
        handle: ResizeHandle,
        cumulativeDelta: CanvasPoint,
        minimumSize: Double
    ) -> CanvasRect {
        let minimum = minimumSize.isFinite ? max(0, minimumSize) : 0
        var minX = original.minX
        var maxX = original.maxX
        var minY = original.minY
        var maxY = original.maxY

        switch handle {
        case .topLeft, .left, .bottomLeft:
            minX = min(original.minX + cumulativeDelta.x, original.maxX - minimum)
        case .topRight, .right, .bottomRight:
            maxX = max(original.maxX + cumulativeDelta.x, original.minX + minimum)
        case .top, .bottom:
            break
        }

        switch handle {
        case .topLeft, .top, .topRight:
            minY = min(original.minY + cumulativeDelta.y, original.maxY - minimum)
        case .bottomLeft, .bottom, .bottomRight:
            maxY = max(original.maxY + cumulativeDelta.y, original.minY + minimum)
        case .left, .right:
            break
        }

        return CanvasRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public static func resize(
        original: CanvasElement,
        handle: ResizeHandle,
        cumulativeDelta: CanvasPoint,
        minimumSize: Double
    ) throws -> CanvasElement {
        let bounds = resizedBounds(
            original: original.bounds,
            handle: handle,
            cumulativeDelta: cumulativeDelta,
            minimumSize: minimumSize
        )
        return try original.replacingBounds(bounds)
    }
}

public enum CanvasViewportError: Error, Equatable, Sendable {
    case invalidZoom
    case invalidTranslation
    case invalidSize
    case invalidDelta
    case invalidAnchor
    case invalidFactor
    case nonfiniteResult
}

public struct CanvasViewport: Hashable, Sendable {
    public static let zoomRange = 1.0...20.0

    public private(set) var zoom: Double
    public private(set) var translation: CanvasPoint
    public private(set) var viewportSize: CanvasSize

    public init(zoom: Double, translation: CanvasPoint, viewportSize: CanvasSize) throws {
        guard zoom.isFinite, zoom > 0 else { throw CanvasViewportError.invalidZoom }
        guard translation.x.isFinite, translation.y.isFinite else {
            throw CanvasViewportError.invalidTranslation
        }
        guard viewportSize.width.isFinite, viewportSize.height.isFinite,
              viewportSize.width >= 0, viewportSize.height >= 0 else {
            throw CanvasViewportError.invalidSize
        }
        self.zoom = Self.clampedZoom(zoom)
        self.translation = translation
        self.viewportSize = viewportSize
    }

    public static func identity(size: CanvasSize) throws -> CanvasViewport {
        try CanvasViewport(
            zoom: 1,
            translation: .init(x: 0, y: 0),
            viewportSize: size
        )
    }

    public var visibleCanvasRect: CanvasRect {
        let origin = canvasPoint(fromScreen: .init(x: 0, y: 0))
        return CanvasRect(
            x: origin.x,
            y: origin.y,
            width: viewportSize.width / zoom,
            height: viewportSize.height / zoom
        )
    }

    public func screenPoint(fromCanvas point: CanvasPoint) -> CanvasPoint {
        CanvasPoint(
            x: point.x * zoom + translation.x,
            y: point.y * zoom + translation.y
        )
    }

    public func canvasPoint(fromScreen point: CanvasPoint) -> CanvasPoint {
        CanvasPoint(
            x: (point.x - translation.x) / zoom,
            y: (point.y - translation.y) / zoom
        )
    }

    public func panned(byScreen delta: CanvasPoint) throws -> CanvasViewport {
        guard delta.x.isFinite, delta.y.isFinite else {
            throw CanvasViewportError.invalidDelta
        }
        guard isValid else {
            throw CanvasViewportError.nonfiniteResult
        }
        let nextTranslation = CanvasPoint(
            x: translation.x + delta.x,
            y: translation.y + delta.y
        )
        guard nextTranslation.x.isFinite, nextTranslation.y.isFinite else {
            throw CanvasViewportError.nonfiniteResult
        }
        return try CanvasViewport(
            zoom: zoom,
            translation: nextTranslation,
            viewportSize: viewportSize
        )
    }

    public func zoomed(
        by factor: Double,
        anchoredAtScreen anchor: CanvasPoint
    ) throws -> CanvasViewport {
        guard factor.isFinite, factor > 0 else {
            throw CanvasViewportError.invalidFactor
        }
        guard anchor.x.isFinite, anchor.y.isFinite else {
            throw CanvasViewportError.invalidAnchor
        }
        guard isValid else {
            throw CanvasViewportError.nonfiniteResult
        }
        let fixedCanvasPoint = canvasPoint(fromScreen: anchor)
        let requestedZoom = zoom * factor
        guard fixedCanvasPoint.x.isFinite, fixedCanvasPoint.y.isFinite,
              requestedZoom.isFinite, requestedZoom > 0 else {
            throw CanvasViewportError.nonfiniteResult
        }
        let nextZoom = Self.clampedZoom(requestedZoom)
        let nextTranslation = CanvasPoint(
            x: anchor.x.addingProduct(-fixedCanvasPoint.x, nextZoom),
            y: anchor.y.addingProduct(-fixedCanvasPoint.y, nextZoom)
        )
        guard nextTranslation.x.isFinite, nextTranslation.y.isFinite else {
            throw CanvasViewportError.nonfiniteResult
        }
        return try CanvasViewport(
            zoom: nextZoom,
            translation: nextTranslation,
            viewportSize: viewportSize
        )
    }

    public var isValid: Bool {
        zoom.isFinite && zoom > 0
            && translation.x.isFinite && translation.y.isFinite
            && viewportSize.width.isFinite && viewportSize.height.isFinite
            && viewportSize.width >= 0 && viewportSize.height >= 0
    }

    private static func clampedZoom(_ zoom: Double) -> Double {
        guard zoom.isFinite else {
            return zoomRange.lowerBound
        }
        return min(zoomRange.upperBound, max(zoomRange.lowerBound, zoom))
    }
}

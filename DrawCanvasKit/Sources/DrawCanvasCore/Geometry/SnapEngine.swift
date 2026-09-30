import Foundation

public enum SnapGuide: Hashable, Sendable {
    case vertical(canvasX: Double)
    case horizontal(canvasY: Double)
}

public struct SnapResult: Hashable, Sendable {
    public var point: CanvasPoint
    public var guides: [SnapGuide]

    public init(point: CanvasPoint, guides: [SnapGuide]) {
        self.point = point
        self.guides = guides
    }
}

public struct SnapConfiguration: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    public var screenThreshold: Double
    public var gridSpacing: Double
    public var snapToGrid: Bool

    public init(screenThreshold: Double, gridSpacing: Double, snapToGrid: Bool, isEnabled: Bool = true) {
        self.isEnabled = isEnabled
        self.screenThreshold = screenThreshold
        self.gridSpacing = gridSpacing
        self.snapToGrid = snapToGrid
    }

    public func validate() throws {
        try requireFinite(
            screenThreshold,
            field: "snapConfiguration.screenThreshold"
        )
        guard screenThreshold >= 0 else {
            throw CanvasValidationError(
                field: "snapConfiguration.screenThreshold",
                reason: "must not be negative"
            )
        }
        try requireFinite(gridSpacing, field: "snapConfiguration.gridSpacing")
        guard gridSpacing > 0 else {
            throw CanvasValidationError(
                field: "snapConfiguration.gridSpacing",
                reason: "must be greater than zero"
            )
        }
        guard gridSpacing.isNormal else {
            throw CanvasValidationError(
                field: "snapConfiguration.gridSpacing",
                reason: "must be normal"
            )
        }
    }
}

public enum SnapEngine {
    public static func snap(
        point: CanvasPoint,
        excluding id: UUID?,
        elements: [CanvasElement],
        viewport: CanvasViewport,
        configuration: SnapConfiguration
    ) -> SnapResult {
        guard point.x.isFinite, point.y.isFinite else {
            return SnapResult(
                point: CanvasPoint(
                    x: point.x.isFinite ? point.x : 0,
                    y: point.y.isFinite ? point.y : 0
                ),
                guides: []
            )
        }

        guard configuration.isEnabled else { return SnapResult(point: point, guides: []) }
        let canvasThreshold: Double?
        if configuration.screenThreshold.isFinite,
           configuration.screenThreshold >= 0,
           viewport.zoom.isFinite,
           viewport.zoom > 0 {
            let convertedThreshold = configuration.screenThreshold / viewport.zoom
            canvasThreshold = convertedThreshold.isFinite ? convertedThreshold : nil
        } else {
            canvasThreshold = nil
        }

        let eligibleElements = elements.filter { $0.id != id }
        if let canvasThreshold {
            if let target = nearestPointTarget(
                to: point,
                in: eligibleElements,
                threshold: canvasThreshold
            ) {
                return SnapResult(
                    point: target,
                    guides: [
                        .vertical(canvasX: target.x),
                        .horizontal(canvasY: target.y),
                    ]
                )
            }

            let edges = nearestEdgeTargets(
                to: point,
                in: eligibleElements,
                threshold: canvasThreshold
            )
            if edges.x != nil || edges.y != nil {
                let snappedPoint = CanvasPoint(
                    x: edges.x ?? point.x,
                    y: edges.y ?? point.y
                )
                var guides: [SnapGuide] = []
                if let x = edges.x {
                    guides.append(.vertical(canvasX: x))
                }
                if let y = edges.y {
                    guides.append(.horizontal(canvasY: y))
                }
                return SnapResult(point: snappedPoint, guides: guides)
            }
        }

        guard configuration.snapToGrid,
              configuration.gridSpacing.isFinite,
              configuration.gridSpacing > 0,
              let x = gridValue(for: point.x, spacing: configuration.gridSpacing),
              let y = gridValue(for: point.y, spacing: configuration.gridSpacing) else {
            return SnapResult(point: point, guides: [])
        }
        return SnapResult(point: CanvasPoint(x: x, y: y), guides: [])
    }
}

private extension SnapEngine {
    static func nearestPointTarget(
        to point: CanvasPoint,
        in elements: [CanvasElement],
        threshold: Double
    ) -> CanvasPoint? {
        var nearest: CanvasPoint?
        var nearestDistance = Double.infinity

        for target in elements.flatMap(geometryPointTargets) {
            let distance = point.distance(to: target)
            guard distance.isFinite,
                  distance <= threshold,
                  distance < nearestDistance else {
                continue
            }
            nearest = target
            nearestDistance = distance
        }
        return nearest
    }

    static func nearestEdgeTargets(
        to point: CanvasPoint,
        in elements: [CanvasElement],
        threshold: Double
    ) -> (x: Double?, y: Double?) {
        var nearestX: Double?
        var nearestXDistance = Double.infinity
        var nearestY: Double?
        var nearestYDistance = Double.infinity

        for element in elements {
            let bounds = element.bounds
            guard bounds.isFinite, bounds.width >= 0, bounds.height >= 0 else {
                continue
            }

            for target in [bounds.minX, bounds.maxX] {
                let distance = abs(point.x - target)
                if distance.isFinite, distance <= threshold, distance < nearestXDistance {
                    nearestX = target
                    nearestXDistance = distance
                }
            }
            for target in [bounds.minY, bounds.maxY] {
                let distance = abs(point.y - target)
                if distance.isFinite, distance <= threshold, distance < nearestYDistance {
                    nearestY = target
                    nearestYDistance = distance
                }
            }
        }
        return (nearestX, nearestY)
    }

    static func geometryPointTargets(for element: CanvasElement) -> [CanvasPoint] {
        let points: [CanvasPoint]
        switch element.geometry {
        case .line(let line):
            points = [line.start, line.end]
        case .rectangle(let rectangle):
            points = corners(of: rectangle.rect)
        case .arch(let arch):
            points = [arch.start, arch.end]
        case .freehand(let stroke):
            points = stroke.points
        case .text:
            points = corners(of: element.bounds)
        }
        return points.filter { $0.x.isFinite && $0.y.isFinite }
    }

    static func corners(of rect: CanvasRect) -> [CanvasPoint] {
        guard rect.isFinite, rect.width >= 0, rect.height >= 0 else {
            return []
        }
        return [
            CanvasPoint(x: rect.minX, y: rect.minY),
            CanvasPoint(x: rect.maxX, y: rect.minY),
            CanvasPoint(x: rect.maxX, y: rect.maxY),
            CanvasPoint(x: rect.minX, y: rect.maxY),
        ]
    }

    static func gridValue(for value: Double, spacing: Double) -> Double? {
        let gridCoordinate = value / spacing
        guard gridCoordinate.isFinite else {
            return nil
        }
        let snapped = gridCoordinate.rounded() * spacing
        return snapped.isFinite ? snapped : nil
    }
}

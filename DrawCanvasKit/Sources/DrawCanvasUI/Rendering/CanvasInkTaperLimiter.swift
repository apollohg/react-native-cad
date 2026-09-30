import DrawCanvasCore
import Foundation

enum CanvasInkTaperLimiter {
    private static let maximumRadiusSlope = 0.95

    static func limit(
        _ vertices: [CanvasInkVertex],
        lineWidth: Double,
        precedingVertex: CanvasInkVertex? = nil
    ) -> [CanvasInkVertex] {
        guard lineWidth.isFinite, lineWidth > 0 else { return vertices }

        var prior = precedingVertex
        return vertices.map { vertex in
            guard let previous = prior else {
                prior = vertex
                return vertex
            }

            let distance = hypot(
                vertex.point.x - previous.point.x,
                vertex.point.y - previous.point.y
            )
            let maximumChange = 2 * distance * maximumRadiusSlope / lineWidth
            let widthFactor = min(
                previous.widthFactor + maximumChange,
                max(previous.widthFactor - maximumChange, vertex.widthFactor)
            )
            let limited = CanvasInkVertex(point: vertex.point, widthFactor: widthFactor)
            prior = limited
            return limited
        }
    }
}

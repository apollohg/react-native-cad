import DrawCanvasCore

enum CanvasInkVisibilityPolicy {
    static func apply(
        to vertices: [CanvasInkVertex],
        lineWidth: Double,
        pixelsPerCanvasUnit: Double,
        pressureEnabled: Bool
    ) throws -> [CanvasInkVertex] {
        guard lineWidth.isFinite,
              lineWidth > 0,
              pixelsPerCanvasUnit.isFinite,
              pixelsPerCanvasUnit > 0 else {
            throw CanvasInkCurveError.invalidInput
        }
        guard pressureEnabled else { return vertices }
        let physicalLineWidth = lineWidth * pixelsPerCanvasUnit
        guard physicalLineWidth.isFinite, physicalLineWidth > 0 else {
            throw CanvasInkCurveError.invalidInput
        }
        let minimumWidthFactor = 1 / physicalLineWidth
        return vertices.map {
            CanvasInkVertex(
                point: $0.point,
                widthFactor: max($0.widthFactor, minimumWidthFactor)
            )
        }
    }
}

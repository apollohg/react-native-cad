import CoreGraphics
import DrawCanvasCore

enum CanvasInkRenderingMode: Equatable {
    case centerline(widthFactor: Double)
    case compound
}

struct CanvasInkRenderPath {
    let path: CGPath
    let mode: CanvasInkRenderingMode
}

enum CanvasInkOutlineBuilder {
    static func makePath(
        snapshot: CanvasPreparedInkSnapshot,
        viewportScale: Double,
        lineWidth: Double
    ) throws -> CGPath {
        let visibleVertices = try CanvasInkVisibilityPolicy.apply(
            to: flattenedVertices(
                snapshot: snapshot,
                viewportScale: viewportScale,
                lineWidth: lineWidth
            ),
            lineWidth: lineWidth,
            pixelsPerCanvasUnit: viewportScale,
            pressureEnabled: snapshot.pressureEnabled
        )
        let vertices = CanvasInkTaperLimiter.limit(
            visibleVertices,
            lineWidth: lineWidth
        )
        return try makeCompoundPath(vertices: vertices, lineWidth: lineWidth)
    }

    static func makeRenderPath(
        snapshot: CanvasPreparedInkSnapshot,
        viewportScale: Double,
        lineWidth: Double,
        uniformViewportScale: Double
    ) throws -> CanvasInkRenderPath {
        let visibleVertices = try CanvasInkVisibilityPolicy.apply(
            to: flattenedVertices(
                snapshot: snapshot,
                viewportScale: viewportScale,
                lineWidth: lineWidth
            ),
            lineWidth: lineWidth,
            pixelsPerCanvasUnit: viewportScale,
            pressureEnabled: snapshot.pressureEnabled
        )
        let vertices = CanvasInkTaperLimiter.limit(
            visibleVertices,
            lineWidth: lineWidth
        )
        if vertices.count > 1,
           let widthFactor = vertices.first?.widthFactor,
           vertices.dropFirst().allSatisfy({ $0.widthFactor == widthFactor }) {
            let centerlineVertices: [CanvasInkVertex]
            if uniformViewportScale == viewportScale {
                centerlineVertices = vertices
            } else {
                let uniformVisibleVertices = try CanvasInkVisibilityPolicy.apply(
                    to: flattenedVertices(
                        snapshot: snapshot,
                        viewportScale: uniformViewportScale,
                        lineWidth: lineWidth
                    ),
                    lineWidth: lineWidth,
                    pixelsPerCanvasUnit: uniformViewportScale,
                    pressureEnabled: snapshot.pressureEnabled
                )
                centerlineVertices = CanvasInkTaperLimiter.limit(
                    uniformVisibleVertices,
                    lineWidth: lineWidth
                )
            }
            guard centerlineVertices.allSatisfy({ $0.widthFactor == widthFactor }) else {
                return CanvasInkRenderPath(
                    path: try makeCompoundPath(vertices: vertices, lineWidth: lineWidth),
                    mode: .compound
                )
            }
            let path = CGMutablePath()
            path.move(to: cgPoint(centerlineVertices[0].point))
            for vertex in centerlineVertices.dropFirst() {
                path.addLine(to: cgPoint(vertex.point))
            }
            return CanvasInkRenderPath(
                path: path,
                mode: .centerline(widthFactor: widthFactor)
            )
        }
        return CanvasInkRenderPath(
            path: try makeCompoundPath(vertices: vertices, lineWidth: lineWidth),
            mode: .compound
        )
    }
}

private extension CanvasInkOutlineBuilder {
    static func flattenedVertices(
        snapshot: CanvasPreparedInkSnapshot,
        viewportScale: Double,
        lineWidth: Double
    ) throws -> [CanvasInkVertex] {
        guard viewportScale.isFinite, viewportScale > 0 else {
            throw CanvasInkCurveError.invalidInput
        }
        let maximumError = 0.25 / viewportScale
        guard maximumError.isFinite, maximumError > 0 else {
            throw CanvasInkCurveError.invalidInput
        }
        let pixelLineWidth = lineWidth * viewportScale
        let maximumWidthError = 0.5 / max(pixelLineWidth, 0.5)
        guard maximumWidthError.isFinite, maximumWidthError > 0 else {
            throw CanvasInkCurveError.invalidInput
        }
        return try CanvasInkCurve.flatten(
            stroke: CanvasInkStroke(
                samples: snapshot.confirmed + snapshot.predicted,
                pressureEnabled: snapshot.pressureEnabled,
                widthMode: snapshot.widthMode
            ),
            maximumError: maximumError,
            maximumWidthError: maximumWidthError
        )
    }

    static func makeCompoundPath(
        vertices: [CanvasInkVertex],
        lineWidth: Double
    ) throws -> CGPath {
        let path = CGMutablePath()
        guard lineWidth.isFinite, lineWidth > 0 else {
            throw CanvasInkCurveError.invalidInput
        }

        if vertices.count > 1 {
            for index in 1..<vertices.count {
                appendExternalTangentHull(
                    from: vertices[index - 1],
                    to: vertices[index],
                    lineWidth: lineWidth,
                    path: path
                )
            }
        }
        for vertex in vertices {
            let radius = lineWidth * vertex.widthFactor / 2
            guard radius.isFinite, radius > 0 else {
                throw CanvasInkCurveError.invalidInput
            }
            path.addEllipse(in: CGRect(
                x: vertex.point.x - radius,
                y: vertex.point.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
        }
        return path
    }

    static func cgPoint(_ point: CanvasPoint) -> CGPoint {
        CGPoint(x: point.x, y: point.y)
    }

    static func appendExternalTangentHull(
        from start: CanvasInkVertex,
        to end: CanvasInkVertex,
        lineWidth: Double,
        path: CGMutablePath
    ) {
        let startRadius = lineWidth * start.widthFactor / 2
        let endRadius = lineWidth * end.widthFactor / 2
        let dx = end.point.x - start.point.x
        let dy = end.point.y - start.point.y
        let distance = hypot(dx, dy)
        let radiusDifference = endRadius - startRadius
        guard startRadius.isFinite,
              endRadius.isFinite,
              dx.isFinite,
              dy.isFinite,
              distance.isFinite,
              distance > abs(radiusDifference) else {
            return
        }

        let unitX = dx / distance
        let unitY = dy / distance
        let normalAlongSegment = min(1, max(-1, -radiusDifference / distance))
        let normalAcrossSegment = sqrt(max(0, 1 - normalAlongSegment * normalAlongSegment))
        let firstNormalX = unitX * normalAlongSegment - unitY * normalAcrossSegment
        let firstNormalY = unitY * normalAlongSegment + unitX * normalAcrossSegment
        let secondNormalX = unitX * normalAlongSegment + unitY * normalAcrossSegment
        let secondNormalY = unitY * normalAlongSegment - unitX * normalAcrossSegment

        path.move(to: CGPoint(
            x: start.point.x + secondNormalX * startRadius,
            y: start.point.y + secondNormalY * startRadius
        ))
        path.addLine(to: CGPoint(
            x: end.point.x + secondNormalX * endRadius,
            y: end.point.y + secondNormalY * endRadius
        ))
        path.addLine(to: CGPoint(
            x: end.point.x + firstNormalX * endRadius,
            y: end.point.y + firstNormalY * endRadius
        ))
        path.addLine(to: CGPoint(
            x: start.point.x + firstNormalX * startRadius,
            y: start.point.y + firstNormalY * startRadius
        ))
        path.closeSubpath()
    }
}

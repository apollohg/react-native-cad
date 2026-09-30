import Foundation

public struct HeuristicShapeRecognizer: ShapeRecognizing {
    public init() {}

    public func recognize(_ sample: StrokeSample) -> RecognitionResult? {
        let points = sample.points
        guard points.count >= 2,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              let extent = Extent(points: points),
              extent.maxDimension > 0 else {
            return nil
        }

        let pathLength = zip(points, points.dropFirst()).reduce(0.0) {
            $0 + $1.0.distance(to: $1.1)
        }
        guard pathLength.isFinite, pathLength > 0 else {
            return nil
        }

        let closureTolerance = min(12, extent.maxDimension * 0.08)
        let isClosed = points[0].distance(to: points[points.count - 1]) <= closureTolerance
        if isClosed,
           pathLength >= closureTolerance * 2,
           let rectangle = recognizeRectangle(points, extent: extent) {
            return validated(rectangle)
        }

        let simplificationTolerance = max(0.5, extent.maxDimension * 0.01)
        guard let simplified = PathSimplifier.simplify(
            points,
            tolerance: simplificationTolerance,
            operationBudget: 1_000_000
        ) else {
            return nil
        }
        if let line = recognizeLine(points, extent: extent) {
            return validated(line)
        }
        if let arch = recognizeArch(points, simplified: simplified, extent: extent) {
            return validated(arch)
        }
        return nil
    }

    private func recognizeRectangle(
        _ points: [CanvasPoint],
        extent: Extent
    ) -> RecognitionResult? {
        guard extent.width > 0, extent.height > 0 else {
            return nil
        }

        let tolerance = max(1.5, extent.maxDimension * 0.04)
        var maximumError = 0.0
        var pointSides: [Set<RectangleSide>] = []
        for point in points {
            let distances = [
                (RectangleSide.top, abs(point.y - extent.minY)),
                (.right, abs(point.x - extent.maxX)),
                (.bottom, abs(point.y - extent.maxY)),
                (.left, abs(point.x - extent.minX)),
            ]
            guard let closest = distances.min(by: { lhs, rhs in
                lhs.1 == rhs.1 ? lhs.0.rawValue < rhs.0.rawValue : lhs.1 < rhs.1
            }) else {
                return nil
            }
            maximumError = max(maximumError, closest.1)
            let nearbySides = Set(distances.compactMap { side, distance in
                distance <= tolerance ? side : nil
            })
            pointSides.append(nearbySides)
        }

        var traversedSides = Set<RectangleSide>()
        for (firstSides, secondSides) in zip(pointSides, pointSides.dropFirst()) {
            let sharedSides = firstSides.intersection(secondSides)
            guard !sharedSides.isEmpty else {
                return nil
            }
            if sharedSides.count == 1 {
                traversedSides.formUnion(sharedSides)
            }
        }
        guard maximumError <= tolerance,
              traversedSides.count == RectangleSide.allCases.count else {
            return nil
        }

        let geometry = CanvasGeometry.rectangle(
            .init(
                rect: .init(
                    x: extent.minX,
                    y: extent.minY,
                    width: extent.width,
                    height: extent.height
                )
            )
        )
        return RecognitionResult(
            geometry: geometry,
            confidence: confidence(error: maximumError, tolerance: tolerance)
        )
    }

    private func recognizeLine(
        _ points: [CanvasPoint],
        extent: Extent
    ) -> RecognitionResult? {
        guard let first = points.first, let last = points.last else {
            return nil
        }
        let length = first.distance(to: last)
        let tolerance = max(1.5, extent.maxDimension * 0.03)
        guard length.isFinite,
              length > tolerance else {
            return nil
        }

        let maximumError = points.map {
            distanceFromSegment($0, start: first, end: last)
        }.max() ?? .infinity
        guard maximumError.isFinite, maximumError <= tolerance else {
            return nil
        }

        return RecognitionResult(
            geometry: .line(.init(start: first, end: last)),
            confidence: confidence(error: maximumError, tolerance: tolerance)
        )
    }

    private func recognizeArch(
        _ points: [CanvasPoint],
        simplified: [CanvasPoint],
        extent: Extent
    ) -> RecognitionResult? {
        guard simplified.count >= 3,
              let first = points.first,
              let last = points.last else {
            return nil
        }

        let dx = last.x - first.x
        let dy = last.y - first.y
        let chordLength = hypot(dx, dy)
        guard chordLength.isFinite, chordLength > 0 else {
            return nil
        }
        let normal = CanvasPoint(x: -dy / chordLength, y: dx / chordLength)
        let signedDistances = points.map { point in
            (point.x - first.x) * normal.x + (point.y - first.y) * normal.y
        }
        guard let sagitta = signedDistances.max(by: { abs($0) < abs($1) }) else {
            return nil
        }

        let minimumSagitta = max(1.5, extent.maxDimension * 0.04)
        guard abs(sagitta) >= minimumSagitta else {
            return nil
        }
        let oppositeSideTolerance = max(1, abs(sagitta) * 0.15)
        guard signedDistances.allSatisfy({ distance in
            distance == 0 || distance.sign == sagitta.sign || abs(distance) <= oppositeSideTolerance
        }) else {
            return nil
        }

        let arch = CanvasArch(start: first, end: last, sagitta: sagitta)
        guard let parameters = try? ArchGeometry.parameters(for: arch) else {
            return nil
        }
        let radialTolerance = max(1.5, extent.maxDimension * 0.03)
        let radialErrors = points.map {
            abs(parameters.center.distance(to: $0) - parameters.radius)
        }
        guard let maximumError = radialErrors.max(),
              maximumError.isFinite,
              maximumError <= radialTolerance,
              points.dropFirst().dropLast().allSatisfy({ point in
                  parameters.contains(
                    angle: atan2(point.y - parameters.center.y, point.x - parameters.center.x)
                  )
              }) else {
            return nil
        }

        return RecognitionResult(
            geometry: .arch(arch),
            confidence: confidence(error: maximumError, tolerance: radialTolerance)
        )
    }

    private func validated(_ result: RecognitionResult) -> RecognitionResult? {
        guard result.confidence.isFinite,
              (0 ... 1).contains(result.confidence),
              result.geometry.bounds.isFinite,
              !result.geometry.renderPath.commands.isEmpty else {
            return nil
        }

        let validationDocument = CanvasDocument(
            elements: [CanvasElement(id: UUID(), geometry: result.geometry)]
        )
        guard (try? validationDocument.validate()) != nil else {
            return nil
        }

        if case .arch(let arch) = result.geometry {
            guard (try? ArchGeometry.bounds(for: arch))?.isFinite == true,
                  (try? ArchGeometry.renderPath(for: arch))?.commands.isEmpty == false else {
                return nil
            }
        }
        return result
    }

    private func confidence(error: Double, tolerance: Double) -> Double {
        min(1, max(0, 1 - error / tolerance))
    }

    private func distanceFromSegment(
        _ point: CanvasPoint,
        start: CanvasPoint,
        end: CanvasPoint
    ) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0, length.isFinite else {
            return point.distance(to: start)
        }
        let unitX = dx / length
        let unitY = dy / length
        let along = (point.x - start.x) * unitX + (point.y - start.y) * unitY
        guard along.isFinite else {
            return .infinity
        }
        let projection = min(
            length,
            max(0, along)
        )
        return point.distance(
            to: .init(x: start.x + projection * unitX, y: start.y + projection * unitY)
        )
    }
}

private struct Extent {
    let minX: Double
    let maxX: Double
    let minY: Double
    let maxY: Double

    var width: Double { maxX - minX }
    var height: Double { maxY - minY }
    var maxDimension: Double { max(width, height) }

    init?(points: [CanvasPoint]) {
        guard let first = points.first else {
            return nil
        }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        guard minX.isFinite, maxX.isFinite, minY.isFinite, maxY.isFinite else {
            return nil
        }
        self.minX = minX
        self.maxX = maxX
        self.minY = minY
        self.maxY = maxY
    }
}

private enum RectangleSide: Int, CaseIterable {
    case top
    case right
    case bottom
    case left
}

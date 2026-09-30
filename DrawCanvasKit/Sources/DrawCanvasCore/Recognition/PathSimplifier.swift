import Foundation

enum PathSimplifier {
    static func simplify(
        _ points: [CanvasPoint],
        tolerance: Double,
        operationBudget: Int = .max
    ) -> [CanvasPoint]? {
        guard points.count > 2, tolerance.isFinite, tolerance >= 0 else {
            return points
        }
        guard operationBudget >= 0 else { return nil }

        var retained = Array(repeating: false, count: points.count)
        retained[0] = true
        retained[points.count - 1] = true
        var pending = [(first: 0, last: points.count - 1)]
        var operations = 0

        while let range = pending.popLast() {
            let rangeOperations = max(0, range.last - range.first - 1)
            guard rangeOperations <= operationBudget - operations else { return nil }
            operations += rangeOperations
            guard let split = maximumDeviationIndex(
                in: points,
                first: range.first,
                last: range.last,
                tolerance: tolerance
            ) else {
                continue
            }
            retained[split] = true
            pending.append((split, range.last))
            pending.append((range.first, split))
        }
        return points.indices.compactMap { retained[$0] ? points[$0] : nil }
    }

    private static func maximumDeviationIndex(
        in points: [CanvasPoint],
        first firstIndex: Int,
        last lastIndex: Int,
        tolerance: Double
    ) -> Int? {
        guard lastIndex > firstIndex + 1 else {
            return nil
        }

        let first = points[firstIndex]
        let last = points[lastIndex]
        var maximumDistance = -Double.infinity
        var maximumIndex: Int?

        for index in (firstIndex + 1)..<lastIndex {
            let distance = perpendicularDistance(from: points[index], to: first, and: last)
            if distance > maximumDistance {
                maximumDistance = distance
                maximumIndex = index
            }
        }

        return maximumDistance > tolerance ? maximumIndex : nil
    }

    private static func perpendicularDistance(
        from point: CanvasPoint,
        to first: CanvasPoint,
        and last: CanvasPoint
    ) -> Double {
        let dx = last.x - first.x
        let dy = last.y - first.y
        let baselineLength = hypot(dx, dy)
        guard baselineLength > 0, baselineLength.isFinite else {
            return point.distance(to: first)
        }
        let unitNormalX = -dy / baselineLength
        let unitNormalY = dx / baselineLength
        let offsetX = point.x - first.x
        let offsetY = point.y - first.y
        return abs(offsetX * unitNormalX + offsetY * unitNormalY)
    }
}

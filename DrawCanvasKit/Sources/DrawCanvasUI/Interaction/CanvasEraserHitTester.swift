import Foundation
import DrawCanvasCore

package struct CanvasEraserHitTester: Sendable {
    private var documentID: UUID?
    private var replacementGeneration: CanvasGeneration?
    private var cache: [UUID: CacheEntry] = [:]

    package init() {}

    package static func hoverTarget(
        at point: CanvasPoint,
        elements: [CanvasElement],
        viewport: CanvasViewport,
        toleranceScreen: Double
    ) -> UUID? {
        var tester = CanvasEraserHitTester()
        return tester.cachedHoverTarget(
            at: point,
            elements: elements,
            viewport: viewport,
            toleranceScreen: toleranceScreen
        )
    }

    package static func sweptTargets(
        from start: CanvasPoint,
        to end: CanvasPoint,
        elements: [CanvasElement],
        viewport: CanvasViewport,
        toleranceScreen: Double
    ) -> [UUID] {
        var tester = CanvasEraserHitTester()
        return tester.cachedSweptTargets(
            along: [start, end],
            elements: elements,
            excluding: [],
            viewport: viewport,
            toleranceScreen: toleranceScreen
        )
    }

    package mutating func useDocument(
        id: UUID,
        replacementGeneration: CanvasGeneration
    ) {
        guard documentID != id || self.replacementGeneration != replacementGeneration else {
            return
        }
        documentID = id
        self.replacementGeneration = replacementGeneration
        cache.removeAll(keepingCapacity: true)
    }

    package mutating func cachedHoverTarget(
        at point: CanvasPoint,
        elements: [CanvasElement],
        viewport: CanvasViewport,
        toleranceScreen: Double
    ) -> UUID? {
        guard let tolerance = canvasTolerance(
            screen: toleranceScreen,
            viewport: viewport
        ), finite(point) else {
            return nil
        }
        pruneCache(for: elements)
        for element in elements.reversed() {
            guard let prepared = preparedGeometry(for: element, tolerance: tolerance) else {
                continue
            }
            if prepared.hitTest(point: point, tolerance: tolerance) {
                return element.id
            }
        }
        return nil
    }

    package mutating func cachedSweptTargets(
        along points: [CanvasPoint],
        elements: [CanvasElement],
        excluding excludedIDs: Set<UUID>,
        viewport: CanvasViewport,
        toleranceScreen: Double
    ) -> [UUID] {
        guard let tolerance = canvasTolerance(
            screen: toleranceScreen,
            viewport: viewport
        ), points.count >= 2, points.allSatisfy(finite) else {
            return []
        }
        pruneCache(for: elements)
        let sweep = PreparedSweep(points: points)
        return elements.reversed().compactMap { element in
            guard !excludedIDs.contains(element.id),
                  let prepared = preparedGeometry(for: element, tolerance: tolerance),
                  prepared.hitTest(sweep: sweep, tolerance: tolerance) else {
                return nil
            }
            return element.id
        }
    }
}

private extension CanvasEraserHitTester {
    struct CacheEntry: Sendable {
        let contentRevision: UInt64
        let geometry: PreparedHitGeometry
    }

    mutating func pruneCache(for elements: [CanvasElement]) {
        let liveIDs = Set(elements.lazy.map(\.id))
        cache = cache.filter { liveIDs.contains($0.key) }
    }

    mutating func preparedGeometry(
        for element: CanvasElement,
        tolerance: Double
    ) -> PreparedHitGeometry? {
        if let entry = cache[element.id], entry.contentRevision == element.contentRevision,
           entry.geometry.isPrecise(enoughFor: tolerance) {
            return entry.geometry
        }
        guard let geometry = PreparedHitGeometry(element: element, tolerance: tolerance) else {
            cache[element.id] = nil
            return nil
        }
        cache[element.id] = CacheEntry(
            contentRevision: element.contentRevision,
            geometry: geometry
        )
        return geometry
    }

    func canvasTolerance(
        screen: Double,
        viewport: CanvasViewport
    ) -> Double? {
        guard viewport.isValid, screen.isFinite, screen >= 0 else { return nil }
        let result = screen / viewport.zoom
        return result.isFinite && result >= 0 ? result : nil
    }

    func finite(_ point: CanvasPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }
}

private enum PreparedHitGeometry: Sendable {
    case area(CanvasRect)
    case path(
        bounds: CanvasRect,
        segments: [PreparedSegment],
        flatness: Double,
        preparedTolerance: Double
    )

    init?(element: CanvasElement, tolerance: Double) {
        switch element.geometry {
        case .rectangle(let rectangle):
            guard rectangle.rect.isValid else { return nil }
            self = .area(rectangle.rect)
        case .text(let text):
            guard text.frame.isValid else { return nil }
            self = .area(text.frame)
        case .line(let line):
            guard line.start.isFinite, line.end.isFinite else { return nil }
            let segment = PreparedSegment(start: line.start, end: line.end)
            self = .path(
                bounds: segment.bounds,
                segments: [segment],
                flatness: 0,
                preparedTolerance: 0
            )
        case .arch, .freehand:
            let path = element.geometry.renderPath
            guard let bounds = path.preparedBounds else { return nil }
            guard bounds.isValid else { return nil }
            let scale = max(1, bounds.width, bounds.height)
            let flatness = max(tolerance / 4, scale * 1e-12)
            self = .path(
                bounds: bounds,
                segments: path.preparedSegments(flatness: flatness),
                flatness: flatness,
                preparedTolerance: tolerance
            )
        }
    }

    func isPrecise(enoughFor tolerance: Double) -> Bool {
        switch self {
        case .area:
            true
        case .path(_, _, let flatness, let preparedTolerance):
            flatness == 0 || preparedTolerance <= tolerance
        }
    }

    func hitTest(point: CanvasPoint, tolerance: Double) -> Bool {
        switch self {
        case .area(let bounds):
            return bounds.expanded(by: tolerance).contains(point)
        case .path(let bounds, let segments, let flatness, _):
            let effectiveTolerance = tolerance + flatness
            guard bounds.expanded(by: effectiveTolerance).contains(point) else { return false }
            let pointBounds = CanvasRect(x: point.x, y: point.y, width: 0, height: 0)
                .expanded(by: effectiveTolerance)
            return segments.contains { segment in
                intersects(segment.bounds, pointBounds)
                    && distanceFromPoint(point, toSegmentFrom: segment.start, to: segment.end)
                        <= effectiveTolerance
            }
        }
    }

    func hitTest(sweep: PreparedSweep, tolerance: Double) -> Bool {
        switch self {
        case .area(let bounds):
            let target = bounds.expanded(by: tolerance)
            guard intersects(target, sweep.bounds) else { return false }
            return sweep.segments.contains { segment in
                intersects(target, segment.bounds)
                    && target.intersectsSegment(from: segment.start, to: segment.end)
            }
        case .path(let bounds, let segments, let flatness, _):
            let effectiveTolerance = tolerance + flatness
            guard intersects(bounds.expanded(by: effectiveTolerance), sweep.bounds) else {
                return false
            }
            return segments.contains { target in
                let targetBounds = target.bounds.expanded(by: effectiveTolerance)
                guard intersects(targetBounds, sweep.bounds) else { return false }
                return sweep.segments.contains { sample in
                    intersects(targetBounds, sample.bounds)
                        && distanceBetweenSegments(
                            target.start,
                            target.end,
                            sample.start,
                            sample.end
                        ) <= effectiveTolerance
                }
            }
        }
    }
}

private struct PreparedSweep: Sendable {
    let bounds: CanvasRect
    let segments: [PreparedSegment]

    init(points: [CanvasPoint]) {
        var bounds = CanvasRect(x: points[0].x, y: points[0].y, width: 0, height: 0)
        for point in points.dropFirst() {
            bounds = bounds.including(point)
        }
        self.bounds = bounds
        segments = zip(points, points.dropFirst()).map(PreparedSegment.init)
    }
}

private struct PreparedSegment: Sendable {
    let start: CanvasPoint
    let end: CanvasPoint
    let bounds: CanvasRect

    init(start: CanvasPoint, end: CanvasPoint) {
        self.start = start
        self.end = end
        bounds = CanvasRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }
}

private extension CanvasPath {
    var preparedBounds: CanvasRect? {
        var result: CanvasRect?
        for command in commands {
            let points: [CanvasPoint]
            switch command {
            case .move(let point), .line(let point):
                points = [point]
            case .quad(let control, let end):
                points = [control, end]
            case .cubic(let control1, let control2, let end):
                points = [control1, control2, end]
            case .close:
                points = []
            }
            for point in points {
                result = result?.including(point)
                    ?? CanvasRect(x: point.x, y: point.y, width: 0, height: 0)
            }
        }
        return result
    }

    func preparedSegments(flatness: Double) -> [PreparedSegment] {
        var result: [PreparedSegment] = []
        result.reserveCapacity(commands.count)
        var current: CanvasPoint?
        var subpathStart: CanvasPoint?

        for command in commands {
            switch command {
            case .move(let destination):
                current = destination
                subpathStart = destination
            case .line(let destination):
                if let current {
                    result.append(PreparedSegment(start: current, end: destination))
                }
                current = destination
            case .quad(let control, let end):
                if let current {
                    let points = flattenedQuadratic(
                        start: current,
                        control: control,
                        end: end,
                        flatness: flatness
                    )
                    result.append(contentsOf: zip(points, points.dropFirst()).map(PreparedSegment.init))
                }
                current = end
            case .cubic(let control1, let control2, let end):
                if let current {
                    let points = flattenedCubic(
                        start: current,
                        control1: control1,
                        control2: control2,
                        end: end,
                        flatness: flatness
                    )
                    result.append(contentsOf: zip(points, points.dropFirst()).map(PreparedSegment.init))
                }
                current = end
            case .close:
                if let current, let subpathStart {
                    result.append(PreparedSegment(start: current, end: subpathStart))
                }
                current = subpathStart
            }
        }
        return result
    }
}

private extension CanvasPoint {
    var isFinite: Bool {
        x.isFinite && y.isFinite
    }
}

private extension CanvasRect {
    var isValid: Bool {
        isFinite && width >= 0 && height >= 0
    }

    func including(_ point: CanvasPoint) -> CanvasRect {
        let nextMinX = min(minX, point.x)
        let nextMinY = min(minY, point.y)
        return CanvasRect(
            x: nextMinX,
            y: nextMinY,
            width: max(maxX, point.x) - nextMinX,
            height: max(maxY, point.y) - nextMinY
        )
    }

    func expanded(by amount: Double) -> CanvasRect {
        CanvasRect(
            x: minX - amount,
            y: minY - amount,
            width: width + amount * 2,
            height: height + amount * 2
        )
    }

    func contains(_ point: CanvasPoint) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }

    func intersectsSegment(from start: CanvasPoint, to end: CanvasPoint) -> Bool {
        if contains(start) || contains(end) { return true }
        let topLeft = CanvasPoint(x: minX, y: minY)
        let topRight = CanvasPoint(x: maxX, y: minY)
        let bottomRight = CanvasPoint(x: maxX, y: maxY)
        let bottomLeft = CanvasPoint(x: minX, y: maxY)
        return segmentsIntersect(start, end, topLeft, topRight)
            || segmentsIntersect(start, end, topRight, bottomRight)
            || segmentsIntersect(start, end, bottomRight, bottomLeft)
            || segmentsIntersect(start, end, bottomLeft, topLeft)
    }
}

private func intersects(_ lhs: CanvasRect, _ rhs: CanvasRect) -> Bool {
    lhs.maxX >= rhs.minX && lhs.minX <= rhs.maxX
        && lhs.maxY >= rhs.minY && lhs.minY <= rhs.maxY
}

private func distanceFromPoint(
    _ point: CanvasPoint,
    toSegmentFrom start: CanvasPoint,
    to end: CanvasPoint
) -> Double {
    let dx = end.x - start.x
    let dy = end.y - start.y
    let squaredLength = dx * dx + dy * dy
    guard squaredLength > 0 else { return point.distance(to: start) }
    let projection = ((point.x - start.x) * dx + (point.y - start.y) * dy) / squaredLength
    let fraction = min(1, max(0, projection))
    return point.distance(to: CanvasPoint(
        x: start.x + fraction * dx,
        y: start.y + fraction * dy
    ))
}

private func distanceBetweenSegments(
    _ firstStart: CanvasPoint,
    _ firstEnd: CanvasPoint,
    _ secondStart: CanvasPoint,
    _ secondEnd: CanvasPoint
) -> Double {
    if segmentsIntersect(firstStart, firstEnd, secondStart, secondEnd) { return 0 }
    return min(
        distanceFromPoint(firstStart, toSegmentFrom: secondStart, to: secondEnd),
        distanceFromPoint(firstEnd, toSegmentFrom: secondStart, to: secondEnd),
        distanceFromPoint(secondStart, toSegmentFrom: firstStart, to: firstEnd),
        distanceFromPoint(secondEnd, toSegmentFrom: firstStart, to: firstEnd)
    )
}

private func segmentsIntersect(
    _ firstStart: CanvasPoint,
    _ firstEnd: CanvasPoint,
    _ secondStart: CanvasPoint,
    _ secondEnd: CanvasPoint
) -> Bool {
    let scale = max(
        1,
        abs(firstStart.x), abs(firstStart.y), abs(firstEnd.x), abs(firstEnd.y),
        abs(secondStart.x), abs(secondStart.y), abs(secondEnd.x), abs(secondEnd.y)
    )
    let epsilon = scale * 1e-12
    let firstSecondStart = cross(firstStart, firstEnd, secondStart)
    let firstSecondEnd = cross(firstStart, firstEnd, secondEnd)
    let secondFirstStart = cross(secondStart, secondEnd, firstStart)
    let secondFirstEnd = cross(secondStart, secondEnd, firstEnd)
    if opposite(firstSecondStart, firstSecondEnd, epsilon: epsilon),
       opposite(secondFirstStart, secondFirstEnd, epsilon: epsilon) {
        return true
    }
    return (abs(firstSecondStart) <= epsilon
        && liesOnSegment(secondStart, from: firstStart, to: firstEnd, epsilon: epsilon))
        || (abs(firstSecondEnd) <= epsilon
            && liesOnSegment(secondEnd, from: firstStart, to: firstEnd, epsilon: epsilon))
        || (abs(secondFirstStart) <= epsilon
            && liesOnSegment(firstStart, from: secondStart, to: secondEnd, epsilon: epsilon))
        || (abs(secondFirstEnd) <= epsilon
            && liesOnSegment(firstEnd, from: secondStart, to: secondEnd, epsilon: epsilon))
}

private func cross(_ start: CanvasPoint, _ end: CanvasPoint, _ point: CanvasPoint) -> Double {
    (end.x - start.x) * (point.y - start.y) - (end.y - start.y) * (point.x - start.x)
}

private func opposite(_ first: Double, _ second: Double, epsilon: Double) -> Bool {
    (first > epsilon && second < -epsilon) || (first < -epsilon && second > epsilon)
}

private func liesOnSegment(
    _ point: CanvasPoint,
    from start: CanvasPoint,
    to end: CanvasPoint,
    epsilon: Double
) -> Bool {
    point.x >= min(start.x, end.x) - epsilon
        && point.x <= max(start.x, end.x) + epsilon
        && point.y >= min(start.y, end.y) - epsilon
        && point.y <= max(start.y, end.y) + epsilon
}

private func flattenedQuadratic(
    start: CanvasPoint,
    control: CanvasPoint,
    end: CanvasPoint,
    flatness: Double
) -> [CanvasPoint] {
    var points = [start]
    appendFlattenedQuadratic(
        start: start,
        control: control,
        end: end,
        flatness: flatness,
        depth: 0,
        to: &points
    )
    return points
}

private func flattenedCubic(
    start: CanvasPoint,
    control1: CanvasPoint,
    control2: CanvasPoint,
    end: CanvasPoint,
    flatness: Double
) -> [CanvasPoint] {
    var points = [start]
    appendFlattenedCubic(
        start: start,
        control1: control1,
        control2: control2,
        end: end,
        flatness: flatness,
        depth: 0,
        to: &points
    )
    return points
}

private let maximumCurveSubdivisionDepth = 16

private func appendFlattenedQuadratic(
    start: CanvasPoint,
    control: CanvasPoint,
    end: CanvasPoint,
    flatness: Double,
    depth: Int,
    to points: inout [CanvasPoint]
) {
    guard depth < maximumCurveSubdivisionDepth,
          distanceFromPoint(control, toSegmentFrom: start, to: end) > flatness else {
        points.append(end)
        return
    }
    let startControl = midpoint(start, control)
    let controlEnd = midpoint(control, end)
    let split = midpoint(startControl, controlEnd)
    appendFlattenedQuadratic(
        start: start,
        control: startControl,
        end: split,
        flatness: flatness,
        depth: depth + 1,
        to: &points
    )
    appendFlattenedQuadratic(
        start: split,
        control: controlEnd,
        end: end,
        flatness: flatness,
        depth: depth + 1,
        to: &points
    )
}

private func appendFlattenedCubic(
    start: CanvasPoint,
    control1: CanvasPoint,
    control2: CanvasPoint,
    end: CanvasPoint,
    flatness: Double,
    depth: Int,
    to points: inout [CanvasPoint]
) {
    let controlFlatness = max(
        distanceFromPoint(control1, toSegmentFrom: start, to: end),
        distanceFromPoint(control2, toSegmentFrom: start, to: end)
    )
    guard depth < maximumCurveSubdivisionDepth, controlFlatness > flatness else {
        points.append(end)
        return
    }
    let firstMidpoint = midpoint(start, control1)
    let controlMidpoint = midpoint(control1, control2)
    let lastMidpoint = midpoint(control2, end)
    let firstControl = midpoint(firstMidpoint, controlMidpoint)
    let secondControl = midpoint(controlMidpoint, lastMidpoint)
    let split = midpoint(firstControl, secondControl)
    appendFlattenedCubic(
        start: start,
        control1: firstMidpoint,
        control2: firstControl,
        end: split,
        flatness: flatness,
        depth: depth + 1,
        to: &points
    )
    appendFlattenedCubic(
        start: split,
        control1: secondControl,
        control2: lastMidpoint,
        end: end,
        flatness: flatness,
        depth: depth + 1,
        to: &points
    )
}

private func midpoint(_ first: CanvasPoint, _ second: CanvasPoint) -> CanvasPoint {
    CanvasPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
}

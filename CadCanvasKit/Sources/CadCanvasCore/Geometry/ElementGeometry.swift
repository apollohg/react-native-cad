import Foundation

public enum CanvasGeometryKind: String, Codable, Hashable, Sendable {
    case line
    case rectangle
    case arch
    case freehand
    case text
}

public enum CanvasGeometryError: Error, Equatable, Sendable {
    case invalidBounds
    case unsupportedResize(CanvasGeometryKind)
    case degenerateSourceBounds(CanvasGeometryKind)
    case revisionOverflow
}

public extension CanvasPoint {
    func distance(to other: CanvasPoint) -> Double {
        hypot(x - other.x, y - other.y)
    }
}

public extension CanvasRect {
    var isFinite: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite
    }
}

public extension CanvasPath {
    var bounds: CanvasRect {
        let points = commands.flatMap(\CanvasPathCommand.geometryPoints)
        guard let first = points.first else {
            return CanvasRect(x: 0, y: 0, width: 0, height: 0)
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
        return CanvasRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

public extension CanvasGeometry {
    var kind: CanvasGeometryKind {
        switch self {
        case .line:
            .line
        case .rectangle:
            .rectangle
        case .arch:
            .arch
        case .freehand:
            .freehand
        case .text:
            .text
        }
    }

    var bounds: CanvasRect {
        switch self {
        case .line(let line):
            rectContaining([line.start, line.end])
        case .rectangle(let rectangle):
            rectangle.rect
        case .arch(let arch):
            (try? ArchGeometry.bounds(for: arch)) ?? rectContaining([arch.start, arch.end])
        case .freehand(let stroke):
            (try? CanvasInkCurve.bounds(stroke: stroke)) ?? stroke.bounds
        case .text(let text):
            text.frame
        }
    }

    var renderPath: CanvasPath {
        switch self {
        case .line(let line):
            return CanvasPath(commands: [.move(line.start), .line(line.end)])
        case .rectangle(let rectangle):
            let rect = rectangle.rect
            return CanvasPath(commands: [
                .move(.init(x: rect.minX, y: rect.minY)),
                .line(.init(x: rect.maxX, y: rect.minY)),
                .line(.init(x: rect.maxX, y: rect.maxY)),
                .line(.init(x: rect.minX, y: rect.maxY)),
                .close,
            ])
        case .arch(let arch):
            return (try? ArchGeometry.renderPath(for: arch))
                ?? CanvasPath(commands: [.move(arch.start), .line(arch.end)])
        case .freehand(let stroke):
            let points = stroke.points
            guard let first = points.first else {
                return CanvasPath(commands: [])
            }
            return CanvasPath(
                commands: [.move(first)] + points.dropFirst().map(CanvasPathCommand.line)
            )
        case .text:
            return CanvasPath(commands: [])
        }
    }

    func hitTest(
        _ point: CanvasPoint,
        tolerance: Double,
        textBounds: CanvasRect?,
        maximumFreehandWidthInCanvasUnits: Double = 0
    ) -> Bool {
        guard point.x.isFinite, point.y.isFinite, tolerance.isFinite, tolerance >= 0 else {
            return false
        }

        switch self {
        case .line(let line):
            return distanceFromPoint(point, toSegmentFrom: line.start, to: line.end) <= tolerance
        case .rectangle(let rectangle):
            return rectangle.rect.expanded(by: tolerance).contains(point)
        case .arch(let arch):
            return ArchGeometry.hitTest(point, arch: arch, tolerance: tolerance)
        case .freehand(let stroke):
            return (try? CanvasInkCurve.hitTest(
                point,
                stroke: stroke,
                tolerance: tolerance,
                maximumWidthInCanvasUnits: maximumFreehandWidthInCanvasUnits
            )) ?? false
        case .text:
            guard let textBounds, textBounds.isFinite else {
                return false
            }
            return textBounds.expanded(by: tolerance).contains(point)
        }
    }

    package func hitTest(
        segmentFrom start: CanvasPoint,
        to end: CanvasPoint,
        tolerance: Double,
        textBounds: CanvasRect?
    ) -> Bool {
        guard start.x.isFinite, start.y.isFinite,
              end.x.isFinite, end.y.isFinite,
              tolerance.isFinite, tolerance >= 0 else {
            return false
        }
        if start == end {
            return hitTest(start, tolerance: tolerance, textBounds: textBounds)
        }

        switch self {
        case .line(let line):
            return distanceBetweenSegments(start, end, line.start, line.end) <= tolerance
        case .rectangle(let rectangle):
            return rectangle.rect.expanded(by: tolerance).intersectsSegment(from: start, to: end)
        case .arch:
            return renderPath.hitTest(segmentFrom: start, to: end, tolerance: tolerance)
        case .freehand:
            return renderPath.hitTest(segmentFrom: start, to: end, tolerance: tolerance)
        case .text:
            guard let textBounds, textBounds.isFinite,
                  textBounds.width >= 0, textBounds.height >= 0 else {
                return false
            }
            return textBounds.expanded(by: tolerance).intersectsSegment(from: start, to: end)
        }
    }
}

public extension CanvasElement {
    var bounds: CanvasRect {
        geometry.bounds
    }

    func hitTest(
        _ point: CanvasPoint,
        tolerance: Double,
        viewport: CanvasViewport
    ) -> Bool {
        let maximumFreehandWidth: Double
        if case .freehand(let stroke) = geometry {
            guard let width = try? CanvasInkCurve.maximumPaintedWidthInCanvasUnits(
                lineWidth: style.lineWidth,
                viewportZoom: viewport.zoom,
                pressureEnabled: stroke.pressureEnabled,
                widthMode: stroke.widthMode
            ) else {
                return false
            }
            maximumFreehandWidth = width
        } else {
            maximumFreehandWidth = 0
        }
        return geometry.hitTest(
            point,
            tolerance: tolerance,
            textBounds: bounds,
            maximumFreehandWidthInCanvasUnits: maximumFreehandWidth
        )
    }

    func moved(by delta: CanvasPoint) throws -> CanvasElement {
        let nextRevision = try nextContentRevision()
        var copy = self
        copy.geometry = geometry.translated(by: delta)
        copy.contentRevision = nextRevision
        return copy
    }

    func replacingBounds(_ bounds: CanvasRect) throws -> CanvasElement {
        let nextRevision = try nextContentRevision()
        guard bounds.isFinite, bounds.width >= 0, bounds.height >= 0 else {
            throw CanvasGeometryError.invalidBounds
        }

        let replacementGeometry: CanvasGeometry
        switch geometry {
        case .rectangle:
            replacementGeometry = .rectangle(.init(rect: bounds))

        case .line(let line):
            let map = try BoundsMap(source: geometry.bounds, target: bounds, kind: .line)
            replacementGeometry = .line(.init(start: map.point(line.start), end: map.point(line.end)))

        case .arch(let arch):
            let map = try BoundsMap(source: geometry.bounds, target: bounds, kind: .arch)
            let newStart = map.point(arch.start)
            let newEnd = map.point(arch.end)
            guard let parameters = try? ArchGeometry.parameters(for: arch) else {
                throw CanvasGeometryError.unsupportedResize(.arch)
            }
            let newApex = map.point(parameters.apex)
            let chordMidpoint = midpoint(newStart, newEnd)
            guard let normal = unitNormal(from: newStart, to: newEnd) else {
                throw CanvasGeometryError.unsupportedResize(.arch)
            }
            let sagitta = (newApex.x - chordMidpoint.x) * normal.x
                + (newApex.y - chordMidpoint.y) * normal.y
            let replacementArch = CanvasArch(start: newStart, end: newEnd, sagitta: sagitta)
            guard let replacementBounds = try? ArchGeometry.bounds(for: replacementArch),
                  approximatelyEqual(replacementBounds, bounds) else {
                throw CanvasGeometryError.unsupportedResize(.arch)
            }
            replacementGeometry = .arch(replacementArch)

        case .freehand(let stroke):
            guard let initialMap = try? BoundsMap(
                source: geometry.bounds,
                target: bounds,
                kind: .freehand
            ) else {
                throw CanvasGeometryError.unsupportedResize(.freehand)
            }
            var candidate = stroke.mapped(using: initialMap)
            var converged = false
            for correctionIndex in 0..<maximumFreehandBoundsCorrectionCount {
                guard let candidateBounds = try? CanvasInkCurve.bounds(stroke: candidate),
                      candidateBounds.isFinite,
                      candidateBounds.width >= 0,
                      candidateBounds.height >= 0 else {
                    throw CanvasGeometryError.unsupportedResize(.freehand)
                }
                if approximatelyEqual(candidateBounds, bounds) {
                    converged = true
                    break
                }
                guard correctionIndex + 1 < maximumFreehandBoundsCorrectionCount,
                      let correction = try? BoundsMap(
                        source: candidateBounds,
                        target: bounds,
                        kind: .freehand
                      ) else {
                    break
                }
                candidate = candidate.mapped(using: correction)
            }
            guard converged else {
                throw CanvasGeometryError.unsupportedResize(.freehand)
            }
            replacementGeometry = .freehand(candidate)

        case .text(let text):
            replacementGeometry = .text(.init(
                frame: bounds,
                text: text.text,
                font: text.font,
                color: text.color
            ))
        }

        var copy = self
        copy.geometry = replacementGeometry
        copy.contentRevision = nextRevision
        return copy
    }

    private func nextContentRevision() throws -> UInt64 {
        guard let nextRevision = contentRevision.nextValidCanvasRevision else {
            throw CanvasGeometryError.revisionOverflow
        }
        return nextRevision
    }
}

private extension CanvasPathCommand {
    var geometryPoints: [CanvasPoint] {
        switch self {
        case .move(let point), .line(let point):
            [point]
        case .quad(let control, let end):
            [control, end]
        case .cubic(let control1, let control2, let end):
            [control1, control2, end]
        case .close:
            []
        }
    }
}

private extension CanvasRect {
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
        guard isFinite, width >= 0, height >= 0 else { return false }
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

extension CanvasPath {
    func hitTest(_ point: CanvasPoint, tolerance: Double) -> Bool {
        var current: CanvasPoint?
        var subpathStart: CanvasPoint?
        let geometryScale = max(1, bounds.width, bounds.height)
        let effectiveCurveTolerance = max(tolerance, geometryScale * 1e-12)

        for command in commands {
            switch command {
            case .move(let destination):
                current = destination
                subpathStart = destination

            case .line(let destination):
                if let current,
                   distanceFromPoint(point, toSegmentFrom: current, to: destination) <= tolerance {
                    return true
                }
                current = destination

            case .quad(let control, let end):
                if let start = current {
                    if point.distance(to: start) <= tolerance || point.distance(to: end) <= tolerance {
                        return true
                    }
                    if flattenedQuadratic(
                        start: start,
                        control: control,
                        end: end,
                        tolerance: effectiveCurveTolerance
                       ).containsSegment(near: point, tolerance: effectiveCurveTolerance) {
                        return true
                    }
                }
                current = end

            case .cubic(let control1, let control2, let end):
                if let start = current {
                    if point.distance(to: start) <= tolerance || point.distance(to: end) <= tolerance {
                        return true
                    }
                    if flattenedCubic(
                        start: start,
                        control1: control1,
                        control2: control2,
                        end: end,
                        tolerance: effectiveCurveTolerance
                       ).containsSegment(near: point, tolerance: effectiveCurveTolerance) {
                        return true
                    }
                }
                current = end

            case .close:
                if let current, let subpathStart,
                   distanceFromPoint(point, toSegmentFrom: current, to: subpathStart) <= tolerance {
                    return true
                }
                current = subpathStart
            }
        }
        return false
    }

    func hitTest(segmentFrom sweepStart: CanvasPoint, to sweepEnd: CanvasPoint, tolerance: Double) -> Bool {
        var current: CanvasPoint?
        var subpathStart: CanvasPoint?
        let geometryScale = max(1, bounds.width, bounds.height)
        let effectiveCurveTolerance = max(tolerance, geometryScale * 1e-12)

        for command in commands {
            switch command {
            case .move(let destination):
                current = destination
                subpathStart = destination

            case .line(let destination):
                if let current,
                   distanceBetweenSegments(sweepStart, sweepEnd, current, destination) <= tolerance {
                    return true
                }
                current = destination

            case .quad(let control, let end):
                if let start = current,
                   flattenedQuadratic(
                    start: start,
                    control: control,
                    end: end,
                    tolerance: effectiveCurveTolerance
                   ).containsSegment(
                    nearSegmentFrom: sweepStart,
                    to: sweepEnd,
                    tolerance: effectiveCurveTolerance
                   ) {
                    return true
                }
                current = end

            case .cubic(let control1, let control2, let end):
                if let start = current,
                   flattenedCubic(
                    start: start,
                    control1: control1,
                    control2: control2,
                    end: end,
                    tolerance: effectiveCurveTolerance
                   ).containsSegment(
                    nearSegmentFrom: sweepStart,
                    to: sweepEnd,
                    tolerance: effectiveCurveTolerance
                   ) {
                    return true
                }
                current = end

            case .close:
                if let current, let subpathStart,
                   distanceBetweenSegments(sweepStart, sweepEnd, current, subpathStart) <= tolerance {
                    return true
                }
                current = subpathStart
            }
        }
        return false
    }
}

private extension Array where Element == CanvasPoint {
    func containsSegment(near point: CanvasPoint, tolerance: Double) -> Bool {
        zip(self, dropFirst()).contains { start, end in
            distanceFromPoint(point, toSegmentFrom: start, to: end) <= tolerance
        }
    }

    func containsSegment(
        nearSegmentFrom sweepStart: CanvasPoint,
        to sweepEnd: CanvasPoint,
        tolerance: Double
    ) -> Bool {
        zip(self, dropFirst()).contains { start, end in
            distanceBetweenSegments(sweepStart, sweepEnd, start, end) <= tolerance
        }
    }
}

private extension CanvasGeometry {
    func translated(by delta: CanvasPoint) -> CanvasGeometry {
        let translate: (CanvasPoint) -> CanvasPoint = { point in
            CanvasPoint(x: point.x + delta.x, y: point.y + delta.y)
        }

        switch self {
        case .line(let line):
            return .line(.init(start: translate(line.start), end: translate(line.end)))
        case .rectangle(let rectangle):
            return .rectangle(
                .init(
                    rect: .init(
                        x: rectangle.rect.x + delta.x,
                        y: rectangle.rect.y + delta.y,
                        width: rectangle.rect.width,
                        height: rectangle.rect.height
                    )
                )
            )
        case .arch(let arch):
            return .arch(.init(start: translate(arch.start), end: translate(arch.end), sagitta: arch.sagitta))
        case .freehand(let stroke):
            return .freehand(CanvasInkStroke(
                samples: stroke.samples.map {
                    CanvasInkSample(point: translate($0.point), pressure: $0.pressure)
                },
                pressureEnabled: stroke.pressureEnabled,
                widthMode: stroke.widthMode
            ))
        case .text(let text):
            return .text(
                .init(
                    frame: .init(
                        x: text.frame.x + delta.x,
                        y: text.frame.y + delta.y,
                        width: text.frame.width,
                        height: text.frame.height
                    ),
                    text: text.text,
                    font: text.font,
                    color: text.color
                )
            )
        }
    }
}

private struct BoundsMap {
    let source: CanvasRect
    let target: CanvasRect
    let scaleX: Double
    let scaleY: Double

    init(source: CanvasRect, target: CanvasRect, kind: CanvasGeometryKind) throws {
        guard source.isFinite, source.width >= 0, source.height >= 0 else {
            throw CanvasGeometryError.invalidBounds
        }
        guard source.width > 0 || target.width == 0,
              source.height > 0 || target.height == 0 else {
            throw CanvasGeometryError.degenerateSourceBounds(kind)
        }
        self.source = source
        self.target = target
        scaleX = source.width == 0 ? 1 : target.width / source.width
        scaleY = source.height == 0 ? 1 : target.height / source.height
    }

    func point(_ point: CanvasPoint) -> CanvasPoint {
        CanvasPoint(
            x: source.width == 0 ? target.minX : target.minX + (point.x - source.minX) * scaleX,
            y: source.height == 0 ? target.minY : target.minY + (point.y - source.minY) * scaleY
        )
    }
}

private let maximumFreehandBoundsCorrectionCount = 16

private extension CanvasInkStroke {
    func mapped(using map: BoundsMap) -> CanvasInkStroke {
        CanvasInkStroke(
            samples: samples.map {
                CanvasInkSample(point: map.point($0.point), pressure: $0.pressure)
            },
            pressureEnabled: pressureEnabled,
            widthMode: widthMode
        )
    }
}

private func rectContaining(_ points: [CanvasPoint]) -> CanvasRect {
    CanvasPath(commands: points.map(CanvasPathCommand.move)).bounds
}

private func midpoint(_ first: CanvasPoint, _ second: CanvasPoint) -> CanvasPoint {
    CanvasPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
}

private func approximatelyEqual(_ first: Double, _ second: Double) -> Bool {
    let scale = max(1, abs(first), abs(second))
    return abs(first - second) <= scale * 0.000_000_000_001
}

private func approximatelyEqual(_ first: CanvasRect, _ second: CanvasRect) -> Bool {
    approximatelyEqual(first.x, second.x)
        && approximatelyEqual(first.y, second.y)
        && approximatelyEqual(first.width, second.width)
        && approximatelyEqual(first.height, second.height)
}

private func unitNormal(from start: CanvasPoint, to end: CanvasPoint) -> CanvasPoint? {
    let dx = end.x - start.x
    let dy = end.y - start.y
    let length = hypot(dx, dy)
    guard length > 0, length.isFinite else {
        return nil
    }
    return CanvasPoint(x: -dy / length, y: dx / length)
}

private func distanceFromPoint(
    _ point: CanvasPoint,
    toSegmentFrom start: CanvasPoint,
    to end: CanvasPoint
) -> Double {
    let dx = end.x - start.x
    let dy = end.y - start.y
    let squaredLength = dx * dx + dy * dy
    guard squaredLength > 0 else {
        return point.distance(to: start)
    }
    let projection = ((point.x - start.x) * dx + (point.y - start.y) * dy) / squaredLength
    let t = min(1, max(0, projection))
    return point.distance(to: .init(x: start.x + t * dx, y: start.y + t * dy))
}

private func distanceBetweenSegments(
    _ firstStart: CanvasPoint,
    _ firstEnd: CanvasPoint,
    _ secondStart: CanvasPoint,
    _ secondEnd: CanvasPoint
) -> Double {
    if segmentsIntersect(firstStart, firstEnd, secondStart, secondEnd) {
        return 0
    }
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
        abs(firstStart.x), abs(firstStart.y),
        abs(firstEnd.x), abs(firstEnd.y),
        abs(secondStart.x), abs(secondStart.y),
        abs(secondEnd.x), abs(secondEnd.y)
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
        && point(secondStart, liesOnSegmentFrom: firstStart, to: firstEnd, epsilon: epsilon))
        || (abs(firstSecondEnd) <= epsilon
            && point(secondEnd, liesOnSegmentFrom: firstStart, to: firstEnd, epsilon: epsilon))
        || (abs(secondFirstStart) <= epsilon
            && point(firstStart, liesOnSegmentFrom: secondStart, to: secondEnd, epsilon: epsilon))
        || (abs(secondFirstEnd) <= epsilon
            && point(firstEnd, liesOnSegmentFrom: secondStart, to: secondEnd, epsilon: epsilon))
}

private func cross(_ start: CanvasPoint, _ end: CanvasPoint, _ point: CanvasPoint) -> Double {
    (end.x - start.x) * (point.y - start.y) - (end.y - start.y) * (point.x - start.x)
}

private func opposite(_ first: Double, _ second: Double, epsilon: Double) -> Bool {
    (first > epsilon && second < -epsilon) || (first < -epsilon && second > epsilon)
}

private func point(
    _ point: CanvasPoint,
    liesOnSegmentFrom start: CanvasPoint,
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
    tolerance: Double
) -> [CanvasPoint] {
    var points = [start]
    appendFlattenedQuadratic(
        start: start,
        control: control,
        end: end,
        flatness: tolerance / 2,
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
    tolerance: Double
) -> [CanvasPoint] {
    var points = [start]
    appendFlattenedCubic(
        start: start,
        control1: control1,
        control2: control2,
        end: end,
        flatness: tolerance / 2,
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

    let startControl1 = midpoint(start, control1)
    let control1Control2 = midpoint(control1, control2)
    let control2End = midpoint(control2, end)
    let leftControl2 = midpoint(startControl1, control1Control2)
    let rightControl1 = midpoint(control1Control2, control2End)
    let split = midpoint(leftControl2, rightControl1)
    appendFlattenedCubic(
        start: start,
        control1: startControl1,
        control2: leftControl2,
        end: split,
        flatness: flatness,
        depth: depth + 1,
        to: &points
    )
    appendFlattenedCubic(
        start: split,
        control1: rightControl1,
        control2: control2End,
        end: end,
        flatness: flatness,
        depth: depth + 1,
        to: &points
    )
}

import Foundation

public enum ArchGeometryError: Error, Equatable, Sendable {
    case nonFiniteInput
    case zeroLengthChord
    case zeroSagitta
    case nonFiniteResult
}

public struct ArchParameters: Hashable, Sendable {
    public let startPoint: CanvasPoint
    public let endPoint: CanvasPoint
    public let center: CanvasPoint
    public let apex: CanvasPoint
    public let radius: Double
    public let startAngle: Double
    public let endAngle: Double
    public let sweepAngle: Double

    public var clockwise: Bool { sweepAngle < 0 }

    public func contains(angle: Double) -> Bool {
        guard angle.isFinite else {
            return false
        }
        if sweepAngle >= 0 {
            return normalizedPositiveAngle(angle - startAngle) <= sweepAngle
        }
        return normalizedPositiveAngle(startAngle - angle) <= -sweepAngle
    }
}

public struct ArchPathDescription: Hashable, Sendable {
    public let moveTo: CanvasPoint
    public let center: CanvasPoint
    public let radius: Double
    public let startAngle: Double
    public let endAngle: Double
    public let clockwise: Bool
}

public enum ArchGeometry {
    public static func parameters(for arch: CanvasArch) throws -> ArchParameters {
        guard arch.start.x.isFinite,
              arch.start.y.isFinite,
              arch.end.x.isFinite,
              arch.end.y.isFinite,
              arch.sagitta.isFinite else {
            throw ArchGeometryError.nonFiniteInput
        }
        guard arch.sagitta != 0 else {
            throw ArchGeometryError.zeroSagitta
        }

        let dx = arch.end.x - arch.start.x
        let dy = arch.end.y - arch.start.y
        let chordLength = hypot(dx, dy)
        guard chordLength.isFinite else {
            throw ArchGeometryError.nonFiniteResult
        }
        guard chordLength > 0 else {
            throw ArchGeometryError.zeroLengthChord
        }

        let perpendicular = CanvasPoint(x: -dy / chordLength, y: dx / chordLength)
        let midpoint = CanvasPoint(
            x: arch.start.x + dx / 2,
            y: arch.start.y + dy / 2
        )
        let absoluteSagitta = abs(arch.sagitta)
        let radius = try stableArchRadius(
            chordLength: chordLength,
            sagitta: absoluteSagitta
        )
        let sagittaSign = arch.sagitta.sign == .minus ? -1.0 : 1.0
        let centerOffset = sagittaSign * (radius - absoluteSagitta)
        let center = CanvasPoint(
            x: midpoint.x - perpendicular.x * centerOffset,
            y: midpoint.y - perpendicular.y * centerOffset
        )
        let apex = CanvasPoint(
            x: midpoint.x + perpendicular.x * arch.sagitta,
            y: midpoint.y + perpendicular.y * arch.sagitta
        )

        guard perpendicular.x.isFinite,
              perpendicular.y.isFinite,
              midpoint.x.isFinite,
              midpoint.y.isFinite,
              radius.isFinite,
              radius > 0,
              center.x.isFinite,
              center.y.isFinite,
              apex.x.isFinite,
              apex.y.isFinite else {
            throw ArchGeometryError.nonFiniteResult
        }

        let startAngle = atan2(arch.start.y - center.y, arch.start.x - center.x)
        let apexAngle = atan2(apex.y - center.y, apex.x - center.x)
        let sweepScale = max(absoluteSagitta, chordLength)
        let normalizedSagitta = absoluteSagitta / sweepScale
        let normalizedHalfChord = chordLength / sweepScale / 2
        let sweepMagnitude = 4 * atan2(normalizedSagitta, normalizedHalfChord)
        let sweepAngle = -sagittaSign * sweepMagnitude
        let endAngle = startAngle + sweepAngle
        guard startAngle.isFinite,
              apexAngle.isFinite,
              sweepMagnitude.isFinite,
              sweepMagnitude > 0,
              sweepAngle.isFinite,
              endAngle.isFinite else {
            throw ArchGeometryError.nonFiniteResult
        }

        let result = ArchParameters(
            startPoint: arch.start,
            endPoint: arch.end,
            center: center,
            apex: apex,
            radius: radius,
            startAngle: startAngle,
            endAngle: endAngle,
            sweepAngle: sweepAngle
        )
        guard result.contains(angle: apexAngle) else {
            throw ArchGeometryError.nonFiniteResult
        }
        return result
    }

    public static func bounds(for arch: CanvasArch) throws -> CanvasRect {
        let parameters = try parameters(for: arch)
        var points = [parameters.startPoint, parameters.endPoint, parameters.apex]
        for (index, angle) in [0.0, Double.pi / 2, Double.pi, Double.pi * 3 / 2].enumerated() {
            if parameters.contains(angle: angle) {
                points.append(cardinalPoint(on: parameters, index: index))
            }
        }

        guard let first = points.first else {
            throw ArchGeometryError.nonFiniteResult
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
        let bounds = CanvasRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
        guard bounds.isFinite, bounds.width >= 0, bounds.height >= 0 else {
            throw ArchGeometryError.nonFiniteResult
        }
        return bounds
    }

    public static func pathDescription(for arch: CanvasArch) throws -> ArchPathDescription {
        let parameters = try parameters(for: arch)
        return ArchPathDescription(
            moveTo: parameters.startPoint,
            center: parameters.center,
            radius: parameters.radius,
            startAngle: parameters.startAngle,
            endAngle: parameters.endAngle,
            clockwise: parameters.clockwise
        )
    }

    public static func hitTest(
        _ point: CanvasPoint,
        arch: CanvasArch,
        tolerance: Double
    ) -> Bool {
        guard point.x.isFinite,
              point.y.isFinite,
              tolerance.isFinite,
              tolerance >= 0,
              let parameters = try? parameters(for: arch) else {
            return false
        }
        let distance = parameters.center.distance(to: point)
        guard distance.isFinite,
              abs(distance - parameters.radius) <= tolerance,
              distance > 0 else {
            return false
        }
        let angle = atan2(
            point.y - parameters.center.y,
            point.x - parameters.center.x
        )
        return parameters.contains(angle: angle)
    }

    static func renderPath(for arch: CanvasArch) throws -> CanvasPath {
        let parameters = try parameters(for: arch)
        let segmentCount = max(1, Int(ceil(abs(parameters.sweepAngle) / (Double.pi / 2))))
        let segmentSweep = parameters.sweepAngle / Double(segmentCount)
        var commands: [CanvasPathCommand] = [.move(parameters.startPoint)]

        for index in 0..<segmentCount {
            let firstAngle = parameters.startAngle + Double(index) * segmentSweep
            let secondAngle = firstAngle + segmentSweep
            let firstPoint = index == 0
                ? parameters.startPoint
                : point(on: parameters, at: firstAngle)
            let endPoint = index == segmentCount - 1
                ? parameters.endPoint
                : point(on: parameters, at: secondAngle)
            let tangentScale = 4 / 3 * tan(segmentSweep / 4) * parameters.radius
            let control1 = CanvasPoint(
                x: firstPoint.x - sin(firstAngle) * tangentScale,
                y: firstPoint.y + cos(firstAngle) * tangentScale
            )
            let control2 = CanvasPoint(
                x: endPoint.x + sin(secondAngle) * tangentScale,
                y: endPoint.y - cos(secondAngle) * tangentScale
            )
            guard control1.x.isFinite,
                  control1.y.isFinite,
                  control2.x.isFinite,
                  control2.y.isFinite else {
                throw ArchGeometryError.nonFiniteResult
            }
            commands.append(.cubic(control1: control1, control2: control2, end: endPoint))
        }
        return CanvasPath(commands: commands)
    }
}

private let fullTurn = Double.pi * 2

private func stableArchRadius(chordLength: Double, sagitta: Double) throws -> Double {
    var chordExponent: Int32 = 0
    var sagittaExponent: Int32 = 0
    let chordMantissa = frexp(chordLength, &chordExponent)
    let sagittaMantissa = frexp(sagitta, &sagittaExponent)

    guard chordMantissa.isFinite,
          chordMantissa > 0,
          sagittaMantissa.isFinite,
          sagittaMantissa > 0 else {
        throw ArchGeometryError.nonFiniteResult
    }

    let chordContributionMantissa = chordMantissa * chordMantissa / sagittaMantissa
    let chordContributionExponent = 2 * chordExponent - sagittaExponent - 3
    let sagittaContributionExponent = sagittaExponent - 1
    let radiusExponent = max(chordContributionExponent, sagittaContributionExponent)
    let alignedChordContribution = scalbn(
        chordContributionMantissa,
        chordContributionExponent - radiusExponent
    )
    let alignedSagittaContribution = scalbn(
        sagittaMantissa,
        sagittaContributionExponent - radiusExponent
    )
    let radiusMantissa = alignedChordContribution + alignedSagittaContribution
    let radius = scalbn(radiusMantissa, radiusExponent)

    guard alignedChordContribution.isFinite,
          alignedChordContribution >= 0,
          alignedSagittaContribution.isFinite,
          alignedSagittaContribution >= 0,
          radiusMantissa.isFinite,
          radiusMantissa > 0,
          radius.isFinite,
          radius > 0 else {
        throw ArchGeometryError.nonFiniteResult
    }
    return radius
}

private func normalizedPositiveAngle(_ angle: Double) -> Double {
    let remainder = angle.truncatingRemainder(dividingBy: fullTurn)
    return remainder >= 0 ? remainder : remainder + fullTurn
}

private func cardinalPoint(on parameters: ArchParameters, index: Int) -> CanvasPoint {
    switch index {
    case 0:
        CanvasPoint(x: parameters.center.x + parameters.radius, y: parameters.center.y)
    case 1:
        CanvasPoint(x: parameters.center.x, y: parameters.center.y + parameters.radius)
    case 2:
        CanvasPoint(x: parameters.center.x - parameters.radius, y: parameters.center.y)
    default:
        CanvasPoint(x: parameters.center.x, y: parameters.center.y - parameters.radius)
    }
}

private func point(on parameters: ArchParameters, at angle: Double) -> CanvasPoint {
    CanvasPoint(
        x: parameters.center.x + cos(angle) * parameters.radius,
        y: parameters.center.y + sin(angle) * parameters.radius
    )
}

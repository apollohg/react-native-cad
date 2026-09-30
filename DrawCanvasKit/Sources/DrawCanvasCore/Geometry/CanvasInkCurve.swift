import Foundation

public struct CanvasInkVertex: Hashable, Sendable {
    public var point: CanvasPoint
    public var widthFactor: Double

    public init(point: CanvasPoint, widthFactor: Double) {
        self.point = point
        self.widthFactor = widthFactor
    }
}

public struct CanvasFlattenedInkCurve: Hashable, Sendable {
    public let vertices: [CanvasInkVertex]
    public let spanEndVertexIndices: [Int]

    public init(vertices: [CanvasInkVertex], spanEndVertexIndices: [Int]) {
        self.vertices = vertices
        self.spanEndVertexIndices = spanEndVertexIndices
    }
}

package struct CanvasInkIncrementalBoundary: Equatable, Sendable {
    package let finalizedSampleCount: Int
    package let stableSpanCount: Int

    package init(finalizedSampleCount: Int, stableSpanCount: Int) {
        self.finalizedSampleCount = finalizedSampleCount
        self.stableSpanCount = stableSpanCount
    }
}

public enum CanvasInkCurveError: Error, Equatable, Sendable {
    case invalidInput
    case outputLimitExceeded
}

public enum CanvasInkCurve {
    package static func incrementalBoundary(
        confirmedPrefix: [CanvasInkSample],
        appending appendedSamples: [CanvasInkSample],
        isFinalized: Bool
    ) -> CanvasInkIncrementalBoundary {
        let sampleCount = confirmedPrefix.count + appendedSamples.count
        if isFinalized {
            return CanvasInkIncrementalBoundary(
                finalizedSampleCount: sampleCount,
                stableSpanCount: max(0, sampleCount - 1)
            )
        }
        guard sampleCount > 0 else {
            return CanvasInkIncrementalBoundary(finalizedSampleCount: 0, stableSpanCount: 0)
        }

        func sample(at index: Int) -> CanvasInkSample {
            index < confirmedPrefix.count
                ? confirmedPrefix[index]
                : appendedSamples[index - confirmedPrefix.count]
        }

        var retainedRunLastIndex = sampleCount - 1
        var retainedRunFirstIndex = retainedRunLastIndex
        while retainedRunFirstIndex > 0,
              sample(at: retainedRunFirstIndex - 1).point
                == sample(at: retainedRunLastIndex).point {
            retainedRunFirstIndex -= 1
        }
        for _ in 1..<5 {
            guard retainedRunFirstIndex > 0 else {
                return CanvasInkIncrementalBoundary(finalizedSampleCount: 0, stableSpanCount: 0)
            }
            retainedRunLastIndex = retainedRunFirstIndex - 1
            retainedRunFirstIndex = retainedRunLastIndex
            while retainedRunFirstIndex > 0,
                  sample(at: retainedRunFirstIndex - 1).point
                    == sample(at: retainedRunLastIndex).point {
                retainedRunFirstIndex -= 1
            }
        }
        let finalizedSampleCount = retainedRunLastIndex + 1
        return CanvasInkIncrementalBoundary(
            finalizedSampleCount: finalizedSampleCount,
            stableSpanCount: max(0, finalizedSampleCount - 1)
        )
    }

    public static func maximumWidthFactor(pressureEnabled: Bool) -> Double {
        pressureEnabled ? maximumPressureWidthFactor : 1
    }

    public static func flatten(
        stroke: CanvasInkStroke,
        maximumError: Double,
        maximumWidthError: Double = .greatestFiniteMagnitude
    ) throws -> [CanvasInkVertex] {
        try flattenWithSpanEnds(
            stroke: stroke,
            maximumError: maximumError,
            maximumWidthError: maximumWidthError
        ).vertices
    }

    public static func flattenWithSpanEnds(
        stroke: CanvasInkStroke,
        maximumError: Double,
        maximumWidthError: Double = .greatestFiniteMagnitude
    ) throws -> CanvasFlattenedInkCurve {
        try flattenWithSpanEnds(
            stroke: stroke,
            maximumError: maximumError,
            maximumWidthError: maximumWidthError,
            controlRunDidPrepare: nil
        )
    }

    static func flattenWithSpanEnds(
        stroke: CanvasInkStroke,
        maximumError: Double,
        maximumWidthError: Double,
        controlRunDidPrepare: ((Int) -> Void)?
    ) throws -> CanvasFlattenedInkCurve {
        guard stroke.samples.count <= maximumOutputVertexCount else {
            throw CanvasInkCurveError.outputLimitExceeded
        }
        guard maximumError.isFinite, maximumError > 0,
              maximumWidthError.isFinite, maximumWidthError > 0 else {
            throw CanvasInkCurveError.invalidInput
        }

        let samples = try controlSamples(for: stroke)
        guard !samples.isEmpty else {
            return CanvasFlattenedInkCurve(vertices: [], spanEndVertexIndices: [])
        }
        let preparedRuns = try preparedControlRuns(
            sampleCount: samples.count,
            spanRange: 0..<(samples.count - 1),
            controlVertexAt: { samples[$0] },
            controlRunDidPrepare: controlRunDidPrepare
        )
        return try flattenPreparedSpanRange(
            sampleCount: samples.count,
            spanRange: 0..<(samples.count - 1),
            maximumError: maximumError,
            maximumWidthError: maximumWidthError,
            preparedRuns: preparedRuns
        )
    }

    public static func flattenSpanRange(
        confirmedPrefix: [CanvasInkSample],
        appending appendedSamples: [CanvasInkSample],
        pressureEnabled: Bool,
        spanRange: Range<Int>,
        maximumError: Double,
        maximumWidthError: Double = .greatestFiniteMagnitude
    ) throws -> CanvasFlattenedInkCurve {
        try flattenSpanRange(
            confirmedPrefix: confirmedPrefix,
            appending: appendedSamples,
            pressureEnabled: pressureEnabled,
            spanRange: spanRange,
            maximumError: maximumError,
            maximumWidthError: maximumWidthError,
            controlVertexDidDerive: nil
        )
    }

    static func flattenSpanRange(
        confirmedPrefix: [CanvasInkSample],
        appending appendedSamples: [CanvasInkSample],
        pressureEnabled: Bool,
        spanRange: Range<Int>,
        maximumError: Double,
        maximumWidthError: Double,
        controlVertexDidDerive: ((Int) -> Void)?,
        controlRunDidPrepare: ((Int) -> Void)? = nil
    ) throws -> CanvasFlattenedInkCurve {
        let sampleCount = confirmedPrefix.count + appendedSamples.count
        guard sampleCount <= maximumOutputVertexCount else {
            throw CanvasInkCurveError.outputLimitExceeded
        }
        guard maximumError.isFinite,
              maximumError > 0,
              maximumWidthError.isFinite,
              maximumWidthError > 0,
              spanRange.lowerBound >= 0,
              spanRange.upperBound <= max(0, sampleCount - 1) else {
            throw CanvasInkCurveError.invalidInput
        }
        guard !spanRange.isEmpty else {
            return CanvasFlattenedInkCurve(vertices: [], spanEndVertexIndices: [])
        }

        func sample(at index: Int) throws -> CanvasInkSample {
            guard index >= 0, index < sampleCount else {
                throw CanvasInkCurveError.invalidInput
            }
            let sample = index < confirmedPrefix.count
                ? confirmedPrefix[index]
                : appendedSamples[index - confirmedPrefix.count]
            guard sample.point.x.isFinite,
                  sample.point.y.isFinite,
                  sample.pressure.isFinite else {
                throw CanvasInkCurveError.invalidInput
            }
            return sample
        }

        var controlVertices: [Int: ControlVertex] = [:]
        controlVertices.reserveCapacity(min(sampleCount, spanRange.count + 10))

        func vertex(at index: Int) throws -> ControlVertex {
            if let cached = controlVertices[index] {
                return cached
            }
            let current = try sample(at: index)
            let result: ControlVertex
            guard pressureEnabled else {
                result = ControlVertex(point: current.point, widthFactor: 1)
                controlVertices[index] = result
                controlVertexDidDerive?(index)
                return result
            }
            let normalizedPressure = min(1, max(0, current.pressure))
            result = ControlVertex(
                point: current.point,
                widthFactor: widthFactor(forPressure: normalizedPressure),
                normalizedPressure: normalizedPressure
            )
            controlVertices[index] = result
            controlVertexDidDerive?(index)
            return result
        }

        let preparedRuns = try preparedControlRuns(
            sampleCount: sampleCount,
            spanRange: spanRange,
            controlVertexAt: vertex,
            controlRunDidPrepare: controlRunDidPrepare
        )
        return try flattenPreparedSpanRange(
            sampleCount: sampleCount,
            spanRange: spanRange,
            maximumError: maximumError,
            maximumWidthError: maximumWidthError,
            preparedRuns: preparedRuns
        )
    }

    public static func bounds(stroke: CanvasInkStroke) throws -> CanvasRect {
        let samples = try controlSamples(for: stroke)
        guard let first = samples.first else {
            return CanvasRect(x: 0, y: 0, width: 0, height: 0)
        }
        guard samples.count > 1 else {
            return CanvasRect(x: first.point.x, y: first.point.y, width: 0, height: 0)
        }

        var minX = first.point.x
        var maxX = first.point.x
        var minY = first.point.y
        var maxY = first.point.y
        for index in 0..<(samples.count - 1) {
            guard samples[index].point != samples[index + 1].point else { continue }
            let cubic = try cubic(forSpanAt: index, samples: samples)
            var parameters = [0.0, 1.0]
            parameters.append(contentsOf: try extremaParameters(
                cubic.start.point.x,
                cubic.control1.point.x,
                cubic.control2.point.x,
                cubic.end.point.x
            ))
            parameters.append(contentsOf: try extremaParameters(
                cubic.start.point.y,
                cubic.control1.point.y,
                cubic.control2.point.y,
                cubic.end.point.y
            ))
            for parameter in parameters {
                let point = try cubic.point(at: parameter)
                minX = min(minX, point.x)
                maxX = max(maxX, point.x)
                minY = min(minY, point.y)
                maxY = max(maxY, point.y)
            }
        }

        let width = maxX - minX
        let height = maxY - minY
        guard minX.isFinite, minY.isFinite, width.isFinite, height.isFinite else {
            throw CanvasInkCurveError.invalidInput
        }
        return CanvasRect(x: minX, y: minY, width: width, height: height)
    }

    public static func boundsOfSpans(
        confirmedPrefix: [CanvasInkSample],
        appending appendedSamples: [CanvasInkSample],
        spanRange: Range<Int>
    ) throws -> CanvasRect? {
        let sampleCount = confirmedPrefix.count + appendedSamples.count
        guard sampleCount <= maximumOutputVertexCount else {
            throw CanvasInkCurveError.outputLimitExceeded
        }
        guard spanRange.lowerBound >= 0,
              spanRange.upperBound <= max(0, sampleCount - 1) else {
            throw CanvasInkCurveError.invalidInput
        }
        guard !spanRange.isEmpty else { return nil }

        func sample(at index: Int) throws -> CanvasInkSample {
            guard index >= 0, index < sampleCount else {
                throw CanvasInkCurveError.invalidInput
            }
            let sample = index < confirmedPrefix.count
                ? confirmedPrefix[index]
                : appendedSamples[index - confirmedPrefix.count]
            guard sample.point.x.isFinite,
                  sample.point.y.isFinite,
                  sample.pressure.isFinite else {
                throw CanvasInkCurveError.invalidInput
            }
            return sample
        }

        func vertex(at index: Int) throws -> ControlVertex {
            let sample = try sample(at: index)
            return ControlVertex(point: sample.point, widthFactor: 1)
        }

        let firstRun = try controlRun(
            containing: spanRange.lowerBound,
            sampleCount: sampleCount,
            controlVertexAt: vertex
        )
        let firstPoint = try derivedControl(
            for: firstRun,
            sampleCount: sampleCount,
            controlVertexAt: vertex
        ).point
        var minimumX = firstPoint.x
        var maximumX = firstPoint.x
        var minimumY = firstPoint.y
        var maximumY = firstPoint.y
        for index in spanRange {
            guard try vertex(at: index).point != vertex(at: index + 1).point else { continue }
            let cubic = try cubic(
                forSpanAt: index,
                sampleCount: sampleCount,
                controlVertexAt: vertex
            )
            var parameters = [0.0, 1.0]
            parameters.append(contentsOf: try extremaParameters(
                cubic.start.point.x,
                cubic.control1.point.x,
                cubic.control2.point.x,
                cubic.end.point.x
            ))
            parameters.append(contentsOf: try extremaParameters(
                cubic.start.point.y,
                cubic.control1.point.y,
                cubic.control2.point.y,
                cubic.end.point.y
            ))
            for parameter in parameters {
                let point = try cubic.point(at: parameter)
                minimumX = min(minimumX, point.x)
                maximumX = max(maximumX, point.x)
                minimumY = min(minimumY, point.y)
                maximumY = max(maximumY, point.y)
            }
        }
        let width = maximumX - minimumX
        let height = maximumY - minimumY
        guard minimumX.isFinite,
              minimumY.isFinite,
              width.isFinite,
              height.isFinite else {
            throw CanvasInkCurveError.invalidInput
        }
        return CanvasRect(x: minimumX, y: minimumY, width: width, height: height)
    }

    public static func hitTest(
        _ point: CanvasPoint,
        stroke: CanvasInkStroke,
        tolerance: Double,
        maximumWidthInCanvasUnits: Double
    ) throws -> Bool {
        guard point.x.isFinite,
              point.y.isFinite,
              tolerance.isFinite,
              tolerance >= 0,
              maximumWidthInCanvasUnits.isFinite,
              maximumWidthInCanvasUnits >= 0 else {
            throw CanvasInkCurveError.invalidInput
        }
        let radius = tolerance + 0.5 * maximumWidthInCanvasUnits
        guard radius.isFinite else {
            throw CanvasInkCurveError.invalidInput
        }
        let samples = try controlSamples(for: stroke)
        guard let firstSample = samples.first else { return false }
        guard samples.count > 1 else {
            return try finiteDistance(point, firstSample.point) <= radius
        }
        if try finiteDistance(point, firstSample.point) <= radius
            || finiteDistance(point, samples[samples.count - 1].point) <= radius {
            return true
        }
        let vertices = try flatten(
            stroke: stroke,
            maximumError: max(1e-6, tolerance * 0.25),
            maximumWidthError: 0.01
        )
        for index in 1..<vertices.count where try distance(
            point,
            toSegmentFrom: vertices[index - 1].point,
            to: vertices[index].point
        ) <= radius {
            return true
        }
        return false
    }

    public static func maximumPaintedWidthInCanvasUnits(
        lineWidth: Double,
        viewportZoom: Double,
        pressureEnabled: Bool = true,
        widthMode: CanvasInkWidthMode
    ) throws -> Double {
        let lineWidth = try lineWidthInCanvasUnits(
            lineWidth: lineWidth,
            viewportZoom: viewportZoom,
            widthMode: widthMode
        )
        let width = lineWidth * maximumWidthFactor(pressureEnabled: pressureEnabled)
        guard width.isFinite else {
            throw CanvasInkCurveError.invalidInput
        }
        return width
    }

    public static func lineWidthInCanvasUnits(
        lineWidth: Double,
        viewportZoom: Double,
        widthMode: CanvasInkWidthMode
    ) throws -> Double {
        guard lineWidth.isFinite,
              lineWidth >= 0,
              viewportZoom.isFinite,
              viewportZoom > 0 else {
            throw CanvasInkCurveError.invalidInput
        }
        let width = switch widthMode {
        case .canvasScaled: lineWidth
        case .screenConstant: lineWidth / viewportZoom
        }
        guard width.isFinite else {
            throw CanvasInkCurveError.invalidInput
        }
        return width
    }

    public static func paintedBounds(
        centerlineBounds: CanvasRect,
        lineWidth: Double,
        viewportZoom: Double,
        pressureEnabled: Bool = true,
        widthMode: CanvasInkWidthMode
    ) throws -> CanvasRect {
        guard centerlineBounds.isFinite,
              centerlineBounds.width >= 0,
              centerlineBounds.height >= 0,
              centerlineBounds.maxX.isFinite,
              centerlineBounds.maxY.isFinite else {
            throw CanvasInkCurveError.invalidInput
        }
        let width = try maximumPaintedWidthInCanvasUnits(
            lineWidth: lineWidth,
            viewportZoom: viewportZoom,
            pressureEnabled: pressureEnabled,
            widthMode: widthMode
        )
        let radius = width / 2
        let painted = CanvasRect(
            x: centerlineBounds.x - radius,
            y: centerlineBounds.y - radius,
            width: centerlineBounds.width + width,
            height: centerlineBounds.height + width
        )
        guard painted.isFinite,
              painted.maxX.isFinite,
              painted.maxY.isFinite else {
            throw CanvasInkCurveError.invalidInput
        }
        return painted
    }
}

private extension CanvasInkCurve {
    static let minimumWidthFactor = 0.20
    static let maximumPressureWidthFactor = 1.75
    static let nominalPressure = 0.30
    static let pressureResponseExponent = log(
        (1 - minimumWidthFactor) / (maximumPressureWidthFactor - minimumWidthFactor)
    ) / log(nominalPressure)
    static let maximumSubdivisionDepth = 16
    static let maximumOutputVertexCount = 1_000_000
    static let maximumFlattenedTurn = Double.pi / 60
    static let smoothingCornerTurn = Double.pi / 3
    static let smoothingWeights = [-3.0, 12, 17, 12, -3]
    static let smoothingWeightSum = 35.0

    struct ControlVertex {
        var point: CanvasPoint
        var widthFactor: Double
        var normalizedPressure: Double? = nil

        var publicVertex: CanvasInkVertex {
            CanvasInkVertex(
                point: point,
                widthFactor: min(
                    maximumPressureWidthFactor,
                    max(minimumWidthFactor, widthFactor)
                )
            )
        }
    }

    struct ControlRun {
        var firstIndex: Int
        var lastIndex: Int
        var representative: ControlVertex
    }

    struct PreparedControlRuns {
        var runs: [ControlRun]
        var firstAffectedRunIndex: Int
    }

    struct Cubic {
        var start: ControlVertex
        var control1: ControlVertex
        var control2: ControlVertex
        var end: ControlVertex

        func point(at parameter: Double) throws -> CanvasPoint {
            let startControl1 = try interpolate(start, control1, at: parameter)
            let control1Control2 = try interpolate(control1, control2, at: parameter)
            let control2End = try interpolate(control2, end, at: parameter)
            let leftControl = try interpolate(startControl1, control1Control2, at: parameter)
            let rightControl = try interpolate(control1Control2, control2End, at: parameter)
            return try interpolate(leftControl, rightControl, at: parameter).point
        }

        @inline(__always)
        func split() throws -> (left: Cubic, right: Cubic) {
            let startControl1 = try midpoint(start, control1)
            let control1Control2 = try midpoint(control1, control2)
            let control2End = try midpoint(control2, end)
            let leftControl2 = try midpoint(startControl1, control1Control2)
            let rightControl1 = try midpoint(control1Control2, control2End)
            let split = try midpoint(leftControl2, rightControl1)
            return (
                Cubic(start: start, control1: startControl1, control2: leftControl2, end: split),
                Cubic(start: split, control1: rightControl1, control2: control2End, end: end)
            )
        }
    }

    static func controlSamples(for stroke: CanvasInkStroke) throws -> [ControlVertex] {
        for sample in stroke.samples {
            guard sample.point.x.isFinite, sample.point.y.isFinite, sample.pressure.isFinite else {
                throw CanvasInkCurveError.invalidInput
            }
        }

        return stroke.samples.map { sample in
            guard stroke.pressureEnabled else {
                return ControlVertex(point: sample.point, widthFactor: 1)
            }
            let normalizedPressure = min(1, max(0, sample.pressure))
            return ControlVertex(
                point: sample.point,
                widthFactor: widthFactor(forPressure: normalizedPressure),
                normalizedPressure: normalizedPressure
            )
        }
    }

    static func widthFactor(forPressure pressure: Double) -> Double {
        let normalized = min(1, max(0, pressure))
        return minimumWidthFactor
            + (maximumPressureWidthFactor - minimumWidthFactor)
            * pow(normalized, pressureResponseExponent)
    }

    static func cubic(
        forSpanAt index: Int,
        samples: [ControlVertex]
    ) throws -> Cubic {
        try cubic(
            forSpanAt: index,
            sampleCount: samples.count,
            controlVertexAt: { samples[$0] }
        )
    }

    static func cubic(
        forSpanAt index: Int,
        sampleCount: Int,
        sampleAt: (Int) throws -> CanvasInkSample
    ) throws -> Cubic {
        func vertex(at sampleIndex: Int) throws -> ControlVertex {
            let sample = try sampleAt(sampleIndex)
            return ControlVertex(point: sample.point, widthFactor: 1)
        }
        return try cubic(
            forSpanAt: index,
            sampleCount: sampleCount,
            controlVertexAt: vertex
        )
    }

    static func cubic(
        forSpanAt index: Int,
        sampleCount: Int,
        controlVertexAt vertex: (Int) throws -> ControlVertex
    ) throws -> Cubic {
        guard index >= 0, index + 1 < sampleCount else {
            throw CanvasInkCurveError.invalidInput
        }
        let startRun = try controlRun(
            containing: index,
            sampleCount: sampleCount,
            controlVertexAt: vertex
        )
        let endRun = try controlRun(
            containing: index + 1,
            sampleCount: sampleCount,
            controlVertexAt: vertex
        )
        guard startRun.lastIndex < endRun.firstIndex else {
            throw CanvasInkCurveError.invalidInput
        }
        let start = try derivedControl(
            for: startRun,
            sampleCount: sampleCount,
            controlVertexAt: vertex
        )
        let end = try derivedControl(
            for: endRun,
            sampleCount: sampleCount,
            controlVertexAt: vertex
        )
        let previous = if let run = try previousRun(
            before: startRun,
            sampleCount: sampleCount,
            controlVertexAt: vertex
        ) {
            try derivedControl(
                for: run,
                sampleCount: sampleCount,
                controlVertexAt: vertex
            )
        } else {
            start
        }
        let next = if let run = try nextRun(
            after: endRun,
            sampleCount: sampleCount,
            controlVertexAt: vertex
        ) {
            try derivedControl(
                for: run,
                sampleCount: sampleCount,
                controlVertexAt: vertex
            )
        } else {
            end
        }
        return try cubic(previous: previous, start: start, end: end, next: next)
    }

    @inline(__always)
    static func cubic(
        previous: ControlVertex,
        start: ControlVertex,
        end: ControlVertex,
        next: ControlVertex
    ) throws -> Cubic {
        let previousInterval = try parameterIncrement(from: previous.point, to: start.point)
        let spanInterval = try parameterIncrement(from: start.point, to: end.point)
        let nextInterval = try parameterIncrement(from: end.point, to: next.point)
        let startTangent = try tangent(
            previous: previous,
            point: start,
            next: end,
            previousInterval: previousInterval,
            nextInterval: spanInterval,
            spanInterval: spanInterval
        )
        let endTangent = try tangent(
            previous: start,
            point: end,
            next: next,
            previousInterval: spanInterval,
            nextInterval: nextInterval,
            spanInterval: spanInterval
        )
        return Cubic(
            start: start,
            control1: try offset(start, by: startTangent, scale: 1.0 / 3),
            control2: try offset(end, by: endTangent, scale: -1.0 / 3),
            end: end
        )
    }

    static func preparedControlRuns(
        sampleCount: Int,
        spanRange: Range<Int>,
        controlVertexAt vertex: (Int) throws -> ControlVertex,
        controlRunDidPrepare: ((Int) -> Void)?
    ) throws -> PreparedControlRuns {
        var runs = [try controlRun(
            containing: spanRange.lowerBound,
            sampleCount: sampleCount,
            controlVertexAt: vertex
        )]
        controlRunDidPrepare?(runs[0].firstIndex)

        for _ in 0..<4 {
            guard let run = try previousRun(
                before: runs[0],
                sampleCount: sampleCount,
                controlVertexAt: vertex
            ) else { break }
            runs.insert(run, at: 0)
            controlRunDidPrepare?(run.firstIndex)
        }
        let firstAffectedRunIndex = runs.count - 1

        while runs[runs.count - 1].lastIndex < spanRange.upperBound {
            guard let run = try nextRun(
                after: runs[runs.count - 1],
                sampleCount: sampleCount,
                controlVertexAt: vertex
            ) else {
                throw CanvasInkCurveError.invalidInput
            }
            runs.append(run)
            controlRunDidPrepare?(run.firstIndex)
        }
        for _ in 0..<5 {
            guard let run = try nextRun(
                after: runs[runs.count - 1],
                sampleCount: sampleCount,
                controlVertexAt: vertex
            ) else { break }
            runs.append(run)
            controlRunDidPrepare?(run.firstIndex)
        }
        return PreparedControlRuns(
            runs: runs,
            firstAffectedRunIndex: firstAffectedRunIndex
        )
    }

    static func flattenPreparedSpanRange(
        sampleCount: Int,
        spanRange: Range<Int>,
        maximumError: Double,
        maximumWidthError: Double,
        preparedRuns: PreparedControlRuns
    ) throws -> CanvasFlattenedInkCurve {
        let derivedControls = try preparedDerivedControls(
            in: preparedRuns.runs,
            sampleCount: sampleCount
        )
        let first = derivedControls[preparedRuns.firstAffectedRunIndex]
        var output = [first.publicVertex]
        var spanEndVertexIndices: [Int] = []
        spanEndVertexIndices.reserveCapacity(spanRange.count)
        var runIndex = preparedRuns.firstAffectedRunIndex
        for index in spanRange {
            while index > preparedRuns.runs[runIndex].lastIndex {
                runIndex += 1
            }
            let startRun = preparedRuns.runs[runIndex]
            guard index == startRun.lastIndex else {
                spanEndVertexIndices.append(output.count - 1)
                continue
            }
            let endRunIndex = runIndex + 1
            guard endRunIndex < preparedRuns.runs.count else {
                throw CanvasInkCurveError.invalidInput
            }
            let endRun = preparedRuns.runs[endRunIndex]
            let start = derivedControls[runIndex]
            let end = derivedControls[endRunIndex]
            let previous = startRun.firstIndex > 0
                ? derivedControls[runIndex - 1]
                : start
            let next = endRun.lastIndex + 1 < sampleCount
                ? derivedControls[endRunIndex + 1]
                : end
            let cubic = try cubic(
                previous: previous,
                start: start,
                end: end,
                next: next
            )
            try appendFlattened(
                cubic,
                maximumError: maximumError,
                maximumWidthError: maximumWidthError,
                depth: 0,
                to: &output
            )
            spanEndVertexIndices.append(output.count - 1)
        }
        return CanvasFlattenedInkCurve(
            vertices: output,
            spanEndVertexIndices: spanEndVertexIndices
        )
    }

    static func preparedDerivedControls(
        in runs: [ControlRun],
        sampleCount: Int
    ) throws -> [ControlVertex] {
        var anchors = Array(repeating: true, count: runs.count)
        if runs.count > 2 {
            for index in 1..<(runs.count - 1) {
                let run = runs[index]
                if run.firstIndex == 0 || run.lastIndex + 1 == sampleCount {
                    anchors[index] = true
                    continue
                }
                let previous = runs[index - 1]
                let next = runs[index + 1]
                let incomingX = run.representative.point.x
                    - previous.representative.point.x
                let incomingY = run.representative.point.y
                    - previous.representative.point.y
                let outgoingX = next.representative.point.x
                    - run.representative.point.x
                let outgoingY = next.representative.point.y
                    - run.representative.point.y
                let cross = incomingX * outgoingY - incomingY * outgoingX
                let dot = incomingX * outgoingX + incomingY * outgoingY
                let turn = atan2(abs(cross), dot)
                guard turn.isFinite else {
                    throw CanvasInkCurveError.invalidInput
                }
                anchors[index] = turn >= smoothingCornerTurn
            }
        }

        var controls = runs.map(\.representative)
        guard runs.count >= 5 else { return controls }
        for index in 2..<(runs.count - 2) {
            guard !anchors[index - 2],
                  !anchors[index - 1],
                  !anchors[index],
                  !anchors[index + 1],
                  !anchors[index + 2] else { continue }
            var x = 0.0
            var y = 0.0
            var pressure = 0.0
            var hasPressure = true
            for offset in 0..<5 {
                let source = runs[index + offset - 2].representative
                let weight = smoothingWeights[offset]
                x += weight * source.point.x
                y += weight * source.point.y
                if let normalizedPressure = source.normalizedPressure {
                    pressure += weight * normalizedPressure
                } else {
                    hasPressure = false
                }
            }
            let point = CanvasPoint(
                x: x / smoothingWeightSum,
                y: y / smoothingWeightSum
            )
            let result: ControlVertex
            if hasPressure {
                let normalizedPressure = min(1, max(0, pressure / smoothingWeightSum))
                result = ControlVertex(
                    point: point,
                    widthFactor: widthFactor(forPressure: normalizedPressure),
                    normalizedPressure: normalizedPressure
                )
            } else {
                result = ControlVertex(
                    point: point,
                    widthFactor: runs[index].representative.widthFactor
                )
            }
            try validate(result)
            controls[index] = result
        }
        return controls
    }

    static func controlRun(
        containing index: Int,
        sampleCount: Int,
        controlVertexAt vertex: (Int) throws -> ControlVertex
    ) throws -> ControlRun {
        guard index >= 0, index < sampleCount else {
            throw CanvasInkCurveError.invalidInput
        }
        let point = try vertex(index).point
        var firstIndex = index
        while firstIndex > 0, try vertex(firstIndex - 1).point == point {
            firstIndex -= 1
        }
        var lastIndex = index
        while lastIndex + 1 < sampleCount, try vertex(lastIndex + 1).point == point {
            lastIndex += 1
        }
        return ControlRun(
            firstIndex: firstIndex,
            lastIndex: lastIndex,
            representative: try vertex(lastIndex)
        )
    }

    static func previousRun(
        before run: ControlRun,
        sampleCount: Int,
        controlVertexAt vertex: (Int) throws -> ControlVertex
    ) throws -> ControlRun? {
        guard run.firstIndex > 0 else { return nil }
        return try controlRun(
            containing: run.firstIndex - 1,
            sampleCount: sampleCount,
            controlVertexAt: vertex
        )
    }

    static func nextRun(
        after run: ControlRun,
        sampleCount: Int,
        controlVertexAt vertex: (Int) throws -> ControlVertex
    ) throws -> ControlRun? {
        guard run.lastIndex + 1 < sampleCount else { return nil }
        return try controlRun(
            containing: run.lastIndex + 1,
            sampleCount: sampleCount,
            controlVertexAt: vertex
        )
    }

    static func isSmoothingAnchor(
        _ run: ControlRun,
        sampleCount: Int,
        controlVertexAt vertex: (Int) throws -> ControlVertex
    ) throws -> Bool {
        guard run.firstIndex > 0, run.lastIndex + 1 < sampleCount else { return true }
        guard let previous = try previousRun(
            before: run,
            sampleCount: sampleCount,
            controlVertexAt: vertex
        ), let next = try nextRun(
            after: run,
            sampleCount: sampleCount,
            controlVertexAt: vertex
        ) else {
            return true
        }
        let incomingX = run.representative.point.x - previous.representative.point.x
        let incomingY = run.representative.point.y - previous.representative.point.y
        let outgoingX = next.representative.point.x - run.representative.point.x
        let outgoingY = next.representative.point.y - run.representative.point.y
        let cross = incomingX * outgoingY - incomingY * outgoingX
        let dot = incomingX * outgoingX + incomingY * outgoingY
        let turn = atan2(abs(cross), dot)
        guard turn.isFinite else { throw CanvasInkCurveError.invalidInput }
        return turn >= smoothingCornerTurn
    }

    static func derivedControl(
        for run: ControlRun,
        sampleCount: Int,
        controlVertexAt vertex: (Int) throws -> ControlVertex
    ) throws -> ControlVertex {
        guard let previous1 = try previousRun(
            before: run,
            sampleCount: sampleCount,
            controlVertexAt: vertex
        ), let previous2 = try previousRun(
            before: previous1,
            sampleCount: sampleCount,
            controlVertexAt: vertex
        ), let next1 = try nextRun(
            after: run,
            sampleCount: sampleCount,
            controlVertexAt: vertex
        ), let next2 = try nextRun(
            after: next1,
            sampleCount: sampleCount,
            controlVertexAt: vertex
        ) else {
            return run.representative
        }
        let runs = [previous2, previous1, run, next1, next2]
        for candidate in runs where try isSmoothingAnchor(
            candidate,
            sampleCount: sampleCount,
            controlVertexAt: vertex
        ) {
            return run.representative
        }
        let controls = runs.map(\.representative)
        func filtered(_ component: (ControlVertex) -> Double) -> Double {
            zip(smoothingWeights, controls).reduce(0) { result, pair in
                result + pair.0 * component(pair.1)
            } / smoothingWeightSum
        }
        let point = CanvasPoint(
            x: filtered { $0.point.x },
            y: filtered { $0.point.y }
        )
        let pressureValues = controls.compactMap(\.normalizedPressure)
        let result: ControlVertex
        if pressureValues.count == controls.count {
            let pressure = min(1, max(0, zip(smoothingWeights, pressureValues).reduce(0) {
                $0 + $1.0 * $1.1
            } / smoothingWeightSum))
            result = ControlVertex(
                point: point,
                widthFactor: widthFactor(forPressure: pressure),
                normalizedPressure: pressure
            )
        } else {
            result = ControlVertex(point: point, widthFactor: run.representative.widthFactor)
        }
        try validate(result)
        return result
    }

    @inline(__always)
    static func parameterIncrement(from start: CanvasPoint, to end: CanvasPoint) throws -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        guard dx.isFinite, dy.isFinite else {
            throw CanvasInkCurveError.invalidInput
        }
        let chordLength = hypot(dx, dy)
        let increment = max(sqrt(chordLength), 1e-6)
        guard increment.isFinite else {
            throw CanvasInkCurveError.invalidInput
        }
        return increment
    }

    @inline(__always)
    static func tangent(
        previous: ControlVertex,
        point: ControlVertex,
        next: ControlVertex,
        previousInterval: Double,
        nextInterval: Double,
        spanInterval: Double
    ) throws -> ControlVertex {
        let combinedInterval = previousInterval + nextInterval
        guard combinedInterval.isFinite else {
            throw CanvasInkCurveError.invalidInput
        }
        func component(_ previous: Double, _ point: Double, _ next: Double) throws -> Double {
            let previousDifference = point - previous
            let completeDifference = next - previous
            let nextDifference = next - point
            guard previousDifference.isFinite,
                  completeDifference.isFinite,
                  nextDifference.isFinite else {
                throw CanvasInkCurveError.invalidInput
            }
            let result = spanInterval * (
                previousDifference / previousInterval
                    - completeDifference / combinedInterval
                    + nextDifference / nextInterval
            )
            guard result.isFinite else {
                throw CanvasInkCurveError.invalidInput
            }
            return result
        }
        return ControlVertex(
            point: CanvasPoint(
                x: try component(previous.point.x, point.point.x, next.point.x),
                y: try component(previous.point.y, point.point.y, next.point.y)
            ),
            widthFactor: try component(
                previous.widthFactor,
                point.widthFactor,
                next.widthFactor
            )
        )
    }

    @inline(__always)
    static func offset(
        _ vertex: ControlVertex,
        by tangent: ControlVertex,
        scale: Double
    ) throws -> ControlVertex {
        let result = ControlVertex(
            point: CanvasPoint(
                x: vertex.point.x + tangent.point.x * scale,
                y: vertex.point.y + tangent.point.y * scale
            ),
            widthFactor: vertex.widthFactor + tangent.widthFactor * scale
        )
        try validate(result)
        return result
    }

    static func appendFlattened(
        _ cubic: Cubic,
        maximumError: Double,
        maximumWidthError: Double,
        depth: Int,
        to output: inout [CanvasInkVertex]
    ) throws {
        let control1PositionError = try distance(
            cubic.control1.point,
            toSegmentFrom: cubic.start.point,
            to: cubic.end.point
        )
        var positionIsWithinError = false
        if control1PositionError <= maximumError {
            positionIsWithinError = try distance(
                cubic.control2.point,
                toSegmentFrom: cubic.start.point,
                to: cubic.end.point
            ) <= maximumError
        }
        if positionIsWithinError {
            let widthDelta = cubic.end.widthFactor - cubic.start.widthFactor
            let expectedControl1Width = cubic.start.widthFactor + widthDelta / 3
            let expectedControl2Width = cubic.start.widthFactor + 2 * widthDelta / 3
            let widthError = max(
                abs(cubic.control1.widthFactor - expectedControl1Width),
                abs(cubic.control2.widthFactor - expectedControl2Width)
            )
            guard widthError <= maximumWidthError else {
                return try subdivide(
                    cubic,
                    maximumError: maximumError,
                    maximumWidthError: maximumWidthError,
                    depth: depth,
                    to: &output
                )
            }
            var directionIsSubpixel = false
            if maximumError <= 0.25,
               try finiteDistance(cubic.start.point, cubic.control1.point) <= maximumError,
               try finiteDistance(cubic.start.point, cubic.control2.point) <= maximumError,
               try finiteDistance(cubic.start.point, cubic.end.point) <= maximumError {
                directionIsSubpixel = true
            }
            let directionIsAccepted: Bool
            if directionIsSubpixel {
                directionIsAccepted = true
            } else {
                directionIsAccepted = try controlEdgesAreWithinTurn(
                    cubic,
                    maximumTurn: maximumFlattenedTurn
                )
            }
            if directionIsAccepted
               || depth == maximumSubdivisionDepth {
                guard output.count < maximumOutputVertexCount else {
                    throw CanvasInkCurveError.outputLimitExceeded
                }
                output.append(cubic.end.publicVertex)
                return
            }
        }
        try subdivide(
            cubic,
            maximumError: maximumError,
            maximumWidthError: maximumWidthError,
            depth: depth,
            to: &output
        )
    }

    @inline(__always)
    static func subdivide(
        _ cubic: Cubic,
        maximumError: Double,
        maximumWidthError: Double,
        depth: Int,
        to output: inout [CanvasInkVertex]
    ) throws {
        guard depth < maximumSubdivisionDepth else {
            throw CanvasInkCurveError.outputLimitExceeded
        }
        let split = try cubic.split()
        try appendFlattened(
            split.left,
            maximumError: maximumError,
            maximumWidthError: maximumWidthError,
            depth: depth + 1,
            to: &output
        )
        try appendFlattened(
            split.right,
            maximumError: maximumError,
            maximumWidthError: maximumWidthError,
            depth: depth + 1,
            to: &output
        )
    }

    @inline(__always)
    static func controlEdgesAreWithinTurn(
        _ cubic: Cubic,
        maximumTurn: Double
    ) throws -> Bool {
        let chord = (
            x: cubic.end.point.x - cubic.start.point.x,
            y: cubic.end.point.y - cubic.start.point.y
        )
        let chordLength = hypot(chord.x, chord.y)
        guard chordLength.isFinite else { throw CanvasInkCurveError.invalidInput }
        var hasNonzeroEdge = false
        func edgeIsWithinTurn(x: Double, y: Double) throws -> Bool {
            guard x != 0 || y != 0 else { return true }
            hasNonzeroEdge = true
            guard chordLength > 0 else { return false }
            let cross = chord.x * y - chord.y * x
            let dot = chord.x * x + chord.y * y
            let turn = atan2(abs(cross), dot)
            guard turn.isFinite else { throw CanvasInkCurveError.invalidInput }
            return turn <= maximumTurn
        }
        guard try edgeIsWithinTurn(
            x: cubic.control1.point.x - cubic.start.point.x,
            y: cubic.control1.point.y - cubic.start.point.y
        ) else { return false }
        guard try edgeIsWithinTurn(
            x: cubic.control2.point.x - cubic.control1.point.x,
            y: cubic.control2.point.y - cubic.control1.point.y
        ) else { return false }
        guard try edgeIsWithinTurn(
            x: cubic.end.point.x - cubic.control2.point.x,
            y: cubic.end.point.y - cubic.control2.point.y
        ) else { return false }
        return chordLength > 0 || !hasNonzeroEdge
    }

    @inline(__always)
    static func midpoint(_ first: ControlVertex, _ second: ControlVertex) throws -> ControlVertex {
        try interpolate(first, second, at: 0.5)
    }

    @inline(__always)
    static func interpolate(
        _ first: ControlVertex,
        _ second: ControlVertex,
        at parameter: Double
    ) throws -> ControlVertex {
        let complement = 1 - parameter
        let result = ControlVertex(
            point: CanvasPoint(
                x: complement * first.point.x + parameter * second.point.x,
                y: complement * first.point.y + parameter * second.point.y
            ),
            widthFactor: complement * first.widthFactor + parameter * second.widthFactor
        )
        try validate(result)
        return result
    }

    @inline(__always)
    static func validate(_ vertex: ControlVertex) throws {
        guard vertex.point.x.isFinite,
              vertex.point.y.isFinite,
              vertex.widthFactor.isFinite else {
            throw CanvasInkCurveError.invalidInput
        }
    }

    @inline(__always)
    static func finiteDistance(_ first: CanvasPoint, _ second: CanvasPoint) throws -> Double {
        let dx = first.x - second.x
        let dy = first.y - second.y
        guard dx.isFinite, dy.isFinite else {
            throw CanvasInkCurveError.invalidInput
        }
        let result = hypot(dx, dy)
        guard result.isFinite else {
            throw CanvasInkCurveError.invalidInput
        }
        return result
    }

    @inline(__always)
    static func distance(
        _ point: CanvasPoint,
        toSegmentFrom start: CanvasPoint,
        to end: CanvasPoint
    ) throws -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        guard dx.isFinite, dy.isFinite else {
            throw CanvasInkCurveError.invalidInput
        }
        let length = hypot(dx, dy)
        guard length.isFinite else {
            throw CanvasInkCurveError.invalidInput
        }
        guard length > 0 else {
            return try finiteDistance(point, start)
        }
        let pointDX = point.x - start.x
        let pointDY = point.y - start.y
        guard pointDX.isFinite, pointDY.isFinite else {
            throw CanvasInkCurveError.invalidInput
        }
        let projection = pointDX * (dx / length) + pointDY * (dy / length)
        guard projection.isFinite else {
            throw CanvasInkCurveError.invalidInput
        }
        let along = min(length, max(0, projection))
        let closest = CanvasPoint(
            x: start.x + along * (dx / length),
            y: start.y + along * (dy / length)
        )
        guard closest.x.isFinite, closest.y.isFinite else {
            throw CanvasInkCurveError.invalidInput
        }
        return try finiteDistance(point, closest)
    }

    static func extremaParameters(
        _ start: Double,
        _ control1: Double,
        _ control2: Double,
        _ end: Double
    ) throws -> [Double] {
        let firstDifference = control1 - start
        let secondDifference = control2 - control1
        let thirdDifference = end - control2
        guard firstDifference.isFinite,
              secondDifference.isFinite,
              thirdDifference.isFinite else {
            throw CanvasInkCurveError.invalidInput
        }
        let scale = max(abs(firstDifference), abs(secondDifference), abs(thirdDifference))
        guard scale > 0 else { return [] }

        let d0 = firstDifference / scale
        let d1 = secondDifference / scale
        let d2 = thirdDifference / scale
        let a = d0 - 2 * d1 + d2
        let b = 2 * (d1 - d0)
        let c = d0
        if a == 0 {
            guard b != 0 else { return [] }
            let root = -c / b
            return root > 0 && root < 1 ? [root] : []
        }

        let discriminant = b * b - 4 * a * c
        guard discriminant >= 0 else { return [] }
        let squareRoot = sqrt(discriminant)
        let q = -0.5 * (b + (b >= 0 ? squareRoot : -squareRoot))
        let roots: [Double]
        if q == 0 {
            roots = [-b / (2 * a)]
        } else {
            roots = [q / a, c / q]
        }
        guard roots.allSatisfy(\.isFinite) else {
            throw CanvasInkCurveError.invalidInput
        }
        return roots.filter { $0 > 0 && $0 < 1 }
    }
}

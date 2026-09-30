import XCTest
@testable import CadCanvasCore

final class CanvasInkCurveTests: XCTestCase {
    func testDirectionChangeSubdividesEvenWhenPositionToleranceIsLoose() throws {
        let stroke = self.stroke(
            [.init(x: 0, y: 0), .init(x: 20, y: 5), .init(x: 40, y: -5), .init(x: 60, y: 0)],
            pressures: [0.3, 0.3, 0.3, 0.3]
        )

        let vertices = try CanvasInkCurve.flatten(
            stroke: stroke,
            maximumError: 100,
            maximumWidthError: 100
        )

        XCTAssertGreaterThan(vertices.count, stroke.samples.count)
    }

    func testPressureWidthDeviationSubdividesStraightCentreline() throws {
        let stroke = self.stroke(
            [.init(x: 0, y: 0), .init(x: 20, y: 0), .init(x: 40, y: 0), .init(x: 60, y: 0)],
            pressures: [0, 1, 0, 1]
        )
        let loose = try CanvasInkCurve.flatten(
            stroke: stroke,
            maximumError: 100,
            maximumWidthError: 100
        )
        let smooth = try CanvasInkCurve.flatten(
            stroke: stroke,
            maximumError: 100,
            maximumWidthError: 0.01
        )

        XCTAssertGreaterThan(smooth.count, loose.count)
    }

    func testPhysicalZoomProgressivelyRefinesSameSavedSamples() throws {
        let stroke = self.stroke(
            [.init(x: 0, y: 0), .init(x: 20, y: 15), .init(x: 40, y: -15), .init(x: 60, y: 0)],
            pressures: [0, 0.3, 1, 0.3]
        )
        let counts = try [1.0, 4.0, 20.0].map { scale in
            try CanvasInkCurve.flatten(
                stroke: stroke,
                maximumError: 0.25 / scale,
                maximumWidthError: 0.5 / (1.75 * scale)
            ).count
        }

        XCTAssertLessThan(counts[0], counts[1])
        XCTAssertLessThan(counts[1], counts[2])
    }

    func testCanvasScaledAndScreenConstantWidthsUseSharedCanvasUnits() throws {
        XCTAssertEqual(
            try CanvasInkCurve.lineWidthInCanvasUnits(
                lineWidth: 4,
                viewportZoom: 2,
                widthMode: .canvasScaled
            ),
            4
        )
        XCTAssertEqual(
            try CanvasInkCurve.lineWidthInCanvasUnits(
                lineWidth: 4,
                viewportZoom: 2,
                widthMode: .screenConstant
            ),
            2
        )
        XCTAssertEqual(
            try CanvasInkCurve.maximumPaintedWidthInCanvasUnits(
                lineWidth: 4,
                viewportZoom: 2,
                pressureEnabled: true,
                widthMode: .canvasScaled
            ),
            7
        )
        XCTAssertEqual(
            try CanvasInkCurve.maximumPaintedWidthInCanvasUnits(
                lineWidth: 4,
                viewportZoom: 2,
                pressureEnabled: true,
                widthMode: .screenConstant
            ),
            3.5
        )
    }

    func testZeroOneAndTwoSampleStrokesPreserveEndpoints() throws {
        XCTAssertEqual(
            try CanvasInkCurve.flatten(stroke: stroke([]), maximumError: 0.25),
            []
        )

        let single = stroke([.init(x: 7, y: -3)], pressures: [0.5])
        let singleVertices = try CanvasInkCurve.flatten(stroke: single, maximumError: 0.25)
        XCTAssertEqual(singleVertices.map(\.point), single.points)
        XCTAssertEqual(
            try XCTUnwrap(singleVertices.first).widthFactor,
            1.2591607162524587,
            accuracy: 1e-12
        )

        let two = stroke([.init(x: -2, y: 4), .init(x: 9, y: -5)], pressures: [0, 1])
        let twoVertices = try CanvasInkCurve.flatten(stroke: two, maximumError: 0.25)
        XCTAssertEqual(twoVertices.map(\.point), two.points)
        XCTAssertEqual(twoVertices[0].widthFactor, 0.2, accuracy: 1e-15)
        XCTAssertEqual(twoVertices[1].widthFactor, 1.75, accuracy: 1e-12)
    }

    func testPressureResponseUsesApprovedAnchors() throws {
        let fixture = stroke(
            [.init(x: 0, y: 0), .init(x: 1, y: 0), .init(x: 2, y: 0)],
            pressures: [0, 0.3, 1]
        )

        let vertices = try CanvasInkCurve.flatten(stroke: fixture, maximumError: 0.01)
        let widths = try fixture.points.map { point in
            try XCTUnwrap(vertices.first(where: { $0.point == point })).widthFactor
        }

        XCTAssertEqual(widths[0], 0.2, accuracy: 1e-12)
        XCTAssertEqual(widths[1], 1, accuracy: 1e-12)
        XCTAssertEqual(widths[2], 1.75, accuracy: 1e-12)
        XCTAssertEqual(CanvasInkCurve.maximumWidthFactor(pressureEnabled: true), 1.75)
        XCTAssertEqual(CanvasInkCurve.maximumWidthFactor(pressureEnabled: false), 1)
    }

    func testPressureResponseIsFiniteMonotonicAndConcave() throws {
        let pressures = stride(from: 0.0, through: 1.0, by: 0.1).map { $0 }
        let fixture = stroke(
            pressures.indices.map { .init(x: Double($0), y: 0) },
            pressures: pressures
        )
        let vertices = try CanvasInkCurve.flatten(stroke: fixture, maximumError: 0.01)
        let widths = try fixture.points.map { point in
            try XCTUnwrap(vertices.first(where: { $0.point == point })).widthFactor
        }
        let changes = zip(widths, widths.dropFirst()).map { $1 - $0 }

        XCTAssertTrue(widths.allSatisfy(\.isFinite))
        XCTAssertTrue(changes.allSatisfy { $0 > 0 })
        XCTAssertTrue(zip(changes, changes.dropFirst()).allSatisfy { $1 <= $0 + 1e-12 })
    }

    func testSpanRangeBoundsPartitionExactlyMatchesFullCurveBounds() throws {
        let samples = [
            CanvasInkSample(point: .init(x: 0, y: 0), pressure: 0.1),
            CanvasInkSample(point: .init(x: 12, y: 18), pressure: 0.9),
            CanvasInkSample(point: .init(x: 12, y: 18), pressure: 0.4),
            CanvasInkSample(point: .init(x: -7, y: 31), pressure: 0.7),
            CanvasInkSample(point: .init(x: 44, y: -16), pressure: 0.2),
            CanvasInkSample(point: .init(x: 9, y: 5), pressure: 1),
        ]
        let prefix = Array(samples.prefix(3))
        let suffix = Array(samples.dropFirst(3))
        let firstPartition = try XCTUnwrap(CanvasInkCurve.boundsOfSpans(
            confirmedPrefix: prefix,
            appending: suffix,
            spanRange: 0..<2
        ))
        let secondPartition = try XCTUnwrap(CanvasInkCurve.boundsOfSpans(
            confirmedPrefix: prefix,
            appending: suffix,
            spanRange: 2..<5
        ))

        XCTAssertEqual(
            union(firstPartition, secondPartition),
            try CanvasInkCurve.bounds(stroke: .init(samples: samples, pressureEnabled: true))
        )
        XCTAssertNil(try CanvasInkCurve.boundsOfSpans(
            confirmedPrefix: prefix,
            appending: suffix,
            spanRange: 3..<3
        ))
    }

    func testSpanRangeBoundsRejectsInvalidRangeAndAffectedNonFiniteSamples() {
        let prefix = [CanvasInkSample(point: .init(x: 0, y: 0), pressure: 0.5)]
        let invalid = CanvasInkSample(point: .init(x: .nan, y: 2), pressure: 0.5)

        XCTAssertThrowsError(try CanvasInkCurve.boundsOfSpans(
            confirmedPrefix: prefix,
            appending: [invalid],
            spanRange: 0..<1
        )) { error in
            XCTAssertEqual(error as? CanvasInkCurveError, .invalidInput)
        }
        XCTAssertThrowsError(try CanvasInkCurve.boundsOfSpans(
            confirmedPrefix: prefix,
            appending: [],
            spanRange: 0..<1
        )) { error in
            XCTAssertEqual(error as? CanvasInkCurveError, .invalidInput)
        }
    }

    func testSpanRangeFlattenExactlyMatchesIndependentFullFlattenSlice() throws {
        let samples = [
            CanvasInkSample(point: .init(x: 0, y: 0), pressure: 0.1),
            CanvasInkSample(point: .init(x: 18, y: 26), pressure: 0.9),
            CanvasInkSample(point: .init(x: 18, y: 26), pressure: 0.3),
            CanvasInkSample(point: .init(x: -9, y: 42), pressure: 0.7),
            CanvasInkSample(point: .init(x: 31, y: -12), pressure: 0.2),
            CanvasInkSample(point: .init(x: 0, y: 0), pressure: 1),
            CanvasInkSample(point: .init(x: 54, y: 17), pressure: 0.4),
            CanvasInkSample(point: .init(x: 63, y: -8), pressure: 0.8),
        ]
        let maximumError = 0.125
        let range = 3..<(samples.count - 1)
        let full = try CanvasInkCurve.flattenWithSpanEnds(
            stroke: .init(samples: samples, pressureEnabled: true),
            maximumError: maximumError
        )
        let partial = try CanvasInkCurve.flattenSpanRange(
            confirmedPrefix: Array(samples.prefix(5)),
            appending: Array(samples.dropFirst(5)),
            pressureEnabled: true,
            spanRange: range,
            maximumError: maximumError
        )
        let fullStart = full.spanEndVertexIndices[range.lowerBound - 1]
        let fullEnd = full.spanEndVertexIndices[range.upperBound - 1]
        let expectedVertices = Array(full.vertices[fullStart...fullEnd])
        let expectedSpanEnds = full.spanEndVertexIndices[range].map {
            $0 - fullStart
        }

        XCTAssertEqual(partial.vertices, expectedVertices)
        XCTAssertEqual(partial.spanEndVertexIndices, expectedSpanEnds)
    }

    func testPartialFlattenDerivesEachControlVertexOnce() throws {
        let samples = [
            CanvasInkSample(point: .init(x: 0, y: 0), pressure: 0.1),
            CanvasInkSample(point: .init(x: 8, y: 5), pressure: 0.2),
            CanvasInkSample(point: .init(x: 8, y: 5), pressure: 0.7),
            CanvasInkSample(point: .init(x: 18, y: 7), pressure: 0.3),
            CanvasInkSample(point: .init(x: 30, y: 2), pressure: 0.4),
            CanvasInkSample(point: .init(x: 30, y: 2), pressure: 0.6),
            CanvasInkSample(point: .init(x: 42, y: 9), pressure: 0.5),
            CanvasInkSample(point: .init(x: 42, y: 24), pressure: 0.8),
            CanvasInkSample(point: .init(x: 31, y: 31), pressure: 1),
            CanvasInkSample(point: .init(x: 16, y: 29), pressure: 0.4),
        ]
        var derivations: [Int: Int] = [:]
        let partial = try CanvasInkCurve.flattenSpanRange(
            confirmedPrefix: samples,
            appending: [],
            pressureEnabled: true,
            spanRange: 0..<(samples.count - 1),
            maximumError: 0.25,
            maximumWidthError: 0.1,
            controlVertexDidDerive: { derivations[$0, default: 0] += 1 }
        )
        let complete = try CanvasInkCurve.flattenWithSpanEnds(
            stroke: CanvasInkStroke(samples: samples, pressureEnabled: true),
            maximumError: 0.25,
            maximumWidthError: 0.1
        )

        XCTAssertFalse(partial.vertices.isEmpty)
        XCTAssertTrue(derivations.values.allSatisfy { $0 == 1 })
        XCTAssertLessThanOrEqual(derivations.count, samples.count)
        XCTAssertEqual(partial, complete)
    }

    func testPartialFlattenPreparesEachAffectedControlRunOnce() throws {
        let samples = (0..<500).map { index in
            CanvasInkSample(
                point: CanvasPoint(x: Double(index), y: sin(Double(index) * 0.05)),
                pressure: Double(index % 11) / 10
            )
        }
        var preparations: [Int: Int] = [:]

        _ = try CanvasInkCurve.flattenSpanRange(
            confirmedPrefix: samples,
            appending: [],
            pressureEnabled: true,
            spanRange: 395..<499,
            maximumError: 0.25,
            maximumWidthError: 0.1,
            controlVertexDidDerive: nil,
            controlRunDidPrepare: { preparations[$0, default: 0] += 1 }
        )

        XCTAssertTrue(preparations.values.allSatisfy { $0 == 1 })
        XCTAssertLessThanOrEqual(preparations.count, 115)
    }

    func testFullFlattenPreparesEachControlRunOnce() throws {
        let samples = (0..<500).map { index in
            CanvasInkSample(
                point: CanvasPoint(x: Double(index), y: cos(Double(index) * 0.05)),
                pressure: Double(index % 13) / 12
            )
        }
        var preparations: [Int: Int] = [:]

        _ = try CanvasInkCurve.flattenWithSpanEnds(
            stroke: CanvasInkStroke(samples: samples, pressureEnabled: true),
            maximumError: 0.25,
            maximumWidthError: 0.1,
            controlRunDidPrepare: { preparations[$0, default: 0] += 1 }
        )

        XCTAssertEqual(preparations.count, samples.count)
        XCTAssertTrue(preparations.values.allSatisfy { $0 == 1 })
    }

    func testDegenerateAndDiagnosticFixturesRemainFiniteInterpolatingAndDeterministic() throws {
        for (name, fixture) in diagnosticFixtures {
            let original = fixture
            let first = try CanvasInkCurve.flatten(stroke: fixture, maximumError: 0.03125)
            let second = try CanvasInkCurve.flatten(stroke: fixture, maximumError: 0.03125)

            XCTAssertEqual(first, second, "\(name) was not deterministic")
            XCTAssertEqual(fixture, original, "\(name) mutated its source samples")
            assertFinite(first, fixture: name)
            assertPreservesEndpoints(fixture, vertices: first, fixture: name)
        }
    }

    func testConsecutiveExactDuplicatesDoNotChangeDerivedCurve() throws {
        let canonical = stroke(
            [.init(x: 0, y: 0), .init(x: 8, y: 5), .init(x: 18, y: 7), .init(x: 30, y: 2)],
            pressures: [0.1, 0.2, 0.3, 0.4]
        )
        let duplicated = stroke(
            [
                .init(x: 0, y: 0), .init(x: 0, y: 0),
                .init(x: 8, y: 5), .init(x: 8, y: 5),
                .init(x: 18, y: 7), .init(x: 30, y: 2), .init(x: 30, y: 2),
            ],
            pressures: [0.1, 0.1, 0.2, 0.2, 0.3, 0.4, 0.4]
        )

        let expected = try CanvasInkCurve.flattenWithSpanEnds(
            stroke: canonical,
            maximumError: 0.01
        )
        let actual = try CanvasInkCurve.flattenWithSpanEnds(
            stroke: duplicated,
            maximumError: 0.01
        )

        XCTAssertEqual(actual.vertices, expected.vertices)
        XCTAssertEqual(actual.spanEndVertexIndices.count, duplicated.samples.count - 1)
        XCTAssertEqual(actual.spanEndVertexIndices[0], 0)
        XCTAssertEqual(actual.spanEndVertexIndices[2], actual.spanEndVertexIndices[1])
        XCTAssertEqual(actual.spanEndVertexIndices[5], actual.spanEndVertexIndices[4])
    }

    func testSamePositionRunUsesLatestPressureWithoutMutatingSamples() throws {
        let duplicated = stroke(
            [.init(x: 0, y: 0), .init(x: 10, y: 5), .init(x: 10, y: 5), .init(x: 20, y: 0)],
            pressures: [0.2, 0.2, 0.8, 0.4]
        )
        let original = duplicated
        let canonical = stroke(
            [.init(x: 0, y: 0), .init(x: 10, y: 5), .init(x: 20, y: 0)],
            pressures: [0.2, 0.8, 0.4]
        )

        XCTAssertEqual(
            try CanvasInkCurve.flatten(stroke: duplicated, maximumError: 0.01),
            try CanvasInkCurve.flatten(stroke: canonical, maximumError: 0.01)
        )
        XCTAssertEqual(duplicated, original)
    }

    func testFiveRunSmoothingUsesApprovedPositionAndPressureCoefficients() throws {
        let points = [
            CanvasPoint(x: 0, y: 0), CanvasPoint(x: 1, y: 1),
            CanvasPoint(x: 2, y: 1), CanvasPoint(x: 3, y: 2),
            CanvasPoint(x: 4, y: 2), CanvasPoint(x: 5, y: 3),
            CanvasPoint(x: 6, y: 3),
        ]
        let fixture = stroke(
            points,
            pressures: [0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]
        )
        let original = fixture
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let encoded = try encoder.encode(fixture)
        let flattened = try CanvasInkCurve.flattenWithSpanEnds(
            stroke: fixture,
            maximumError: 0.001,
            maximumWidthError: 0.001
        )
        let center = flattened.vertices[flattened.spanEndVertexIndices[2]]
        let expectedY = 58.0 / 35
        let expectedPressure = 0.5
        let reference = try CanvasInkCurve.flatten(
            stroke: stroke([.init(x: 0, y: 0)], pressures: [expectedPressure]),
            maximumError: 0.001
        )

        XCTAssertEqual(center.point.x, 3, accuracy: 1e-12)
        XCTAssertEqual(center.point.y, expectedY, accuracy: 1e-12)
        XCTAssertEqual(center.widthFactor, try XCTUnwrap(reference.first).widthFactor, accuracy: 1e-12)
        XCTAssertEqual(fixture, original)
        XCTAssertEqual(try encoder.encode(fixture), encoded)
    }

    func testFiveRunSmoothingIsScaleEquivariant() throws {
        let points = [
            CanvasPoint(x: 0, y: 0), CanvasPoint(x: 1, y: 1),
            CanvasPoint(x: 2, y: 1), CanvasPoint(x: 3, y: 2),
            CanvasPoint(x: 4, y: 2), CanvasPoint(x: 5, y: 3),
            CanvasPoint(x: 6, y: 3),
        ]
        let pressures = [0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]
        let base = try CanvasInkCurve.flattenWithSpanEnds(
            stroke: stroke(points, pressures: pressures),
            maximumError: 0.001,
            maximumWidthError: 0.001
        )
        let scaled = try CanvasInkCurve.flattenWithSpanEnds(
            stroke: stroke(
                points.map { .init(x: $0.x * 4, y: $0.y * 4) },
                pressures: pressures
            ),
            maximumError: 0.004,
            maximumWidthError: 0.001
        )
        let baseControls = mappedControls(base)
        let scaledControls = mappedControls(scaled)

        XCTAssertEqual(baseControls.count, scaledControls.count)
        for (baseControl, scaledControl) in zip(baseControls, scaledControls) {
            XCTAssertEqual(scaledControl.point.x, baseControl.point.x * 4, accuracy: 1e-12)
            XCTAssertEqual(scaledControl.point.y, baseControl.point.y * 4, accuracy: 1e-12)
            XCTAssertEqual(scaledControl.widthFactor, baseControl.widthFactor, accuracy: 1e-12)
        }
    }

    func testSmoothingPreservesCornerAndDoesNotCrossIt() throws {
        let points = [
            CanvasPoint(x: -6, y: 0), CanvasPoint(x: -5, y: 0),
            CanvasPoint(x: -4, y: 0), CanvasPoint(x: -3, y: 0),
            CanvasPoint(x: -2, y: 0), CanvasPoint(x: -1, y: 0),
            CanvasPoint(x: 0, y: 0), CanvasPoint(x: 0, y: 1),
            CanvasPoint(x: 0, y: 2), CanvasPoint(x: 0, y: 3),
            CanvasPoint(x: 0, y: 4), CanvasPoint(x: 0, y: 5),
            CanvasPoint(x: 0, y: 6),
        ]
        let flattened = try CanvasInkCurve.flattenWithSpanEnds(
            stroke: stroke(points, pressures: Array(repeating: 0.5, count: points.count)),
            maximumError: 0.001
        )
        let controls = mappedControls(flattened)

        for index in 4...8 {
            XCTAssertEqual(controls[index].point, points[index])
        }
    }

    func testSmoothingReducesHalfPointQuantizationResidual() throws {
        let points = (0..<50).map { index in
            let rawY = 0.6 * sin(Double(index) * 0.25) + 0.025 * Double(index)
            return CanvasPoint(
                x: Double(index) * 3,
                y: (rawY * 2).rounded() / 2
            )
        }
        let fixture = stroke(points, pressures: Array(repeating: 0.5, count: points.count))
        let flattened = try CanvasInkCurve.flattenWithSpanEnds(
            stroke: fixture,
            maximumError: 0.001
        )
        let derivedPoints = mappedControls(flattened).map(\.point)

        XCTAssertGreaterThan(percentile99(fiveRunResiduals(points)), 0.25)
        XCTAssertLessThanOrEqual(percentile99(fiveRunResiduals(derivedPoints)), 0.15)
    }

    func testSpanRangeFlattenMatchesFullSliceAcrossDuplicateRuns() throws {
        let samples = [
            CanvasInkSample(point: .init(x: 0, y: 0), pressure: 0.1),
            CanvasInkSample(point: .init(x: 8, y: 5), pressure: 0.2),
            CanvasInkSample(point: .init(x: 8, y: 5), pressure: 0.7),
            CanvasInkSample(point: .init(x: 18, y: 7), pressure: 0.3),
            CanvasInkSample(point: .init(x: 30, y: 2), pressure: 0.4),
            CanvasInkSample(point: .init(x: 30, y: 2), pressure: 0.6),
            CanvasInkSample(point: .init(x: 42, y: 9), pressure: 0.5),
        ]
        let range = 1..<6
        let full = try CanvasInkCurve.flattenWithSpanEnds(
            stroke: .init(samples: samples, pressureEnabled: true),
            maximumError: 0.01
        )
        let partial = try CanvasInkCurve.flattenSpanRange(
            confirmedPrefix: Array(samples.prefix(4)),
            appending: Array(samples.dropFirst(4)),
            pressureEnabled: true,
            spanRange: range,
            maximumError: 0.01
        )
        let fullStart = full.spanEndVertexIndices[range.lowerBound - 1]
        let fullEnd = full.spanEndVertexIndices[range.upperBound - 1]

        XCTAssertEqual(partial.vertices, Array(full.vertices[fullStart...fullEnd]))
        XCTAssertEqual(
            partial.spanEndVertexIndices,
            full.spanEndVertexIndices[range].map { $0 - fullStart }
        )
    }

    func testSpanRangeFlattenMatchesFullSliceAcrossSmoothingAndCornerWindows() throws {
        let samples = [
            CanvasInkSample(point: .init(x: 0, y: 0), pressure: 0.1),
            CanvasInkSample(point: .init(x: 5, y: 1), pressure: 0.2),
            CanvasInkSample(point: .init(x: 10, y: 1.5), pressure: 0.3),
            CanvasInkSample(point: .init(x: 15, y: 3), pressure: 0.4),
            CanvasInkSample(point: .init(x: 20, y: 3), pressure: 0.5),
            CanvasInkSample(point: .init(x: 25, y: 5), pressure: 0.6),
            CanvasInkSample(point: .init(x: 25, y: 5), pressure: 0.9),
            CanvasInkSample(point: .init(x: 30, y: 6), pressure: 0.7),
            CanvasInkSample(point: .init(x: 30, y: 11), pressure: 0.8),
            CanvasInkSample(point: .init(x: 30, y: 16), pressure: 0.7),
            CanvasInkSample(point: .init(x: 30, y: 21), pressure: 0.6),
            CanvasInkSample(point: .init(x: 30, y: 26), pressure: 0.5),
            CanvasInkSample(point: .init(x: 30, y: 31), pressure: 0.4),
            CanvasInkSample(point: .init(x: 30, y: 36), pressure: 0.3),
        ]
        let range = 2..<12
        let full = try CanvasInkCurve.flattenWithSpanEnds(
            stroke: .init(samples: samples, pressureEnabled: true),
            maximumError: 0.01,
            maximumWidthError: 0.01
        )
        let partial = try CanvasInkCurve.flattenSpanRange(
            confirmedPrefix: Array(samples.prefix(8)),
            appending: Array(samples.dropFirst(8)),
            pressureEnabled: true,
            spanRange: range,
            maximumError: 0.01,
            maximumWidthError: 0.01
        )
        let fullStart = full.spanEndVertexIndices[range.lowerBound - 1]
        let fullEnd = full.spanEndVertexIndices[range.upperBound - 1]

        XCTAssertEqual(partial.vertices, Array(full.vertices[fullStart...fullEnd]))
        XCTAssertEqual(
            partial.spanEndVertexIndices,
            full.spanEndVertexIndices[range].map { $0 - fullStart }
        )
    }

    func testIncrementalBoundaryRetainsFiveDistinctTailRuns() {
        let unique = (0..<7).map {
            CanvasInkSample(point: .init(x: Double($0), y: 0), pressure: 0.5)
        }
        let tooShort = CanvasInkCurve.incrementalBoundary(
            confirmedPrefix: Array(unique.prefix(4)),
            appending: [],
            isFinalized: false
        )
        let fiveRuns = CanvasInkCurve.incrementalBoundary(
            confirmedPrefix: Array(unique.prefix(5)),
            appending: [],
            isFinalized: false
        )
        let sevenRuns = CanvasInkCurve.incrementalBoundary(
            confirmedPrefix: Array(unique.prefix(3)),
            appending: Array(unique.dropFirst(3)),
            isFinalized: false
        )

        XCTAssertEqual(tooShort, .init(finalizedSampleCount: 0, stableSpanCount: 0))
        XCTAssertEqual(fiveRuns, .init(finalizedSampleCount: 1, stableSpanCount: 0))
        XCTAssertEqual(sevenRuns, .init(finalizedSampleCount: 3, stableSpanCount: 2))
    }

    func testIncrementalBoundaryIncludesDuplicateSamplesInRetainedRunAndFinalizesAll() {
        let samples = [
            CanvasInkSample(point: .init(x: 0, y: 0), pressure: 0.1),
            CanvasInkSample(point: .init(x: 1, y: 0), pressure: 0.2),
            CanvasInkSample(point: .init(x: 2, y: 0), pressure: 0.3),
            CanvasInkSample(point: .init(x: 2, y: 0), pressure: 0.9),
            CanvasInkSample(point: .init(x: 3, y: 0), pressure: 0.4),
            CanvasInkSample(point: .init(x: 4, y: 0), pressure: 0.5),
            CanvasInkSample(point: .init(x: 5, y: 0), pressure: 0.6),
            CanvasInkSample(point: .init(x: 6, y: 0), pressure: 0.7),
        ]

        XCTAssertEqual(
            CanvasInkCurve.incrementalBoundary(
                confirmedPrefix: Array(samples.prefix(4)),
                appending: Array(samples.dropFirst(4)),
                isFinalized: false
            ),
            .init(finalizedSampleCount: 4, stableSpanCount: 3)
        )
        XCTAssertEqual(
            CanvasInkCurve.incrementalBoundary(
                confirmedPrefix: samples,
                appending: [],
                isFinalized: true
            ),
            .init(finalizedSampleCount: samples.count, stableSpanCount: samples.count - 1)
        )
    }

    func testPressureDisabledProducesExactlyUniformWidth() throws {
        let fixture = CanvasInkStroke(
            samples: handwritingPoints.enumerated().map { index, point in
                CanvasInkSample(point: point, pressure: Double(index % 9) / 8)
            },
            pressureEnabled: false
        )

        let vertices = try CanvasInkCurve.flatten(stroke: fixture, maximumError: 0.01)

        XCTAssertFalse(vertices.isEmpty)
        XCTAssertTrue(vertices.allSatisfy { $0.widthFactor == 1 })
    }

    func testPressureSamplesPreserveTheirIndividualWidthResponse() throws {
        let fixture = stroke(
            (0..<5).map { CanvasPoint(x: Double($0), y: 0) },
            pressures: [0, 0, 1, 0, 0]
        )

        let vertices = try CanvasInkCurve.flatten(stroke: fixture, maximumError: 0.01)
        let endpointWidths = try fixture.points.map { sourcePoint in
            try XCTUnwrap(vertices.first { $0.point == sourcePoint }).widthFactor
        }

        XCTAssertEqual(endpointWidths[0], 0.2, accuracy: 1e-15)
        XCTAssertEqual(endpointWidths[1], 0.2, accuracy: 1e-15)
        XCTAssertEqual(endpointWidths[2], 1.75, accuracy: 1e-12)
        XCTAssertEqual(endpointWidths[3], 0.2, accuracy: 1e-15)
        XCTAssertEqual(endpointWidths[4], 0.2, accuracy: 1e-15)
        XCTAssertTrue(endpointWidths.contains(1.75))
    }

    func testPressureEndpointsPreserveTheFullAvailableWidthRange() throws {
        let fixture = stroke(
            [.init(x: 0, y: 0), .init(x: 10, y: 0)],
            pressures: [0, 1]
        )

        let vertices = try CanvasInkCurve.flatten(stroke: fixture, maximumError: 0.01)

        XCTAssertEqual(try XCTUnwrap(vertices.first).widthFactor, 0.2, accuracy: 1e-15)
        XCTAssertEqual(try XCTUnwrap(vertices.last).widthFactor, 1.75, accuracy: 1e-12)
    }

    func testFiniteOutOfRangePressureIsClampedBeforeFiltering() throws {
        let fixture = stroke(
            [.init(x: 0, y: 0), .init(x: 1, y: 0), .init(x: 2, y: 0)],
            pressures: [-100, 0.5, 100]
        )

        let vertices = try CanvasInkCurve.flatten(stroke: fixture, maximumError: 0.1)

        assertFinite(vertices, fixture: "clamped pressure")
        XCTAssertEqual(try XCTUnwrap(vertices.first).widthFactor, 0.2, accuracy: 1e-15)
        XCTAssertEqual(try XCTUnwrap(vertices.last).widthFactor, 1.75, accuracy: 1e-12)
    }

    func testDenseOracleStaysWithinQuarterPhysicalPixelAtAllRequiredScales() throws {
        let fixtures = diagnosticFixtures + [("inflected midpoint trap", inflectedMidpointFixture)]
        for viewportScale in [1.0, 2.0, 4.0, 8.0] {
            let maximumError = max(1e-6, 0.25 / viewportScale)
            for (name, fixture) in fixtures {
                let oracleFixture = derivedCurveStroke(fixture)
                let vertices = try CanvasInkCurve.flatten(
                    stroke: fixture,
                    maximumError: maximumError
                )
                var maximumDistance = 0.0
                var flattenedStartIndex = vertices.startIndex
                for (spanIndex, span) in barryGoldmanSpans(for: oracleFixture).enumerated() {
                    let sourceEnd = oracleFixture.points[spanIndex + 1]
                    let searchStart = vertices.index(after: flattenedStartIndex)
                    let flattenedEndIndex = try XCTUnwrap(
                        vertices[searchStart...].firstIndex { vertex in
                            hypot(vertex.point.x - sourceEnd.x, vertex.point.y - sourceEnd.y) <= 1e-12
                        },
                        "\(name) omitted endpoint for span \(spanIndex)"
                    )
                    let flattenedSpan = vertices[flattenedStartIndex...flattenedEndIndex].map(\.point)
                    for step in 0...1_024 {
                        let point = span.point(at: Double(step) / 1_024)
                        maximumDistance = max(
                            maximumDistance,
                            distance(point, toPolyline: flattenedSpan)
                        )
                    }
                    flattenedStartIndex = flattenedEndIndex
                }
                XCTAssertLessThanOrEqual(
                    maximumDistance * viewportScale,
                    0.25 + 1e-9,
                    "\(name) exceeded the physical-pixel bound at scale \(viewportScale)"
                )
            }
        }
    }

    func testInflectedSpanHasMidpointOnChordButInteriorAwayFromChord() throws {
        let span = try XCTUnwrap(barryGoldmanSpans(for: inflectedMidpointFixture).dropFirst().first)
        let midpointDistance = distanceFromSegment(span.point(at: 0.5), span.start, span.end)
        let quarterDistance = distanceFromSegment(span.point(at: 0.25), span.start, span.end)

        XCTAssertEqual(midpointDistance, 0, accuracy: 1e-12)
        XCTAssertGreaterThan(quarterDistance, 0.1)

        let vertices = try CanvasInkCurve.flatten(
            stroke: inflectedMidpointFixture,
            maximumError: 0.01
        )
        XCTAssertGreaterThan(vertices.count, inflectedMidpointFixture.samples.count)
    }

    func testFortyEightThousandNearLinearSamplesStayBoundedAndPreserveSource() throws {
        let samples = (0..<48_000).map { index -> CanvasInkSample in
            let x = Double(index) * 0.25
            let y = x * 0.002 + sin(Double(index) * 0.01) * 0.000_01
            return CanvasInkSample(point: .init(x: x, y: y), pressure: Double(index % 101) / 100)
        }
        let fixture = CanvasInkStroke(samples: samples, pressureEnabled: true)
        let original = fixture

        let vertices = try CanvasInkCurve.flatten(stroke: fixture, maximumError: 0.25)

        XCTAssertLessThanOrEqual(vertices.count, 1_000_000)
        XCTAssertEqual(vertices.first?.point, samples.first?.point)
        XCTAssertEqual(vertices.last?.point, samples.last?.point)
        XCTAssertEqual(vertices.count, samples.count)
        XCTAssertEqual(fixture, original)
        assertFinite(vertices, fixture: "48,000 near-linear samples")
    }

    func testDepthLimitThrowsAtomically() {
        let fixture = stroke([
            .init(x: -1, y: -1_000),
            .init(x: 0, y: 0),
            .init(x: 100, y: 0),
            .init(x: 101, y: 1_000),
        ])

        XCTAssertThrowsError(
            try CanvasInkCurve.flatten(stroke: fixture, maximumError: .leastNonzeroMagnitude)
        ) { error in
            XCTAssertEqual(error as? CanvasInkCurveError, .outputLimitExceeded)
        }
    }

    func testVertexLimitThrowsAtomically() {
        let fixture = CanvasInkStroke(
            samples: (0...1_000_000).map {
                CanvasInkSample(point: .init(x: Double($0), y: 0), pressure: 1)
            },
            pressureEnabled: false
        )

        XCTAssertThrowsError(
            try CanvasInkCurve.flatten(stroke: fixture, maximumError: 1)
        ) { error in
            XCTAssertEqual(error as? CanvasInkCurveError, .outputLimitExceeded)
        }
    }

    func testVertexLimitPreflightTakesPrecedenceOverInvalidSampleContent() {
        var samples = (0...1_000_000).map {
            CanvasInkSample(point: .init(x: Double($0), y: 0), pressure: 1)
        }
        samples[samples.count - 1].pressure = .nan
        let fixture = CanvasInkStroke(samples: samples, pressureEnabled: true)

        XCTAssertThrowsError(
            try CanvasInkCurve.flatten(stroke: fixture, maximumError: 1)
        ) { error in
            XCTAssertEqual(error as? CanvasInkCurveError, .outputLimitExceeded)
        }
    }

    func testInvalidInputsThrowTypedErrors() {
        let valid = stroke([.init(x: 0, y: 0), .init(x: 1, y: 1)])
        for maximumError: Double in [0, -1, .infinity, -.infinity, .nan] {
            XCTAssertThrowsError(
                try CanvasInkCurve.flatten(stroke: valid, maximumError: maximumError)
            ) { error in
                XCTAssertEqual(error as? CanvasInkCurveError, .invalidInput)
            }
        }

        let invalidStrokes = [
            stroke([.init(x: .nan, y: 0)]),
            stroke([.init(x: 0, y: .infinity)]),
            stroke([.init(x: 0, y: 0)], pressures: [.nan]),
        ]
        for invalid in invalidStrokes {
            XCTAssertThrowsError(
                try CanvasInkCurve.flatten(stroke: invalid, maximumError: 0.25)
            ) { error in
                XCTAssertEqual(error as? CanvasInkCurveError, .invalidInput)
            }
            XCTAssertThrowsError(try CanvasInkCurve.bounds(stroke: invalid)) { error in
                XCTAssertEqual(error as? CanvasInkCurveError, .invalidInput)
            }
        }
    }

    func testBoundsMatchIndependentExtremaOracleAndGeometryUsesThem() throws {
        let fixture = inflectedMidpointFixture
        let expected = independentBounds(of: barryGoldmanSpans(for: fixture))

        let actual = try CanvasInkCurve.bounds(stroke: fixture)

        XCTAssertEqual(actual.x, expected.x, accuracy: 1e-10)
        XCTAssertEqual(actual.y, expected.y, accuracy: 1e-10)
        XCTAssertEqual(actual.width, expected.width, accuracy: 1e-10)
        XCTAssertEqual(actual.height, expected.height, accuracy: 1e-10)
        XCTAssertEqual(CanvasGeometry.freehand(fixture).bounds, actual)
        XCTAssertEqual(
            try CanvasInkCurve.bounds(stroke: stroke([])),
            CanvasRect(x: 0, y: 0, width: 0, height: 0)
        )
        XCTAssertEqual(
            try CanvasInkCurve.bounds(stroke: stroke([.init(x: 8, y: -4)])),
            CanvasRect(x: 8, y: -4, width: 0, height: 0)
        )
    }

    func testCurveHitTestingFindsCurvedInteriorThatSourceChordMisses() throws {
        let span = try XCTUnwrap(barryGoldmanSpans(for: inflectedMidpointFixture).dropFirst().first)
        let curvedPoint = span.point(at: 0.25)
        XCTAssertGreaterThan(distanceFromSegment(curvedPoint, span.start, span.end), 0.1)

        XCTAssertTrue(try CanvasInkCurve.hitTest(
            curvedPoint,
            stroke: inflectedMidpointFixture,
            tolerance: 0.05,
            maximumWidthInCanvasUnits: 0
        ))
        XCTAssertFalse(try CanvasInkCurve.hitTest(
            .init(x: curvedPoint.x, y: curvedPoint.y + 10),
            stroke: inflectedMidpointFixture,
            tolerance: 0.05,
            maximumWidthInCanvasUnits: 0
        ))
    }

    func testHitTestingAccountsForMaximumWidthAndDots() throws {
        let line = stroke([.init(x: 0, y: 0), .init(x: 10, y: 0)])
        XCTAssertTrue(try CanvasInkCurve.hitTest(
            .init(x: 5, y: 2.9),
            stroke: line,
            tolerance: 0,
            maximumWidthInCanvasUnits: 6
        ))
        XCTAssertFalse(try CanvasInkCurve.hitTest(
            .init(x: 5, y: 3.1),
            stroke: line,
            tolerance: 0,
            maximumWidthInCanvasUnits: 6
        ))

        let dot = stroke([.init(x: 4, y: 5)])
        XCTAssertTrue(try CanvasInkCurve.hitTest(
            .init(x: 4, y: 7),
            stroke: dot,
            tolerance: 1,
            maximumWidthInCanvasUnits: 2
        ))
        XCTAssertFalse(try CanvasInkCurve.hitTest(
            .init(x: 4, y: 7.01),
            stroke: dot,
            tolerance: 1,
            maximumWidthInCanvasUnits: 2
        ))
    }

    func testHugeExactEndpointsResolveBeforeInteriorFlatteningLimit() throws {
        let fixture = stroke([
            .init(x: 0, y: 0),
            .init(x: 510_000, y: 499_800),
            .init(x: 1_000_000, y: 0),
        ])

        XCTAssertTrue(try CanvasInkCurve.hitTest(
            fixture.points[0],
            stroke: fixture,
            tolerance: 0,
            maximumWidthInCanvasUnits: 0
        ))
        XCTAssertTrue(try CanvasInkCurve.hitTest(
            fixture.points[2],
            stroke: fixture,
            tolerance: 0,
            maximumWidthInCanvasUnits: 0
        ))
        XCTAssertThrowsError(try CanvasInkCurve.hitTest(
            fixture.points[1],
            stroke: fixture,
            tolerance: 0,
            maximumWidthInCanvasUnits: 0
        )) { error in
            XCTAssertEqual(error as? CanvasInkCurveError, .outputLimitExceeded)
        }
    }

    func testHitTestRejectsInvalidArguments() {
        let fixture = stroke([.init(x: 0, y: 0), .init(x: 1, y: 1)])
        let arguments: [(CanvasPoint, Double, Double)] = [
            (.init(x: .nan, y: 0), 1, 1),
            (.init(x: 0, y: .infinity), 1, 1),
            (.init(x: 0, y: 0), -.leastNonzeroMagnitude, 1),
            (.init(x: 0, y: 0), .infinity, 1),
            (.init(x: 0, y: 0), 1, -.leastNonzeroMagnitude),
            (.init(x: 0, y: 0), 1, .nan),
        ]
        for (point, tolerance, width) in arguments {
            XCTAssertThrowsError(try CanvasInkCurve.hitTest(
                point,
                stroke: fixture,
                tolerance: tolerance,
                maximumWidthInCanvasUnits: width
            )) { error in
                XCTAssertEqual(error as? CanvasInkCurveError, .invalidInput)
            }
        }
    }

    func testPaintedBoundsRejectsExtremeFiniteInputsWithInfiniteDerivedEdges() {
        let maximum = Double.greatestFiniteMagnitude
        let cases: [(bounds: CanvasRect, lineWidth: Double)] = [
            (
                CanvasRect(x: maximum * 0.75, y: 0, width: maximum * 0.5, height: 0),
                0
            ),
            (
                CanvasRect(x: maximum * 0.75, y: 0, width: 0, height: 0),
                maximum
            ),
            (
                CanvasRect(x: 0, y: maximum * 0.75, width: 0, height: 0),
                maximum
            ),
        ]

        for fixture in cases {
            XCTAssertTrue(fixture.bounds.isFinite)
            XCTAssertThrowsError(try CanvasInkCurve.paintedBounds(
                centerlineBounds: fixture.bounds,
                lineWidth: fixture.lineWidth,
                viewportZoom: 1,
                widthMode: .canvasScaled
            )) { error in
                XCTAssertEqual(error as? CanvasInkCurveError, .invalidInput)
            }
        }
    }

    func testPaintedWidthAndBoundsUsePressureSpecificMaximum() throws {
        XCTAssertEqual(
            try CanvasInkCurve.maximumPaintedWidthInCanvasUnits(
                lineWidth: 4,
                viewportZoom: 2,
                pressureEnabled: true,
                widthMode: .screenConstant
            ),
            3.5,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            try CanvasInkCurve.maximumPaintedWidthInCanvasUnits(
                lineWidth: 4,
                viewportZoom: 2,
                pressureEnabled: false,
                widthMode: .screenConstant
            ),
            2,
            accuracy: 1e-12
        )

        let centerline = CanvasRect(x: 10, y: 20, width: 30, height: 40)
        XCTAssertEqual(
            try CanvasInkCurve.paintedBounds(
                centerlineBounds: centerline,
                lineWidth: 4,
                viewportZoom: 2,
                pressureEnabled: true,
                widthMode: .screenConstant
            ),
            CanvasRect(x: 8.25, y: 18.25, width: 33.5, height: 43.5)
        )
        XCTAssertEqual(
            try CanvasInkCurve.paintedBounds(
                centerlineBounds: centerline,
                lineWidth: 4,
                viewportZoom: 2,
                pressureEnabled: false,
                widthMode: .screenConstant
            ),
            CanvasRect(x: 9, y: 19, width: 32, height: 42)
        )
    }
}

private extension CanvasInkCurveTests {
    func union(_ first: CanvasRect, _ second: CanvasRect) -> CanvasRect {
        let minimumX = min(first.minX, second.minX)
        let maximumX = max(first.maxX, second.maxX)
        let minimumY = min(first.minY, second.minY)
        let maximumY = max(first.maxY, second.maxY)
        return CanvasRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX,
            height: maximumY - minimumY
        )
    }

    var diagnosticFixtures: [(String, CanvasInkStroke)] {
        [
            ("repeated points", stroke([
                .init(x: 0, y: 0), .init(x: 0, y: 0), .init(x: 5, y: 2),
                .init(x: 5, y: 2), .init(x: 10, y: 0),
            ])),
            ("very close points", stroke([
                .init(x: 0, y: 0), .init(x: 1e-14, y: -1e-14),
                .init(x: 2e-14, y: 3e-14), .init(x: 1, y: 1),
            ])),
            ("sharp reversal", stroke([
                .init(x: 0, y: 0), .init(x: 20, y: 0), .init(x: 0.01, y: 0.1),
                .init(x: 20, y: 0.2), .init(x: 0, y: 0.3),
            ])),
            ("loop", stroke([
                .init(x: 0, y: 0), .init(x: 8, y: -10), .init(x: 18, y: 0),
                .init(x: 8, y: 10), .init(x: 0, y: 0), .init(x: 10, y: -3),
            ])),
            ("shallow diagonal", stroke([
                .init(x: -30, y: 1), .init(x: -10, y: 1.1),
                .init(x: 10, y: 1.25), .init(x: 30, y: 1.3),
            ])),
            ("steep diagonal", stroke([
                .init(x: 1, y: -30), .init(x: 1.1, y: -10),
                .init(x: 1.25, y: 10), .init(x: 1.3, y: 30),
            ])),
            ("42-point M4 handwriting", CanvasInkStroke(
                samples: handwritingPoints.enumerated().map { index, point in
                    CanvasInkSample(point: point, pressure: Double((index * 17) % 41) / 40)
                },
                pressureEnabled: true
            )),
        ]
    }

    var handwritingPoints: [CanvasPoint] {
        [
            .init(x: 10, y: 70), .init(x: 11, y: 59), .init(x: 13, y: 45),
            .init(x: 16, y: 34), .init(x: 19, y: 43), .init(x: 20, y: 57),
            .init(x: 21, y: 70), .init(x: 23, y: 55), .init(x: 27, y: 42),
            .init(x: 31, y: 50), .init(x: 32, y: 66), .init(x: 34, y: 72),
            .init(x: 38, y: 64), .init(x: 40, y: 51), .init(x: 44, y: 45),
            .init(x: 49, y: 49), .init(x: 50, y: 59), .init(x: 47, y: 67),
            .init(x: 43, y: 64), .init(x: 44, y: 56), .init(x: 52, y: 52),
            .init(x: 60, y: 51), .init(x: 66, y: 49), .init(x: 69, y: 43),
            .init(x: 68, y: 55), .init(x: 67, y: 68), .init(x: 69, y: 72),
            .init(x: 74, y: 68), .init(x: 77, y: 59), .init(x: 79, y: 50),
            .init(x: 82, y: 47), .init(x: 85, y: 54), .init(x: 84, y: 63),
            .init(x: 80, y: 68), .init(x: 84, y: 70), .init(x: 91, y: 66),
            .init(x: 95, y: 58), .init(x: 98, y: 49), .init(x: 103, y: 47),
            .init(x: 108, y: 52), .init(x: 106, y: 61), .init(x: 101, y: 67),
        ]
    }

    var inflectedMidpointFixture: CanvasInkStroke {
        stroke([
            .init(x: -1, y: -6), .init(x: 0, y: 0),
            .init(x: 3, y: 0), .init(x: 4, y: 6),
        ])
    }

    func stroke(
        _ points: [CanvasPoint],
        pressures: [Double]? = nil,
        pressureEnabled: Bool = true
    ) -> CanvasInkStroke {
        let resolvedPressures = pressures ?? points.indices.map { Double($0 % 5) / 4 }
        return CanvasInkStroke(
            samples: zip(points, resolvedPressures).map(CanvasInkSample.init),
            pressureEnabled: pressureEnabled
        )
    }

    func normalizedCurveStroke(_ stroke: CanvasInkStroke) -> CanvasInkStroke {
        var samples: [CanvasInkSample] = []
        samples.reserveCapacity(stroke.samples.count)
        for sample in stroke.samples {
            if samples.last?.point == sample.point {
                samples[samples.count - 1] = sample
            } else {
                samples.append(sample)
            }
        }
        return CanvasInkStroke(
            samples: samples,
            pressureEnabled: stroke.pressureEnabled,
            widthMode: stroke.widthMode
        )
    }

    func derivedCurveStroke(_ stroke: CanvasInkStroke) -> CanvasInkStroke {
        let normalized = normalizedCurveStroke(stroke)
        let points = normalized.points
        guard points.count >= 7 else { return normalized }
        let anchors = points.indices.map { index -> Bool in
            guard index > 0, index + 1 < points.count else { return true }
            let incoming = CanvasPoint(
                x: points[index].x - points[index - 1].x,
                y: points[index].y - points[index - 1].y
            )
            let outgoing = CanvasPoint(
                x: points[index + 1].x - points[index].x,
                y: points[index + 1].y - points[index].y
            )
            let cross = incoming.x * outgoing.y - incoming.y * outgoing.x
            let dot = incoming.x * outgoing.x + incoming.y * outgoing.y
            return atan2(abs(cross), dot) >= Double.pi / 3
        }
        let weights = [-3.0, 12, 17, 12, -3]
        let samples = normalized.samples.indices.map { index -> CanvasInkSample in
            guard index >= 2,
                  index + 2 < normalized.samples.count,
                  !(index - 2...index + 2).contains(where: { anchors[$0] }) else {
                return normalized.samples[index]
            }
            let window = normalized.samples[(index - 2)...(index + 2)]
            let filteredX = zip(weights, window).reduce(0) { $0 + $1.0 * $1.1.point.x } / 35
            let filteredY = zip(weights, window).reduce(0) { $0 + $1.0 * $1.1.point.y } / 35
            let filteredPressure = zip(weights, window).reduce(0) {
                $0 + $1.0 * min(1, max(0, $1.1.pressure))
            } / 35
            return CanvasInkSample(
                point: .init(x: filteredX, y: filteredY),
                pressure: min(1, max(0, filteredPressure))
            )
        }
        return CanvasInkStroke(
            samples: samples,
            pressureEnabled: normalized.pressureEnabled,
            widthMode: normalized.widthMode
        )
    }

    func mappedControls(_ flattened: CanvasFlattenedInkCurve) -> [CanvasInkVertex] {
        guard let first = flattened.vertices.first else { return [] }
        return [first] + flattened.spanEndVertexIndices.map { flattened.vertices[$0] }
    }

    func assertFinite(
        _ vertices: [CanvasInkVertex],
        fixture: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for vertex in vertices {
            XCTAssertTrue(vertex.point.x.isFinite, "\(fixture) x", file: file, line: line)
            XCTAssertTrue(vertex.point.y.isFinite, "\(fixture) y", file: file, line: line)
            XCTAssertTrue(vertex.widthFactor.isFinite, "\(fixture) width", file: file, line: line)
            XCTAssertGreaterThanOrEqual(vertex.widthFactor, 0.2, fixture, file: file, line: line)
            XCTAssertLessThanOrEqual(vertex.widthFactor, 1.75, fixture, file: file, line: line)
        }
    }

    func assertPreservesEndpoints(
        _ fixture: CanvasInkStroke,
        vertices: [CanvasInkVertex],
        fixture name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let first = fixture.points.first else {
            XCTAssertTrue(vertices.isEmpty, name, file: file, line: line)
            return
        }
        XCTAssertEqual(vertices.first?.point, first, name, file: file, line: line)
        XCTAssertEqual(vertices.last?.point, fixture.points.last, name, file: file, line: line)
    }

    func fiveRunResiduals(_ points: [CanvasPoint]) -> [Double] {
        guard points.count >= 5 else { return [] }
        let weights = [-3.0, 12, 17, 12, -3]
        return (2..<(points.count - 2)).map { index in
            let window = points[(index - 2)...(index + 2)]
            let filteredX = zip(weights, window).reduce(0) { $0 + $1.0 * $1.1.x } / 35
            let filteredY = zip(weights, window).reduce(0) { $0 + $1.0 * $1.1.y } / 35
            return hypot(points[index].x - filteredX, points[index].y - filteredY)
        }
    }

    func percentile99(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[Int(ceil(Double(sorted.count) * 0.99)) - 1]
    }
}

private struct BarryGoldmanSpan {
    var p0: CanvasPoint
    var p1: CanvasPoint
    var p2: CanvasPoint
    var p3: CanvasPoint
    var t0: Double
    var t1: Double
    var t2: Double
    var t3: Double

    var start: CanvasPoint { p1 }
    var end: CanvasPoint { p2 }

    func point(at normalizedParameter: Double) -> CanvasPoint {
        let parameter = t1 + normalizedParameter * (t2 - t1)
        let a1 = interpolate(p0, p1, from: t0, to: t1, at: parameter)
        let a2 = interpolate(p1, p2, from: t1, to: t2, at: parameter)
        let a3 = interpolate(p2, p3, from: t2, to: t3, at: parameter)
        let b1 = interpolate(a1, a2, from: t0, to: t2, at: parameter)
        let b2 = interpolate(a2, a3, from: t1, to: t3, at: parameter)
        return interpolate(b1, b2, from: t1, to: t2, at: parameter)
    }

    private func interpolate(
        _ first: CanvasPoint,
        _ second: CanvasPoint,
        from firstKnot: Double,
        to secondKnot: Double,
        at parameter: Double
    ) -> CanvasPoint {
        let denominator = secondKnot - firstKnot
        let firstWeight = (secondKnot - parameter) / denominator
        let secondWeight = (parameter - firstKnot) / denominator
        return CanvasPoint(
            x: firstWeight * first.x + secondWeight * second.x,
            y: firstWeight * first.y + secondWeight * second.y
        )
    }
}

private func barryGoldmanSpans(for stroke: CanvasInkStroke) -> [BarryGoldmanSpan] {
    guard stroke.samples.count > 1 else { return [] }
    let points = stroke.points
    return points.indices.dropLast().map { index in
        let p0 = points[index == 0 ? index : index - 1]
        let p1 = points[index]
        let p2 = points[index + 1]
        let p3 = points[index + 1 == points.count - 1 ? index + 1 : index + 2]
        let dt01 = max(sqrt(hypot(p1.x - p0.x, p1.y - p0.y)), 1e-6)
        let dt12 = max(sqrt(hypot(p2.x - p1.x, p2.y - p1.y)), 1e-6)
        let dt23 = max(sqrt(hypot(p3.x - p2.x, p3.y - p2.y)), 1e-6)
        let t0 = 0.0
        let t1 = t0 + dt01
        let t2 = t1 + dt12
        let t3 = t2 + dt23
        return BarryGoldmanSpan(
            p0: p0,
            p1: p1,
            p2: p2,
            p3: p3,
            t0: t0,
            t1: t1,
            t2: t2,
            t3: t3
        )
    }
}

private func distance(_ point: CanvasPoint, toPolyline polyline: [CanvasPoint]) -> Double {
    guard let first = polyline.first else { return .infinity }
    guard polyline.count > 1 else { return hypot(point.x - first.x, point.y - first.y) }
    var result = Double.infinity
    for index in 1..<polyline.count {
        result = min(result, distanceFromSegment(point, polyline[index - 1], polyline[index]))
    }
    return result
}

private func distanceFromSegment(_ point: CanvasPoint, _ start: CanvasPoint, _ end: CanvasPoint) -> Double {
    let dx = end.x - start.x
    let dy = end.y - start.y
    let squaredLength = dx * dx + dy * dy
    guard squaredLength > 0 else { return hypot(point.x - start.x, point.y - start.y) }
    let projection = ((point.x - start.x) * dx + (point.y - start.y) * dy) / squaredLength
    let t = min(1, max(0, projection))
    return hypot(point.x - (start.x + t * dx), point.y - (start.y + t * dy))
}

private func independentBounds(of spans: [BarryGoldmanSpan]) -> CanvasRect {
    guard let first = spans.first else {
        return CanvasRect(x: 0, y: 0, width: 0, height: 0)
    }
    var points = [first.start]
    let partitionCount = 2_048
    for span in spans {
        let sampled = (0...partitionCount).map { index in
            span.point(at: Double(index) / Double(partitionCount))
        }
        points.append(contentsOf: [sampled[0], sampled[partitionCount]])
        for coordinate in [\CanvasPoint.x, \CanvasPoint.y] {
            for index in 1..<partitionCount {
                let previous = sampled[index - 1][keyPath: coordinate]
                let current = sampled[index][keyPath: coordinate]
                let next = sampled[index + 1][keyPath: coordinate]
                let lower = Double(index - 1) / Double(partitionCount)
                let upper = Double(index + 1) / Double(partitionCount)
                if current <= previous, current <= next {
                    let parameter = refinedExtremum(
                        from: lower,
                        to: upper,
                        maximize: false,
                        value: { span.point(at: $0)[keyPath: coordinate] }
                    )
                    points.append(span.point(at: parameter))
                }
                if current >= previous, current >= next {
                    let parameter = refinedExtremum(
                        from: lower,
                        to: upper,
                        maximize: true,
                        value: { span.point(at: $0)[keyPath: coordinate] }
                    )
                    points.append(span.point(at: parameter))
                }
            }
        }
    }
    let minX = points.map(\.x).min()!
    let maxX = points.map(\.x).max()!
    let minY = points.map(\.y).min()!
    let maxY = points.map(\.y).max()!
    return CanvasRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}

private func refinedExtremum(
    from lowerBound: Double,
    to upperBound: Double,
    maximize: Bool,
    value: (Double) -> Double
) -> Double {
    var lower = lowerBound
    var upper = upperBound
    for _ in 0..<100 {
        let third = (upper - lower) / 3
        let first = lower + third
        let second = upper - third
        let firstValue = value(first)
        let secondValue = value(second)
        if (firstValue < secondValue) == maximize {
            lower = first
        } else {
            upper = second
        }
    }
    return (lower + upper) / 2
}

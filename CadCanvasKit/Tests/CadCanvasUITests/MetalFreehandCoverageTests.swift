import CoreGraphics
import CadCanvasCore
import Metal
import XCTest
@testable import CadCanvasUI

private final class CoverageLifetimeProbe {
    let value: Int

    init(value: Int) {
        self.value = value
    }
}

private final class WeakCoverageBox {
    weak var value: CoverageLifetimeProbe?

    init(_ value: CoverageLifetimeProbe) {
        self.value = value
    }
}

@MainActor
final class MetalFreehandCoverageTests: XCTestCase {
    func testWidthModesUploadExpectedPhysicalWidthsAtZoom() throws {
        let viewport = try CanvasViewport(
            zoom: 4,
            translation: .init(x: 0, y: 0),
            viewportSize: .init(width: 128, height: 128)
        )
        func uploadedWidth(_ widthMode: CanvasInkWidthMode) throws -> Float {
            let ink = CanvasPreparedInk(
                confirmedSamples: [
                    .init(point: .init(x: 20, y: 30), pressure: 0.3),
                    .init(point: .init(x: 60, y: 30), pressure: 0.3),
                ],
                pressureEnabled: true,
                widthMode: widthMode
            )
            let prepared = geometry(
                polyline: ink,
                style: .init(stroke: .black, lineWidth: 1)
            )
            let cache = try MetalFreehandCoverageCache(device: metalDevice())
            try cache.update(activeGeometry: prepared, viewport: viewport, displayScale: 2)
            let resource = try XCTUnwrap(cache.coverage(
                for: prepared,
                viewport: viewport,
                displayScale: 2
            ))
            return resource.segmentBuffer.contents()
                .bindMemory(to: MetalCoverageSegment.self, capacity: 1)
                .pointee.startWidth
        }

        XCTAssertEqual(try uploadedWidth(.canvasScaled), 8, accuracy: 0.000_001)
        XCTAssertEqual(try uploadedWidth(.screenConstant), 2, accuracy: 0.000_001)
    }

    func testMetalCoverageRefinesCurvesAtTwentyTimesZoom() throws {
        let ink = CanvasPreparedInk(
            confirmedSamples: [
                .init(point: .init(x: 0, y: 0), pressure: 0),
                .init(point: .init(x: 20, y: 15), pressure: 0.3),
                .init(point: .init(x: 40, y: -15), pressure: 1),
                .init(point: .init(x: 60, y: 0), pressure: 0.3),
            ],
            pressureEnabled: true,
            widthMode: .canvasScaled
        )
        let prepared = geometry(
            polyline: ink,
            style: .init(stroke: .black, lineWidth: 1)
        )
        let oneXViewport = try CanvasViewport(
            zoom: 1,
            translation: .init(x: 0, y: 0),
            viewportSize: .init(width: 128, height: 128)
        )
        let twentyXViewport = try CanvasViewport(
            zoom: 20,
            translation: .init(x: 0, y: 0),
            viewportSize: .init(width: 128, height: 128)
        )
        func resource(at viewport: CanvasViewport) throws -> MetalCoverageResource {
            let cache = try MetalFreehandCoverageCache(device: metalDevice())
            try cache.update(activeGeometry: prepared, viewport: viewport, displayScale: 2)
            return try XCTUnwrap(cache.coverage(
                for: prepared,
                viewport: viewport,
                displayScale: 2
            ))
        }

        let oneX = try resource(at: oneXViewport)
        let twentyX = try resource(at: twentyXViewport)
        let count = coverageSegmentCount(vertexCount: twentyX.prefixVertexCount)
        let segments = twentyX.segmentBuffer.contents().bindMemory(
            to: MetalCoverageSegment.self,
            capacity: count
        )
        let maximumWidth = (0..<count).reduce(Float.zero) { partial, index in
            max(partial, segments[index].startWidth, segments[index].endWidth)
        }

        XCTAssertGreaterThan(twentyX.prefixVertexCount, oneX.prefixVertexCount)
        XCTAssertEqual(maximumWidth, 70, accuracy: 0.000_001)
    }


    func testUploadedPressureTapersDoNotCollapseIntoEndpointBlobs() throws {
        let samples = [0.0, 1.0, 0.0].enumerated().map {
            CanvasInkSample(
                point: .init(x: 20 + Double($0.offset) * 2, y: 30),
                pressure: $0.element
            )
        }
        let ink = CanvasPreparedInk(
            confirmedSamples: samples,
            predictedSamples: [],
            pressureEnabled: true,
            isFinalized: true
        )
        let geometry = geometry(
            polyline: ink,
            style: .init(stroke: .black, lineWidth: 20)
        )
        let cache = try MetalFreehandCoverageCache(device: metalDevice())

        try cache.update(activeGeometry: geometry, viewport: viewport())
        let resource = try XCTUnwrap(cache.coverage(
            for: geometry,
            viewport: viewport(),
            displayScale: 1
        ))
        let segmentCount = coverageSegmentCount(vertexCount: resource.prefixVertexCount)
        let segments = resource.segmentBuffer.contents()
            .bindMemory(to: MetalCoverageSegment.self, capacity: segmentCount)

        for index in 0 ..< segmentCount {
            let segment = segments[index]
            let delta = segment.end - segment.start
            let length = sqrt(delta.x * delta.x + delta.y * delta.y)
            let radiusChange = abs(segment.endWidth - segment.startWidth) / 2
            XCTAssertLessThanOrEqual(
                radiusChange,
                length,
                "Segment \(index) collapses to a larger endpoint disk"
            )
        }
    }

    func testTaperedCoverageSegmentABIAndUploadedEndpointWidths() throws {
        XCTAssertEqual(MemoryLayout<MetalCoverageSegment>.size, 32)
        XCTAssertEqual(MemoryLayout<MetalCoverageSegment>.stride, 32)
        XCTAssertEqual(MemoryLayout<MetalCoverageSegment>.alignment, 8)

        let ink = CanvasPreparedInk(
            confirmedSamples: [
                .init(point: .init(x: 20, y: 30), pressure: 0),
                .init(point: .init(x: 60, y: 30), pressure: 1),
            ],
            predictedSamples: [],
            pressureEnabled: true,
            isFinalized: true
        )
        let geometry = geometry(
            polyline: ink,
            style: .init(stroke: .black, lineWidth: 20)
        )
        let cache = try MetalFreehandCoverageCache(device: metalDevice())

        try cache.update(activeGeometry: geometry, viewport: viewport())
        let resource = try XCTUnwrap(cache.coverage(
            for: geometry,
            viewport: viewport(),
            displayScale: 1
        ))
        let count = coverageSegmentCount(vertexCount: resource.prefixVertexCount)
        let segments = resource.segmentBuffer.contents()
            .bindMemory(to: MetalCoverageSegment.self, capacity: count)
        let first = segments[0]
        let last = segments[count - 1]

        XCTAssertEqual(first.start, SIMD2<Float>(20, 30))
        XCTAssertEqual(last.end, SIMD2<Float>(60, 30))
        XCTAssertEqual(first.startWidth, 4, accuracy: 0.000_001)
        XCTAssertEqual(last.endWidth, 35, accuracy: 0.000_001)
    }

    func testLowPressureOnePointStrokeUploadsOnePhysicalPixelWidths() throws {
        let ink = CanvasPreparedInk(
            confirmedSamples: [
                .init(point: .init(x: 40, y: 20), pressure: 0),
                .init(point: .init(x: 40, y: 80), pressure: 0),
            ],
            predictedSamples: [],
            pressureEnabled: true,
            isFinalized: true
        )
        let prepared = geometry(
            polyline: ink,
            style: .init(stroke: .black, lineWidth: 1)
        )
        let cache = try MetalFreehandCoverageCache(device: metalDevice())

        try cache.update(
            activeGeometry: prepared,
            viewport: viewport(),
            displayScale: 2
        )
        let resource = try XCTUnwrap(cache.coverage(
            for: prepared,
            viewport: viewport(),
            displayScale: 2
        ))
        let count = coverageSegmentCount(vertexCount: resource.prefixVertexCount)
        let segments = resource.segmentBuffer.contents().bindMemory(
            to: MetalCoverageSegment.self,
            capacity: count
        )

        for index in 0..<count {
            XCTAssertGreaterThanOrEqual(segments[index].startWidth, 1)
            XCTAssertGreaterThanOrEqual(segments[index].endWidth, 1)
        }
    }

    func testNominalAndFirmPressureUploadExpectedPhysicalWidths() throws {
        let ink = CanvasPreparedInk(
            confirmedSamples: [
                .init(point: .init(x: 40, y: 20), pressure: 0.3),
                .init(point: .init(x: 40, y: 80), pressure: 1),
            ],
            predictedSamples: [],
            pressureEnabled: true,
            isFinalized: true
        )
        let prepared = geometry(
            polyline: ink,
            style: .init(stroke: .black, lineWidth: 1)
        )
        let cache = try MetalFreehandCoverageCache(device: metalDevice())

        try cache.update(activeGeometry: prepared, viewport: viewport(), displayScale: 2)
        let resource = try XCTUnwrap(cache.coverage(
            for: prepared,
            viewport: viewport(),
            displayScale: 2
        ))
        let count = coverageSegmentCount(vertexCount: resource.prefixVertexCount)
        let segments = resource.segmentBuffer.contents().bindMemory(
            to: MetalCoverageSegment.self,
            capacity: count
        )

        XCTAssertEqual(segments[0].startWidth, 2, accuracy: 0.000_001)
        XCTAssertEqual(segments[count - 1].endWidth, 3.5, accuracy: 0.000_001)
    }

    func testIncrementalLowPressureTailUploadsOnePhysicalPixelWidths() throws {
        var samples = (0..<6).map {
            CanvasInkSample(
                point: .init(x: 40, y: Double(20 + $0 * 10)),
                pressure: 0
            )
        }
        let ink = CanvasPreparedInk(
            confirmedSamples: samples,
            predictedSamples: [],
            pressureEnabled: true,
            isFinalized: false
        )
        let cache = try MetalFreehandCoverageCache(device: metalDevice())
        var prepared = geometry(
            polyline: ink,
            style: .init(stroke: .black, lineWidth: 1)
        )
        try cache.update(
            activeGeometry: prepared,
            viewport: viewport(),
            displayScale: 2
        )

        samples.append(.init(point: .init(x: 40, y: 80), pressure: 0))
        XCTAssertTrue(ink.appendConfirmed(samples))
        prepared = geometry(
            polyline: ink,
            style: .init(stroke: .black, lineWidth: 1)
        )
        try cache.update(
            activeGeometry: prepared,
            viewport: viewport(),
            displayScale: 2
        )
        let resource = try XCTUnwrap(cache.coverage(
            for: prepared,
            viewport: viewport(),
            displayScale: 2
        ))
        let count = coverageSegmentCount(vertexCount: resource.prefixVertexCount)
        let segments = resource.segmentBuffer.contents().bindMemory(
            to: MetalCoverageSegment.self,
            capacity: count
        )

        XCTAssertEqual(cache.statistics.incrementalFlattenCount, 1)
        for index in 0..<count {
            XCTAssertGreaterThanOrEqual(segments[index].startWidth, 1)
            XCTAssertGreaterThanOrEqual(segments[index].endWidth, 1)
        }
    }

    func testFinalizedPrefixCutUsesSourceSpanMetadataAcrossRepeatedCoordinates() throws {
        let samples = [
            CanvasInkSample(point: .init(x: 20, y: 20), pressure: 0.2),
            CanvasInkSample(point: .init(x: 50, y: 18), pressure: 0.8),
            CanvasInkSample(point: .init(x: 32, y: 54), pressure: 0.4),
            CanvasInkSample(point: .init(x: 20, y: 20), pressure: 0.7),
            CanvasInkSample(point: .init(x: 72, y: 62), pressure: 0.3),
            CanvasInkSample(point: .init(x: 106, y: 24), pressure: 1),
        ]
        let ink = CanvasPreparedInk(
            confirmedSamples: samples,
            predictedSamples: [],
            pressureEnabled: true,
            isFinalized: false
        )
        let flattened = try CanvasInkCurve.flattenWithSpanEnds(
            stroke: .init(samples: samples, pressureEnabled: true),
            maximumError: 0.25,
            maximumWidthError: 0.5 / 6
        )
        let boundary = CanvasInkCurve.incrementalBoundary(
            confirmedPrefix: samples,
            appending: [],
            isFinalized: false
        )
        let finalizedBoundaryIndex = flattened.spanEndVertexIndices[
            boundary.finalizedSampleCount - 2
        ]
        XCTAssertEqual(
            flattened.vertices[finalizedBoundaryIndex].point,
            samples[boundary.finalizedSampleCount - 1].point
        )
        XCTAssertEqual(flattened.vertices.first?.point, samples[3].point)
        XCTAssertGreaterThan(finalizedBoundaryIndex, 0)
        let prepared = geometry(polyline: ink)
        let cache = try MetalFreehandCoverageCache(device: metalDevice())

        try cache.update(activeGeometry: prepared, viewport: viewport())
        let first = try XCTUnwrap(cache.coverage(
            for: prepared,
            viewport: viewport(),
            displayScale: 1
        ))
        let stablePrefix = Array(first.vertices.prefix(first.prefixVertexCount))
        XCTAssertEqual(first.prefixVertexCount, finalizedBoundaryIndex + 1)

        ink.appendConfirmed(samples + [
            .init(point: .init(x: 112, y: 76), pressure: 0.55),
        ])
        let grown = geometry(polyline: ink)
        try cache.update(activeGeometry: grown, viewport: viewport())
        let second = try XCTUnwrap(cache.coverage(
            for: grown,
            viewport: viewport(),
            displayScale: 1
        ))

        XCTAssertEqual(Array(second.vertices.prefix(stablePrefix.count)), stablePrefix)
        XCTAssertGreaterThan(second.prefixVertexCount, first.prefixVertexCount)
    }

    func testFramePlanIncrementallyFlattensOnlyLocalTailAndMatchesFullOracle() throws {
        let initialConfirmed = [
            CanvasInkSample(point: .init(x: 12, y: 18), pressure: 0.1),
            CanvasInkSample(point: .init(x: 34, y: 45), pressure: 0.9),
            CanvasInkSample(point: .init(x: 34, y: 45), pressure: 0.3),
            CanvasInkSample(point: .init(x: 8, y: 72), pressure: 0.7),
            CanvasInkSample(point: .init(x: 61, y: 22), pressure: 0.2),
            CanvasInkSample(point: .init(x: 12, y: 18), pressure: 1),
            CanvasInkSample(point: .init(x: 82, y: 66), pressure: 0.4),
            CanvasInkSample(point: .init(x: 94, y: 31), pressure: 0.8),
        ]
        let ink = CanvasPreparedInk(
            confirmedSamples: initialConfirmed,
            predictedSamples: [
                .init(point: .init(x: 108, y: 74), pressure: 0.6),
                .init(point: .init(x: 116, y: 40), pressure: 0.2),
            ],
            pressureEnabled: true,
            isFinalized: false
        )
        let id = UUID()
        let cache = try MetalFreehandCoverageCache(device: metalDevice())
        let initial = geometry(id: id, polyline: ink)
        try cache.update(activeGeometry: initial, viewport: viewport())
        XCTAssertEqual(cache.statistics.fullFlattenCount, 1)

        let confirmedSuffix = [
            CanvasInkSample(point: .init(x: 103, y: 83), pressure: 0.5),
            CanvasInkSample(point: .init(x: 74, y: 101), pressure: 0.75),
        ]
        let replacementPredictions = [
            CanvasInkSample(point: .init(x: 48, y: 88), pressure: 0.35),
            CanvasInkSample(point: .init(x: 22, y: 109), pressure: 0.95),
        ]
        XCTAssertTrue(ink.apply(
            confirmed: initialConfirmed + confirmedSuffix,
            predicted: replacementPredictions,
            isFinalized: false
        ))
        let grown = geometry(id: id, polyline: ink)
        XCTAssertNotEqual(initial.resourceIdentity, grown.resourceIdentity)
        let plan = try cache.makeFramePlan(
            geometries: [grown],
            viewport: viewport(),
            displayScale: 1
        )

        XCTAssertEqual(cache.statistics.fullFlattenCount, 1)
        XCTAssertEqual(cache.statistics.incrementalFlattenCount, 1)
        XCTAssertEqual(cache.statistics.incrementallyFlattenedSpanCount, 8)
        try cache.update(
            activeGeometry: grown,
            using: plan,
            viewport: viewport(),
            displayScale: 1
        )
        let resource = try XCTUnwrap(cache.coverage(
            for: grown,
            viewport: viewport(),
            displayScale: 1
        ))
        let allSamples = initialConfirmed + confirmedSuffix + replacementPredictions
        let oracle = try CanvasInkCurve.flattenWithSpanEnds(
            stroke: .init(samples: allSamples, pressureEnabled: true),
            maximumError: 0.25,
            maximumWidthError: 0.5 / 6
        )
        let visibleOracleVertices = try CanvasInkVisibilityPolicy.apply(
            to: oracle.vertices,
            lineWidth: grown.style.lineWidth / viewport().zoom,
            pixelsPerCanvasUnit: 1,
            pressureEnabled: true
        )
        let oracleVertices = CanvasInkTaperLimiter.limit(
            visibleOracleVertices,
            lineWidth: grown.style.lineWidth / viewport().zoom
        )
        XCTAssertEqual(resource.vertices, oracleVertices)
        XCTAssertEqual(resource.spanEndVertexIndices, oracle.spanEndVertexIndices)
        XCTAssertEqual(resource.preparedResourceIdentity, grown.resourceIdentity)
    }

    func testIncrementalFramePlanCopiesAndValidatesOnlyReplacementTail() throws {
        let initialConfirmed = points(0..<256).map {
            CanvasInkSample(point: $0, pressure: 0.5)
        }
        let ink = CanvasPreparedInk(
            confirmedSamples: initialConfirmed,
            predictedSamples: [
                .init(point: .init(x: 3_100, y: 44), pressure: 0.5),
                .init(point: .init(x: 3_112, y: 20), pressure: 0.5),
            ],
            pressureEnabled: false,
            isFinalized: false
        )
        let id = UUID()
        let cache = try MetalFreehandCoverageCache(device: metalDevice())
        try cache.update(
            activeGeometry: geometry(id: id, polyline: ink),
            viewport: viewport()
        )
        let before = cache.statistics
        let appended = [
            CanvasInkSample(point: .init(x: 3_124, y: 44), pressure: 0.5),
            CanvasInkSample(point: .init(x: 3_136, y: 20), pressure: 0.5),
        ]
        XCTAssertTrue(ink.apply(
            confirmed: initialConfirmed + appended,
            predicted: [
                .init(point: .init(x: 3_148, y: 44), pressure: 0.5),
                .init(point: .init(x: 3_160, y: 20), pressure: 0.5),
            ],
            isFinalized: false
        ))

        _ = try cache.makeFramePlan(
            geometries: [geometry(id: id, polyline: ink)],
            viewport: viewport(),
            displayScale: 1
        )

        let copiedVertices = cache.statistics.incrementallyCopiedVertexCount
            - before.incrementallyCopiedVertexCount
        let copiedSpanEnds = cache.statistics.incrementallyCopiedSpanEndCount
            - before.incrementallyCopiedSpanEndCount
        let copiedPoints = cache.statistics.incrementallyCopiedPointCount
            - before.incrementallyCopiedPointCount
        let validatedSamples = cache.statistics.incrementallyValidatedSampleCount
            - before.incrementallyValidatedSampleCount
        let flattenedSpans = cache.statistics.incrementallyFlattenedSpanCount
            - before.incrementallyFlattenedSpanCount
        XCTAssertLessThan(copiedVertices, 256)
        XCTAssertEqual(copiedSpanEnds, flattenedSpans)
        XCTAssertLessThanOrEqual(copiedPoints, 8)
        XCTAssertLessThanOrEqual(validatedSamples, 8)
    }

    func testPersistentCoverageSequenceTraversesFortyEightThousandGenerationsIteratively() {
        let generationCount = 48_000
        var sequence = MetalCoverageSequence([0])
        for value in 1..<generationCount {
            sequence = MetalCoverageSequence(
                reusing: sequence,
                retainedPrefixCount: sequence.count,
                replacementTail: [value]
            )
        }

        var visitedCount = 0
        var expectedValue = 0
        for slice in sequence.slices(in: 0..<sequence.count) {
            for value in slice {
                XCTAssertEqual(value, expectedValue)
                visitedCount += 1
                expectedValue += 1
            }
        }
        XCTAssertEqual(visitedCount, generationCount)
        XCTAssertEqual(sequence.element(at: generationCount - 1), generationCount - 1)
        XCTAssertTrue(sequence.elementsEqual(
            to: MetalCoverageSequence(Array(0..<generationCount))
        ))
    }

    func testCoverageSequenceReleasesEverySupersededPredictionTail() {
        var sequence = MetalCoverageSequence<CoverageLifetimeProbe>([])
        var weakTails: [WeakCoverageBox] = []

        for value in 0..<512 {
            let probe = CoverageLifetimeProbe(value: value)
            weakTails.append(WeakCoverageBox(probe))
            sequence = MetalCoverageSequence(
                reusing: sequence,
                retainedPrefixCount: 0,
                replacementTail: [probe]
            )
        }

        XCTAssertEqual(sequence.materialized().map(\.value), [511])
        XCTAssertEqual(weakTails.compactMap(\.value).count, 1)
    }

    func testIncrementalFlatteningColdFallsBackForChangedProvenance() throws {
        let id = UUID()
        let baseSamples = points(0..<8).map { CanvasInkSample(point: $0, pressure: 0.5) }

        func assertColdFallback(
            replacementInk: CanvasPreparedInk,
            replacementStyle: CanvasStyle = .init(stroke: .black, lineWidth: 6),
            replacementViewport: CanvasViewport? = nil
        ) throws {
            let cache = try MetalFreehandCoverageCache(device: metalDevice())
            let initialInk = CanvasPreparedInk(
                confirmedSamples: baseSamples,
                predictedSamples: [],
                pressureEnabled: false,
                isFinalized: false
            )
            try cache.update(
                activeGeometry: geometry(id: id, polyline: initialInk),
                viewport: viewport()
            )
            let replacement = geometry(
                id: id,
                polyline: replacementInk,
                style: replacementStyle
            )
            _ = try cache.makeFramePlan(
                geometries: [replacement],
                viewport: replacementViewport ?? viewport(),
                displayScale: 1
            )
            XCTAssertEqual(cache.statistics.fullFlattenCount, 2)
            XCTAssertEqual(cache.statistics.incrementalFlattenCount, 0)
        }

        let differentSource = CanvasPreparedInk(
            confirmedSamples: baseSamples + [
                .init(point: .init(x: 112, y: 84), pressure: 0.5),
            ],
            predictedSamples: [],
            pressureEnabled: false,
            isFinalized: false
        )
        try assertColdFallback(replacementInk: differentSource)

        let pressureChanged = CanvasPreparedInk(
            confirmedSamples: baseSamples,
            predictedSamples: [],
            pressureEnabled: true,
            isFinalized: false
        )
        try assertColdFallback(replacementInk: pressureChanged)

        let styleInk = CanvasPreparedInk(
            confirmedSamples: baseSamples,
            predictedSamples: [],
            pressureEnabled: false,
            isFinalized: false
        )
        let styleCache = try MetalFreehandCoverageCache(device: metalDevice())
        try styleCache.update(
            activeGeometry: geometry(id: id, polyline: styleInk),
            viewport: viewport()
        )
        styleInk.append([.init(x: 112, y: 84)])
        let changedStyle = geometry(
            id: id,
            polyline: styleInk,
            style: .init(stroke: .black, lineWidth: 9)
        )
        _ = try styleCache.makeFramePlan(
            geometries: [changedStyle],
            viewport: viewport(),
            displayScale: 1
        )
        XCTAssertEqual(styleCache.statistics.fullFlattenCount, 2)
        XCTAssertEqual(styleCache.statistics.incrementalFlattenCount, 0)

        let viewportInk = CanvasPreparedInk(
            confirmedSamples: baseSamples,
            predictedSamples: [],
            pressureEnabled: false,
            isFinalized: false
        )
        let viewportCache = try MetalFreehandCoverageCache(device: metalDevice())
        try viewportCache.update(
            activeGeometry: geometry(id: id, polyline: viewportInk),
            viewport: viewport()
        )
        viewportInk.append([.init(x: 112, y: 84)])
        let changedViewport = try! CanvasViewport(
            zoom: 1.25,
            translation: .init(x: 3, y: -2),
            viewportSize: .init(width: 128, height: 128)
        )
        _ = try viewportCache.makeFramePlan(
            geometries: [geometry(id: id, polyline: viewportInk)],
            viewport: changedViewport,
            displayScale: 1
        )
        XCTAssertEqual(viewportCache.statistics.fullFlattenCount, 2)
        XCTAssertEqual(viewportCache.statistics.incrementalFlattenCount, 0)
    }

    func testPredictedTailReplacementPreservesPrefixAndRemovesOldPixels() throws {
        let ink = CanvasPreparedInk(
            confirmedSamples: [
                .init(point: .init(x: 18, y: 24), pressure: 0.3),
                .init(point: .init(x: 44, y: 24), pressure: 0.8),
                .init(point: .init(x: 68, y: 40), pressure: 0.5),
                .init(point: .init(x: 82, y: 56), pressure: 0.7),
            ],
            predictedSamples: [
                .init(point: .init(x: 108, y: 104), pressure: 1),
            ],
            pressureEnabled: true,
            isFinalized: false
        )
        let engine = try MetalRenderEngine(device: metalDevice())
        let first = try render(
            [geometry(polyline: ink, style: .init(stroke: .black, lineWidth: 12))],
            engine: engine
        )
        let prefixBefore = pixel(first, x: 30, y: 24)
        XCTAssertLessThan(pixel(first, x: 108, y: 104)[0], 16)

        ink.replacePredicted([
            .init(point: .init(x: 108, y: 18), pressure: 0.2),
        ])
        let second = try render(
            [geometry(polyline: ink, style: .init(stroke: .black, lineWidth: 12))],
            engine: engine
        )

        XCTAssertEqual(pixel(second, x: 30, y: 24), prefixBefore)
        XCTAssertGreaterThan(pixel(second, x: 108, y: 104)[0], 247)
        XCTAssertLessThan(pixel(second, x: 108, y: 18)[0], 16)
        XCTAssertGreaterThan(engine.transientTailEncodeCount, 1)
        XCTAssertGreaterThan(engine.prefixToScratchCopyCount, 1)
    }

    func testFrameLocalCoveragePlanPreparesPreviewPredictionAndCommitOncePerSubmission() throws {
        let id = UUID()
        let ink = CanvasPreparedInk(
            confirmedSamples: [
                .init(point: .init(x: 18, y: 24), pressure: 0.3),
                .init(point: .init(x: 44, y: 24), pressure: 0.8),
                .init(point: .init(x: 68, y: 40), pressure: 0.5),
                .init(point: .init(x: 82, y: 56), pressure: 0.7),
            ],
            predictedSamples: [
                .init(point: .init(x: 108, y: 104), pressure: 1),
            ],
            pressureEnabled: true,
            isFinalized: false
        )
        let engine = try MetalRenderEngine(device: metalDevice())
        let style = CanvasStyle(stroke: .black, lineWidth: 12)

        let first = try render(
            [geometry(id: id, polyline: ink, style: style)],
            engine: engine
        )
        XCTAssertEqual(engine.lastPreparedFreehandInputCount, 1)
        XCTAssertLessThan(pixel(first, x: 108, y: 104)[0], 16)
        XCTAssertEqual(engine.derivedFreehandResourceCount, 1)
        XCTAssertEqual(engine.transientCoverageAllocationCount, 1)
        XCTAssertEqual(engine.transientTailEncodeCount, 1)
        XCTAssertEqual(engine.prefixToScratchCopyCount, 1)

        ink.replacePredicted([
            .init(point: .init(x: 108, y: 18), pressure: 0.2),
        ])
        let replacement = try render(
            [geometry(id: id, polyline: ink, style: style)],
            engine: engine
        )
        XCTAssertEqual(engine.lastPreparedFreehandInputCount, 1)
        XCTAssertGreaterThan(pixel(replacement, x: 108, y: 104)[0], 247)
        XCTAssertLessThan(pixel(replacement, x: 108, y: 18)[0], 16)
        XCTAssertEqual(engine.derivedFreehandResourceCount, 1)
        XCTAssertEqual(engine.transientCoverageAllocationCount, 2)
        XCTAssertEqual(engine.transientTailEncodeCount, 2)
        XCTAssertEqual(engine.prefixToScratchCopyCount, 2)

        let committedInk = CanvasPreparedInk(
            confirmedSamples: ink.confirmedSamples,
            pressureEnabled: true
        )
        let committed = geometry(
            id: id,
            renderKey: .committed(id: id, contentRevision: 1),
            polyline: committedInk,
            style: style
        )
        let final = try render([committed], engine: engine)
        XCTAssertEqual(engine.lastPreparedFreehandInputCount, 1)
        XCTAssertLessThan(pixel(final, x: 82, y: 56)[0], 16)
        XCTAssertGreaterThan(pixel(final, x: 108, y: 18)[0], 247)
        XCTAssertEqual(engine.derivedFreehandResourceCount, 1)
        XCTAssertEqual(engine.transientCoverageAllocationCount, 2)
        XCTAssertEqual(engine.transientTailEncodeCount, 2)
        XCTAssertEqual(engine.prefixToScratchCopyCount, 2)
        XCTAssertEqual(engine.freehandCommitReuseCount, 1)
    }

    func testWarmPresentedFrameDoesNotRerasterizeCommittedInkAsHistoryGrows() throws {
        let device = try metalDevice()
        for committedCount in [1, 10, 100] {
            let engine = try MetalRenderEngine(device: device)
            let committed = (0 ..< committedCount).map { index in
                let id = UUID()
                let y = Double(index + 8)
                return geometry(
                    id: id,
                    renderKey: .committed(id: id, contentRevision: 1),
                    polyline: CanvasPreparedInk(
                        confirmedSamples: [
                            .init(point: .init(x: 8, y: y), pressure: 1),
                            .init(point: .init(x: 112, y: y), pressure: 1),
                        ],
                        predictedSamples: [],
                        pressureEnabled: true,
                        isFinalized: true
                    ),
                    style: .init(stroke: .black, lineWidth: 1)
                )
            }
            let activeID = UUID()
            let active = geometry(
                id: activeID,
                polyline: CanvasPreparedInk(
                    confirmedSamples: [
                        .init(point: .init(x: 8, y: 120), pressure: 1),
                        .init(point: .init(x: 112, y: 120), pressure: 1),
                    ],
                    predictedSamples: [],
                    pressureEnabled: true,
                    isFinalized: false
                ),
                style: .init(stroke: .black, lineWidth: 2)
            )
            let compiler = MetalSceneCompiler()
            let output = try outputTexture(device: device)

            try renderPresented(
                try compiler.compile(presentation(committed: committed)),
                into: output,
                using: engine
            )
            try renderPresented(
                try compiler.compile(presentation(
                    committed: committed,
                    live: [active]
                )),
                into: output,
                using: engine
            )

            XCTAssertEqual(engine.lastCommittedTileReplayCount, 0)
            XCTAssertEqual(engine.lastCommittedCoverageEncodeCount, 0)
            XCTAssertEqual(engine.lastLiveCoverageEncodeCount, 1)
            XCTAssertLessThan(pixel(output, x: 64, y: 8)[0], 200)
            XCTAssertLessThan(pixel(output, x: 64, y: committedCount + 7)[0], 200)
            XCTAssertLessThan(pixel(output, x: 64, y: 120)[0], 16)
        }
    }

    func testPublishingCommittedTileReleasesTemporaryStrokeCoverage() throws {
        let device = try metalDevice()
        let committed = (0 ..< 3).map { index in
            let id = UUID()
            let y = Double(index * 12 + 20)
            return geometry(
                id: id,
                renderKey: .committed(id: id, contentRevision: 1),
                polyline: CanvasPreparedInk(
                    confirmedSamples: [
                        .init(point: .init(x: 8, y: y), pressure: 1),
                        .init(point: .init(x: 112, y: y), pressure: 1),
                    ],
                    predictedSamples: [],
                    pressureEnabled: true,
                    isFinalized: true
                ),
                style: .init(stroke: .black, lineWidth: 2)
            )
        }
        let engine = try MetalRenderEngine(device: device)
        let output = try outputTexture(device: device)

        try renderPresented(
            try MetalSceneCompiler().compile(presentation(committed: committed)),
            into: output,
            using: engine
        )

        XCTAssertEqual(engine.lastCommittedTileReplayCount, 1)
        XCTAssertEqual(engine.derivedFreehandResourceCount, 1)
    }

    func testFreehandCommitDoesNotReplayTilesOrWaitBeforeNextStroke() throws {
        let device = try metalDevice()
        let engine = try MetalRenderEngine(device: device)
        let compiler = MetalSceneCompiler()
        let output = try outputTexture(device: device)
        let baseID = UUID()
        let base = geometry(
            id: baseID,
            renderKey: .committed(id: baseID, contentRevision: 1),
            polyline: CanvasPreparedInk(points: [
                .init(x: 12, y: 24),
                .init(x: 116, y: 24),
            ])
        )

        try renderPresented(
            try compiler.compile(presentation(committed: [base], revision: 1)),
            into: output,
            using: engine
        )

        let firstID = UUID()
        let firstSamples = [
            CanvasInkSample(point: .init(x: 12, y: 54), pressure: 0.3),
            CanvasInkSample(point: .init(x: 42, y: 76), pressure: 0.7),
            CanvasInkSample(point: .init(x: 76, y: 48), pressure: 1),
            CanvasInkSample(point: .init(x: 116, y: 70), pressure: 0.5),
        ]
        let liveFirst = geometry(
            id: firstID,
            polyline: CanvasPreparedInk(
                confirmedSamples: firstSamples,
                predictedSamples: [],
                pressureEnabled: true,
                isFinalized: false
            )
        )
        try renderPresented(
            try compiler.compile(presentation(
                committed: [base],
                live: [liveFirst],
                revision: 1
            )),
            into: output,
            using: engine
        )
        let waitsBeforeCommit = engine.synchronousOutputWaitCount
        let committedFirst = geometry(
            id: firstID,
            renderKey: .committed(id: firstID, contentRevision: 1),
            polyline: CanvasPreparedInk(
                confirmedSamples: firstSamples,
                pressureEnabled: true
            )
        )

        try renderPresented(
            try compiler.compile(presentation(
                committed: [base, committedFirst],
                revision: 2
            )),
            into: output,
            using: engine
        )

        XCTAssertEqual(engine.lastCommittedTileReplayCount, 0)
        XCTAssertEqual(engine.synchronousOutputWaitCount, waitsBeforeCommit)
        XCTAssertLessThan(pixel(output, x: 76, y: 48)[0], 32)

        let secondID = UUID()
        let liveSecond = geometry(
            id: secondID,
            polyline: CanvasPreparedInk(
                confirmedSamples: [
                    .init(point: .init(x: 12, y: 102), pressure: 0.5),
                    .init(point: .init(x: 116, y: 102), pressure: 0.8),
                ],
                predictedSamples: [],
                pressureEnabled: true,
                isFinalized: false
            )
        )
        try renderPresented(
            try compiler.compile(presentation(
                committed: [base, committedFirst],
                live: [liveSecond],
                revision: 2
            )),
            into: output,
            using: engine
        )

        XCTAssertEqual(engine.lastCommittedTileReplayCount, 0)
        XCTAssertEqual(engine.lastCommittedCoverageEncodeCount, 0)
        XCTAssertLessThan(pixel(output, x: 64, y: 102)[0], 32)
    }

    func testFirstFreehandCommitPatchesTransparentTilesWithoutReplay() throws {
        let device = try metalDevice()
        let engine = try MetalRenderEngine(device: device)
        let compiler = MetalSceneCompiler()
        let output = try outputTexture(device: device)
        let strokeID = UUID()
        let samples = [
            CanvasInkSample(point: .init(x: 12, y: 64), pressure: 0.4),
            CanvasInkSample(point: .init(x: 64, y: 40), pressure: 0.8),
            CanvasInkSample(point: .init(x: 116, y: 64), pressure: 0.6),
        ]
        let live = geometry(
            id: strokeID,
            polyline: CanvasPreparedInk(
                confirmedSamples: samples,
                predictedSamples: [],
                pressureEnabled: true,
                isFinalized: false
            )
        )
        try renderPresented(
            try compiler.compile(presentation(committed: [], live: [live], revision: 1)),
            into: output,
            using: engine
        )
        let waitsBeforeCommit = engine.synchronousOutputWaitCount
        let committed = geometry(
            id: strokeID,
            renderKey: .committed(id: strokeID, contentRevision: 1),
            polyline: CanvasPreparedInk(
                confirmedSamples: samples,
                pressureEnabled: true
            )
        )

        try renderPresented(
            try compiler.compile(presentation(committed: [committed], revision: 2)),
            into: output,
            using: engine
        )

        XCTAssertEqual(engine.lastCommittedTileReplayCount, 0)
        XCTAssertEqual(engine.synchronousOutputWaitCount, waitsBeforeCommit)
        XCTAssertLessThan(pixel(output, x: 64, y: 40)[0], 32)
        XCTAssertGreaterThan(pixel(output, x: 64, y: 96)[0], 224)
    }

    func testLongFreehandCommitPatchesMultipleTilesWithoutReplay() throws {
        let device = try metalDevice()
        let engine = try MetalRenderEngine(device: device)
        let compiler = MetalSceneCompiler()
        let size = CGSize(width: 512, height: 512)
        let viewport = try CanvasViewport.identity(size: .init(width: 512, height: 512))
        let output = try outputTexture(device: device, size: 512)
        let baseID = UUID()
        let base = geometry(
            id: baseID,
            renderKey: .committed(id: baseID, contentRevision: 1),
            polyline: CanvasPreparedInk(points: [
                .init(x: 24, y: 64),
                .init(x: 488, y: 64),
            ])
        )
        try renderPresented(
            try compiler.compile(presentation(
                committed: [base],
                viewport: viewport,
                revision: 1
            )),
            into: output,
            size: size,
            using: engine
        )

        let strokeID = UUID()
        let samples = stride(from: 16, through: 496, by: 8).map {
            CanvasInkSample(point: .init(x: Double($0), y: 220), pressure: 0.7)
        }
        let live = geometry(
            id: strokeID,
            polyline: CanvasPreparedInk(
                confirmedSamples: samples,
                predictedSamples: [],
                pressureEnabled: true,
                isFinalized: false
            )
        )
        try renderPresented(
            try compiler.compile(presentation(
                committed: [base],
                live: [live],
                viewport: viewport,
                revision: 1
            )),
            into: output,
            size: size,
            using: engine
        )
        let waitsBeforeCommit = engine.synchronousOutputWaitCount
        let committed = geometry(
            id: strokeID,
            renderKey: .committed(id: strokeID, contentRevision: 1),
            polyline: CanvasPreparedInk(
                confirmedSamples: samples,
                pressureEnabled: true
            )
        )

        try renderPresented(
            try compiler.compile(presentation(
                committed: [base, committed],
                viewport: viewport,
                revision: 2
            )),
            into: output,
            size: size,
            using: engine
        )

        XCTAssertEqual(engine.lastCommittedTileReplayCount, 0)
        XCTAssertEqual(engine.synchronousOutputWaitCount, waitsBeforeCommit)
        for x in [24, 128, 255, 256, 384, 488] {
            XCTAssertLessThan(pixel(output, x: x, y: 220)[0], 32)
        }
    }

    func testPreparedFreehandInputCountResetsForFailedAndEmptySubmissions() throws {
        let device = try metalDevice()
        let engine = try MetalRenderEngine(device: device)
        let geometry = geometry(
            polyline: CanvasPreparedInk(points: points(0..<3))
        )
        let compiled = try MetalSceneCompiler().compile(scene([geometry]))

        _ = try engine.renderOffscreen(
            compiled,
            size: .init(width: 128, height: 128),
            displayScale: 1
        )
        XCTAssertEqual(engine.lastPreparedFreehandInputCount, 1)

        let wrongSizedOutput = try outputTexture(device: device, size: 64)
        XCTAssertThrowsError(try engine.render(
            compiled,
            into: wrongSizedOutput,
            size: .init(width: 128, height: 128),
            displayScale: 1
        )) {
            XCTAssertEqual($0 as? MetalCanvasError, .invalidResourceSize)
        }
        XCTAssertEqual(engine.lastPreparedFreehandInputCount, 0)

        let empty = try MetalSceneCompiler().compile(scene([]))
        _ = try engine.renderOffscreen(
            empty,
            size: .init(width: 128, height: 128),
            displayScale: 1
        )
        XCTAssertEqual(engine.lastPreparedFreehandInputCount, 0)
    }

    func testAppendOnlyUpdateEncodesOnlyNewSegmentSuffix() throws {
        let device = try metalDevice()
        let polyline = CanvasPreparedInk(points: points(0..<3))
        let cache = try MetalFreehandCoverageCache(device: device)
        let compiler = MetalSceneCompiler()
        let initialGeometry = geometry(polyline: polyline)

        _ = try compiler.compile(scene([initialGeometry]))
        XCTAssertEqual(compiler.statistics.validatedFreehandPointCount, 3)
        _ = try compiler.compile(scene([initialGeometry]))
        XCTAssertEqual(compiler.statistics.validatedFreehandPointCount, 3)

        try cache.update(
            activeGeometry: initialGeometry,
            viewport: viewport()
        )
        let initialResource = try XCTUnwrap(cache.coverage(
            for: initialGeometry,
            viewport: viewport(),
            displayScale: 1
        ))
        let initialSegmentCount = coverageSegmentCount(
            vertexCount: initialResource.prefixVertexCount
        )
        XCTAssertEqual(cache.statistics.encodedSegmentCount, initialSegmentCount)
        XCTAssertEqual(cache.statistics.validatedPointCount, 3)
        XCTAssertEqual(cache.statistics.coverageCommandBufferCount, 1)
        XCTAssertEqual(try cache.additionalCoverageByteCount(
            geometry: initialGeometry,
            viewport: viewport(),
            displayScale: 1
        ), 0)

        try cache.update(
            activeGeometry: geometry(polyline: polyline),
            viewport: viewport()
        )
        XCTAssertEqual(cache.statistics.encodedSegmentCount, initialSegmentCount)
        XCTAssertEqual(cache.statistics.validatedPointCount, 3)
        XCTAssertEqual(cache.statistics.coverageCommandBufferCount, 1)

        polyline.append(points(3..<7))
        let grownGeometry = geometry(polyline: polyline)
        let grownPrefixVertexCount = try persistentVertexCount(polyline)
        let grownSegmentCount = coverageSegmentCount(vertexCount: grownPrefixVertexCount)
        let grownSegmentCapacity = segmentCapacity(required: grownSegmentCount)
        let grownSegmentPayloadBytes = grownSegmentCapacity
            * MemoryLayout<MetalCoverageSegment>.stride
        let expectedGrowthBytes = try MetalCachedResource.conservativeAllocationByteCount(
            payloadByteCount: grownSegmentPayloadBytes,
            reportedByteCount: device.heapBufferSizeAndAlign(
                length: grownSegmentPayloadBytes,
                options: .storageModeShared
            ).size
        )
        XCTAssertEqual(try cache.additionalCoverageByteCount(
            geometry: grownGeometry,
            viewport: viewport(),
            displayScale: 1
        ), expectedGrowthBytes)
        _ = try compiler.compile(scene([geometry(polyline: polyline)]))
        XCTAssertEqual(compiler.statistics.validatedFreehandPointCount, 7)
        let drawsBeforeAppend = cache.statistics.coverageDrawCallCount
        try cache.update(
            activeGeometry: geometry(polyline: polyline),
            viewport: viewport()
        )
        XCTAssertEqual(
            cache.statistics.coverageDrawCallCount - drawsBeforeAppend,
            1
        )

        let appendedSegmentCount = grownSegmentCount
            - max(0, initialResource.prefixVertexCount - 1)
        XCTAssertEqual(
            cache.statistics.encodedSegmentCount,
            initialSegmentCount + appendedSegmentCount
        )
        XCTAssertEqual(cache.statistics.validatedPointCount, 7)
        XCTAssertEqual(cache.statistics.coverageCommandBufferCount, 2)
        XCTAssertEqual(cache.statistics.fullBuildCount, 1)
        XCTAssertEqual(cache.activePointCount, 7)
        let incrementalResource = try XCTUnwrap(cache.coverage(
            for: grownGeometry,
            viewport: viewport(),
            displayScale: 1
        ))
        let fullCache = try MetalFreehandCoverageCache(device: device)
        try fullCache.update(activeGeometry: grownGeometry, viewport: viewport())
        let fullResource = try XCTUnwrap(fullCache.coverage(
            for: grownGeometry,
            viewport: viewport(),
            displayScale: 1
        ))
        XCTAssertEqual(
            coverageBytes(incrementalResource.texture),
            coverageBytes(fullResource.texture)
        )

        polyline.append(points(7..<8))
        cache.injectFailureOnce(.completion)
        XCTAssertThrowsError(try cache.update(
            activeGeometry: geometry(polyline: polyline),
            viewport: viewport()
        )) {
            XCTAssertEqual($0 as? MetalCanvasError, .commandBufferFailed)
        }
        XCTAssertFalse(cache.hasActiveCoverage)
        XCTAssertEqual(cache.residentByteCount, 0)

        try cache.update(
            activeGeometry: geometry(polyline: polyline),
            viewport: viewport()
        )
        XCTAssertTrue(cache.hasActiveCoverage)
        XCTAssertEqual(cache.activePointCount, 8)
        XCTAssertEqual(cache.statistics.fullBuildCount, 2)
    }

    func testTransientTailUsesValidatedFramePlanWithoutRevalidatingRetainedSamples() throws {
        let device = try metalDevice()
        let ink = CanvasPreparedInk(
            confirmedSamples: points(0..<8).map {
                CanvasInkSample(point: $0, pressure: 1)
            },
            predictedSamples: [
                CanvasInkSample(point: .init(x: 90, y: 42), pressure: 1),
                CanvasInkSample(point: .init(x: 104, y: 64), pressure: 1),
            ],
            pressureEnabled: false,
            isFinalized: false
        )
        let prepared = geometry(polyline: ink)
        let cache = try MetalFreehandCoverageCache(device: device)
        let plan = try cache.makeFramePlan(
            geometries: [prepared],
            viewport: viewport(),
            displayScale: 1
        )
        try cache.update(
            activeGeometry: prepared,
            using: plan,
            viewport: viewport(),
            displayScale: 1
        )
        let validatedBeforeTransient = cache.statistics.validatedPointCount
        let maximumPointCount = try cache.maximumPointCount(
            in: [prepared],
            using: plan
        )
        let scratch = try cache.makeTransientCoverage(
            maximumPointCount: maximumPointCount,
            viewport: viewport(),
            displayScale: 1
        )
        let commandQueue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(commandQueue.makeCommandBuffer())

        _ = try cache.encodeTransientCoverage(
            geometry: prepared,
            using: scratch,
            framePlan: plan,
            commandBuffer: commandBuffer
        )

        XCTAssertEqual(cache.statistics.validatedPointCount, validatedBeforeTransient)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed)
    }

    func testEqualLengthPredictedReplacementKeepsPersistentPrefixWithoutRebuildAdmission() throws {
        let device = try metalDevice()
        let ink = CanvasPreparedInk(
            confirmedSamples: points(0..<3).map {
                CanvasInkSample(point: $0, pressure: 1)
            },
            predictedSamples: [
                CanvasInkSample(point: .init(x: 30, y: 30), pressure: 1),
                CanvasInkSample(point: .init(x: 40, y: 40), pressure: 1),
            ],
            pressureEnabled: false,
            isFinalized: false
        )
        let initialGeometry = geometry(polyline: ink)
        let resources = MetalResourceCache(device: device)
        let cache = try MetalFreehandCoverageCache(
            device: device,
            coveragePipeline: MetalPipelineLibrary(device: device).coverageSegment,
            resourceCache: resources
        )
        try cache.update(activeGeometry: initialGeometry, viewport: viewport())
        let retained = try XCTUnwrap(cache.coverage(
            for: initialGeometry,
            viewport: viewport(),
            displayScale: 1
        ))
        let retainedPoints = retained.points
        let retainedPrefix = Array(retained.vertices.prefix(retained.prefixVertexCount))
        let residentBeforeReplacement = cache.residentByteCount

        ink.replacePredicted([
            CanvasInkSample(point: .init(x: 31, y: 12), pressure: 1),
            CanvasInkSample(point: .init(x: 42, y: 18), pressure: 1),
        ])
        let replacementGeometry = geometry(polyline: ink)
        let additionalBytes = try cache.additionalCoverageByteCount(
            geometry: replacementGeometry,
            viewport: viewport(),
            displayScale: 1
        )

        XCTAssertEqual(additionalBytes, 0)
        try cache.update(activeGeometry: replacementGeometry, viewport: viewport())
        let replacement = try XCTUnwrap(cache.coverage(
            for: replacementGeometry,
            viewport: viewport(),
            displayScale: 1
        ))
        XCTAssertEqual(cache.residentByteCount, residentBeforeReplacement)
        XCTAssertTrue(cache.hasActiveCoverage)
        XCTAssertEqual(retained.points, retainedPoints)
        XCTAssertEqual(
            Array(replacement.vertices.prefix(replacement.prefixVertexCount)),
            retainedPrefix
        )
        XCTAssertTrue((replacement.texture as AnyObject) === (retained.texture as AnyObject))
    }

    func testMaximumCoverageUnionDoesNotDarkenSelfIntersections() throws {
        let style = CanvasStyle(
            stroke: .init(red: 0, green: 0, blue: 0, alpha: 0.5),
            lineWidth: 12
        )
        let crossing = CanvasPreparedInk(points: [
            .init(x: 24, y: 24), .init(x: 104, y: 104),
            .init(x: 24, y: 104), .init(x: 104, y: 24),
        ])
        let image = try render(geometry(polyline: crossing, style: style))

        XCTAssertEqual(pixel(image, x: 64, y: 64), pixel(image, x: 42, y: 42))

        let zoomedViewport = try! CanvasViewport(
            zoom: 2,
            translation: .init(x: 0, y: 0),
            viewportSize: .init(width: 128, height: 128)
        )
        let zoomedStroke = geometry(
            polyline: CanvasPreparedInk(
                confirmedSamples: [
                    .init(point: .init(x: 12, y: 32), pressure: 1),
                    .init(point: .init(x: 52, y: 32), pressure: 1),
                ],
                predictedSamples: [],
                pressureEnabled: false,
                widthMode: .screenConstant,
                isFinalized: false
            ),
            style: .init(stroke: .black, lineWidth: 6)
        )
        let zoomedImage = try render(zoomedStroke, viewport: zoomedViewport)
        XCTAssertLessThan(pixel(zoomedImage, x: 64, y: 66)[0], 8)
        XCTAssertGreaterThan(pixel(zoomedImage, x: 64, y: 69)[0], 247)
    }

    func testTranslucentStrokeMatchesSingleSourceOverComposite() throws {
        let alpha = 0.35
        let style = CanvasStyle(
            stroke: .init(red: 0.2, green: 0.4, blue: 0.8, alpha: alpha),
            lineWidth: 14
        )
        let crossing = CanvasPreparedInk(points: [
            .init(x: 20, y: 20), .init(x: 108, y: 108),
            .init(x: 20, y: 108), .init(x: 108, y: 20),
        ])
        let actual = pixel(try render(geometry(polyline: crossing, style: style)), x: 64, y: 64)
        let expected = [
            UInt8(((0.2 * alpha + (1 - alpha)) * 255).rounded()),
            UInt8(((0.4 * alpha + (1 - alpha)) * 255).rounded()),
            UInt8(((0.8 * alpha + (1 - alpha)) * 255).rounded()),
            255,
        ]

        for channel in 0..<4 {
            XCTAssertEqual(actual[channel], expected[channel], accuracy: 1)
        }
    }

    func testExactCommitRekeysCoverageWithoutReencoding() throws {
        let device = try metalDevice()
        let id = UUID()
        let previewPolyline = CanvasPreparedInk(points: points(0..<4))
        previewPolyline.finalizeConfirmed()
        let cache = try MetalFreehandCoverageCache(device: device)
        try cache.update(
            activeGeometry: geometry(id: id, polyline: previewPolyline),
            viewport: viewport()
        )
        let activeTexture = try XCTUnwrap(cache.activeTexture)
        let encodedBeforeCommit = cache.statistics.encodedSegmentCount
        let validatedBeforeCommit = cache.statistics.validatedPointCount
        let committedPolyline = CanvasPreparedInk(points: previewPolyline.points)
        committedPolyline.finalizeConfirmed()
        let committed = geometry(
            id: id,
            renderKey: .committed(id: id, contentRevision: 1),
            polyline: committedPolyline
        )

        try cache.commit(geometry: committed)

        XCTAssertEqual(cache.statistics.encodedSegmentCount, encodedBeforeCommit)
        XCTAssertEqual(cache.statistics.validatedPointCount, validatedBeforeCommit)
        XCTAssertEqual(cache.statistics.commitReuseCount, 1)
        XCTAssertFalse(cache.hasActiveCoverage)
        XCTAssertNil(cache.activeElementID)
        XCTAssertEqual(cache.activePointCount, 0)
        XCTAssertTrue(cache.hasCoverage(for: committed, viewport: viewport()))
        let committedTexture = try XCTUnwrap(cache.coverage(
            for: committed,
            viewport: viewport(),
            displayScale: 1
        )?.texture)
        XCTAssertTrue((activeTexture as AnyObject) === (committedTexture as AnyObject))

        let statisticsBeforeCacheHit = cache.statistics
        try cache.commit(geometry: committed)
        XCTAssertEqual(cache.statistics, statisticsBeforeCacheHit)
    }

    func testFinalizingSameInkIncrementallyFlattensTailAndRekeysResourceIdentity() throws {
        let id = UUID()
        let samples = points(0..<7).map { CanvasInkSample(point: $0, pressure: 1) }
        let ink = CanvasPreparedInk(
            confirmedSamples: samples,
            predictedSamples: [],
            pressureEnabled: false,
            isFinalized: false
        )
        let cache = try MetalFreehandCoverageCache(device: metalDevice())
        let preview = geometry(id: id, polyline: ink)
        try cache.update(activeGeometry: preview, viewport: viewport())
        let previewResource = try XCTUnwrap(cache.coverage(
            for: preview,
            viewport: viewport(),
            displayScale: 1
        ))
        let previewTexture = previewResource.texture
        let fullFlattensBeforeCommit = cache.statistics.fullFlattenCount

        ink.finalizeConfirmed()
        let committed = geometry(
            id: id,
            renderKey: .committed(id: id, contentRevision: 1),
            polyline: ink
        )
        XCTAssertNotEqual(preview.resourceIdentity, committed.resourceIdentity)
        let plan = try cache.makeFramePlan(
            geometries: [committed],
            viewport: viewport(),
            displayScale: 1
        )
        XCTAssertEqual(cache.statistics.fullFlattenCount, fullFlattensBeforeCommit)
        XCTAssertEqual(cache.statistics.incrementalFlattenCount, 1)

        try cache.commit(
            geometry: committed,
            using: plan,
            viewport: viewport(),
            displayScale: 1
        )
        let committedResource = try XCTUnwrap(cache.coverage(
            for: committed,
            viewport: viewport(),
            displayScale: 1
        ))
        let oracle = try CanvasInkCurve.flattenWithSpanEnds(
            stroke: .init(samples: samples, pressureEnabled: false),
            maximumError: 0.25
        )
        XCTAssertTrue(
            (previewTexture as AnyObject) === (committedResource.texture as AnyObject)
        )
        XCTAssertTrue(committedResource.sourceInk === ink)
        XCTAssertEqual(committedResource.sourceGeneration, ink.generation)
        XCTAssertEqual(committedResource.preparedResourceIdentity, committed.resourceIdentity)
        XCTAssertEqual(committedResource.points, samples.map(\.point))
        XCTAssertEqual(committedResource.vertices, oracle.vertices)
        XCTAssertEqual(committedResource.spanEndVertexIndices, oracle.spanEndVertexIndices)
        XCTAssertEqual(cache.statistics.commitReuseCount, 1)
    }

    func testIncrementalAllocationFailureLeavesCachedCoverageMetadataUnchanged() throws {
        let ink = CanvasPreparedInk(points: points(0..<3))
        let id = UUID()
        let cache = try MetalFreehandCoverageCache(device: metalDevice())
        let initial = geometry(id: id, polyline: ink)
        try cache.update(activeGeometry: initial, viewport: viewport())
        let retained = try XCTUnwrap(cache.coverage(
            for: initial,
            viewport: viewport(),
            displayScale: 1
        ))
        let retainedPoints = retained.points
        let retainedVertices = retained.vertices
        let retainedSpanEnds = retained.spanEndVertexIndices
        let retainedPrefixVertexCount = retained.prefixVertexCount
        let retainedConfirmedCount = retained.confirmedSampleCount
        let retainedFinalizedCount = retained.finalizedConfirmedSampleCount
        let retainedGeneration = retained.sourceGeneration
        let retainedPreparedIdentity = retained.preparedResourceIdentity

        ink.append(points(3..<80))
        let grown = geometry(id: id, polyline: ink)
        let plan = try cache.makeFramePlan(
            geometries: [grown],
            viewport: viewport(),
            displayScale: 1
        )
        cache.injectFailureOnce(.allocation)
        XCTAssertThrowsError(try cache.update(
            activeGeometry: grown,
            using: plan,
            viewport: viewport(),
            displayScale: 1
        )) {
            XCTAssertEqual($0 as? MetalCanvasError, .invalidResourceSize)
        }

        let afterFailure = try XCTUnwrap(cache.coverage(
            for: grown,
            viewport: viewport(),
            displayScale: 1
        ))
        XCTAssertTrue(afterFailure === retained)
        XCTAssertEqual(afterFailure.points, retainedPoints)
        XCTAssertEqual(afterFailure.vertices, retainedVertices)
        XCTAssertEqual(afterFailure.spanEndVertexIndices, retainedSpanEnds)
        XCTAssertEqual(afterFailure.prefixVertexCount, retainedPrefixVertexCount)
        XCTAssertEqual(afterFailure.confirmedSampleCount, retainedConfirmedCount)
        XCTAssertEqual(afterFailure.finalizedConfirmedSampleCount, retainedFinalizedCount)
        XCTAssertEqual(afterFailure.sourceGeneration, retainedGeneration)
        XCTAssertEqual(afterFailure.preparedResourceIdentity, retainedPreparedIdentity)
    }

    func testDirectUnfinalizedPreviewCommitAppendsSuffixAndRekeysSameResource() throws {
        let device = try metalDevice()
        let id = UUID()
        let samples = points(0..<5).map { CanvasInkSample(point: $0, pressure: 1) }
        let previewInk = CanvasPreparedInk(
            confirmedSamples: samples,
            predictedSamples: [],
            pressureEnabled: false,
            isFinalized: false
        )
        let preview = geometry(id: id, polyline: previewInk)
        let cache = try MetalFreehandCoverageCache(device: device)
        try cache.update(activeGeometry: preview, viewport: viewport())
        let previewResource = try XCTUnwrap(cache.coverage(
            for: preview,
            viewport: viewport(),
            displayScale: 1
        ))
        XCTAssertLessThan(previewResource.prefixVertexCount, previewResource.vertices.count)
        let encodedBeforeCommit = cache.statistics.encodedSegmentCount
        let fullBuildsBeforeCommit = cache.statistics.fullBuildCount

        let committedInk = CanvasPreparedInk(
            confirmedSamples: samples,
            pressureEnabled: false
        )
        let committed = geometry(
            id: id,
            renderKey: .committed(id: id, contentRevision: 1),
            polyline: committedInk
        )
        try cache.commit(geometry: committed)

        let committedResource = try XCTUnwrap(cache.coverage(
            for: committed,
            viewport: viewport(),
            displayScale: 1
        ))
        XCTAssertTrue(
            (committedResource.texture as AnyObject) === (previewResource.texture as AnyObject)
        )
        XCTAssertEqual(cache.statistics.fullBuildCount, fullBuildsBeforeCommit)
        XCTAssertGreaterThan(cache.statistics.encodedSegmentCount, encodedBeforeCommit)
        XCTAssertEqual(cache.statistics.commitReuseCount, 1)
        XCTAssertEqual(committedResource.prefixVertexCount, committedResource.vertices.count)
        XCTAssertFalse(cache.hasActiveCoverage)
    }

    func testCommitDropsPredictedTailAndReusesStablePrefix() throws {
        let device = try metalDevice()
        let id = UUID()
        let confirmed = points(0..<5).map { CanvasInkSample(point: $0, pressure: 1) }
        let previewInk = CanvasPreparedInk(
            confirmedSamples: confirmed,
            predictedSamples: [
                CanvasInkSample(point: .init(x: 112, y: 92), pressure: 0.4),
            ],
            pressureEnabled: true,
            isFinalized: false
        )
        let preview = geometry(id: id, polyline: previewInk)
        let cache = try MetalFreehandCoverageCache(device: device)
        try cache.update(activeGeometry: preview, viewport: viewport())
        let previewResource = try XCTUnwrap(cache.coverage(
            for: preview,
            viewport: viewport(),
            displayScale: 1
        ))
        let buildsBeforeCommit = cache.statistics.fullBuildCount

        let committed = geometry(
            id: id,
            renderKey: .committed(id: id, contentRevision: 1),
            polyline: CanvasPreparedInk(
                confirmedSamples: confirmed,
                pressureEnabled: true
            )
        )
        try cache.commit(geometry: committed)

        let committedResource = try XCTUnwrap(cache.coverage(
            for: committed,
            viewport: viewport(),
            displayScale: 1
        ))
        XCTAssertTrue(
            (committedResource.texture as AnyObject) === (previewResource.texture as AnyObject)
        )
        XCTAssertEqual(cache.statistics.fullBuildCount, buildsBeforeCommit)
        XCTAssertEqual(cache.statistics.commitReuseCount, 1)
        XCTAssertEqual(committedResource.points, confirmed.map(\.point))
        XCTAssertEqual(committedResource.prefixVertexCount, committedResource.vertices.count)
    }

    func testTransientTailFrameLeasesPersistentPrefixUntilGPUCompletion() throws {
        let device = try metalDevice()
        let engine = try MetalRenderEngine(device: device)
        let ink = CanvasPreparedInk(
            confirmedSamples: points(0..<5).map {
                CanvasInkSample(point: $0, pressure: 1)
            },
            predictedSamples: [
                CanvasInkSample(point: .init(x: 100, y: 88), pressure: 1),
            ],
            pressureEnabled: false,
            isFinalized: false
        )
        let compiled = try MetalSceneCompiler().compile(scene([geometry(polyline: ink)]))
        let output = try outputTexture(device: device)
        let gate = try XCTUnwrap(device.makeSharedEvent())
        gate.signaledValue = 0
        var submitted: (any MTLCommandBuffer)?

        try engine.renderPresentedFrame(
            compiled,
            into: output,
            size: .init(width: 128, height: 128),
            displayScale: 1,
            configureBeforeCommit: { commandBuffer in
                submitted = commandBuffer
                commandBuffer.encodeWaitForEvent(gate, value: 1)
            },
            completion: { _ in }
        )

        XCTAssertEqual(engine.prefixToScratchCopyCount, 1)
        XCTAssertTrue(engine.activeFreehandCoverageIsInFlight)
        gate.signaledValue = 1
        let commandBuffer = try XCTUnwrap(submitted)
        commandBuffer.waitUntilCompleted()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        XCTAssertFalse(engine.activeFreehandCoverageIsInFlight)
    }

    func testEmptyLivePreviewIsANoOpOffscreenAndOnscreen() throws {
        let device = try metalDevice()
        let engine = try MetalRenderEngine(device: device)
        let empty = CanvasPreparedInk(
            confirmedSamples: [],
            predictedSamples: [],
            pressureEnabled: false,
            isFinalized: false
        )
        let compiled = try MetalSceneCompiler().compile(scene([geometry(polyline: empty)]))

        let offscreen = try engine.renderOffscreen(
            compiled,
            size: .init(width: 128, height: 128),
            displayScale: 1
        )
        XCTAssertEqual(pixel(offscreen, x: 64, y: 64), [255, 255, 255, 255])

        let output = try outputTexture(device: device)
        var submitted: (any MTLCommandBuffer)?
        XCTAssertNoThrow(try engine.renderPresentedFrame(
            compiled,
            into: output,
            size: .init(width: 128, height: 128),
            displayScale: 1,
            configureBeforeCommit: { submitted = $0 },
            completion: { _ in }
        ))
        let commandBuffer = try XCTUnwrap(submitted)
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed)
        XCTAssertEqual(pixel(output, x: 64, y: 64), [255, 255, 255, 255])
        XCTAssertEqual(engine.transientTailEncodeCount, 0)
        XCTAssertEqual(engine.transientCoverageAllocationCount, 0)
    }

    func testCommitMismatchDoesNotReuseActiveCoverage() throws {
        let mismatches: (CanvasPreparedGeometry, CanvasPreparedGeometry) -> [CanvasPreparedGeometry] = {
            preview, exact in
            let exactPoints = self.polyline(in: exact).points
            return [
                self.geometry(
                    id: UUID(),
                    renderKey: exact.renderKey,
                    polyline: CanvasPreparedInk(points: exactPoints)
                ),
                self.geometry(
                    id: exact.id,
                    renderKey: exact.renderKey,
                    polyline: CanvasPreparedInk(points: exactPoints),
                    style: .init(stroke: .black, lineWidth: 9)
                ),
                self.geometry(
                    id: exact.id,
                    renderKey: exact.renderKey,
                    polyline: CanvasPreparedInk(points: [
                        exactPoints[0], .init(x: 77, y: 31), exactPoints[2], exactPoints[3],
                    ])
                ),
            ]
        }

        for committed in try mismatchGeometries(mismatches) {
            let device = try metalDevice()
            let cache = try MetalFreehandCoverageCache(device: device)
            try cache.update(activeGeometry: committed.preview, viewport: viewport())
            let encodedBeforeCommit = cache.statistics.encodedSegmentCount

            try cache.commit(geometry: committed.committed)

            XCTAssertEqual(cache.statistics.commitReuseCount, 0)
            XCTAssertGreaterThan(cache.statistics.encodedSegmentCount, encodedBeforeCommit)
            XCTAssertTrue(cache.hasCoverage(for: committed.committed, viewport: viewport()))
        }

        let device = try metalDevice()
        let cache = try MetalFreehandCoverageCache(device: device)
        let id = UUID()
        let preview = geometry(
            id: id,
            polyline: CanvasPreparedInk(points: points(0..<4))
        )
        try cache.update(activeGeometry: preview, viewport: viewport())
        let activeTexture = try XCTUnwrap(cache.activeTexture)
        let residentBeforeFailure = cache.residentByteCount
        let mismatchedCommit = geometry(
            id: id,
            renderKey: .committed(id: id, contentRevision: 1),
            polyline: CanvasPreparedInk(points: points(0..<4)),
            style: .init(stroke: .black, lineWidth: 9)
        )
        cache.injectFailureOnce(.encoding)

        XCTAssertThrowsError(try cache.commit(geometry: mismatchedCommit)) {
            XCTAssertEqual($0 as? MetalCanvasError, .commandEncodingFailed)
        }
        XCTAssertTrue(cache.hasActiveCoverage)
        XCTAssertEqual(cache.residentByteCount, residentBeforeFailure)
        let retainedActiveTexture = try XCTUnwrap(cache.activeTexture)
        XCTAssertTrue((retainedActiveTexture as AnyObject) === (activeTexture as AnyObject))
        XCTAssertFalse(cache.hasCoverage(for: mismatchedCommit, viewport: viewport()))

        let residentDestinationID = UUID()
        let residentDestination = geometry(
            id: residentDestinationID,
            renderKey: .committed(id: residentDestinationID, contentRevision: 1),
            polyline: CanvasPreparedInk(points: points(0..<4))
        )
        try cache.commit(
            geometry: residentDestination,
            viewport: viewport(),
            displayScale: 1
        )
        try cache.update(
            activeGeometry: geometry(
                id: residentDestinationID,
                polyline: CanvasPreparedInk(points: points(0..<4)),
                style: .init(stroke: .black, lineWidth: 9)
            ),
            viewport: viewport()
        )
        let statisticsBeforeResidentDestinationHit = cache.statistics

        try cache.commit(
            geometry: residentDestination,
            viewport: viewport(),
            displayScale: 1
        )

        XCTAssertEqual(cache.statistics, statisticsBeforeResidentDestinationHit)
        XCTAssertFalse(cache.hasActiveCoverage)
        XCTAssertTrue(cache.hasCoverage(for: residentDestination, viewport: viewport()))
    }

    func testResourceCacheEvictsLeastRecentlyUsedAtExactly64MiB() throws {
        let device = try metalDevice()
        let oversizedCache = MetalResourceCache(
            device: device,
            budgetBytes: CanvasMetalLimits.resourceBudgetBytes * 2
        )
        XCTAssertEqual(
            oversizedCache.budgetByteCount,
            CanvasMetalLimits.resourceBudgetBytes,
            "The cache budget is a hard ceiling, including injected budgets"
        )
        let cache = MetalResourceCache(device: device)
        let halfBudget = CanvasMetalLimits.resourceBudgetBytes / 2
        let firstKey = immutableKey(revision: 1)
        let secondKey = immutableKey(revision: 2)
        let thirdKey = immutableKey(revision: 3)
        let first = try bufferResource(device: device, byteCount: halfBudget)
        let second = try bufferResource(device: device, byteCount: halfBudget)
        XCTAssertEqual(first.byteCount, halfBudget)
        XCTAssertEqual(second.byteCount, halfBudget)
        try cache.insert(first, for: firstKey)
        try cache.insert(second, for: secondKey)

        XCTAssertEqual(cache.residentByteCount, CanvasMetalLimits.resourceBudgetBytes)
        XCTAssertEqual(
            try cache.combinedResidentByteCount(retaining: []),
            CanvasMetalLimits.resourceBudgetBytes
        )
        XCTAssertNotNil(cache.resource(for: firstKey), "Touch first so second becomes LRU")
        let third = try bufferResource(device: device, byteCount: 1)
        XCTAssertGreaterThanOrEqual(third.byteCount, 1)
        try cache.insert(third, for: thirdKey)

        XCTAssertNotNil(cache.resource(for: firstKey))
        XCTAssertNil(cache.resource(for: secondKey))
        XCTAssertNotNil(cache.resource(for: thirdKey))
        XCTAssertEqual(cache.residentByteCount, halfBudget + third.byteCount)

        let unionResources = MetalResourceCache(device: device)
        let unionCache = try MetalFreehandCoverageCache(
            device: device,
            coveragePipeline: MetalPipelineLibrary(device: device).coverageSegment,
            resourceCache: unionResources
        )
        let unionGeometry = geometry(
            polyline: CanvasPreparedInk(points: points(0..<3))
        )
        try unionCache.update(activeGeometry: unionGeometry, viewport: viewport())
        let cachedCoverage = try XCTUnwrap(unionCache.coverage(
            for: unionGeometry,
            viewport: viewport(),
            displayScale: 1
        ))
        let distinctSegmentBuffer = try XCTUnwrap(device.makeBuffer(
            length: cachedCoverage.segmentBuffer.length,
            options: .storageModeShared
        ))
        let distinctSegmentByteCount = try MetalCachedResource(
            buffer: distinctSegmentBuffer
        ).byteCount
        let retainedCoverage = MetalCoverageResource(
            texture: cachedCoverage.texture,
            textureByteCount: cachedCoverage.textureByteCount,
            segmentBuffer: distinctSegmentBuffer,
            segmentBufferByteCount: distinctSegmentByteCount,
            segmentCapacity: cachedCoverage.segmentCapacity,
            pointCount: cachedCoverage.pointCount,
            points: cachedCoverage.points,
            sourceInk: cachedCoverage.sourceInk,
            elementID: cachedCoverage.elementID,
            styleFingerprint: cachedCoverage.styleFingerprint,
            viewportSignature: cachedCoverage.viewportSignature,
            premultipliedColor: cachedCoverage.premultipliedColor
        )
        XCTAssertEqual(
            try unionResources.combinedResidentByteCount(
                retaining: [cachedCoverage, retainedCoverage]
            ),
            cachedCoverage.textureByteCount
                + cachedCoverage.segmentBufferByteCount
                + distinctSegmentByteCount
        )

        let strokes = [20.0, 40, 60, 80, 100].map { y -> CanvasPreparedGeometry in
            let id = UUID()
            return geometry(
                id: id,
                renderKey: .committed(id: id, contentRevision: 0),
                polyline: CanvasPreparedInk(points: [
                    .init(x: 12, y: y), .init(x: 116, y: y),
                ]),
                style: .init(stroke: .black, lineWidth: 6)
            )
        }
        let renderDevice = try metalDevice()
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 128,
            height: 128,
            mipmapped: false
        )
        outputDescriptor.storageMode = .shared
        outputDescriptor.usage = [.renderTarget, .shaderRead]
        let outputByteCount = try MetalCachedResource.conservativeAllocationByteCount(
            payloadByteCount: 128 * 128 * 4,
            reportedByteCount: renderDevice.heapTextureSizeAndAlign(
                descriptor: outputDescriptor
            ).size
        )
        let engine = try MetalRenderEngine(
            device: renderDevice,
            resourceBudgetBytes: outputByteCount + 40_000
        )
        let rendered = try render(strokes, engine: engine)
        XCTAssertEqual(engine.outputCommandBufferCount, strokes.count * 2 + 1)
        XCTAssertLessThanOrEqual(
            engine.maximumOwnedCoverageByteCount,
            outputByteCount + 40_000
        )
        for y in [20, 40, 60, 80, 100] {
            XCTAssertLessThan(pixel(rendered, x: 64, y: y)[0], 8)
        }

        let presentationEngine = try MetalRenderEngine(device: renderDevice)
        let compiledStrokes = try MetalSceneCompiler().compile(scene(strokes))
        var finalConfigurationCount = 0
        var finalConfigurationObservedEndedEncoder = false
        var finalCommandBuffer: (any MTLCommandBuffer)?
        let gate = try XCTUnwrap(renderDevice.makeSharedEvent())
        gate.signaledValue = 0
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
            gate.signaledValue = 1
        }
        let renderStart = ProcessInfo.processInfo.systemUptime
        try presentationEngine.render(
            compiledStrokes,
            into: rendered,
            size: .init(width: 128, height: 128),
            displayScale: 1,
            configureFinalOutputCommandBuffer: { commandBuffer in
                finalConfigurationCount += 1
                finalCommandBuffer = commandBuffer
                XCTAssertEqual(commandBuffer.status, .notEnqueued)
                let orderingProbe = commandBuffer.makeBlitCommandEncoder()
                finalConfigurationObservedEndedEncoder = orderingProbe != nil
                orderingProbe?.endEncoding()
                commandBuffer.encodeWaitForEvent(gate, value: 1)
            }
        )
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - renderStart, 0.1)
        XCTAssertEqual(gate.signaledValue, 0)
        XCTAssertEqual(presentationEngine.outputCommandBufferCount, 1)
        XCTAssertEqual(presentationEngine.freehandCoverageCommandBufferCount, 0)
        XCTAssertEqual(presentationEngine.synchronousOutputWaitCount, 0)
        XCTAssertEqual(finalConfigurationCount, 1)
        XCTAssertTrue(finalConfigurationObservedEndedEncoder)
        let submittedPresentation = try XCTUnwrap(finalCommandBuffer)
        submittedPresentation.waitUntilCompleted()
        XCTAssertEqual(submittedPresentation.status, .completed)
        for y in [20, 40, 60, 80, 100] {
            XCTAssertLessThan(pixel(rendered, x: 64, y: y)[0], 8)
        }

        let transientStrokes = Array(strokes.prefix(2))
        let cachedEngine = try MetalRenderEngine(
            device: renderDevice,
            resourceBudgetBytes: outputByteCount + 70_000
        )
        _ = try render(transientStrokes, engine: cachedEngine)
        let commandBuffersBeforeCachedFrame = cachedEngine.outputCommandBufferCount
        _ = try render(transientStrokes, engine: cachedEngine)
        XCTAssertEqual(
            cachedEngine.outputCommandBufferCount - commandBuffersBeforeCachedFrame,
            transientStrokes.count * 2 + 1
        )
        XCTAssertLessThanOrEqual(
            cachedEngine.maximumOwnedCoverageByteCount,
            outputByteCount + 70_000
        )

        let stableID = UUID()
        let stableCommitted = geometry(
            id: stableID,
            renderKey: .committed(id: stableID, contentRevision: 0),
            polyline: CanvasPreparedInk(points: [
                .init(x: 12, y: 88), .init(x: 116, y: 88),
            ])
        )
        let activeID = UUID()
        let activePolyline = CanvasPreparedInk(points: points(0..<4))
        let suffixEngine = try MetalRenderEngine(
            device: renderDevice,
            resourceBudgetBytes: outputByteCount + 70_000
        )
        _ = try render([
            stableCommitted,
            geometry(id: activeID, polyline: activePolyline),
        ], engine: suffixEngine)
        activePolyline.append(points(4..<5))
        let commandBuffersBeforeSuffixFrame = suffixEngine.outputCommandBufferCount
        _ = try render([
            stableCommitted,
            geometry(id: activeID, polyline: activePolyline),
        ], engine: suffixEngine)
        XCTAssertEqual(
            suffixEngine.outputCommandBufferCount - commandBuffersBeforeSuffixFrame,
            5
        )
        XCTAssertLessThanOrEqual(
            suffixEngine.maximumOwnedCoverageByteCount,
            outputByteCount + 70_000
        )
    }

    func testInFlightCoverageRemainsBudgetedAfterCacheEvictionUntilRelease() throws {
        let device = try metalDevice()
        let resources = MetalResourceCache(device: device)
        let cache = try MetalFreehandCoverageCache(
            device: device,
            coveragePipeline: MetalPipelineLibrary(device: device).coverageSegment,
            resourceCache: resources
        )
        let activeGeometry = geometry(
            polyline: CanvasPreparedInk(points: points(0..<3))
        )
        try cache.update(activeGeometry: activeGeometry, viewport: viewport())
        let coverage = try XCTUnwrap(cache.coverage(
            for: activeGeometry,
            viewport: viewport(),
            displayScale: 1
        ))
        let coverageBytes = coverage.textureByteCount + coverage.segmentBufferByteCount

        let lease = try resources.retainInFlight(
            coverage: [coverage],
            fallback: [],
            textures: []
        )
        let alias = MetalCoverageResource(
            texture: coverage.texture,
            textureByteCount: coverage.textureByteCount,
            segmentBuffer: coverage.segmentBuffer,
            segmentBufferByteCount: coverage.segmentBufferByteCount,
            segmentCapacity: coverage.segmentCapacity,
            pointCount: coverage.pointCount,
            points: coverage.points,
            sourceInk: coverage.sourceInk,
            elementID: coverage.elementID,
            styleFingerprint: coverage.styleFingerprint,
            viewportSignature: coverage.viewportSignature,
            premultipliedColor: coverage.premultipliedColor
        )
        let overlappingLease = try resources.retainInFlight(
            coverage: [coverage],
            fallback: [],
            textures: []
        )
        XCTAssertTrue(resources.isInFlight(coverage))
        XCTAssertTrue(resources.isInFlight(alias))
        XCTAssertEqual(
            try resources.combinedResidentByteCount(retaining: []),
            coverageBytes
        )

        resources.removeAll()
        XCTAssertEqual(resources.residentByteCount, 0)
        XCTAssertEqual(
            try resources.combinedResidentByteCount(retaining: []),
            coverageBytes
        )
        XCTAssertThrowsError(try resources.reserve(
            additionalByteCount: CanvasMetalLimits.resourceBudgetBytes - coverageBytes + 1
        )) {
            XCTAssertEqual($0 as? MetalCanvasError, .resourceBudgetExceeded)
        }

        resources.releaseInFlight(lease)
        XCTAssertTrue(resources.isInFlight(coverage))
        XCTAssertEqual(
            try resources.combinedResidentByteCount(retaining: []),
            coverageBytes
        )
        resources.releaseInFlight(overlappingLease)
        XCTAssertFalse(resources.isInFlight(coverage))
        XCTAssertEqual(try resources.combinedResidentByteCount(retaining: []), 0)
        XCTAssertNoThrow(try resources.reserve(
            additionalByteCount: CanvasMetalLimits.resourceBudgetBytes
        ))
    }

    func testFailedInFlightReservationsRestoreEveryEvictedCacheEntry() throws {
        let device = try metalDevice()
        let sourceResources = MetalResourceCache(device: device)
        let sourceCache = try MetalFreehandCoverageCache(
            device: device,
            coveragePipeline: MetalPipelineLibrary(device: device).coverageSegment,
            resourceCache: sourceResources
        )
        let sourceGeometry = geometry(
            polyline: CanvasPreparedInk(points: points(0..<3))
        )
        try sourceCache.update(activeGeometry: sourceGeometry, viewport: viewport())
        let coverage = try XCTUnwrap(sourceCache.coverage(
            for: sourceGeometry,
            viewport: viewport(),
            displayScale: 1
        ))
        let coverageBytes = coverage.textureByteCount + coverage.segmentBufferByteCount
        let firstKey = immutableKey(revision: 41)
        let secondKey = immutableKey(revision: 42)
        let firstBuffer = try XCTUnwrap(device.makeBuffer(length: 1))
        let secondBuffer = try XCTUnwrap(device.makeBuffer(length: 1))

        let reserveResources = MetalResourceCache(
            device: device,
            budgetBytes: coverageBytes + 32_768
        )
        try reserveResources.insert(try MetalCachedResource(buffer: firstBuffer), for: firstKey)
        try reserveResources.insert(try MetalCachedResource(buffer: secondBuffer), for: secondKey)
        let reserveResidentBefore = reserveResources.residentByteCount
        XCTAssertThrowsError(try reserveResources.reserve(
            additionalByteCount: reserveResources.budgetByteCount - coverageBytes + 1,
            retaining: [coverage],
            fallback: []
        )) {
            XCTAssertEqual($0 as? MetalCanvasError, .resourceBudgetExceeded)
        }
        XCTAssertEqual(reserveResources.resourceCount, 2)
        XCTAssertEqual(reserveResources.residentByteCount, reserveResidentBefore)
        XCTAssertNotNil(reserveResources.peekResource(for: firstKey))
        XCTAssertNotNil(reserveResources.peekResource(for: secondKey))

        let leaseResources = MetalResourceCache(
            device: device,
            budgetBytes: coverageBytes - 1
        )
        try leaseResources.insert(try MetalCachedResource(buffer: firstBuffer), for: firstKey)
        let leaseResidentBefore = leaseResources.residentByteCount
        XCTAssertThrowsError(try leaseResources.retainInFlight(
            coverage: [coverage],
            fallback: [],
            textures: []
        )) {
            XCTAssertEqual($0 as? MetalCanvasError, .resourceBudgetExceeded)
        }
        XCTAssertEqual(leaseResources.resourceCount, 1)
        XCTAssertEqual(leaseResources.residentByteCount, leaseResidentBefore)
        XCTAssertNotNil(leaseResources.peekResource(for: firstKey))
        XCTAssertEqual(leaseResources.inFlightLeaseCount, 0)
    }

    func testGrowingPreviewDoesNotMutateCoverageRetainedByAnInFlightFrame() throws {
        let device = try metalDevice()
        let resources = MetalResourceCache(device: device)
        let cache = try MetalFreehandCoverageCache(
            device: device,
            coveragePipeline: MetalPipelineLibrary(device: device).coverageSegment,
            resourceCache: resources
        )
        let polyline = CanvasPreparedInk(points: points(0..<3))
        let initial = geometry(polyline: polyline)
        try cache.update(activeGeometry: initial, viewport: viewport())
        let retained = try XCTUnwrap(cache.coverage(
            for: initial,
            viewport: viewport(),
            displayScale: 1
        ))
        let retainedPoints = retained.points
        let retainedVertices = retained.vertices
        let retainedSpanEnds = retained.spanEndVertexIndices
        let retainedGeneration = retained.sourceGeneration
        let retainedPreparedIdentity = retained.preparedResourceIdentity
        let lease = try resources.retainInFlight(
            coverage: [retained],
            fallback: [],
            textures: []
        )

        polyline.append(points(3..<7))
        let grown = geometry(polyline: polyline)
        XCTAssertEqual(
            try cache.additionalCoverageByteCount(
                geometry: grown,
                viewport: viewport(),
                displayScale: 1
            ),
            try cache.estimatedCoverageByteCount(
                geometry: grown,
                viewport: viewport(),
                displayScale: 1
            )
        )
        let statisticsBeforeReplacement = cache.statistics
        try cache.update(activeGeometry: grown, viewport: viewport())
        let replacement = try XCTUnwrap(cache.coverage(
            for: grown,
            viewport: viewport(),
            displayScale: 1
        ))

        XCTAssertFalse((replacement.texture as AnyObject) === (retained.texture as AnyObject))
        XCTAssertTrue(resources.isInFlight(retained))
        XCTAssertEqual(retained.points, retainedPoints)
        XCTAssertEqual(retained.vertices, retainedVertices)
        XCTAssertEqual(retained.spanEndVertexIndices, retainedSpanEnds)
        XCTAssertEqual(retained.sourceGeneration, retainedGeneration)
        XCTAssertEqual(retained.preparedResourceIdentity, retainedPreparedIdentity)
        let oracle = try CanvasInkCurve.flattenWithSpanEnds(
            stroke: .init(
                samples: polyline.snapshot().confirmed + polyline.snapshot().predicted,
                pressureEnabled: false
            ),
            maximumError: 0.25
        )
        XCTAssertEqual(replacement.vertices, oracle.vertices)
        XCTAssertEqual(replacement.spanEndVertexIndices, oracle.spanEndVertexIndices)
        XCTAssertEqual(replacement.preparedResourceIdentity, grown.resourceIdentity)
        XCTAssertLessThan(
            cache.statistics.incrementallyCopiedVertexCount
                - statisticsBeforeReplacement.incrementallyCopiedVertexCount,
            256
        )
        XCTAssertEqual(
            cache.statistics.incrementallyCopiedSpanEndCount
                - statisticsBeforeReplacement.incrementallyCopiedSpanEndCount,
            cache.statistics.incrementallyFlattenedSpanCount
                - statisticsBeforeReplacement.incrementallyFlattenedSpanCount
        )
        XCTAssertLessThanOrEqual(
            cache.statistics.incrementallyCopiedPointCount
                - statisticsBeforeReplacement.incrementallyCopiedPointCount,
            8
        )
        XCTAssertLessThanOrEqual(
            cache.statistics.incrementallyValidatedSampleCount
                - statisticsBeforeReplacement.incrementallyValidatedSampleCount,
            8
        )
        resources.releaseInFlight(lease)
    }

    func testDrawableFinalOutputDoesNotSynchronouslyWaitForCompletion() throws {
        let device = try metalDevice()
        let engine = try MetalRenderEngine(device: device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 128,
            height: 128,
            mipmapped: false
        )
        descriptor.usage = .renderTarget
        let destination = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let compiled = try MetalSceneCompiler().compile(scene([]))
        var finalCommandBuffer: (any MTLCommandBuffer)?
        var leaseCountAtCompletion: Int?
        let gate = try XCTUnwrap(device.makeSharedEvent())
        gate.signaledValue = 0
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
            gate.signaledValue = 1
        }
        let renderStart = ProcessInfo.processInfo.systemUptime

        try engine.renderPresentedFrame(
            compiled,
            into: destination,
            size: .init(width: 128, height: 128),
            displayScale: 1,
            configureBeforeCommit: { commandBuffer in
                finalCommandBuffer = commandBuffer
                commandBuffer.encodeWaitForEvent(gate, value: 1)
            },
            completion: { _ in
                leaseCountAtCompletion = engine.inFlightResourceLeaseCount
            }
        )

        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - renderStart, 0.1)
        XCTAssertEqual(gate.signaledValue, 0)
        XCTAssertEqual(engine.synchronousOutputWaitCount, 0)
        XCTAssertEqual(engine.inFlightResourceLeaseCount, 1)
        let submitted = try XCTUnwrap(finalCommandBuffer)
        XCTAssertNotEqual(submitted.status, .notEnqueued)
        submitted.waitUntilCompleted()
        XCTAssertEqual(submitted.status, .completed)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        XCTAssertEqual(leaseCountAtCompletion, 0)
        XCTAssertEqual(engine.inFlightResourceLeaseCount, 0)

        _ = try engine.renderOffscreen(
            compiled,
            size: .init(width: 128, height: 128),
            displayScale: 1
        )
        XCTAssertEqual(engine.synchronousOutputWaitCount, 1)
    }

    func testCoverageAllocationOver64MegapixelsFailsAtomically() throws {
        let device = try metalDevice()
        let cache = try MetalFreehandCoverageCache(device: device)
        let valid = geometry(polyline: CanvasPreparedInk(points: points(0..<3)))
        try cache.update(activeGeometry: valid, viewport: viewport())
        let residentBefore = cache.residentByteCount
        let pointsBefore = cache.activePointCount
        let oversized = try! CanvasViewport.identity(size: .init(width: 8_193, height: 8_192))
        let oversizedGeometry = geometry(
            polyline: CanvasPreparedInk(points: points(0..<3))
        )

        XCTAssertThrowsError(try cache.update(
            activeGeometry: oversizedGeometry,
            viewport: oversized
        )) {
            XCTAssertEqual($0 as? MetalCanvasError, .invalidResourceSize)
        }
        XCTAssertEqual(cache.residentByteCount, residentBefore)
        let engine = try MetalRenderEngine(device: device)
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 128,
            height: 128,
            mipmapped: false
        )
        outputDescriptor.storageMode = .shared
        outputDescriptor.usage = [.renderTarget, .shaderRead]
        let output = try XCTUnwrap(device.makeTexture(descriptor: outputDescriptor))
        let compiledOversized = try MetalSceneCompiler().compile(
            scene([oversizedGeometry], viewport: oversized)
        )
        var preflightFailureConfigurationCount = 0
        XCTAssertThrowsError(try engine.render(
            compiledOversized,
            into: output,
            size: CGSize(
                width: oversized.viewportSize.width,
                height: oversized.viewportSize.height
            ),
            displayScale: 1,
            configureFinalOutputCommandBuffer: { _ in
                preflightFailureConfigurationCount += 1
            }
        )) {
            XCTAssertEqual($0 as? MetalCanvasError, .invalidResourceSize)
        }
        XCTAssertEqual(preflightFailureConfigurationCount, 0)
        XCTAssertEqual(cache.activePointCount, pointsBefore)

        let budgetBytes = 80_000
        let transactionalResources = MetalResourceCache(
            device: device,
            budgetBytes: budgetBytes
        )
        let transactionalCache = try MetalFreehandCoverageCache(
            device: device,
            coveragePipeline: MetalPipelineLibrary(device: device).coverageSegment,
            resourceCache: transactionalResources
        )
        let transactionalActive = geometry(
            polyline: CanvasPreparedInk(points: points(0..<3))
        )
        try transactionalCache.update(
            activeGeometry: transactionalActive,
            viewport: viewport()
        )
        let unrelatedKey = immutableKey(revision: 99)
        weak var unrelatedBuffer: (any MTLBuffer)?
        do {
            let buffer = try XCTUnwrap(device.makeBuffer(
                length: 32_768,
                options: .storageModeShared
            ))
            unrelatedBuffer = buffer
            try transactionalResources.insert(
                try MetalCachedResource(buffer: buffer),
                for: unrelatedKey
            )
        }
        let transactionalResidentBefore = transactionalCache.residentByteCount
        let transactionalTextureBefore = try XCTUnwrap(transactionalCache.activeTexture)
        let replacementPolyline = CanvasPreparedInk(points: points(1..<4))
        let replacementGeometry = geometry(polyline: replacementPolyline)
        let canonicalReplacementPoints = replacementPolyline.points
        transactionalCache.injectFailureOnce(.allocation)

        XCTAssertThrowsError(try transactionalCache.update(
            activeGeometry: replacementGeometry,
            viewport: viewport()
        )) {
            XCTAssertEqual($0 as? MetalCanvasError, .invalidResourceSize)
        }
        XCTAssertLessThan(transactionalCache.residentByteCount, transactionalResidentBefore)
        XCTAssertNil(transactionalResources.resource(for: unrelatedKey))
        XCTAssertNil(unrelatedBuffer)
        XCTAssertLessThanOrEqual(
            try transactionalResources.combinedResidentByteCount(retaining: []),
            budgetBytes
        )
        XCTAssertEqual(replacementPolyline.points, canonicalReplacementPoints)
        XCTAssertFalse(transactionalCache.hasCoverage(
            for: replacementGeometry,
            viewport: viewport()
        ))
        XCTAssertTrue(transactionalCache.hasActiveCoverage)
        let transactionalTextureAfter = try XCTUnwrap(transactionalCache.activeTexture)
        XCTAssertTrue(
            (transactionalTextureAfter as AnyObject) === (transactionalTextureBefore as AnyObject)
        )

        try transactionalCache.update(
            activeGeometry: replacementGeometry,
            viewport: viewport()
        )
        XCTAssertTrue(transactionalCache.hasCoverage(
            for: replacementGeometry,
            viewport: viewport()
        ))
        XCTAssertEqual(transactionalCache.activePointCount, canonicalReplacementPoints.count)
        XCTAssertLessThanOrEqual(
            try transactionalResources.combinedResidentByteCount(retaining: []),
            budgetBytes
        )
    }

    func testCancellationReplacementMemoryPressureAndDeinitReleaseResourcesAndAccounting() throws {
        let device = try metalDevice()
        var cache: MetalFreehandCoverageCache? = try MetalFreehandCoverageCache(device: device)
        let first = geometry(polyline: CanvasPreparedInk(points: points(0..<3)))
        try cache?.update(activeGeometry: first, viewport: viewport())
        XCTAssertGreaterThan(cache?.residentByteCount ?? 0, 0)

        cache?.reset()
        XCTAssertEqual(cache?.residentByteCount, 0)
        XCTAssertNil(cache?.activeElementID)
        XCTAssertEqual(cache?.activePointCount, 0)

        try cache?.update(activeGeometry: first, viewport: viewport())
        let unrelatedID = UUID()
        let unrelatedCommitted = geometry(
            id: unrelatedID,
            renderKey: .committed(id: unrelatedID, contentRevision: 0),
            polyline: CanvasPreparedInk(points: points(0..<2))
        )
        try cache?.commit(geometry: unrelatedCommitted)
        XCTAssertTrue(cache?.hasActiveCoverage ?? false)
        XCTAssertTrue(cache?.hasCoverage(for: first, viewport: viewport()) ?? false)
        XCTAssertEqual(cache?.resourceCount, 2)

        cache?.handleMemoryPressure()
        XCTAssertEqual(cache?.residentByteCount, 0)
        XCTAssertEqual(cache?.resourceCount, 0)
        XCTAssertNil(cache?.activeElementID)
        XCTAssertEqual(cache?.activePointCount, 0)

        try cache?.update(activeGeometry: first, viewport: viewport())
        let second = geometry(polyline: CanvasPreparedInk(points: [
            .init(x: 18, y: 18), .init(x: 42, y: 42),
            .init(x: 76, y: 76), .init(x: 110, y: 110),
        ]))
        try cache?.update(activeGeometry: second, viewport: viewport())
        XCTAssertFalse(cache?.hasCoverage(for: first, viewport: viewport()) ?? true)
        XCTAssertEqual(cache?.resourceCount, 1)

        cache?.handleMemoryPressure()
        XCTAssertEqual(cache?.residentByteCount, 0)
        XCTAssertEqual(cache?.resourceCount, 0)
        XCTAssertNil(cache?.activeElementID)
        XCTAssertEqual(cache?.activePointCount, 0)

        try cache?.update(activeGeometry: second, viewport: viewport())
        weak var texture: (any MTLTexture)?
        texture = cache?.activeTexture
        XCTAssertNotNil(texture)
        cache = nil
        XCTAssertNil(texture)

        let engine = try MetalRenderEngine(device: device)
        _ = try render([unrelatedCommitted, first], engine: engine)
        XCTAssertTrue(engine.hasActiveFreehandCoverage)
        XCTAssertGreaterThan(engine.derivedFreehandResourceCount, 0)
        engine.handleMemoryPressure()
        XCTAssertFalse(engine.hasActiveFreehandCoverage)
        XCTAssertEqual(engine.derivedFreehandResourceCount, 0)
        XCTAssertEqual(engine.residentFreehandByteCount, 0)
        _ = try render([unrelatedCommitted, first], engine: engine)
        XCTAssertTrue(engine.hasActiveFreehandCoverage)
        _ = try render([unrelatedCommitted], engine: engine)
        XCTAssertFalse(engine.hasActiveFreehandCoverage)
    }

    func testFortyEightThousandSamplesRemainAcceptedAndRenderable() throws {
        let device = try metalDevice()
        let samples = (0..<48_000).map { index in
            CanvasPoint(x: index.isMultiple(of: 2) ? 20 : 108, y: 64)
        }
        let polyline = CanvasPreparedInk(points: samples)
        let cache = try MetalFreehandCoverageCache(device: device)

        try cache.update(
            activeGeometry: geometry(
                polyline: polyline,
                style: .init(stroke: .black, lineWidth: 8)
            ),
            viewport: viewport()
        )

        XCTAssertEqual(polyline.points.count, 48_000)
        XCTAssertEqual(cache.activePointCount, 48_000)
        XCTAssertEqual(cache.statistics.encodedSegmentCount, 47_995)
        XCTAssertEqual(cache.statistics.coverageDrawCallCount, 1)
        XCTAssertGreaterThan(cache.activeCoverage(atX: 64, y: 64), 0)
    }

    func testDimensionAndByteCountOverflowReturnsTypedError() throws {
        XCTAssertThrowsError(try MetalCachedResource.checkedByteCount(
            width: Int.max,
            height: 2,
            bytesPerPixel: 4
        )) {
            XCTAssertEqual($0 as? MetalCanvasError, .invalidResourceSize)
        }

        let device = try metalDevice()
        let cache = try MetalFreehandCoverageCache(device: device)
        let overflowingViewport = try! CanvasViewport.identity(size: .init(
            width: Double.greatestFiniteMagnitude,
            height: 2
        ))
        XCTAssertThrowsError(try cache.update(
            activeGeometry: geometry(polyline: CanvasPreparedInk(points: points(0..<2))),
            viewport: overflowingViewport
        )) {
            XCTAssertEqual($0 as? MetalCanvasError, .invalidResourceSize)
        }
        XCTAssertEqual(cache.residentByteCount, 0)
    }
}

private extension MetalFreehandCoverageTests {
    typealias CommitPair = (preview: CanvasPreparedGeometry, committed: CanvasPreparedGeometry)

    func metalDevice() throws -> any MTLDevice {
        try XCTUnwrap(MTLCreateSystemDefaultDevice())
    }

    func outputTexture(
        device: any MTLDevice,
        size: Int = 128
    ) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: size,
            height: size,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    func viewport() -> CanvasViewport {
        try! .identity(size: .init(width: 128, height: 128))
    }

    func points(_ range: Range<Int>) -> [CanvasPoint] {
        range.map { .init(x: Double(12 + $0 * 12), y: Double(20 + ($0 % 2) * 24)) }
    }

    func persistentVertexCount(_ ink: CanvasPreparedInk) throws -> Int {
        let snapshot = ink.snapshot()
        guard snapshot.finalizedConfirmedSampleCount > 0 else { return 0 }
        let flattened = try CanvasInkCurve.flattenWithSpanEnds(
            stroke: .init(
                samples: snapshot.confirmed + snapshot.predicted,
                pressureEnabled: snapshot.pressureEnabled
            ),
            maximumError: 0.25
        )
        guard snapshot.finalizedConfirmedSampleCount > 1 else { return 1 }
        return flattened.spanEndVertexIndices[snapshot.finalizedConfirmedSampleCount - 2] + 1
    }

    func coverageSegmentCount(vertexCount: Int) -> Int {
        vertexCount == 0 ? 0 : max(1, vertexCount - 1)
    }

    func segmentCapacity(required: Int) -> Int {
        var capacity = 1
        while capacity < required { capacity *= 2 }
        return capacity
    }

    func geometry(
        id: UUID = UUID(),
        renderKey: CanvasRenderKey? = nil,
        polyline: CanvasPreparedInk,
        style: CanvasStyle = .init(stroke: .black, lineWidth: 6)
    ) -> CanvasPreparedGeometry {
        let resolvedKey = renderKey ?? .preview(id: id, generation: polyline.generation)
        let xs = polyline.points.map(\.x)
        let ys = polyline.points.map(\.y)
        let minimumX = xs.min() ?? 0
        let minimumY = ys.min() ?? 0
        return CanvasPreparedGeometry(
            id: id,
            renderKey: resolvedKey,
            path: .ink(polyline),
            bounds: .init(
                x: minimumX,
                y: minimumY,
                width: (xs.max() ?? minimumX) - minimumX,
                height: (ys.max() ?? minimumY) - minimumY
            ),
            style: style
        )
    }

    func polyline(in geometry: CanvasPreparedGeometry) -> CanvasPreparedInk {
        guard case .ink(let polyline) = geometry.path else {
            preconditionFailure("Expected append-only geometry")
        }
        return polyline
    }

    func mismatchGeometries(
        _ makeMismatches: (CanvasPreparedGeometry, CanvasPreparedGeometry) -> [CanvasPreparedGeometry]
    ) throws -> [CommitPair] {
        let id = UUID()
        let preview = geometry(id: id, polyline: CanvasPreparedInk(points: points(0..<7)))
        let exact = geometry(
            id: id,
            renderKey: .committed(id: id, contentRevision: 1),
            polyline: CanvasPreparedInk(points: polyline(in: preview).points)
        )
        return makeMismatches(preview, exact).map { (preview, $0) }
    }

    func render(
        _ geometry: CanvasPreparedGeometry,
        viewport: CanvasViewport? = nil
    ) throws -> any MTLTexture {
        try render([geometry], viewport: viewport)
    }

    func render(
        _ geometry: [CanvasPreparedGeometry],
        resourceBudgetBytes: Int = CanvasMetalLimits.resourceBudgetBytes,
        viewport: CanvasViewport? = nil
    ) throws -> any MTLTexture {
        let engine = try MetalRenderEngine(
            device: metalDevice(),
            resourceBudgetBytes: resourceBudgetBytes
        )
        return try render(geometry, engine: engine, viewport: viewport)
    }

    func render(
        _ geometry: [CanvasPreparedGeometry],
        engine: MetalRenderEngine,
        viewport: CanvasViewport? = nil
    ) throws -> any MTLTexture {
        let resolvedViewport = viewport ?? self.viewport()
        let scene = scene(geometry, viewport: resolvedViewport)
        let compiled = try MetalSceneCompiler().compile(scene)
        return try engine.renderOffscreen(
            compiled,
            size: .init(width: 128, height: 128),
            displayScale: 1
        )
    }

    func renderPresented(
        _ scene: MetalCompiledScene,
        into output: any MTLTexture,
        size: CGSize = .init(width: 128, height: 128),
        using engine: MetalRenderEngine
    ) throws {
        var submitted: (any MTLCommandBuffer)?
        var completed = false
        try engine.renderPresentedFrame(
            scene,
            into: output,
            size: size,
            displayScale: 1,
            configureBeforeCommit: { submitted = $0 },
            completion: { completed = $0 }
        )
        let commandBuffer = try XCTUnwrap(submitted)
        commandBuffer.waitUntilCompleted()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        XCTAssertEqual(commandBuffer.status, .completed)
        XCTAssertTrue(completed)
    }

    func scene(
        _ geometry: [CanvasPreparedGeometry],
        viewport: CanvasViewport? = nil
    ) -> CanvasPreparedScene {
        CanvasPreparedScene(
            geometry: geometry,
            gridLines: [],
            selectionBounds: nil,
            guides: [],
            viewport: viewport ?? self.viewport(),
            theme: .init(
                background: .init(red: 1, green: 1, blue: 1),
                grid: .black,
                stroke: .black,
                selection: .black,
                guides: .black,
                gridLineWidth: 1,
                selectionLineWidth: 1,
                handleSize: 8
            ),
            previewGeneration: nil
        )
    }

    func presentation(
        committed: [CanvasPreparedGeometry],
        live: [CanvasPreparedGeometry] = [],
        viewport: CanvasViewport? = nil,
        revision: UInt64 = 1
    ) -> CanvasPreparedPresentation {
        CanvasPreparedPresentation(
            scene: scene(committed + live, viewport: viewport),
            textDescriptors: [],
            committed: .init(
                generation: .init(
                    documentRevision: revision,
                    replacementGeneration: .zero
                ),
                items: committed.enumerated().map {
                    .init(
                        documentIndex: $0.offset,
                        geometry: $0.element,
                        paintedBounds: $0.element.bounds
                    )
                },
                replacement: nil
            ),
            viewportRenderPhase: .settled
        )
    }

    func pixel(_ texture: any MTLTexture, x: Int, y: Int) -> [UInt8] {
        var bgra = [UInt8](repeating: 0, count: 4)
        texture.getBytes(
            &bgra,
            bytesPerRow: 4,
            from: MTLRegionMake2D(x, y, 1, 1),
            mipmapLevel: 0
        )
        return [bgra[2], bgra[1], bgra[0], bgra[3]]
    }

    func coverageBytes(_ texture: any MTLTexture) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height)
        texture.getBytes(
            &bytes,
            bytesPerRow: texture.width,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0
        )
        return bytes
    }

    func immutableKey(revision: UInt64) -> MetalResourceKey {
        let id = UUID()
        let geometry = CanvasPreparedGeometry(
            id: id,
            renderKey: .committed(id: id, contentRevision: revision),
            path: .immutable(.init(commands: [])),
            bounds: .init(x: 0, y: 0, width: 0, height: 0),
            style: .default
        )
        return .immutable(
            renderKey: geometry.renderKey,
            resourceIdentity: geometry.resourceIdentity,
            viewportScale: 1
        )
    }

    func bufferResource(device: any MTLDevice, byteCount: Int) throws -> MetalCachedResource {
        let buffer = try XCTUnwrap(device.makeBuffer(length: byteCount, options: .storageModeShared))
        return try MetalCachedResource(buffer: buffer)
    }
}

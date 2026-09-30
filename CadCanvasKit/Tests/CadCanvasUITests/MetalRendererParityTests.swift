import CoreGraphics
import Metal
import UIKit
import XCTest
import CadCanvasCore
@testable import CadCanvasUI

@MainActor
final class MetalRendererParityTests: XCTestCase {
    func testRawVerticalCoverageIsIdenticalWhenDirectionAndEndpointWidthsReverse() throws {
        let harness = MetalParityAcceptanceHarness()
        let downward = try harness.rawCoveragePixels(segment: MetalCoverageSegment(
            start: .init(x: 64, y: 24),
            end: .init(x: 64, y: 104),
            startWidth: 1,
            endWidth: 2
        ))
        let upward = try harness.rawCoveragePixels(segment: MetalCoverageSegment(
            start: .init(x: 64, y: 104),
            end: .init(x: 64, y: 24),
            startWidth: 2,
            endWidth: 1
        ))

        XCTAssertEqual(downward, upward)
    }

    func testBatchedCoverageUsesMaximumBlendForOverlap() throws {
        let harness = MetalParityAcceptanceHarness()
        let segment = MetalCoverageSegment(
            start: .init(x: 24, y: 64),
            end: .init(x: 104, y: 64),
            startWidth: 8,
            endWidth: 8
        )

        XCTAssertEqual(
            try harness.rawCoveragePixels(segment: segment),
            try harness.rawCoveragePixels(segments: [segment, segment])
        )
    }

    func testShortPressureTransitionIsLimitedAndMatchesCoreGraphics() throws {
        try MetalParityAcceptanceHarness().assertLimitedPressureTransitionParity(
            start: .init(x: 60, y: 64),
            end: .init(x: 64, y: 64),
            startPressure: 0,
            endPressure: 1,
            lineWidth: 20,
            fixture: 21
        )
    }

    func testLowPressureVerticalInkMatchesCoreGraphicsAtTwoX() throws {
        try MetalParityAcceptanceHarness().assertLimitedPressureTransitionParity(
            start: .init(x: 64, y: 24),
            end: .init(x: 64, y: 104),
            startPressure: 0,
            endPressure: 0,
            lineWidth: 1,
            displayScale: 2,
            fixture: 23
        )
    }

    func testCoincidentPressureTransitionIsLimitedAndMatchesCoreGraphics() throws {
        try MetalParityAcceptanceHarness().assertLimitedPressureTransitionParity(
            start: .init(x: 64, y: 64),
            end: .init(x: 64, y: 64),
            startPressure: 0,
            endPressure: 1,
            lineWidth: 20,
            fixture: 22
        )
    }

    func testFiniteEndpointsWithOverflowingAxisLengthMatchLargerEndpointCircle() throws {
        try MetalParityAcceptanceHarness().assertRawLargerCircleFallback(
            segment: MetalCoverageSegment(
                start: .init(x: 64, y: 64),
                end: .init(x: 2.0e20, y: 64),
                startWidth: 17.5,
                endWidth: 5
            ),
            expectedCenter: .init(x: 64, y: 64),
            expectedRadius: 8.75
        )
    }

    func testAggressiveUnequalRadiusExternalTangentMatchesCoreGraphics() throws {
        for difference in try MetalParityAcceptanceHarness().aggressiveTaperDifferences() {
            XCTAssertLessThanOrEqual(difference.maximumOutsideEdgeBand, 1)
            XCTAssertLessThanOrEqual(difference.meanChannelInsideEdgeBand, 8)
            XCTAssertLessThanOrEqual(difference.p99ChannelInsideEdgeBand, 32)
            XCTAssertLessThanOrEqual(difference.maximumChannelInsideEdgeBand, 64)
        }
    }

    func testPressureAwareFortyTwoPointFixtureMatchesAtOneTwoAndFourX() throws {
        try MetalParityAcceptanceHarness().assertPressureFixtureParity(scales: [1, 2, 4])
    }

    func testAnalyticInkBandContainsPressureStrokeAtQuantizedScales() throws {
        try MetalParityAcceptanceHarness().assertAnalyticInkBandContainsPressureStroke()
    }

    func testGridParityAtDisplayScalesOneTwoAndThree() throws {
        try MetalParityAcceptanceHarness().assertGridParity(scales: [1, 2, 3])
    }

    func testShapeParityAcrossTransformsOpacityFillAndStroke() throws {
        try MetalParityAcceptanceHarness().assertShapeParity()
    }

    func testWideSelfIntersectingFreehandParity() throws {
        try MetalParityAcceptanceHarness().assertWideFreehandParity(sampleCount: 48_000)
    }

    func testQuadraticCubicAndComplexFillParity() throws {
        try MetalParityAcceptanceHarness().assertComplexPathParity()
    }

    func testOrderingAndFlatColorParity() throws {
        try MetalParityAcceptanceHarness().assertOrderingAndFlatColorParity()
    }

    func testPixelDifferencesOutsideOnePixelEdgeBandAreAtMostOne() throws {
        // The full fixture includes the 48k self-intersection stress stroke. It verifies
        // geometric classification; ordinary and tapered fixtures own edge-distribution QA.
        let difference = try MetalParityAcceptanceHarness().fullFixtureDifference()
        XCTAssertLessThanOrEqual(
            difference.maximumOutsideEdgeBand,
            1,
            difference.outsideMaximumLocation
        )
    }

    func testRepresentativeEdgeBandChannelDistributionMeetsThresholds() throws {
        let difference = try MetalParityAcceptanceHarness().representativeFixtureDifference()
        XCTAssertLessThanOrEqual(difference.meanChannelInsideEdgeBand, 8)
        XCTAssertLessThanOrEqual(difference.p99ChannelInsideEdgeBand, 32)
        XCTAssertLessThanOrEqual(difference.maximumChannelInsideEdgeBand, 64)
    }

    func testFinalActiveAndFirstCommittedMetalFramesArePixelIdentical() throws {
        try MetalParityAcceptanceHarness().assertActiveCommittedIdentity(sampleCount: 48_000)
    }

    func testMetalSchedulerCompositionDoesNotChangeEncodedDocumentOrRecordedSavePayload() throws {
        try MetalParityAcceptanceHarness().assertPersistenceNeutralityThroughSchedulerComposition()
    }

    func testDefaultPerformancePathUsesMetalAndPresentationCallbacks() throws {
        try MetalParityAcceptanceHarness().assertDefaultPerformancePath()
    }
}

@MainActor
private struct MetalParityAcceptanceHarness {
    struct Difference {
        let maximumOutsideEdgeBand: Int
        let maximumOutsideCoreGraphicsEdgeBand: Int
        let meanChannelInsideEdgeBand: Double
        let p99ChannelInsideEdgeBand: Int
        let maximumChannelInsideEdgeBand: Int
        let outsideMaximumLocation: String
    }

    private let size = CGSize(width: 160, height: 128)

    func assertLimitedPressureTransitionParity(
        start: CanvasPoint,
        end: CanvasPoint,
        startPressure: Double,
        endPressure: Double,
        lineWidth: Double,
        displayScale: Double = 1,
        fixture: UInt8
    ) throws {
        let ink = CanvasPreparedInk(
            confirmedSamples: [
                .init(point: start, pressure: startPressure),
                .init(point: end, pressure: endPressure),
            ],
            predictedSamples: [],
            pressureEnabled: true,
            isFinalized: true
        )
        let id = fixtureID(fixture)
        let actualScene = scene(geometry: [CanvasPreparedGeometry(
            id: id,
            renderKey: .committed(id: id, contentRevision: 1),
            path: .ink(ink),
            bounds: .init(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            ),
            style: .init(stroke: .black, lineWidth: lineWidth)
        )])
        let difference = try compare(scene: actualScene, displayScale: displayScale)
        XCTAssertLessThanOrEqual(difference.maximumOutsideEdgeBand, 1)
        XCTAssertLessThanOrEqual(difference.meanChannelInsideEdgeBand, 8)
        XCTAssertLessThanOrEqual(difference.p99ChannelInsideEdgeBand, 32)
        XCTAssertLessThanOrEqual(difference.maximumChannelInsideEdgeBand, 64)
    }

    func assertRawLargerCircleFallback(
        segment: MetalCoverageSegment,
        expectedCenter: CanvasPoint,
        expectedRadius: Double
    ) throws {
        let actual = try rawCoveragePixels(segment: segment)
        let expected = try coreGraphicsCirclePixels(
            center: expectedCenter,
            radius: expectedRadius,
            background: .init(red: 1, green: 1, blue: 1)
        )
        XCTAssertEqual(actual.count, expected.count)

        var maximumOutsideEdge = 0
        var maximumOnEdge = 0
        var outsideLocation = "none"
        for offset in actual.indices {
            let x = Double(offset % Int(size.width)) + 0.5
            let y = Double(offset / Int(size.width)) + 0.5
            let signedDistance = hypot(x - expectedCenter.x, y - expectedCenter.y)
                - expectedRadius
            let expectedCoverage = 255 - Int(expected[offset][0])
            let difference = abs(Int(actual[offset]) - expectedCoverage)
            if abs(signedDistance) <= 1 {
                maximumOnEdge = max(maximumOnEdge, difference)
            } else if difference > maximumOutsideEdge {
                maximumOutsideEdge = difference
                outsideLocation = "x=\(Int(x)),y=\(Int(y)),actual=\(actual[offset]),expected=\(expectedCoverage)"
            }
        }
        XCTAssertLessThanOrEqual(maximumOutsideEdge, 1, outsideLocation)
        XCTAssertLessThanOrEqual(maximumOnEdge, 64)
        let probe = Int(size.width) * Int(expectedCenter.y) + Int(expectedCenter.x)
        XCTAssertGreaterThan(255 - Int(expected[probe][0]), 239, "The Core Graphics oracle cap must be visible")
        XCTAssertGreaterThan(actual[probe], 239, "The raw Metal larger cap must be visible")
    }

    func assertGridParity(scales: [Double]) throws {
        for scale in scales {
            let difference = try compare(scene: gridScene(), displayScale: scale)
            XCTAssertLessThanOrEqual(difference.maximumOutsideEdgeBand, 1)
            XCTAssertLessThanOrEqual(difference.meanChannelInsideEdgeBand, 8)
            XCTAssertLessThanOrEqual(difference.p99ChannelInsideEdgeBand, 32)
            XCTAssertLessThanOrEqual(difference.maximumChannelInsideEdgeBand, 64)
        }
    }

    func assertShapeParity() throws {
        let difference = try compare(scene: shapeScene(), displayScale: 2)
        XCTAssertLessThanOrEqual(
            difference.maximumOutsideEdgeBand,
            1,
            difference.outsideMaximumLocation
        )
        XCTAssertLessThanOrEqual(difference.meanChannelInsideEdgeBand, 8)
        XCTAssertLessThanOrEqual(difference.p99ChannelInsideEdgeBand, 32)
        XCTAssertLessThanOrEqual(difference.maximumChannelInsideEdgeBand, 64)
    }

    func aggressiveTaperDifferences() throws -> [Difference] {
        let ink = CanvasPreparedInk(
            confirmedSamples: [
                .init(point: .init(x: 20, y: 30), pressure: 0),
                .init(point: .init(x: 60, y: 30), pressure: 1),
            ],
            predictedSamples: [],
            pressureEnabled: true,
            isFinalized: true
        )
        let id = fixtureID(18)
        let fixture = scene(geometry: [CanvasPreparedGeometry(
            id: id,
            renderKey: .committed(id: id, contentRevision: 1),
            path: .ink(ink),
            bounds: .init(x: 20, y: 30, width: 40, height: 0),
            style: .init(stroke: .black, lineWidth: 20)
        )])
        return try [false, true].map {
            try compare(scene: fixture, displayScale: 4, transparentBackground: $0)
        }
    }

    func assertPressureFixtureParity(scales: [Double]) throws {
        let fixture = pressureFixtureScene()
        for scale in scales {
            for transparentBackground in [false, true] {
                let difference = try compare(
                    scene: fixture,
                    displayScale: scale,
                    transparentBackground: transparentBackground
                )
                XCTAssertLessThanOrEqual(difference.maximumOutsideEdgeBand, 1)
                XCTAssertLessThanOrEqual(difference.meanChannelInsideEdgeBand, 8)
                XCTAssertLessThanOrEqual(difference.p99ChannelInsideEdgeBand, 32)
                XCTAssertLessThanOrEqual(difference.maximumChannelInsideEdgeBand, 64)
            }
        }
    }

    func pressureFixtureScene() -> CanvasPreparedScene {
        var samples: [CanvasInkSample] = []
        samples.reserveCapacity(42)
        for index in 0..<42 {
            let x = 12 + Double(index) * 3.2
            let y = 62
                + sin(Double(index) * 0.58) * 28
                + cos(Double(index) * 0.19) * 8
            let pressure = Double((index * 17) % 41) / 40
            samples.append(CanvasInkSample(
                point: .init(
                    x: x,
                    y: y
                ),
                pressure: pressure
            ))
        }
        let ink = CanvasPreparedInk(
            confirmedSamples: samples,
            predictedSamples: [],
            pressureEnabled: true,
            isFinalized: true
        )
        let id = fixtureID(19)
        let geometry = CanvasPreparedGeometry(
            id: id,
            renderKey: .committed(id: id, contentRevision: 1),
            path: .ink(ink),
            bounds: pointsBounds(samples.map { $0.point }),
            style: .init(
                stroke: .init(red: 0.1, green: 0.28, blue: 0.76, alpha: 0.62),
                lineWidth: 13
            )
        )
        return scene(geometry: [geometry])
    }

    func assertAnalyticInkBandContainsPressureStroke() throws {
        let fixture = pressureFixtureScene()
        for scale in [2.0, 4.0] {
            let difference = try compare(scene: fixture, displayScale: scale)
            XCTAssertLessThanOrEqual(difference.maximumOutsideEdgeBand, 1)
        }
    }

    func assertWideFreehandParity(sampleCount: Int) throws {
        let fixture = freehandScene(sampleCount: sampleCount)
        guard case .ink(let polyline) = fixture.geometry[0].path else {
            return XCTFail("Expected the acceptance stroke to use append-only storage")
        }
        XCTAssertEqual(polyline.points.count, sampleCount)
        let difference = try compare(scene: fixture, displayScale: 2)
        // This stress fixture owns union geometry and scale behavior, not the handwriting
        // AA distribution contract exercised by the pressure and representative fixtures.
        XCTAssertLessThanOrEqual(
            difference.maximumOutsideEdgeBand,
            1,
            difference.outsideMaximumLocation
        )
    }

    func assertComplexPathParity() throws {
        let scene = complexScene()
        let compiled = try MetalSceneCompiler().compile(scene)
        XCTAssertTrue(compiled.renderItems.allSatisfy {
            if case .fallback = $0 { true } else { false }
        })
        let difference = try compare(scene: scene, displayScale: 2)
        XCTAssertLessThanOrEqual(difference.maximumOutsideEdgeBand, 1)
        XCTAssertLessThanOrEqual(difference.meanChannelInsideEdgeBand, 8)
        XCTAssertLessThanOrEqual(difference.p99ChannelInsideEdgeBand, 32)
        XCTAssertLessThanOrEqual(difference.maximumChannelInsideEdgeBand, 64)
    }

    func assertOrderingAndFlatColorParity() throws {
        let scene = orderingScene()
        let actual = try metalPixels(scene: scene, displayScale: 2)
        let expected = try referencePixels(scene: scene, displayScale: 2)
        XCTAssertEqual(actual.count, expected.count)
        for point in [CGPoint(x: 32, y: 32), CGPoint(x: 64, y: 54), CGPoint(x: 92, y: 74)] {
            let x = Int(point.x * 2)
            let y = Int(point.y * 2)
            let offset = y * Int(size.width * 2) + x
            for channel in 0..<4 {
                XCTAssertLessThanOrEqual(
                    abs(Int(actual[offset][channel]) - Int(expected[offset][channel])),
                    1
                )
            }
        }
        let difference = try compare(scene: scene, displayScale: 2)
        XCTAssertLessThanOrEqual(difference.maximumOutsideEdgeBand, 1)
    }

    func fullFixtureDifference() throws -> Difference {
        let scene = fullScene(sampleCount: 48_000)
        guard case .ink(let polyline) = scene.geometry.last?.path else {
            throw HarnessError.missingFreehand
        }
        XCTAssertEqual(polyline.points.count, 48_000)
        XCTAssertNotNil(scene.selectionBounds)
        XCTAssertFalse(scene.guides.isEmpty)
        XCTAssertFalse(scene.gridLines.isEmpty)
        return try compare(scene: scene, displayScale: 2)
    }

    func representativeFixtureDifference() throws -> Difference {
        let shapes = shapeScene().geometry
        return try compare(
            scene: scene(
                geometry: shapes + complexScene().geometry,
                gridLines: gridScene().gridLines,
                selectionBounds: shapes[0].bounds,
                guides: [.vertical(canvasX: 80), .horizontal(canvasY: 64)]
            ),
            displayScale: 2
        )
    }

    func assertActiveCommittedIdentity(sampleCount: Int) throws {
        let points = acceptancePoints(count: sampleCount)
        let polyline = CanvasPreparedInk(points: points)
        let identifier = fixtureID(90)
        let style = CanvasStyle(
            stroke: .init(red: 0.14, green: 0.36, blue: 0.82, alpha: 0.72),
            lineWidth: 5
        )
        let bounds = pointsBounds(points)
        let active = CanvasPreparedGeometry(
            id: identifier,
            renderKey: .preview(id: identifier, generation: polyline.generation),
            path: .ink(polyline),
            bounds: bounds,
            style: style
        )
        let committed = CanvasPreparedGeometry(
            id: identifier,
            renderKey: .committed(id: identifier, contentRevision: 1),
            path: .ink(CanvasPreparedInk(
                confirmedSamples: points.map { .init(point: $0, pressure: 1) },
                pressureEnabled: false
            )),
            bounds: bounds,
            style: style
        )
        let activeScene = scene(geometry: [active], previewGeneration: polyline.generation)
        let committedScene = scene(geometry: [committed])
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let engine = try MetalRenderEngine(device: device)
        let compiler = MetalSceneCompiler()
        let activeBytes = try presentedPixels(
            compiler.compile(activeScene),
            engine: engine,
            device: device,
            displayScale: 2
        )
        XCTAssertTrue(engine.hasActiveFreehandCoverage)
        XCTAssertEqual(engine.derivedFreehandResourceCount, 1)
        let committedBytes = try presentedPixels(
            compiler.compile(committedScene),
            engine: engine,
            device: device,
            displayScale: 2
        )
        XCTAssertEqual(activeBytes, committedBytes)
        XCTAssertFalse(engine.hasActiveFreehandCoverage)
        XCTAssertEqual(engine.derivedFreehandResourceCount, 1)
        XCTAssertEqual(engine.freehandCommitReuseCount, 1)
        XCTAssertEqual(engine.transientCoverageAllocationCount, 1)
        XCTAssertLessThanOrEqual(
            engine.maximumOwnedCoverageByteCount,
            CanvasMetalLimits.resourceBudgetBytes
        )
    }

    func assertPersistenceNeutralityThroughSchedulerComposition() throws {
        let document = persistenceDocument(sampleCount: 48_000)
        let session = try CanvasSession(document: document, viewport: viewport())
        let before = try CanvasDocumentCodec.encode(session.document)
        let draft = CanvasFreehandDraft(
            id: fixtureID(104),
            style: .init(stroke: .black, lineWidth: 3),
            pressureEnabled: true
        )
        draft.append([
            .init(point: .init(x: 12, y: 18), pressure: 0.2),
            .init(point: .init(x: 28, y: 34), pressure: 0.8),
        ])
        let token = try session.acquirePreview(.freehand(elementID: draft.id))
        try session.appendFreehandInkPreview(
            id: draft.id,
            style: draft.style,
            confirmed: draft.samples,
            predicted: [.init(point: .init(x: 40, y: 46), pressure: 1)],
            pressureEnabled: draft.pressureEnabled,
            token: token
        )
        let preview = CanvasRenderPreview(session.preview)
        let prepared = try CanvasScenePreparer().prepare(
            document: session.document,
            preview: preview,
            viewport: session.viewport,
            selectedElementID: document.elements.first?.id,
            editingTextIDs: [],
            guides: [.vertical(canvasX: 80), .horizontal(canvasY: 64)],
            gridSpacing: 16,
            theme: CanvasTheme.default.renderSnapshot
        )
        XCTAssertEqual(prepared.textDescriptors.count, 1)
        XCTAssertEqual(prepared.scene.previewGeneration, preview?.generation)

        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let frameDriver = SchedulerCompositionFrameDriver()
        let scheduler = MetalFrameScheduler(driver: frameDriver, maximumInFlight: 1)
        let renderer = try MetalCanvasRenderer(
            device: device,
            schedulerFactory: { scheduler }
        )
        var presentationCount = 0
        var presentedGeneration: RecognitionGeneration?
        let renderView = try XCTUnwrap(renderer.makeRenderView { generation, _ in
            presentationCount += 1
            presentedGeneration = generation
        } as? MetalCanvasRenderView)
        renderer.update(prepared, in: renderView)
        XCTAssertEqual(try CanvasDocumentCodec.encode(session.document), before)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(size.width),
            height: Int(size.height),
            mipmapped: false
        )
        descriptor.usage = .renderTarget
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        scheduler.displayLinkDidUpdate(
            with: MetalDisplayLinkDrawable(
                nativeDrawable: NSObject(),
                texture: texture,
                callbackTimestamp: 10,
                targetTimestamp: 10.01,
                targetPresentationTimestamp: 10.02,
                present: { _ in }
            ),
            from: renderView
        )
        XCTAssertEqual(frameDriver.submissionCount, 1)
        XCTAssertEqual(
            frameDriver.submittedScene?.committedItems.map(\.documentIndex),
            prepared.committed.items.map(\.documentIndex)
        )
        XCTAssertEqual(
            frameDriver.submittedScene?.committedGeneration,
            prepared.committed.generation
        )
        XCTAssertEqual(frameDriver.submittedScene?.liveItems.count, 1)
        XCTAssertEqual(presentationCount, 0)
        frameDriver.completeSubmission()
        frameDriver.reportComposedPresentation(at: 10.02)
        XCTAssertEqual(presentationCount, 1)
        XCTAssertEqual(presentedGeneration, prepared.scene.previewGeneration)

        let saveSink = RecordingSaveSink()
        let afterComposition = try CanvasDocumentCodec.encode(session.document)
        saveSink.save(afterComposition)
        XCTAssertEqual(afterComposition, before)
        XCTAssertEqual(saveSink.payloads, [before])
        let decoded = try CanvasDocumentCodec.decode(afterComposition)
        XCTAssertEqual(decoded.id, document.id)
        let savedModes = decoded.elements.compactMap { element -> CanvasInkWidthMode? in
            guard case .freehand(let stroke) = element.geometry else { return nil }
            return stroke.widthMode
        }
        XCTAssertTrue(savedModes.contains(.screenConstant))
        renderer.dismantleRenderView(renderView)
    }

    func assertDefaultPerformancePath() throws {
        let session = CanvasSession(viewport: viewport())
        let drawView = CadCanvasView(session: session, recognizer: nil)
        let configuredRenderer = Mirror(reflecting: drawView).children.first {
            $0.label == "renderer"
        }?.value
        let renderer = try XCTUnwrap(configuredRenderer as? AdaptiveCanvasRenderer)

        let coordinator = CadCanvasCoordinator(
            session: session,
            recognizer: nil,
            renderer: renderer,
            theme: .default
        )
        let host = coordinator.makeHostView()
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutIfNeeded()
        XCTAssertTrue(descendants(of: host.renderView).contains { $0 is MetalCanvasRenderView })
        XCTAssertTrue(descendants(of: host.renderView).contains { $0 is CanvasRenderView })

        let probe = PresentedHandlerProbe()
        var presentationCount = 0
        var observedPresentedTime: TimeInterval?
        try MetalDrawablePresentationRegistration.register(
            on: probe,
            presentedTime: { ($0 as? PresentedHandlerProbe)?.presentedTime ?? 0 }
        ) { presentedTime in
            presentationCount += 1
            observedPresentedTime = presentedTime
        }
        probe.present()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        XCTAssertEqual(probe.registrationCount, 1)
        XCTAssertEqual(presentationCount, 1)
        XCTAssertEqual(observedPresentedTime, probe.presentedTime)
        coordinator.dismantle()

        let lifecycleDriver = LifecycleFrameDriver()
        let lifecycleScheduler = MetalFrameScheduler(driver: lifecycleDriver)
        let lifecycleRenderer = try MetalCanvasRenderer(
            device: try XCTUnwrap(MTLCreateSystemDefaultDevice()),
            schedulerFactory: { lifecycleScheduler }
        )
        var lifecycleView: UIView? = lifecycleRenderer.makeRenderView { _, _ in }
        weak var releasedLifecycleView: UIView?
        releasedLifecycleView = lifecycleView
        lifecycleRenderer.dismantleRenderView(try XCTUnwrap(lifecycleView))
        lifecycleView = nil

        XCTAssertNil(releasedLifecycleView)
        XCTAssertEqual(lifecycleDriver.cacheResetCount, 1)
    }
}

@MainActor
private extension MetalParityAcceptanceHarness {
    enum HarnessError: Error {
        case missingReferenceImage
        case missingFreehand
    }

    final class PresentedHandlerProbe: NSObject {
        private var handler: ((AnyObject) -> Void)?
        private(set) var registrationCount = 0
        let presentedTime: TimeInterval = 73.5

        @objc(addPresentedHandler:)
        func addPresentedHandler(_ handler: @escaping (AnyObject) -> Void) {
            registrationCount += 1
            self.handler = handler
        }

        func present() {
            handler?(self)
        }
    }

    final class LifecycleFrameDriver: MetalFrameDriving {
        private(set) var cacheResetCount = 0

        func submit(
            _: MetalCompiledScene,
            drawable _: MetalDisplayLinkDrawable,
            displayScale _: Double,
            completion _: @escaping @MainActor (MetalFrameCommandResult) -> Void,
            presentation _: @escaping @MainActor (MetalNativePresentationEvent) -> Void
        ) throws {}

        func invalidateSizeDependentResources() {}

        func resetDerivedRenderCaches() {
            cacheResetCount += 1
        }
    }

    final class SchedulerCompositionFrameDriver: MetalFrameDriving {
        private var completion: (@MainActor (MetalFrameCommandResult) -> Void)?
        private var presentation: (@MainActor (MetalNativePresentationEvent) -> Void)?
        private(set) var submissionCount = 0
        private(set) var submittedScene: MetalCompiledScene?

        func submit(
            _ scene: MetalCompiledScene,
            drawable _: MetalDisplayLinkDrawable,
            displayScale _: Double,
            completion: @escaping @MainActor (MetalFrameCommandResult) -> Void,
            presentation: @escaping @MainActor (MetalNativePresentationEvent) -> Void
        ) throws {
            submissionCount += 1
            submittedScene = scene
            self.completion = completion
            self.presentation = presentation
        }

        func completeSubmission() {
            completion?(.completed)
        }

        func reportComposedPresentation(at time: TimeInterval) {
            presentation?(.init(presentedTime: time, isNativePresentation: true))
        }

        func invalidateSizeDependentResources() {}
    }

    final class RecordingSaveSink {
        private(set) var payloads: [Data] = []

        func save(_ payload: Data) {
            payloads.append(payload)
        }
    }

    func descendants(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    func fixtureID(_ value: UInt8) -> UUID {
        UUID(uuid: (0x4d, 0x45, 0x54, 0x41, 0x50, 0x41, 0x52, 0x49,
                    0x54, 0x59, 0, 0, 0, 0, 0, value))
    }

    func viewport() -> CanvasViewport {
        try! CanvasViewport(
            zoom: 1.25,
            translation: .init(x: 7.25, y: -4.5),
            viewportSize: .init(width: size.width, height: size.height)
        )
    }

    func theme(background: CanvasColor = .init(red: 0.96, green: 0.97, blue: 0.98)) -> CanvasThemeSnapshot {
        .init(
            background: background,
            grid: .init(red: 0.72, green: 0.75, blue: 0.8),
            stroke: .black,
            selection: .init(red: 0.04, green: 0.42, blue: 0.96),
            guides: .init(red: 0.96, green: 0.22, blue: 0.18),
            gridLineWidth: 1,
            selectionLineWidth: 2,
            handleSize: 7
        )
    }

    func scene(
        geometry: [CanvasPreparedGeometry],
        gridLines: [CanvasPreparedGridLine] = [],
        selectionBounds: CanvasRect? = nil,
        guides: [SnapGuide] = [],
        background: CanvasColor = .init(red: 0.96, green: 0.97, blue: 0.98),
        previewGeneration: RecognitionGeneration? = nil
    ) -> CanvasPreparedScene {
        CanvasPreparedScene(
            geometry: geometry,
            gridLines: gridLines,
            selectionBounds: selectionBounds,
            guides: guides,
            viewport: viewport(),
            theme: theme(background: background),
            previewGeneration: previewGeneration
        )
    }

    func immutable(
        id: UInt8,
        path: CanvasPath,
        style: CanvasStyle
    ) -> CanvasPreparedGeometry {
        let identifier = fixtureID(id)
        return CanvasPreparedGeometry(
            id: identifier,
            renderKey: .committed(id: identifier, contentRevision: 0),
            path: .immutable(path),
            bounds: path.bounds,
            style: style
        )
    }

    func gridScene() -> CanvasPreparedScene {
        let values = stride(from: -16.0, through: 176.0, by: 16.0)
        let lines = values.flatMap { value in
            [
                CanvasPreparedGridLine(start: .init(x: value, y: -16), end: .init(x: value, y: 144)),
                CanvasPreparedGridLine(start: .init(x: -16, y: value), end: .init(x: 176, y: value)),
            ]
        }
        return scene(geometry: [], gridLines: lines)
    }

    func shapeScene() -> CanvasPreparedScene {
        let rectangle = CanvasGeometry.rectangle(.init(rect: .init(x: 18, y: 18, width: 48, height: 34))).renderPath
        let line = CanvasPath(commands: [.move(.init(x: 12, y: 92)), .line(.init(x: 132, y: 28))])
        let arch = CanvasGeometry.arch(.init(
            start: .init(x: 76, y: 92),
            end: .init(x: 138, y: 98),
            sagitta: -24
        )).renderPath
        return scene(geometry: [
            immutable(id: 1, path: rectangle, style: .init(
                stroke: .init(red: 0.12, green: 0.3, blue: 0.78, alpha: 0.82),
                fill: .init(red: 0.18, green: 0.7, blue: 0.42, alpha: 0.46),
                lineWidth: 3.5
            )),
            immutable(id: 2, path: line, style: .init(
                stroke: .init(red: 0.86, green: 0.18, blue: 0.16, alpha: 0.64),
                lineWidth: 5
            )),
            immutable(id: 3, path: arch, style: .init(
                stroke: .init(red: 0.56, green: 0.18, blue: 0.82, alpha: 0.72),
                lineWidth: 4
            )),
        ])
    }

    func complexScene() -> CanvasPreparedScene {
        let complex = CanvasPath(commands: [
            .move(.init(x: 20, y: 28)),
            .quad(control: .init(x: 42, y: 4), end: .init(x: 66, y: 30)),
            .cubic(
                control1: .init(x: 98, y: 4),
                control2: .init(x: 142, y: 28),
                end: .init(x: 112, y: 62)
            ),
            .line(.init(x: 132, y: 106)),
            .line(.init(x: 72, y: 82)),
            .line(.init(x: 20, y: 108)),
            .line(.init(x: 48, y: 62)),
            .close,
            .move(.init(x: 54, y: 40)),
            .cubic(
                control1: .init(x: 82, y: 68),
                control2: .init(x: 94, y: 8),
                end: .init(x: 116, y: 44)
            ),
            .line(.init(x: 72, y: 72)),
            .close,
        ])
        return scene(geometry: [immutable(id: 4, path: complex, style: .init(
            stroke: .init(red: 0.72, green: 0.12, blue: 0.22, alpha: 0.78),
            fill: .init(red: 0.16, green: 0.58, blue: 0.86, alpha: 0.52),
            lineWidth: 4
        ))])
    }

    func orderingScene() -> CanvasPreparedScene {
        func rectangle(_ id: UInt8, _ rect: CanvasRect, _ color: CanvasColor) -> CanvasPreparedGeometry {
            immutable(
                id: id,
                path: CanvasGeometry.rectangle(.init(rect: rect)).renderPath,
                style: .init(stroke: color, fill: color, lineWidth: 0.25)
            )
        }
        return scene(
            geometry: [
                rectangle(10, .init(x: 12, y: 12, width: 96, height: 82), .init(red: 0.9, green: 0.16, blue: 0.12)),
                rectangle(11, .init(x: 42, y: 30, width: 96, height: 76), .init(red: 0.12, green: 0.72, blue: 0.24)),
                rectangle(12, .init(x: 70, y: 52, width: 66, height: 58), .init(red: 0.14, green: 0.3, blue: 0.9)),
            ],
            background: .init(red: 0.08, green: 0.1, blue: 0.14)
        )
    }

    func acceptancePoints(count: Int) -> [CanvasPoint] {
        let anchors = [
            CanvasPoint(x: -80, y: -80),
            CanvasPoint(x: 220, y: 180),
            CanvasPoint(x: -80, y: 180),
            CanvasPoint(x: 220, y: -80),
        ]
        return (0..<count).map { index in
            let progress = count > 1
                ? Double(index) / Double(count - 1) * Double(anchors.count - 1)
                : 0
            let segment = min(anchors.count - 2, Int(floor(progress)))
            let t = progress - Double(segment)
            let start = anchors[segment]
            let end = anchors[segment + 1]
            return CanvasPoint(
                x: start.x + (end.x - start.x) * t,
                y: start.y + (end.y - start.y) * t
            )
        }
    }

    func pointsBounds(_ points: [CanvasPoint]) -> CanvasRect {
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        let minX = xs.min() ?? 0
        let minY = ys.min() ?? 0
        return .init(
            x: minX,
            y: minY,
            width: (xs.max() ?? minX) - minX,
            height: (ys.max() ?? minY) - minY
        )
    }

    func freehandScene(sampleCount: Int) -> CanvasPreparedScene {
        let points = acceptancePoints(count: sampleCount)
        let polyline = CanvasPreparedInk(points: points)
        let identifier = fixtureID(20)
        return scene(
            geometry: [CanvasPreparedGeometry(
                id: identifier,
                renderKey: .preview(id: identifier, generation: polyline.generation),
                path: .ink(polyline),
                bounds: pointsBounds(points),
                style: .init(
                    stroke: .init(red: 0.18, green: 0.38, blue: 0.88),
                    lineWidth: 7
                )
            )],
            previewGeneration: polyline.generation
        )
    }

    func fullScene(sampleCount: Int) -> CanvasPreparedScene {
        let shapes = shapeScene().geometry
        let complex = complexScene().geometry
        let freehand = freehandScene(sampleCount: sampleCount).geometry
        return scene(
            geometry: shapes + complex + freehand,
            gridLines: gridScene().gridLines,
            selectionBounds: shapes[0].bounds,
            guides: [.vertical(canvasX: 80), .horizontal(canvasY: 64)],
            previewGeneration: freehandScene(sampleCount: 2).previewGeneration
        )
    }

    func persistenceDocument(sampleCount: Int) -> CanvasDocument {
        let points = acceptancePoints(count: sampleCount)
        return CanvasDocument(
            id: fixtureID(100),
            revision: 7,
            elements: [
                CanvasElement.rectangle(
                    id: fixtureID(101),
                    rect: .init(x: 18, y: 18, width: 48, height: 34),
                    style: .init(
                        stroke: .black,
                        fill: .init(red: 1, green: 1, blue: 1),
                        lineWidth: 3
                    )
                ),
                CanvasElement(
                    id: fixtureID(102),
                    geometry: .freehand(CanvasInkStroke(
                        samples: points.map { .init(point: $0, pressure: 1) },
                        pressureEnabled: true,
                        widthMode: .screenConstant
                    )),
                    style: .init(stroke: .black, lineWidth: 5)
                ),
                CanvasElement(
                    id: fixtureID(103),
                    geometry: .text(.init(
                        frame: .init(x: 72, y: 20, width: 70, height: 42),
                        text: "Remote quote fixture wraps",
                        font: .init(familyName: "Helvetica", pointSize: 15),
                        color: .black
                    ))
                ),
            ],
            calibration: .init(millimetersPerPoint: 0.42)
        )
    }

    func compare(
        scene: CanvasPreparedScene,
        displayScale: Double,
        transparentBackground: Bool = false
    ) throws -> Difference {
        var comparisonScene = scene
        if transparentBackground {
            var transparentTheme = scene.theme
            transparentTheme.background = .init(red: 0, green: 0, blue: 0, alpha: 0)
            comparisonScene = CanvasPreparedScene(
                geometry: scene.geometry,
                gridLines: scene.gridLines,
                selectionBounds: scene.selectionBounds,
                guides: scene.guides,
                viewport: scene.viewport,
                theme: transparentTheme,
                previewGeneration: scene.previewGeneration
            )
        }
        let actual = try metalPixels(scene: comparisonScene, displayScale: displayScale)
        let expected = try referencePixels(scene: comparisonScene, displayScale: displayScale)
        XCTAssertEqual(actual.count, expected.count)
        let width = Int(ceil(size.width * displayScale))
        let height = Int(ceil(size.height * displayScale))
        let coreGraphicsEdgeBand = try geometricEdgeBand(
            scene: comparisonScene,
            width: width,
            height: height,
            displayScale: displayScale
        )
        var edgeBand = coreGraphicsEdgeBand
        try addAnalyticInkEdgeBand(
            scene: comparisonScene,
            width: width,
            height: height,
            displayScale: displayScale,
            to: &edgeBand
        )
        var outsideMaximum = 0
        var coreGraphicsOutsideMaximum = 0
        var edgeChannelSum = 0
        var edgeChannelMaximum = 0
        var edgeChannelDifferences: [Int] = []
        var edgeCount = 0
        var outsideLocation = "none"
        for offset in actual.indices {
            if edgeBand[offset] {
                let channelMaximum = (0..<4).reduce(into: 0) { maximum, channel in
                    maximum = max(
                        maximum,
                        abs(Int(actual[offset][channel]) - Int(expected[offset][channel]))
                    )
                }
                edgeChannelSum += channelMaximum
                edgeChannelMaximum = max(edgeChannelMaximum, channelMaximum)
                edgeChannelDifferences.append(channelMaximum)
                edgeCount += 1
            } else {
                for channel in 0..<4 {
                    let difference = abs(Int(actual[offset][channel]) - Int(expected[offset][channel]))
                    if difference > outsideMaximum {
                        outsideMaximum = difference
                        outsideLocation = "x=\(offset % width),y=\(offset / width),channel=\(channel),actual=\(actual[offset]),expected=\(expected[offset])"
                    }
                }
            }
            if !coreGraphicsEdgeBand[offset] {
                for channel in 0..<4 {
                    coreGraphicsOutsideMaximum = max(
                        coreGraphicsOutsideMaximum,
                        abs(Int(actual[offset][channel]) - Int(expected[offset][channel]))
                    )
                }
            }
        }
        if outsideMaximum > 1 {
            print("Metal parity outside-band maximum \(outsideMaximum): \(outsideLocation)")
        }
        edgeChannelDifferences.sort()
        let p99Index = max(
            0,
            min(
                edgeChannelDifferences.count - 1,
                Int(ceil(Double(edgeChannelDifferences.count) * 0.99)) - 1
            )
        )
        return Difference(
            maximumOutsideEdgeBand: outsideMaximum,
            maximumOutsideCoreGraphicsEdgeBand: coreGraphicsOutsideMaximum,
            meanChannelInsideEdgeBand: Double(edgeChannelSum) / Double(max(1, edgeCount)),
            p99ChannelInsideEdgeBand: edgeChannelDifferences.isEmpty
                ? 0
                : edgeChannelDifferences[p99Index],
            maximumChannelInsideEdgeBand: edgeChannelMaximum,
            outsideMaximumLocation: outsideLocation
        )
    }

    func metalPixels(scene: CanvasPreparedScene, displayScale: Double) throws -> [[UInt8]] {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let engine = try MetalRenderEngine(device: device)
        let result = try presentedPixels(
            MetalSceneCompiler().compile(scene),
            engine: engine,
            device: device,
            displayScale: displayScale
        )
        XCTAssertLessThanOrEqual(
            engine.maximumOwnedCoverageByteCount,
            CanvasMetalLimits.resourceBudgetBytes
        )
        return result
    }

    func presentedPixels(
        _ scene: MetalCompiledScene,
        engine: MetalRenderEngine,
        device: any MTLDevice,
        displayScale: Double
    ) throws -> [[UInt8]] {
        let width = Int(size.width * displayScale)
        let height = Int(size.height * displayScale)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var submittedCommandBuffer: (any MTLCommandBuffer)?
        var completedSuccessfully: Bool?
        try engine.renderPresentedFrame(
            scene,
            into: texture,
            size: size,
            displayScale: displayScale,
            configureBeforeCommit: { submittedCommandBuffer = $0 },
            completion: { completedSuccessfully = $0 }
        )
        let commandBuffer = try XCTUnwrap(submittedCommandBuffer)
        commandBuffer.waitUntilCompleted()
        let deadline = Date(timeIntervalSinceNow: 1)
        while completedSuccessfully == nil, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001))
        }
        XCTAssertEqual(commandBuffer.status, .completed)
        XCTAssertEqual(completedSuccessfully, true)
        return pixels(texture)
    }

    func referencePixels(scene: CanvasPreparedScene, displayScale: Double) throws -> [[UInt8]] {
        let image = try XCTUnwrap(CoreGraphicsCanvasRenderer().makeBitmap(
            scene: scene,
            bounds: CGRect(origin: .zero, size: size),
            displayScale: displayScale
        ))
        return pixels(image)
    }

    func coreGraphicsCirclePixels(
        center: CanvasPoint,
        radius: Double,
        background: CanvasColor
    ) throws -> [[UInt8]] {
        let width = Int(size.width)
        let height = Int(size.height)
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            components: [background.red, background.green, background.blue, background.alpha]
        ) ?? UIColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fillEllipse(in: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        return pixels(try XCTUnwrap(context.makeImage()))
    }

    func rawCoveragePixels(segment: MetalCoverageSegment) throws -> [UInt8] {
        try rawCoveragePixels(segments: [segment])
    }

    func rawCoveragePixels(segments: [MetalCoverageSegment]) throws -> [UInt8] {
        XCTAssertFalse(segments.isEmpty)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: Int(size.width),
            height: Int(size.height),
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = .init(red: 0, green: 0, blue: 0, alpha: 0)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commandBuffer.makeRenderCommandEncoder(descriptor: pass))
        encoder.setRenderPipelineState(try MetalPipelineLibrary(device: device).coverageSegment)
        let segmentBuffer = try XCTUnwrap(segments.withUnsafeBytes { bytes in
            device.makeBuffer(
                bytes: try XCTUnwrap(bytes.baseAddress),
                length: bytes.count,
                options: .storageModeShared
            )
        })
        var uniforms = MetalCanvasUniforms(
            viewportSize: SIMD2(Float(texture.width), Float(texture.height)),
            inverseViewportSize: SIMD2(1 / Float(texture.width), 1 / Float(texture.height))
        )
        encoder.setVertexBuffer(segmentBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(
            &uniforms,
            length: MemoryLayout<MetalCanvasUniforms>.stride,
            index: 1
        )
        encoder.setFragmentBuffer(segmentBuffer, offset: 0, index: 0)
        encoder.drawPrimitives(
            type: .triangleStrip,
            vertexStart: 0,
            vertexCount: 4,
            instanceCount: segments.count
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed)

        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height)
        texture.getBytes(
            &bytes,
            bytesPerRow: texture.width,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0
        )
        return bytes
    }

    func pixels(_ texture: any MTLTexture) -> [[UInt8]] {
        let bytesPerRow = texture.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        texture.getBytes(
            &bytes,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0
        )
        return stride(from: 0, to: bytes.count, by: 4).map {
            [bytes[$0 + 2], bytes[$0 + 1], bytes[$0], bytes[$0 + 3]]
        }
    }

    func pixels(_ image: CGImage) -> [[UInt8]] {
        let bytesPerRow = image.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * image.height)
        let context = CGContext(
            data: &bytes,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return stride(from: 0, to: bytes.count, by: 4).map {
            Array(bytes[$0..<($0 + 4)])
        }
    }
}

@MainActor
private extension MetalParityAcceptanceHarness {
    struct AnalyticCoverageSegment {
        let startX: Double
        let startY: Double
        let endX: Double
        let endY: Double
        let startRadius: Double
        let endRadius: Double
    }

    func geometricEdgeBand(
        scene: CanvasPreparedScene,
        width: Int,
        height: Int,
        displayScale: Double
    ) throws -> [Bool] {
        let maskScale = 4
        let maskWidth = width * maskScale
        let maskHeight = height * maskScale
        var result = [Bool](repeating: false, count: width * height)
        let commands = CoreGraphicsCanvasRenderer().renderCommands(
            scene: scene,
            bounds: CGRect(origin: .zero, size: size),
            displayScale: displayScale
        )
        for command in commands {
            guard case .background = command else {
                let modes: [ElementMaskMode]
                if case .element(_, _, _, let fill, _) = command, fill != nil {
                    modes = [.fill, .stroke]
                } else {
                    modes = [.combined]
                }
                for mode in modes {
                    let mask = try commandMask(
                        command,
                        scene: scene,
                        width: maskWidth,
                        height: maskHeight,
                        displayScale: displayScale * Double(maskScale),
                        elementMode: mode
                    )
                    addBoundaryBand(
                        mask: mask,
                        maskWidth: maskWidth,
                        maskHeight: maskHeight,
                        outputWidth: width,
                        outputHeight: height,
                        maskScale: maskScale,
                        to: &result
                    )
                }
                continue
            }
        }
        return result
    }

    func addAnalyticInkEdgeBand(
        scene: CanvasPreparedScene,
        width: Int,
        height: Int,
        displayScale: Double,
        to band: inout [Bool]
    ) throws {
        let viewportScale = scene.viewport.zoom * displayScale
        for geometry in scene.geometry {
            guard case .ink(let ink) = geometry.path else { continue }
            let snapshot = ink.snapshot()
            let canvasLineWidth = try CanvasInkCurve.lineWidthInCanvasUnits(
                lineWidth: geometry.style.lineWidth,
                viewportZoom: scene.viewport.zoom,
                widthMode: snapshot.widthMode
            )
            let pixelLineWidth = canvasLineWidth * viewportScale
            let flattened = try CanvasInkCurve.flatten(
                stroke: CanvasInkStroke(
                    samples: snapshot.confirmed + snapshot.predicted,
                    pressureEnabled: snapshot.pressureEnabled,
                    widthMode: snapshot.widthMode
                ),
                maximumError: 0.25 / viewportScale,
                maximumWidthError: 0.5 / max(pixelLineWidth, 0.5)
            )
            let visible = try CanvasInkVisibilityPolicy.apply(
                to: flattened,
                lineWidth: canvasLineWidth,
                pixelsPerCanvasUnit: viewportScale,
                pressureEnabled: snapshot.pressureEnabled
            )
            let vertices = CanvasInkTaperLimiter.limit(
                visible,
                lineWidth: canvasLineWidth
            )
            guard !vertices.isEmpty else { continue }

            var unionDistance = [Double](repeating: .infinity, count: width * height)
            for index in 0..<max(1, vertices.count - 1) {
                let startVertex = vertices[index]
                let endVertex = vertices.count == 1
                    ? startVertex
                    : vertices[index + 1]
                let start = analyticPixelPoint(
                    startVertex.point,
                    scene: scene,
                    displayScale: displayScale
                )
                let end = analyticPixelPoint(
                    endVertex.point,
                    scene: scene,
                    displayScale: displayScale
                )
                let segment = AnalyticCoverageSegment(
                    startX: start.x,
                    startY: start.y,
                    endX: end.x,
                    endY: end.y,
                    startRadius: pixelLineWidth * startVertex.widthFactor * 0.5,
                    endRadius: pixelLineWidth * endVertex.widthFactor * 0.5
                )
                let expansion = max(segment.startRadius, segment.endRadius) + 1
                let minX = max(0, Int(floor(min(segment.startX, segment.endX) - expansion)))
                let maxX = min(width - 1, Int(ceil(max(segment.startX, segment.endX) + expansion)))
                let minY = max(0, Int(floor(min(segment.startY, segment.endY) - expansion)))
                let maxY = min(height - 1, Int(ceil(max(segment.startY, segment.endY) + expansion)))
                guard minX <= maxX, minY <= maxY else { continue }
                for y in minY...maxY {
                    for x in minX...maxX {
                        let offset = y * width + x
                        let distance = unevenCapsuleDistance(
                            x: Double(x) + 0.5,
                            y: Double(y) + 0.5,
                            segment: segment
                        )
                        unionDistance[offset] = min(unionDistance[offset], distance)
                    }
                }
            }
            for offset in unionDistance.indices where abs(unionDistance[offset]) <= 1 {
                band[offset] = true
            }
        }
    }

    func analyticPixelPoint(
        _ point: CanvasPoint,
        scene: CanvasPreparedScene,
        displayScale: Double
    ) -> (x: Double, y: Double) {
        (
            (point.x * scene.viewport.zoom + scene.viewport.translation.x) * displayScale,
            (point.y * scene.viewport.zoom + scene.viewport.translation.y) * displayScale
        )
    }

    func unevenCapsuleDistance(
        x: Double,
        y: Double,
        segment: AnalyticCoverageSegment
    ) -> Double {
        let axisX = segment.endX - segment.startX
        let axisY = segment.endY - segment.startY
        let axisLength = hypot(axisX, axisY)
        let radiusDifference = segment.startRadius - segment.endRadius
        if axisLength <= 0.000_001 || axisLength <= abs(radiusDifference) {
            let useStart = segment.startRadius >= segment.endRadius
            let centreX = useStart ? segment.startX : segment.endX
            let centreY = useStart ? segment.startY : segment.endY
            let radius = useStart ? segment.startRadius : segment.endRadius
            return hypot(x - centreX, y - centreY) - radius
        }

        let unitX = axisX / axisLength
        let unitY = axisY / axisLength
        let relativeX = x - segment.startX
        let relativeY = y - segment.startY
        let localX = abs(relativeX * -unitY + relativeY * unitX)
        let localY = relativeX * unitX + relativeY * unitY
        let radiusSlope = radiusDifference / axisLength
        let tangentScale = sqrt(max(0, 1 - radiusSlope * radiusSlope))
        let tangentCoordinate = localX * -radiusSlope + localY * tangentScale
        if tangentCoordinate < 0 {
            return hypot(localX, localY) - segment.startRadius
        }
        if tangentCoordinate > tangentScale * axisLength {
            return hypot(localX, localY - axisLength) - segment.endRadius
        }
        return localX * tangentScale + localY * radiusSlope - segment.startRadius
    }

    func commandMask(
        _ command: CoreGraphicsRenderCommand,
        scene: CanvasPreparedScene,
        width: Int,
        height: Int,
        displayScale: Double,
        elementMode: ElementMaskMode
    ) throws -> [Bool] {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.setShouldAntialias(false)
        context.setAllowsAntialiasing(false)
        context.scaleBy(x: displayScale, y: displayScale)
        context.concatenate(CGAffineTransform(
            a: scene.viewport.zoom,
            b: 0,
            c: 0,
            d: scene.viewport.zoom,
            tx: scene.viewport.translation.x,
            ty: scene.viewport.translation.y
        ))
        context.setFillColor(gray: 1, alpha: 1)
        context.setStrokeColor(gray: 1, alpha: 1)
        switch command {
        case .background:
            break
        case .grid(let line, _, let lineWidth):
            context.setLineWidth(lineWidth)
            context.move(to: .init(x: line.start.x, y: line.start.y))
            context.addLine(to: .init(x: line.end.x, y: line.end.y))
            context.strokePath()
        case .element(_, let path, _, let fill, let lineWidth):
            context.addPath(path)
            context.setLineWidth(lineWidth)
            context.setLineJoin(.round)
            context.setLineCap(.round)
            switch elementMode {
            case .fill:
                context.fillPath(using: .winding)
            case .stroke:
                context.strokePath()
            case .combined:
                context.drawPath(using: fill == nil ? .stroke : .fillStroke)
            }
        case .selection(let bounds, _, let lineWidth, let handleSize):
            let rect = CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)
            context.setLineWidth(lineWidth)
            context.stroke(rect)
            let half = handleSize / 2
            for point in [
                CGPoint(x: rect.minX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.maxY),
                CGPoint(x: rect.minX, y: rect.maxY),
            ] {
                context.fill(CGRect(
                    x: point.x - half,
                    y: point.y - half,
                    width: handleSize,
                    height: handleSize
                ))
            }
        case .guide(let guide, _, let lineWidth):
            let visible = scene.viewport.visibleCanvasRect
            context.setLineWidth(lineWidth)
            switch guide {
            case .vertical(let x):
                context.move(to: .init(x: x, y: visible.minY))
                context.addLine(to: .init(x: x, y: visible.maxY))
            case .horizontal(let y):
                context.move(to: .init(x: visible.minX, y: y))
                context.addLine(to: .init(x: visible.maxX, y: y))
            }
            context.strokePath()
        }
        let image = try XCTUnwrap(context.makeImage())
        return pixels(image).map { $0[0] >= 128 }
    }

    enum ElementMaskMode {
        case combined
        case fill
        case stroke
    }

    func addBoundaryBand(
        mask: [Bool],
        maskWidth: Int,
        maskHeight: Int,
        outputWidth: Int,
        outputHeight: Int,
        maskScale: Int,
        to band: inout [Bool]
    ) {
        var boundary = [Bool](repeating: false, count: outputWidth * outputHeight)
        func mark(_ x: Int, _ y: Int) {
            boundary[min(outputHeight - 1, y / maskScale) * outputWidth
                + min(outputWidth - 1, x / maskScale)] = true
        }
        for y in 0..<maskHeight {
            for x in 0..<maskWidth {
                let offset = y * maskWidth + x
                if x + 1 < maskWidth, mask[offset] != mask[offset + 1] {
                    mark(x, y)
                    mark(x + 1, y)
                }
                if y + 1 < maskHeight, mask[offset] != mask[offset + maskWidth] {
                    mark(x, y)
                    mark(x, y + 1)
                }
            }
        }
        for y in 0..<outputHeight {
            for x in 0..<outputWidth where boundary[y * outputWidth + x] {
                for yy in max(0, y - 1)...min(outputHeight - 1, y + 1) {
                    for xx in max(0, x - 1)...min(outputWidth - 1, x + 1) {
                        band[yy * outputWidth + xx] = true
                    }
                }
            }
        }
    }
}

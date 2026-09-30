import Foundation
import CoreGraphics
import Metal
import UIKit
import XCTest
import CadCanvasCore
@testable import CadCanvasUI

@MainActor
final class CanvasPerformanceTests: XCTestCase {
    func testOffscreenOutputAccountsForActualAllocationWithinHardBudget() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable")
        }
        let size = CGSize(width: 128, height: 128)
        let viewport = try CanvasViewport.identity(size: .init(
            width: Double(size.width),
            height: Double(size.height)
        ))
        let presentation = try CanvasScenePreparer().prepare(
            document: CanvasDocument(),
            preview: nil,
            viewport: viewport,
            selectedElementID: nil,
            editingTextIDs: [],
            guides: [],
            gridSpacing: 20,
            theme: CanvasTheme.default.renderSnapshot
        )
        let scene = try MetalSceneCompiler().compile(presentation, displayScale: 1)
        let engine = try MetalRenderEngine(device: device)
        let output = try engine.renderOffscreen(scene, size: size, displayScale: 1)
        let actualBytes = try MetalCachedResource.conservativeAllocationByteCount(
            payloadByteCount: MetalCachedResource.checkedByteCount(
                width: output.width,
                height: output.height,
                bytesPerPixel: 4
            ),
            reportedByteCount: output.allocatedSize
        )
        XCTAssertGreaterThanOrEqual(
            engine.maximumOwnedCoverageByteCount,
            actualBytes,
            "Offscreen ownership must include actual output allocation, not only its estimate"
        )
        XCTAssertLessThanOrEqual(
            engine.maximumOwnedCoverageByteCount,
            CanvasMetalLimits.resourceBudgetBytes
        )
        let constrained = try MetalRenderEngine(
            device: device,
            resourceBudgetBytes: actualBytes - 1
        )
        XCTAssertThrowsError(try constrained.renderOffscreen(
            scene,
            size: size,
            displayScale: 1
        )) { error in
            XCTAssertEqual(error as? MetalCanvasError, .resourceBudgetExceeded)
        }
    }

    private struct CommittedWork: Equatable {
        let preparationVisits: Int
        let compilationVisits: Int
        let engineMaterializationVisits: Int
        let committedTileReplays: Int
        let committedCoverageEncodes: Int
    }

    func testWarmLiveFrameCommittedWorkIsIndependentOfHistory() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable")
        }
        let viewport = try CanvasViewport.identity(size: .init(width: 128, height: 128))
        let theme = CanvasTheme.default.renderSnapshot

        func document(strokeCount: Int) -> CanvasDocument {
            let elements: [CanvasElement] = (0 ..< strokeCount).map { index in
                let y = Double(8 + index % 100)
                let samples: [CanvasInkSample] = [
                    .init(point: .init(x: 8, y: y), pressure: 1),
                    .init(point: .init(x: 112, y: y), pressure: 1),
                ]
                return CanvasElement(
                    id: UUID(),
                    geometry: .freehand(.init(
                        samples: samples,
                        pressureEnabled: true
                    )),
                    style: .init(stroke: .black, lineWidth: 2)
                )
            }
            return CanvasDocument(elements: elements)
        }

        func committedWork(committedStrokeCount: Int) throws -> CommittedWork {
            let document = document(strokeCount: committedStrokeCount)
            let preparer = CanvasScenePreparer()
            let compiler = MetalSceneCompiler()
            let engine = try MetalRenderEngine(device: device)
            let draft = CanvasFreehandDraft(
                id: UUID(),
                style: .init(stroke: .black, lineWidth: 2)
            )
            var generation = RecognitionGeneration.zero
            draft.append([
                .init(point: .init(x: 8, y: 120), pressure: 0.5),
                .init(point: .init(x: 12, y: 120), pressure: 0.5),
            ])
            var preview = CanvasRenderPreview(
                freehand: draft,
                predictedInkSamples: [],
                generation: generation
            )

            let committed = try preparer.prepare(
                document: document,
                preview: nil,
                viewport: viewport,
                selectedElementID: nil,
                editingTextIDs: [],
                guides: [],
                gridSpacing: 20,
                theme: theme
            )
            _ = try engine.renderOffscreen(
                compiler.compile(committed, displayScale: 1),
                size: .init(width: 128, height: 128),
                displayScale: 1
            )

            for frame in 0 ..< 8 {
                generation.advance()
                draft.append([.init(
                    point: .init(x: Double(16 + frame * 2), y: 120),
                    pressure: 0.5
                )])
                XCTAssertTrue(preview.update(
                    freehand: draft,
                    predictedInkSamples: [],
                    generation: generation
                ))
                let presentation = try preparer.prepare(
                    document: document,
                    preview: preview,
                    viewport: viewport,
                    selectedElementID: nil,
                    editingTextIDs: [],
                    guides: [],
                    gridSpacing: 20,
                    theme: theme
                )
                _ = try engine.renderOffscreen(
                    compiler.compile(presentation, displayScale: 1),
                    size: .init(width: 128, height: 128),
                    displayScale: 1
                )
            }

            let preparationBefore = preparer.statistics.committedElementVisitCount
            let compilationBefore = compiler.statistics.committedItemVisitCount
            let materializationBefore = engine.committedPresentationItemVisitCount
            generation.advance()
            draft.append([.init(
                point: .init(x: 36, y: 120),
                pressure: 0.5
            )])
            XCTAssertTrue(preview.update(
                freehand: draft,
                predictedInkSamples: [],
                generation: generation
            ))
            let presentation = try preparer.prepare(
                document: document,
                preview: preview,
                viewport: viewport,
                selectedElementID: nil,
                editingTextIDs: [],
                guides: [],
                gridSpacing: 20,
                theme: theme
            )
            let compiled = try compiler.compile(presentation, displayScale: 1)
            _ = try engine.renderOffscreen(
                compiled,
                size: .init(width: 128, height: 128),
                displayScale: 1
            )
            return CommittedWork(
                preparationVisits: preparer.statistics.committedElementVisitCount
                    - preparationBefore,
                compilationVisits: compiler.statistics.committedItemVisitCount
                    - compilationBefore,
                engineMaterializationVisits: engine.committedPresentationItemVisitCount
                    - materializationBefore,
                committedTileReplays: engine.lastCommittedTileReplayCount,
                committedCoverageEncodes: engine.lastCommittedCoverageEncodeCount
            )
        }

        let expected = CommittedWork(
            preparationVisits: 0,
            compilationVisits: 0,
            engineMaterializationVisits: 0,
            committedTileReplays: 0,
            committedCoverageEncodes: 0
        )
        for committedStrokeCount in [1, 10, 100] {
            XCTAssertEqual(
                try committedWork(committedStrokeCount: committedStrokeCount),
                expected,
                "Warm live work scaled with \(committedStrokeCount) committed strokes"
            )
        }
    }

    func testLiveMetalFrameCommittedCoverageWorkIsIndependentOfHistory() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable")
        }
        let viewport = try! CanvasViewport.identity(size: .init(width: 128, height: 128))
        let theme = CanvasThemeSnapshot(
            background: .init(red: 1, green: 1, blue: 1),
            grid: .black,
            stroke: .black,
            selection: .black,
            guides: .black,
            gridLineWidth: 1,
            selectionLineWidth: 1,
            handleSize: 8
        )

        func preparedInk(
            id: UUID,
            y: Double,
            renderKey: CanvasRenderKey,
            isFinalized: Bool
        ) -> CanvasPreparedGeometry {
            CanvasPreparedGeometry(
                id: id,
                renderKey: renderKey,
                path: .ink(CanvasPreparedInk(
                    confirmedSamples: [
                        .init(point: .init(x: 8, y: y), pressure: 1),
                        .init(point: .init(x: 112, y: y), pressure: 1),
                    ],
                    predictedSamples: [],
                    pressureEnabled: true,
                    isFinalized: isFinalized
                )),
                bounds: .init(x: 8, y: y, width: 104, height: 0),
                style: .init(stroke: .black, lineWidth: 2)
            )
        }

        func scene(_ geometry: [CanvasPreparedGeometry]) -> CanvasPreparedScene {
            CanvasPreparedScene(
                geometry: geometry,
                gridLines: [],
                selectionBounds: nil,
                guides: [],
                viewport: viewport,
                theme: theme,
                previewGeneration: nil
            )
        }

        func presentation(
            committed: [CanvasPreparedGeometry],
            live: [CanvasPreparedGeometry] = []
        ) -> CanvasPreparedPresentation {
            CanvasPreparedPresentation(
                scene: scene(committed + live),
                textDescriptors: [],
                committed: .init(
                    generation: .init(
                        documentRevision: 1,
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

        for committedCount in [1, 10, 100] {
            let engine = try MetalRenderEngine(device: device)
            let committed = (0 ..< committedCount).map { index in
                let id = UUID()
                return preparedInk(
                    id: id,
                    y: Double(index + 8),
                    renderKey: .committed(id: id, contentRevision: 1),
                    isFinalized: true
                )
            }
            let activeID = UUID()
            let active = preparedInk(
                id: activeID,
                y: 120,
                renderKey: .preview(id: activeID, generation: .zero),
                isFinalized: false
            )
            let compiler = MetalSceneCompiler()

            _ = try engine.renderOffscreen(
                try compiler.compile(presentation(committed: committed)),
                size: .init(width: 128, height: 128),
                displayScale: 1
            )
            let preparedCandidateCountBeforeLiveFrame = compiler.statistics
                .preparedFreehandCandidateCount
            let compiledGeometryCountBeforeLiveFrame = compiler.statistics
                .compiledGeometryCount
            _ = try engine.renderOffscreen(
                try compiler.compile(presentation(
                    committed: committed,
                    live: [active]
                )),
                size: .init(width: 128, height: 128),
                displayScale: 1
            )

            XCTAssertEqual(engine.lastCommittedCoverageEncodeCount, 0)
            XCTAssertEqual(engine.lastLiveCoverageEncodeCount, 1)
            XCTAssertEqual(
                compiler.statistics.compiledGeometryCount
                    - compiledGeometryCountBeforeLiveFrame,
                1,
                "A live frame must only compile the active stroke"
            )
            XCTAssertEqual(
                compiler.statistics.preparedFreehandCandidateCount
                    - preparedCandidateCountBeforeLiveFrame,
                1,
                "A live frame must only snapshot the active stroke"
            )
        }
    }

    func testAutomatedRendererBaselineUsesBoundedReusableContext() throws {
        let benchmark = try RendererPerformanceBenchmark(
            document: PerformanceFixture.make()
        )
        let context = try benchmark.makeReusableContext()

        XCTAssertEqual(benchmark.warmUpRenderCount, 30)
        XCTAssertEqual(benchmark.measuredRenderCount, 300)
        XCTAssertNotEqual(benchmark.viewport(at: 0), benchmark.viewport(at: 299))

        benchmark.warmUp(context: context)

        var renderedFrameCount = 0
        var manualBatchDuration = 0.0
        let options = XCTMeasureOptions()
        options.iterationCount = 1
        measure(
            metrics: [XCTClockMetric(), XCTMemoryMetric()],
            options: options
        ) {
            let start = ProcessInfo.processInfo.systemUptime
            benchmark.renderMeasuredBatch(context: context)
            manualBatchDuration = ProcessInfo.processInfo.systemUptime - start
            renderedFrameCount = benchmark.measuredRenderCount
        }

        XCTAssertEqual(renderedFrameCount, benchmark.measuredRenderCount)
        XCTAssertNotNil(context.makeImage())
        add(benchmark.diagnosticAttachment(batchDuration: manualBatchDuration))
    }

    func testViewportOnlySteadyStateDoesNotRebuildGeometryOrBackendPaths() throws {
        let document = try PerformanceFixture.make()
        let nonTextElementCount = document.elements.reduce(into: 0) { count, element in
            if case .text = element.geometry { return }
            count += 1
        }
        let preparer = CanvasScenePreparer()
        let renderer = CoreGraphicsCanvasRenderer()

        for index in 0 ..< 300 {
            let viewport = try! CanvasViewport(
                zoom: 1,
                translation: .init(
                    x: Double(index) / 10,
                    y: Double(index) / 20
                ),
                viewportSize: .init(width: 4_000, height: 2_400)
            )
            let scene = try preparer.prepare(
                document: document,
                preview: nil,
                viewport: viewport,
                selectedElementID: nil,
                editingTextIDs: [],
                guides: [],
                gridSpacing: 20,
                theme: CanvasTheme.default.renderSnapshot
            ).scene
            _ = renderer.renderCommands(
                scene: scene,
                bounds: CGRect(x: 0, y: 0, width: 4_000, height: 2_400),
                displayScale: 2
            )
        }

        XCTAssertEqual(
            preparer.statistics.geometryBuildCount,
            nonTextElementCount,
            "Viewport-only frames must not rebuild geometry"
        )
        XCTAssertLessThanOrEqual(
            preparer.statistics.cachedGeometryCount,
            nonTextElementCount
        )
        XCTAssertEqual(
            renderer.statistics.fullPathBuildCount,
            nonTextElementCount
        )
        XCTAssertLessThanOrEqual(
            renderer.statistics.cachedPathCount,
            nonTextElementCount
        )
    }

    func testDisplayedPreviewGenerationCompletesLatencyIntervalExactlyOnce() throws {
        let signposts = CanvasPerformanceSignposts()
        let renderer = CoreGraphicsCanvasRenderer()
        let renderView = try XCTUnwrap(renderer.makeRenderView(
            displayCompletion: { generation, presentedTime in
                signposts.completeDisplay(through: generation, at: presentedTime)
            }
        ) as? CanvasRenderView)
        renderView.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        var generation = RecognitionGeneration.zero
        generation.advance()
        let presentation = try CanvasScenePreparer().prepare(
            document: .init(elements: [PerformanceFixture.line(at: 0)]),
            preview: nil,
            viewport: .identity(size: .init(width: 100, height: 100)),
            selectedElementID: nil,
            editingTextIDs: [],
            guides: [],
            gridSpacing: 20,
            theme: CanvasTheme.default.renderSnapshot
        )
        let scene = CanvasPreparedScene(
            geometry: presentation.scene.geometry,
            gridLines: presentation.scene.gridLines,
            selectionBounds: presentation.scene.selectionBounds,
            guides: presentation.scene.guides,
            viewport: presentation.scene.viewport,
            theme: presentation.scene.theme,
            previewGeneration: generation
        )

        signposts.begin(generation: generation)
        renderer.update(scene, in: renderView)
        let imageRenderer = UIGraphicsImageRenderer(size: renderView.bounds.size)
        _ = imageRenderer.image { _ in
            renderView.draw(renderView.bounds)
            renderView.draw(renderView.bounds)
        }

        XCTAssertEqual(signposts.statistics.activeIntervalCount, 0)
        XCTAssertEqual(signposts.statistics.completedIntervalCount, 1)
        XCTAssertEqual(signposts.statistics.cancelledIntervalCount, 0)
    }

    func testCumulativeDisplayCompletesEveryApplicablePendingGenerationExactlyOnce() {
        var endStatuses: [CanvasPerformanceSignposts.IntervalEndStatus] = []
        var now = 10.0
        let signposts = CanvasPerformanceSignposts(
            clock: { now },
            onIntervalEnd: { _, status in endStatuses.append(status) }
        )
        var first = RecognitionGeneration.zero
        first.advance()
        var second = first
        second.advance()

        signposts.begin(generation: first)
        now = 11
        signposts.begin(generation: second)

        XCTAssertEqual(signposts.statistics.activeIntervalCount, 2)
        XCTAssertEqual(signposts.statistics.cancelledIntervalCount, 0)

        signposts.completeDisplay(through: second, at: 10.5)

        XCTAssertEqual(signposts.statistics.activeIntervalCount, 2)
        XCTAssertEqual(signposts.statistics.completedIntervalCount, 0)
        XCTAssertTrue(signposts.recentCompletedDurationsMilliseconds.isEmpty)
        XCTAssertTrue(signposts.recentDisplayTimestamps.isEmpty)
        XCTAssertTrue(endStatuses.isEmpty)

        signposts.completeDisplay(through: second, at: 12.5)
        signposts.completeDisplay(through: second, at: 99)

        XCTAssertEqual(signposts.statistics.activeIntervalCount, 0)
        XCTAssertEqual(signposts.statistics.completedIntervalCount, 2)
        XCTAssertEqual(signposts.statistics.cancelledIntervalCount, 0)
        XCTAssertEqual(signposts.recentCompletedDurationsMilliseconds, [2_500, 1_500])
        XCTAssertEqual(signposts.recentDisplayTimestamps, [12.5])
        XCTAssertEqual(endStatuses, [.displayed, .displayed])
    }

    func testExplicitCancellationClosesPendingIntervalsWithoutDisplayedDurations() {
        var endStatuses: [CanvasPerformanceSignposts.IntervalEndStatus] = []
        let signposts = CanvasPerformanceSignposts(onIntervalEnd: { _, status in
            endStatuses.append(status)
        })
        var first = RecognitionGeneration.zero
        first.advance()
        var second = first
        second.advance()

        signposts.begin(generation: first)
        signposts.begin(generation: second)
        signposts.cancelAll()

        XCTAssertEqual(signposts.statistics.activeIntervalCount, 0)
        XCTAssertEqual(signposts.statistics.completedIntervalCount, 0)
        XCTAssertEqual(signposts.statistics.cancelledIntervalCount, 2)
        XCTAssertTrue(signposts.recentCompletedDurationsMilliseconds.isEmpty)
        XCTAssertEqual(endStatuses, [.cancelled, .cancelled])
    }

    func testPendingAndRecentLatencyStateRemainBounded() {
        var endStatuses: [CanvasPerformanceSignposts.IntervalEndStatus] = []
        let signposts = CanvasPerformanceSignposts(onIntervalEnd: { _, status in
            endStatuses.append(status)
        })
        var generation = RecognitionGeneration.zero

        for _ in 0 ..< 1_200 {
            generation.advance()
            signposts.begin(generation: generation)
        }

        XCTAssertLessThanOrEqual(signposts.statistics.activeIntervalCount, 512)
        XCTAssertEqual(signposts.statistics.capacityEvictedIntervalCount, 688)
        XCTAssertEqual(
            endStatuses.filter { $0 == .capacityEvicted }.count,
            688
        )
        signposts.completeDisplay(
            through: generation,
            at: ProcessInfo.processInfo.systemUptime
        )
        XCTAssertLessThanOrEqual(
            signposts.recentCompletedDurationsMilliseconds.count,
            1_024
        )
        XCTAssertEqual(endStatuses.filter { $0 == .displayed }.count, 512)
        XCTAssertFalse(endStatuses.contains(.cancelled))
    }

    func testPhysicalAcceptanceRemainsExternalToRendererSeam() {
        XCTAssertEqual(
            RendererPerformanceBenchmark.pendingPhysicalAcceptance,
            .init(
                requiredHardware: "iPad (A16)",
                requiredEvidence: "Core Animation + Time Profiler",
                p95FrameMilliseconds: 16.7,
                maximumFrameMilliseconds: 33.4
            )
        )
        XCTAssertFalse(isPhysicalA16OrLaterIPad(
            isIPad: true,
            machineIdentifier: "iPad14,1",
            supportsApple8OrNewer: true
        ))
        XCTAssertFalse(isPhysicalA16OrLaterIPad(
            isIPad: true,
            machineIdentifier: "iPad14,2",
            supportsApple8OrNewer: true
        ))
        XCTAssertTrue(isPhysicalA16OrLaterIPad(
            isIPad: true,
            machineIdentifier: "iPad15,7",
            supportsApple8OrNewer: true
        ))
        XCTAssertTrue(isPhysicalA16OrLaterIPad(
            isIPad: true,
            machineIdentifier: "iPad16,5",
            supportsApple8OrNewer: true
        ))
        XCTAssertFalse(isPhysicalA16OrLaterIPad(
            isIPad: false,
            machineIdentifier: "iPhone17,3",
            supportsApple8OrNewer: true
        ))
    }

    func testTimedBatchRunEnforcesMinimumElapsedDuration() throws {
        var now = 10.0

        let result = runTimedBatches(
            minimumDuration: 5,
            clock: { now }
        ) { batchIndex in
            XCTAssertEqual(batchIndex, Int(now - 10))
            now += 1
        }

        XCTAssertEqual(result.batchCount, 5)
        XCTAssertEqual(result.elapsedSeconds, 5)
    }

    func testSustainedInputRunStopsAtMinimumDurationAndDrainsEveryBatch() {
        var state = SustainedInputRunState(
            startTime: 100,
            minimumDuration: 5
        )

        XCTAssertEqual(state.takeBatchIndex(at: 100), 0)
        XCTAssertEqual(state.takeBatchIndex(at: 104.999), 1)
        XCTAssertNil(state.takeBatchIndex(at: 105))
        XCTAssertEqual(state.batchCount, 2)
        XCTAssertEqual(state.elapsedSeconds, 5)
        XCTAssertFalse(state.isDrained(
            completedIntervalCount: 1,
            activeIntervalCount: 0,
            cancelledIntervalCount: 0,
            capacityEvictedIntervalCount: 0,
            pendingFrameCount: 0,
            trackedSubmittedFrameCount: 0
        ))
        XCTAssertFalse(state.isDrained(
            completedIntervalCount: 2,
            activeIntervalCount: 1,
            cancelledIntervalCount: 0,
            capacityEvictedIntervalCount: 0,
            pendingFrameCount: 0,
            trackedSubmittedFrameCount: 0
        ))
        XCTAssertFalse(state.isDrained(
            completedIntervalCount: 2,
            activeIntervalCount: 0,
            cancelledIntervalCount: 0,
            capacityEvictedIntervalCount: 0,
            pendingFrameCount: 1,
            trackedSubmittedFrameCount: 0
        ))
        XCTAssertTrue(state.isDrained(
            completedIntervalCount: 2,
            activeIntervalCount: 0,
            cancelledIntervalCount: 0,
            capacityEvictedIntervalCount: 0,
            pendingFrameCount: 0,
            trackedSubmittedFrameCount: 0
        ))
    }

}

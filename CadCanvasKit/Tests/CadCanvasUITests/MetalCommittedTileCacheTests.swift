import XCTest
import CadCanvasCore
import Metal
@testable import CadCanvasUI

@MainActor
final class MetalCommittedTileCacheTests: XCTestCase {
    func testExactZoomRedrawUsesPersistedCanvasScaledWidth() throws {
        let spans = try exactWidthSpans(widthMode: .canvasScaled)

        XCTAssertEqual(Double(spans.fourX), Double(spans.oneX * 4), accuracy: 2)
    }

    func testExactZoomRedrawUsesPersistedScreenConstantWidth() throws {
        let spans = try exactWidthSpans(widthMode: .screenConstant)

        XCTAssertEqual(Double(spans.fourX), Double(spans.oneX), accuracy: 2)
    }

    private func exactWidthSpans(
        widthMode: CanvasInkWidthMode
    ) throws -> (oneX: Int, fourX: Int) {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let geometry = committedWidthFixture(widthMode: widthMode)
        let compiler = MetalSceneCompiler()
        let oneXViewport = try CanvasViewport(
            zoom: 1,
            translation: .init(x: 0, y: 0),
            viewportSize: .init(width: 128, height: 128)
        )
        let fourXViewport = try CanvasViewport(
            zoom: 4,
            translation: .init(x: -192, y: -192),
            viewportSize: .init(width: 128, height: 128)
        )
        let oneX = try MetalRenderEngine(device: device).renderOffscreen(
            compiler.compile(rasterScene([geometry], viewport: oneXViewport)),
            size: .init(width: 128, height: 128),
            displayScale: 1
        )
        let fourX = try MetalRenderEngine(device: device).renderOffscreen(
            compiler.compile(rasterScene([geometry], viewport: fourXViewport)),
            size: .init(width: 128, height: 128),
            displayScale: 1
        )

        return (
            verticalInkSpan(oneX, x: 64),
            verticalInkSpan(fourX, x: 64)
        )
    }

    func testInteractiveColdCacheFallsBackToDirectCommittedRendering() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let viewport = try CanvasViewport(
            zoom: 1.5,
            translation: .init(x: 17, y: -11),
            viewportSize: .init(width: 128, height: 128)
        )
        let committed = committedRasterFixture()
        let scene = rasterScene(
            committed,
            viewport: viewport,
            includesDecorations: true
        )
        let compiler = MetalSceneCompiler()
        let reference = try MetalRenderEngine(device: device).renderOffscreen(
            compiler.compile(scene),
            size: .init(width: 128, height: 128),
            displayScale: 1
        )
        let presentation = CanvasPreparedPresentation(
            scene: scene,
            textDescriptors: [],
            committed: .init(
                generation: .init(
                    documentRevision: 1,
                    replacementGeneration: .zero
                ),
                items: committed.enumerated().map {
                    committedItem(geometry: $0.element, index: $0.offset)
                },
                replacement: nil
            ),
            viewportRenderPhase: .interactive
        )
        let engine = try MetalRenderEngine(device: device)

        let actual = try engine.renderOffscreen(
            compiler.compile(presentation),
            size: .init(width: 128, height: 128),
            displayScale: 1
        )

        XCTAssertEqual(engine.lastCommittedTileReplayCount, 0)
        assertPixelsEqual(actual, reference, tolerance: 64)
    }

    func testFinalLiveFrameMatchesFirstCommittedFrameWithoutDuplicateOrGap() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let viewport = try! CanvasViewport.identity(
            size: .init(width: 512, height: 256)
        )
        let base = boxGeometry(
            rect: .init(x: 300, y: 30, width: 80, height: 80),
            color: .init(red: 0.1, green: 0.25, blue: 0.9, alpha: 0.65)
        )
        let strokeID = UUID()
        let generation = RecognitionGeneration.zero
        let live = boxGeometry(
            id: strokeID,
            renderKey: .preview(id: strokeID, generation: generation),
            rect: .init(x: 40, y: 45, width: 90, height: 55),
            color: .init(red: 0.8, green: 0.15, blue: 0.2, alpha: 0.55)
        )
        let committedStroke = boxGeometry(
            id: strokeID,
            renderKey: .committed(id: strokeID, contentRevision: 1),
            rect: live.bounds,
            color: try XCTUnwrap(live.style.fill)
        )
        let compiler = MetalSceneCompiler()
        let engine = try MetalRenderEngine(device: device)
        let baseItem = committedItem(geometry: base, index: 0)
        let basePresentation = presentation(
            geometry: [base],
            committedItems: [baseItem],
            revision: 1,
            viewport: viewport
        )
        _ = try engine.renderOffscreen(
            compiler.compile(basePresentation),
            size: .init(width: 512, height: 256),
            displayScale: 1
        )
        let active = presentation(
            geometry: [base, live],
            committedItems: [baseItem],
            revision: 1,
            viewport: viewport,
            previewGeneration: generation
        )
        let finalLiveFrame = try engine.renderOffscreen(
            compiler.compile(active),
            size: .init(width: 512, height: 256),
            displayScale: 1
        )
        let committed = presentation(
            geometry: [base, committedStroke],
            committedItems: [
                baseItem,
                committedItem(geometry: committedStroke, index: 1),
            ],
            revision: 2,
            viewport: viewport
        )
        let firstCommittedFrame = try engine.renderOffscreen(
            compiler.compile(committed),
            size: .init(width: 512, height: 256),
            displayScale: 1
        )

        XCTAssertEqual(engine.lastCommittedTileReplayCount, 1)
        assertPixelsEqual(firstCommittedFrame, finalLiveFrame, tolerance: 64)
    }

    func testCommittedTileReplayMatchesLegacyAcrossBoundariesAndWarmsAtOneTwoAndFourX() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let committed = committedRasterFixture()
        for displayScale in [1.0, 2.0, 4.0] {
            let viewport = try! CanvasViewport(
                zoom: 1,
                translation: .init(x: 64, y: 64),
                viewportSize: .init(width: 128, height: 128)
            )
            let scene = rasterScene(
                committed,
                viewport: viewport,
                includesDecorations: true
            )
            let compiler = MetalSceneCompiler()
            let referenceEngine = try MetalRenderEngine(device: device)
            let tiledEngine = try MetalRenderEngine(device: device)
            let reference = try referenceEngine.renderOffscreen(
                compiler.compile(scene, displayScale: displayScale),
                size: .init(width: 128, height: 128),
                displayScale: displayScale
            )
            let presentation = CanvasPreparedPresentation(
                scene: scene,
                textDescriptors: [],
                committed: .init(
                    generation: .init(
                        documentRevision: 11,
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
            let compiled = try compiler.compile(
                presentation,
                displayScale: displayScale
            )

            let first = try tiledEngine.renderOffscreen(
                compiled,
                size: .init(width: 128, height: 128),
                displayScale: displayScale
            )

            XCTAssertGreaterThan(tiledEngine.lastCommittedTileReplayCount, 0)
            assertPixelsEqual(first, reference, tolerance: 64)

            let materializationVisits = tiledEngine.committedPresentationItemVisitCount
            let warm = try tiledEngine.renderOffscreen(
                compiled,
                size: .init(width: 128, height: 128),
                displayScale: displayScale
            )
            XCTAssertEqual(tiledEngine.lastCommittedTileReplayCount, 0)
            XCTAssertEqual(tiledEngine.lastCommittedCoverageEncodeCount, 0)
            XCTAssertEqual(
                tiledEngine.committedPresentationItemVisitCount,
                materializationVisits
            )
            assertPixelsEqual(warm, reference, tolerance: 64)
        }
    }

    func testMemoryPressureRebuildPreservesDirectPlannerReuse() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let viewport = try CanvasViewport.identity(
            size: .init(width: 128, height: 128)
        )
        let committed = committedRasterFixture()
        let prepared = CanvasPreparedPresentation(
            scene: rasterScene(committed, viewport: viewport),
            textDescriptors: [],
            committed: .init(
                generation: .init(
                    documentRevision: 12,
                    replacementGeneration: .zero
                ),
                items: committed.enumerated().map {
                    committedItem(geometry: $0.element, index: $0.offset)
                },
                replacement: nil
            ),
            viewportRenderPhase: .settled
        )
        let compiled = try MetalSceneCompiler().compile(prepared)
        let engine = try MetalRenderEngine(device: device)
        let size = CGSize(width: 128, height: 128)

        _ = try engine.renderOffscreen(compiled, size: size, displayScale: 1)
        engine.handleMemoryPressure()
        let materializationVisits = engine.committedPresentationItemVisitCount

        _ = try engine.renderOffscreen(compiled, size: size, displayScale: 1)
        XCTAssertGreaterThan(engine.lastCommittedTileReplayCount, 0)
        XCTAssertEqual(
            engine.committedPresentationItemVisitCount,
            materializationVisits
        )

        _ = try engine.renderOffscreen(compiled, size: size, displayScale: 1)
        XCTAssertEqual(engine.lastCommittedTileReplayCount, 0)
        XCTAssertEqual(
            engine.committedPresentationItemVisitCount,
            materializationVisits
        )
    }

    func testReplacementTileReplayPreservesOriginalOrderingAndRefreshesPreviewGeneration() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let originals = [
            boxGeometry(
                rect: .init(x: 15, y: 15, width: 70, height: 70),
                color: .init(red: 0.1, green: 0.7, blue: 0.25, alpha: 0.75)
            ),
            boxGeometry(
                rect: .init(x: 25, y: 25, width: 70, height: 70),
                color: .init(red: 0.8, green: 0.15, blue: 0.2, alpha: 0.7)
            ),
            boxGeometry(
                rect: .init(x: 45, y: 20, width: 55, height: 80),
                color: .init(red: 0.1, green: 0.25, blue: 0.9, alpha: 0.65)
            ),
        ]
        let replacementID = UUID()
        var replacementGeneration = RecognitionGeneration.zero
        let replacements = [
            boxGeometry(
                id: replacementID,
                renderKey: .preview(id: replacementID, generation: replacementGeneration),
                rect: .init(x: 30, y: 35, width: 60, height: 45),
                color: .init(red: 0.95, green: 0.75, blue: 0.1, alpha: 0.55)
            ),
            {
                replacementGeneration.advance()
                return boxGeometry(
                    id: replacementID,
                    renderKey: .preview(
                        id: replacementID,
                        generation: replacementGeneration
                    ),
                    rect: .init(x: 20, y: 45, width: 75, height: 35),
                    color: .init(red: 0.55, green: 0.1, blue: 0.8, alpha: 0.6)
                )
            }(),
        ]
        let viewport = try! CanvasViewport.identity(
            size: .init(width: 128, height: 128)
        )
        let tiledEngine = try MetalRenderEngine(device: device)
        for replacement in replacements {
            let composed = [originals[0], replacement, originals[2]]
            let scene = rasterScene(composed, viewport: viewport)
            let presentation = CanvasPreparedPresentation(
                scene: scene,
                textDescriptors: [],
                committed: .init(
                    generation: .init(
                        documentRevision: 15,
                        replacementGeneration: .zero
                    ),
                    items: originals.enumerated().map {
                        .init(
                            documentIndex: $0.offset,
                            geometry: $0.element,
                            paintedBounds: $0.element.bounds
                        )
                    },
                    replacement: .init(
                        documentIndex: 1,
                        originalGeometry: originals[1],
                        originalPaintedBounds: originals[1].bounds,
                        replacementGeometry: replacement,
                        replacementPaintedBounds: replacement.bounds
                    )
                ),
                viewportRenderPhase: .settled
            )
            let compiler = MetalSceneCompiler()
            let reference = try MetalRenderEngine(device: device).renderOffscreen(
                compiler.compile(scene),
                size: .init(width: 128, height: 128),
                displayScale: 1
            )
            let actual = try tiledEngine.renderOffscreen(
                compiler.compile(presentation),
                size: .init(width: 128, height: 128),
                displayScale: 1
            )

            XCTAssertGreaterThan(tiledEngine.lastCommittedTileReplayCount, 0)
            assertPixelsEqual(actual, reference, tolerance: 64)
        }
    }

    func testTileResourceAccountsGutterAllocationAndDeduplicatesInFlightLease() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let key = try tileKey(zoom: 1)
        let tile = try makeTile(device: device, key: key)
        let expectedBytes = max(278_528, tile.texture.allocatedSize)
        let resources = MetalResourceCache(device: device)

        XCTAssertEqual(tile.byteCount, expectedBytes)
        try resources.insert(
            try MetalCachedResource(tile: tile),
            for: .committedTile(key)
        )
        let lease = try resources.retainInFlight(
            coverage: [],
            fallback: [],
            tiles: [tile],
            textures: []
        )

        XCTAssertTrue(resources.isInFlight(tile))
        XCTAssertEqual(
            try resources.combinedResidentByteCount(
                retaining: [],
                tiles: [tile]
            ),
            expectedBytes
        )
        resources.removeAll()
        XCTAssertEqual(
            try resources.combinedResidentByteCount(retaining: []),
            expectedBytes
        )
        resources.releaseInFlight(lease)
        XCTAssertFalse(resources.isInFlight(tile))
        XCTAssertEqual(try resources.combinedResidentByteCount(retaining: []), 0)
    }

    func testPinnedTileCopyOnWriteDefersWithoutExceedingBudgetOrLosingOldEntry() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let key = try tileKey(zoom: 1)
        let original = try makeTile(device: device, key: key)
        let replacement = try makeTile(device: device, key: key)
        let resources = MetalResourceCache(
            device: device,
            budgetBytes: original.byteCount
        )
        try resources.insert(
            try MetalCachedResource(tile: original),
            for: .committedTile(key)
        )
        let lease = try resources.retainInFlight(
            coverage: [],
            fallback: [],
            tiles: [original],
            textures: []
        )

        XCTAssertThrowsError(try resources.insert(
            try MetalCachedResource(tile: replacement),
            for: .committedTile(key)
        )) {
            XCTAssertEqual($0 as? MetalCanvasError, .resourceBudgetExceeded)
        }
        let retained = try XCTUnwrap(
            resources.peekResource(for: .committedTile(key))?.tile
        )
        XCTAssertTrue(retained.texture === original.texture)
        XCTAssertEqual(resources.residentByteCount, original.byteCount)
        XCTAssertEqual(
            try resources.combinedResidentByteCount(retaining: []),
            original.byteCount
        )

        resources.releaseInFlight(lease)
        XCTAssertNoThrow(try resources.insert(
            try MetalCachedResource(tile: replacement),
            for: .committedTile(key)
        ))
        XCTAssertLessThanOrEqual(
            try resources.combinedResidentByteCount(retaining: []),
            resources.budgetByteCount
        )
    }

    func testAtomicTilePublicationRestoresEveryOldEntryWhenBatchCannotFit() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let firstKey = try tileKey(zoom: 1, x: 0)
        let secondKey = try tileKey(zoom: 1, x: 1)
        let first = try makeTile(device: device, key: firstKey)
        let second = try makeTile(device: device, key: secondKey)
        let firstReplacement = try makeTile(device: device, key: firstKey)
        let secondReplacement = try makeTile(device: device, key: secondKey)
        let resources = MetalResourceCache(
            device: device,
            budgetBytes: first.byteCount + second.byteCount
        )
        try resources.insert(try MetalCachedResource(tile: first), for: .committedTile(firstKey))
        try resources.insert(try MetalCachedResource(tile: second), for: .committedTile(secondKey))
        let lease = try resources.retainInFlight(
            coverage: [],
            fallback: [],
            tiles: [second],
            textures: []
        )

        XCTAssertThrowsError(try resources.insertAtomically([
            (try MetalCachedResource(tile: firstReplacement), .committedTile(firstKey)),
            (try MetalCachedResource(tile: secondReplacement), .committedTile(secondKey)),
        ])) {
            XCTAssertEqual($0 as? MetalCanvasError, .resourceBudgetExceeded)
        }
        XCTAssertTrue(
            resources.peekResource(for: .committedTile(firstKey))?.tile?.texture
                === first.texture
        )
        XCTAssertTrue(
            resources.peekResource(for: .committedTile(secondKey))?.tile?.texture
                === second.texture
        )
        resources.releaseInFlight(lease)
    }

    func testAtomicTilePublicationProtectsEveryTileRequiredByTheFrame() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let retainedKey = try tileKey(zoom: 1, x: 0)
        let disposableKey = try tileKey(zoom: 1, x: 1)
        let appendedKey = try tileKey(zoom: 1, x: 2)
        let retained = try makeTile(device: device, key: retainedKey)
        let disposable = try makeTile(device: device, key: disposableKey)
        let appended = try makeTile(device: device, key: appendedKey)
        let resources = MetalResourceCache(
            device: device,
            budgetBytes: retained.byteCount + disposable.byteCount
        )
        try resources.insert(
            try MetalCachedResource(tile: retained),
            for: .committedTile(retainedKey)
        )
        try resources.insert(
            try MetalCachedResource(tile: disposable),
            for: .committedTile(disposableKey)
        )

        let lease = try resources.retainInFlight(
            coverage: [],
            fallback: [],
            tiles: [appended],
            textures: [],
            protecting: [.committedTile(retainedKey)]
        )
        try resources.insertAtomically(
            [(try MetalCachedResource(tile: appended), .committedTile(appendedKey))],
            protecting: [.committedTile(retainedKey), .committedTile(appendedKey)]
        )

        XCTAssertNotNil(resources.peekResource(for: .committedTile(retainedKey)))
        XCTAssertNotNil(resources.peekResource(for: .committedTile(appendedKey)))
        XCTAssertNil(resources.peekResource(for: .committedTile(disposableKey)))
        XCTAssertLessThanOrEqual(
            try resources.combinedResidentByteCount(retaining: []),
            resources.budgetByteCount
        )
        resources.releaseInFlight(lease)
    }

    func testTileGeometryUsesPhysicalInteriorGutterAndCanonicalNegativeCoordinates() throws {
        let scale = try MetalTileScaleKey(zoom: 1, displayScale: 1)

        XCTAssertEqual(MetalCommittedTileGeometry.interiorPixelLength, 256)
        XCTAssertEqual(MetalCommittedTileGeometry.gutterPixelLength, 1)
        XCTAssertEqual(MetalCommittedTileGeometry.allocationPixelLength, 258)
        XCTAssertEqual(
            try MetalCommittedTileGeometry.documentTileLength(for: scale),
            256,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try MetalCommittedTileGeometry.coordinates(intersecting: CanvasRect(
                x: -256,
                y: -256,
                width: 512,
                height: 512
            ), scale: scale),
            Set([
                .init(x: -1, y: -1), .init(x: 0, y: -1),
                .init(x: -1, y: 0), .init(x: 0, y: 0),
            ])
        )
        XCTAssertEqual(
            try MetalCommittedTileGeometry.coordinates(intersecting: CanvasRect(
                x: 256,
                y: 20,
                width: 0,
                height: 0
            ), scale: scale),
            [.init(x: 1, y: 0)]
        )
    }

    func testOrderedSpatialIndexRebuildsOnlyForCommittedGenerationChanges() throws {
        let generation = CanvasCommittedGeneration(
            documentRevision: 4,
            replacementGeneration: .zero
        )
        let items = [
            committedItem(index: 0, bounds: .init(x: 10, y: 10, width: 40, height: 40)),
            committedItem(index: 2, bounds: .init(x: 240, y: 20, width: 40, height: 20)),
            committedItem(index: 4, bounds: .init(x: 700, y: 700, width: 10, height: 10)),
        ]
        var index = MetalCommittedItemIndex()
        let scale = try MetalTileScaleKey(zoom: 1, displayScale: 1)

        try index.update(generation: generation, items: items)
        try index.update(generation: generation, items: items)

        XCTAssertEqual(index.rebuildCount, 1)
        XCTAssertEqual(
            try index.itemDocumentIndices(
                intersecting: .init(x: 0, y: 0),
                scale: scale
            ),
            [0, 2]
        )
        XCTAssertEqual(
            try index.itemDocumentIndices(
                intersecting: .init(x: 1, y: 0),
                scale: scale
            ),
            [2]
        )

        try index.update(
            generation: .init(documentRevision: 5, replacementGeneration: .zero),
            items: items
        )
        XCTAssertEqual(index.rebuildCount, 2)
    }

    func testSettledPanReusesOverlapAndRequestsOnlyNewlyExposedTiles() throws {
        let committed = committedPresentation()
        var planner = MetalCommittedTilePlanner()
        let firstViewport = try! CanvasViewport.identity(
            size: .init(width: 512, height: 256)
        )
        let first = try planner.plan(
            committed: committed,
            viewport: firstViewport,
            displayScale: 1,
            themeSignature: 9,
            phase: .settled,
            availableKeys: []
        )
        var panned = firstViewport
        panned = try! panned.panned(byScreen: .init(x: -256, y: 0))
        let available = Set(first.requestedKeys)
        let second = try planner.plan(
            committed: committed,
            viewport: panned,
            displayScale: 1,
            themeSignature: 9,
            phase: .settled,
            availableKeys: available
        )

        XCTAssertEqual(Set(first.requestedKeys.map(\.coordinate)), [
            .init(x: 0, y: 0), .init(x: 1, y: 0),
        ])
        XCTAssertEqual(Set(second.reusableKeys.map(\.coordinate)), [
            .init(x: 1, y: 0),
        ])
        XCTAssertEqual(Set(second.missingKeys.map(\.coordinate)), [
            .init(x: 2, y: 0),
        ])
        XCTAssertEqual(planner.statistics.indexRebuildCount, 1)
    }

    func testInteractivePinchUsesNearestAvailableBucketWithoutClaimingExactScale() throws {
        let committed = committedPresentation()
        var planner = MetalCommittedTilePlanner()
        let one = try MetalTileScaleKey(zoom: 1, displayScale: 1)
        let four = try MetalTileScaleKey(zoom: 4, displayScale: 1)
        var available: Set<MetalCommittedTileKey> = [
            .init(coordinate: .init(x: 0, y: 0), scale: one, themeSignature: 2),
        ]
        let viewport = try! CanvasViewport(
            zoom: 3,
            translation: .init(x: 0, y: 0),
            viewportSize: .init(width: 512, height: 512)
        )
        for coordinate in try MetalCommittedTileGeometry.coordinates(
            intersecting: viewport.visibleCanvasRect,
            scale: four
        ) {
            available.insert(.init(
                coordinate: coordinate,
                scale: four,
                themeSignature: 2
            ))
        }

        let interactive = try planner.plan(
            committed: committed,
            viewport: viewport,
            displayScale: 1,
            themeSignature: 2,
            phase: .interactive,
            availableKeys: available
        )
        let settled = try planner.plan(
            committed: committed,
            viewport: viewport,
            displayScale: 1,
            themeSignature: 2,
            phase: .settled,
            availableKeys: available
        )

        XCTAssertEqual(interactive.scale, four)
        XCTAssertFalse(interactive.isExactScale)
        XCTAssertTrue(interactive.missingKeys.isEmpty)
        XCTAssertEqual(interactive.reusableKeys.count, 9)
        XCTAssertEqual(settled.scale, try MetalTileScaleKey(zoom: 3, displayScale: 1))
        XCTAssertTrue(settled.isExactScale)
        XCTAssertEqual(settled.missingKeys.count, 4)
    }

    func testInteractivePinchRejectsCloserIncompleteBucket() throws {
        let committed = committedPresentation()
        var planner = MetalCommittedTilePlanner()
        let one = try MetalTileScaleKey(zoom: 1, displayScale: 1)
        let four = try MetalTileScaleKey(zoom: 4, displayScale: 1)
        let viewport = try! CanvasViewport(
            zoom: 3,
            translation: .init(x: 0, y: 0),
            viewportSize: .init(width: 512, height: 512)
        )
        let available: Set<MetalCommittedTileKey> = [
            .init(coordinate: .init(x: 0, y: 0), scale: one, themeSignature: 2),
            .init(coordinate: .init(x: 0, y: 0), scale: four, themeSignature: 2),
        ]

        let plan = try planner.plan(
            committed: committed,
            viewport: viewport,
            displayScale: 1,
            themeSignature: 2,
            phase: .interactive,
            availableKeys: available
        )

        XCTAssertEqual(plan.scale, one)
        XCTAssertEqual(plan.requestedKeys.count, 1)
        XCTAssertEqual(plan.reusableKeys.count, 1)
        XCTAssertTrue(plan.missingKeys.isEmpty)
    }

    func testReplacementDirtyCoordinatesAreUnionOfOldAndNewPaintedBounds() throws {
        let scale = try MetalTileScaleKey(zoom: 1, displayScale: 1)
        let old = CanvasRect(x: 10, y: 10, width: 20, height: 20)
        let new = CanvasRect(x: 400, y: 10, width: 20, height: 20)

        XCTAssertEqual(
            try MetalCommittedTileGeometry.dirtyCoordinates(
                oldBounds: old,
                newBounds: new,
                scale: scale
            ),
            [.init(x: 0, y: 0), .init(x: 1, y: 0)]
        )
    }

    func testCommittedMutationDirtiesOnlyMovedAndRestyledOldNewUnion() throws {
        let scale = try MetalTileScaleKey(zoom: 1, displayScale: 1)
        let changedID = UUID()
        let unchangedID = UUID()
        let old = [
            committedItem(
                id: changedID,
                index: 0,
                revision: 1,
                bounds: .init(x: 10, y: 10, width: 20, height: 20)
            ),
            committedItem(
                id: unchangedID,
                index: 1,
                revision: 1,
                bounds: .init(x: 700, y: 10, width: 20, height: 20)
            ),
        ]
        let new = [
            committedItem(
                id: changedID,
                index: 0,
                revision: 2,
                bounds: .init(x: 400, y: 10, width: 20, height: 20)
            ),
            old[1],
        ]

        XCTAssertEqual(
            try MetalCommittedTileMutation.dirtyCoordinates(
                from: old,
                to: new,
                oldReplacement: nil,
                newReplacement: nil,
                scale: scale
            ),
            [.init(x: 0, y: 0), .init(x: 1, y: 0)]
        )
    }

    func testCommittedMutationHandlesDeleteUndoAndNoOpExactly() throws {
        let scale = try MetalTileScaleKey(zoom: 1, displayScale: 1)
        let item = committedItem(
            index: 0,
            bounds: .init(x: -300, y: 10, width: 20, height: 20)
        )

        XCTAssertEqual(
            try MetalCommittedTileMutation.dirtyCoordinates(
                from: [item],
                to: [],
                oldReplacement: nil,
                newReplacement: nil,
                scale: scale
            ),
            [.init(x: -2, y: 0)]
        )
        XCTAssertEqual(
            try MetalCommittedTileMutation.dirtyCoordinates(
                from: [],
                to: [item],
                oldReplacement: nil,
                newReplacement: nil,
                scale: scale
            ),
            [.init(x: -2, y: 0)]
        )
        XCTAssertTrue(try MetalCommittedTileMutation.dirtyCoordinates(
            from: [item],
            to: [item],
            oldReplacement: nil,
            newReplacement: nil,
            scale: scale
        ).isEmpty)
    }
}

@MainActor
private func committedRasterFixture() -> [CanvasPreparedGeometry] {
    func geometry(
        path: CanvasPath,
        style: CanvasStyle
    ) -> CanvasPreparedGeometry {
        let id = UUID()
        return CanvasPreparedGeometry(
            id: id,
            renderKey: .committed(id: id, contentRevision: 1),
            path: .immutable(path),
            bounds: path.bounds,
            style: style
        )
    }
    let rectangle = CanvasGeometry.rectangle(.init(
        rect: .init(x: -50, y: -30, width: 100, height: 60)
    )).renderPath
    let line = CanvasPath(commands: [
        .move(.init(x: -58, y: -42)),
        .line(.init(x: 58, y: 42)),
    ])
    let arc = CanvasGeometry.arch(.init(
        start: .init(x: -48, y: 35),
        end: .init(x: 48, y: 35),
        sagitta: -24
    )).renderPath
    let inkID = UUID()
    let ink = CanvasPreparedInk(
        confirmedSamples: [
            .init(point: .init(x: -56, y: 8), pressure: 0.2),
            .init(point: .init(x: -20, y: -12), pressure: 0.8),
            .init(point: .init(x: 18, y: 18), pressure: 0.5),
            .init(point: .init(x: 56, y: -8), pressure: 1),
        ],
        pressureEnabled: true
    )
    let freehand = CanvasPreparedGeometry(
        id: inkID,
        renderKey: .committed(id: inkID, contentRevision: 1),
        path: .ink(ink),
        bounds: .init(x: -56, y: -12, width: 112, height: 30),
        style: .init(
            stroke: .init(red: 0.55, green: 0.05, blue: 0.6, alpha: 0.65),
            lineWidth: 8
        )
    )
    let fallback = CanvasPath(commands: [
        .move(.init(x: -34, y: -48)),
        .cubic(
            control1: .init(x: -8, y: -65),
            control2: .init(x: 8, y: -25),
            end: .init(x: 34, y: -48)
        ),
        .line(.init(x: 0, y: -18)),
        .close,
    ])
    return [
        geometry(
            path: rectangle,
            style: .init(
                stroke: .init(red: 0.05, green: 0.25, blue: 0.8, alpha: 0.7),
                fill: .init(red: 0.2, green: 0.8, blue: 0.45, alpha: 0.35),
                lineWidth: 5
            )
        ),
        geometry(
            path: line,
            style: .init(
                stroke: .init(red: 0.9, green: 0.15, blue: 0.08, alpha: 0.55),
                lineWidth: 7
            )
        ),
        geometry(
            path: arc,
            style: .init(stroke: .black, lineWidth: 4)
        ),
        freehand,
        geometry(
            path: fallback,
            style: .init(
                stroke: .init(red: 0.1, green: 0.1, blue: 0.1, alpha: 0.8),
                fill: .init(red: 0.95, green: 0.75, blue: 0.1, alpha: 0.5),
                lineWidth: 3
            )
        ),
    ]
}

@MainActor
private func committedWidthFixture(
    widthMode: CanvasInkWidthMode
) -> CanvasPreparedGeometry {
    let id = UUID()
    let ink = CanvasPreparedInk(
        confirmedSamples: [
            .init(point: .init(x: 16, y: 64), pressure: 0.3),
            .init(point: .init(x: 112, y: 64), pressure: 0.3),
        ],
        pressureEnabled: true,
        widthMode: widthMode
    )
    return CanvasPreparedGeometry(
        id: id,
        renderKey: .committed(id: id, contentRevision: 1),
        path: .ink(ink),
        bounds: .init(x: 16, y: 64, width: 96, height: 0),
        style: .init(stroke: .black, lineWidth: 4)
    )
}

private func verticalInkSpan(_ texture: any MTLTexture, x: Int) -> Int {
    let bytesPerRow = texture.width * 4
    var bytes = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
    texture.getBytes(
        &bytes,
        bytesPerRow: bytesPerRow,
        from: MTLRegionMake2D(0, 0, texture.width, texture.height),
        mipmapLevel: 0
    )
    return (0..<texture.height).count { y in
        bytes[y * bytesPerRow + x * 4 + 2] < 247
    }
}

@MainActor
private func boxGeometry(
    id: UUID = UUID(),
    renderKey: CanvasRenderKey? = nil,
    rect: CanvasRect,
    color: CanvasColor
) -> CanvasPreparedGeometry {
    let path = CanvasGeometry.rectangle(.init(rect: rect)).renderPath
    return CanvasPreparedGeometry(
        id: id,
        renderKey: renderKey ?? .committed(id: id, contentRevision: 1),
        path: .immutable(path),
        bounds: path.bounds,
        style: .init(
            stroke: .init(red: 0, green: 0, blue: 0, alpha: 0),
            fill: color,
            lineWidth: 1
        )
    )
}

@MainActor
private func rasterScene(
    _ geometry: [CanvasPreparedGeometry],
    viewport: CanvasViewport,
    includesDecorations: Bool = false,
    previewGeneration: RecognitionGeneration? = nil
) -> CanvasPreparedScene {
    CanvasPreparedScene(
        geometry: geometry,
        gridLines: includesDecorations ? [
            .init(start: .init(x: -64, y: 0), end: .init(x: 64, y: 0)),
            .init(start: .init(x: 0, y: -64), end: .init(x: 0, y: 64)),
        ] : [],
        selectionBounds: includesDecorations ? geometry.first?.bounds : nil,
        guides: includesDecorations ? [.vertical(canvasX: 36)] : [],
        viewport: viewport,
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
        previewGeneration: previewGeneration
    )
}

@MainActor
private func presentation(
    geometry: [CanvasPreparedGeometry],
    committedItems: [CanvasCommittedItem],
    revision: UInt64,
    viewport: CanvasViewport,
    previewGeneration: RecognitionGeneration? = nil
) -> CanvasPreparedPresentation {
    CanvasPreparedPresentation(
        scene: rasterScene(
            geometry,
            viewport: viewport,
            previewGeneration: previewGeneration
        ),
        textDescriptors: [],
        committed: .init(
            generation: .init(
                documentRevision: revision,
                replacementGeneration: .zero
            ),
            items: committedItems,
            replacement: nil
        ),
        viewportRenderPhase: .settled
    )
}

@MainActor
private func assertPixelsEqual(
    _ actual: any MTLTexture,
    _ expected: any MTLTexture,
    tolerance: Int,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(actual.width, expected.width, file: file, line: line)
    XCTAssertEqual(actual.height, expected.height, file: file, line: line)
    let byteCount = actual.width * actual.height * 4
    var actualBytes = [UInt8](repeating: 0, count: byteCount)
    var expectedBytes = [UInt8](repeating: 0, count: byteCount)
    actual.getBytes(
        &actualBytes,
        bytesPerRow: actual.width * 4,
        from: MTLRegionMake2D(0, 0, actual.width, actual.height),
        mipmapLevel: 0
    )
    expected.getBytes(
        &expectedBytes,
        bytesPerRow: expected.width * 4,
        from: MTLRegionMake2D(0, 0, expected.width, expected.height),
        mipmapLevel: 0
    )
    let differences = actualBytes.indices.map {
        abs(Int(actualBytes[$0]) - Int(expectedBytes[$0]))
    }.sorted()
    let mean = Double(differences.reduce(0, +)) / Double(max(1, differences.count))
    let p99Index = min(
        differences.count - 1,
        Int(Double(differences.count) * 0.99)
    )
    XCTAssertLessThanOrEqual(mean, 8, file: file, line: line)
    XCTAssertLessThanOrEqual(differences[p99Index], 32, file: file, line: line)
    XCTAssertLessThanOrEqual(differences.last ?? 0, tolerance, file: file, line: line)
}

@MainActor
private func tileKey(zoom: Double, x: Int = 0) throws -> MetalCommittedTileKey {
    MetalCommittedTileKey(
        coordinate: .init(x: x, y: 0),
        scale: try MetalTileScaleKey(zoom: zoom, displayScale: 1),
        themeSignature: 1
    )
}

@MainActor
private func makeTile(
    device: any MTLDevice,
    key: MetalCommittedTileKey
) throws -> MetalCommittedTileResource {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm,
        width: MetalCommittedTileGeometry.allocationPixelLength,
        height: MetalCommittedTileGeometry.allocationPixelLength,
        mipmapped: false
    )
    descriptor.storageMode = .private
    descriptor.usage = [.renderTarget, .shaderRead]
    return try MetalCommittedTileResource(
        key: key,
        texture: XCTUnwrap(device.makeTexture(descriptor: descriptor))
    )
}

@MainActor
private func committedItem(
    id: UUID = UUID(),
    index: Int,
    revision: UInt64 = 1,
    bounds: CanvasRect
) -> CanvasCommittedItem {
    let geometry = CanvasPreparedGeometry(
        id: id,
        renderKey: .committed(id: id, contentRevision: revision),
        path: .immutable(CanvasPath(commands: [
            .move(.init(x: bounds.minX, y: bounds.minY)),
            .line(.init(x: bounds.maxX, y: bounds.maxY)),
        ])),
        bounds: bounds,
        style: .default
    )
    return CanvasCommittedItem(
        documentIndex: index,
        geometry: geometry,
        paintedBounds: bounds
    )
}

@MainActor
private func committedItem(
    geometry: CanvasPreparedGeometry,
    index: Int
) -> CanvasCommittedItem {
    CanvasCommittedItem(
        documentIndex: index,
        geometry: geometry,
        paintedBounds: geometry.bounds
    )
}

@MainActor
private func committedPresentation() -> CanvasCommittedPresentation {
    CanvasCommittedPresentation(
        generation: .init(documentRevision: 1, replacementGeneration: .zero),
        items: [
            committedItem(index: 0, bounds: .init(x: -1_000, y: -1_000, width: 2_000, height: 2_000)),
        ],
        replacement: nil
    )
}

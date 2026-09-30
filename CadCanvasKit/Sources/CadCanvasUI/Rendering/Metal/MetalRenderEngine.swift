import CoreGraphics
import CadCanvasCore
import Metal

@MainActor
final class MetalRenderEngine {
    private static let maximumTextureDimension = 16_384
    private static let fallbackSupersampleScale = 4
    private let device: any MTLDevice
    private let pipelines: MetalPipelineLibrary
    private let commandQueue: any MTLCommandQueue
    private let resources: MetalResourceCache
    private let freehandCoverage: MetalFreehandCoverageCache
    private let pathFallback: MetalPathFallbackCache
    private let tileCompiler = MetalSceneCompiler()
    private var tilePlanner = MetalCommittedTilePlanner()
    private var tileGeneration: CanvasCommittedGeneration?
    private var tileReplacementKey: CanvasRenderKey?
    private var tileReplacementPreviewGeneration: RecognitionGeneration?
    private var publishedCommittedItems: [CanvasCommittedItem] = []
    private var publishedReplacement: CanvasCommittedReplacement?
    private var availableTileKeys = Set<MetalCommittedTileKey>()

    private(set) var outputCommandBufferCount = 0
    private(set) var maximumOwnedCoverageByteCount = 0
    private(set) var synchronousOutputWaitCount = 0
    private(set) var lastPreparedFreehandInputCount = 0
    private(set) var lastCommittedTileReplayCount = 0
    private(set) var lastCommittedCoverageEncodeCount = 0
    private(set) var lastLiveCoverageEncodeCount = 0
    private(set) var committedPresentationItemVisitCount = 0
    var hasActiveFreehandCoverage: Bool { freehandCoverage.hasActiveCoverage }
    var derivedFreehandResourceCount: Int { freehandCoverage.resourceCount }
    var residentFreehandByteCount: Int { freehandCoverage.residentByteCount }
    var inFlightResourceLeaseCount: Int { resources.inFlightLeaseCount }
    var freehandCoverageCommandBufferCount: Int {
        freehandCoverage.statistics.coverageCommandBufferCount
    }
    var transientTailEncodeCount: Int {
        freehandCoverage.statistics.transientTailEncodeCount
    }
    var prefixToScratchCopyCount: Int {
        freehandCoverage.statistics.prefixToScratchCopyCount
    }
    var transientCoverageAllocationCount: Int {
        freehandCoverage.statistics.transientCoverageAllocationCount
    }
    var freehandCommitReuseCount: Int {
        freehandCoverage.statistics.commitReuseCount
    }
    var activeFreehandCoverageIsInFlight: Bool {
        freehandCoverage.activeCoverageIsInFlight
    }

    func handleMemoryPressure() {
        freehandCoverage.handleMemoryPressure()
        resetCommittedTileState()
    }

    convenience init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalCanvasError.deviceUnavailable
        }
        try self.init(device: device)
    }

    convenience init(device: any MTLDevice) throws {
        try self.init(
            device: device,
            resourceBudgetBytes: CanvasMetalLimits.resourceBudgetBytes
        )
    }

    init(device: any MTLDevice, resourceBudgetBytes: Int) throws {
        guard let commandQueue = device.makeCommandQueue() else {
            throw MetalCanvasError.deviceUnavailable
        }
        let pipelineLibrary = try MetalPipelineLibrary(device: device)
        let resourceCache = MetalResourceCache(
            device: device,
            budgetBytes: resourceBudgetBytes
        )
        self.device = device
        pipelines = pipelineLibrary
        self.commandQueue = commandQueue
        resources = resourceCache
        freehandCoverage = try MetalFreehandCoverageCache(
            device: device,
            coveragePipeline: pipelineLibrary.coverageSegment,
            resourceCache: resourceCache
        )
        pathFallback = MetalPathFallbackCache(
            device: device,
            resourceCache: resourceCache
        )
    }

    func renderOffscreen(
        _ scene: MetalCompiledScene,
        size: CGSize,
        displayScale: Double
    ) throws -> any MTLTexture {
        try render(
            scene,
            size: size,
            displayScale: displayScale,
            destinationTexture: nil
        )
    }

    func render(
        _ scene: MetalCompiledScene,
        into texture: any MTLTexture,
        size: CGSize,
        displayScale: Double,
        configureFinalOutputCommandBuffer: ((any MTLCommandBuffer) -> Void)? = nil
    ) throws {
        if let configureFinalOutputCommandBuffer {
            try renderOnscreen(
                scene,
                into: texture,
                size: size,
                displayScale: displayScale,
                configureBeforeCommit: configureFinalOutputCommandBuffer
            )
            return
        }
        _ = try render(
            scene,
            size: size,
            displayScale: displayScale,
            destinationTexture: texture,
            configureFinalOutputCommandBuffer: nil
        )
    }

    func renderPresentedFrame(
        _ scene: MetalCompiledScene,
        into texture: any MTLTexture,
        size: CGSize,
        displayScale: Double,
        configureBeforeCommit: (any MTLCommandBuffer) -> Void,
        completion: @escaping @MainActor (Bool) -> Void
    ) throws {
        try renderOnscreen(
            scene,
            into: texture,
            size: size,
            displayScale: displayScale,
            configureBeforeCommit: configureBeforeCommit,
            completion: completion
        )
    }

    func invalidateSizeDependentResources() {
        freehandCoverage.reset()
    }

    private func render(
        _ scene: MetalCompiledScene,
        size: CGSize,
        displayScale: Double,
        destinationTexture: (any MTLTexture)?,
        configureFinalOutputCommandBuffer: ((any MTLCommandBuffer) -> Void)? = nil
    ) throws -> any MTLTexture {
        let composition = try prepareCommittedComposition(
            scene,
            displayScale: displayScale
        )
        let tiles = committedTiles(in: composition.scene)
        let preparationLease = try tiles.isEmpty ? nil : resources.retainInFlight(
            coverage: [],
            fallback: [],
            tiles: tiles,
            textures: []
        )
        defer {
            if let preparationLease {
                resources.releaseInFlight(preparationLease)
            }
        }
        let texture = try renderLegacy(
            composition.scene,
            size: size,
            displayScale: displayScale,
            destinationTexture: destinationTexture,
            configureFinalOutputCommandBuffer: configureFinalOutputCommandBuffer
        )
        lastCommittedTileReplayCount += composition.replayedTileCount
        lastCommittedCoverageEncodeCount += composition.committedCoverageEncodeCount
        return texture
    }

    private func renderLegacy(
        _ scene: MetalCompiledScene,
        size: CGSize,
        displayScale: Double,
        destinationTexture: (any MTLTexture)?,
        configureFinalOutputCommandBuffer: ((any MTLCommandBuffer) -> Void)? = nil
    ) throws -> any MTLTexture {
        lastPreparedFreehandInputCount = 0
        resetFrameWorkStatistics()
        var submissionSucceeded = false
        defer {
            if !submissionSucceeded {
                lastPreparedFreehandInputCount = 0
                resetFrameWorkStatistics()
            }
        }
        let dimensions = try textureDimensions(size: size, displayScale: displayScale)
        let outputPlan = try outputTexturePlan(dimensions: dimensions)
        let fallbackPlans = try preflightFallbackPlans(
            scene,
            displayScale: displayScale,
            outputDimensions: dimensions
        )
        let maximumSurfaceByteCount = fallbackPlans.values
            .map(\.estimatedByteCount)
            .max() ?? 0
        let freehandGeometries = scene.renderItems.compactMap { item -> CanvasPreparedGeometry? in
            guard case .freehand(let descriptor) = item else { return nil }
            return descriptor.geometry
        }
        let freehandFramePlan = try freehandCoverage.makeFramePlan(
            geometries: freehandGeometries,
            viewport: scene.viewport,
            displayScale: displayScale
        )
        lastPreparedFreehandInputCount = freehandFramePlan.preparedInputCount
        let transientFreehands = try freehandGeometries.filter { geometry in
            try freehandCoverage.requiresTransientCoverage(
                geometry,
                using: freehandFramePlan
            )
        }
        let maximumTransientPointCount = try freehandCoverage.maximumPointCount(
            in: transientFreehands,
            using: freehandFramePlan
        )
        let scratchCoverageByteCount = transientFreehands.isEmpty
            ? 0
            : try freehandCoverage.transientCoverageByteCount(
                maximumPointCount: maximumTransientPointCount,
                viewport: scene.viewport,
                displayScale: displayScale
            )
        let outputTransientByteCount = destinationTexture == nil
            ? outputPlan.estimatedByteCount
            : 0
        var baseTransientByteCount = try checkedSum([
            outputTransientByteCount,
            scratchCoverageByteCount,
        ])
        let maximumOperationTransientByteCount = try checkedSum([
            baseTransientByteCount,
            maximumSurfaceByteCount,
        ])
        try resources.reserveTransient(byteCount: baseTransientByteCount)
        defer { resources.releaseTransientReservation() }
        var preparedFallbacks: [Int: PreparedFallback] = [:]
        var retainedFallbacks: [MetalFallbackResource] = []
        for index in fallbackPlans.keys.sorted() {
            guard case .fallback(let descriptor) = scene.renderItems[index],
                  let surfacePlan = fallbackPlans[index] else { continue }
            let estimatedBytes = try pathFallback.estimatedAdditionalByteCount(
                geometry: descriptor.geometry,
                viewport: scene.viewport,
                displayScale: displayScale
            )
            try resources.reserve(
                additionalByteCount: estimatedBytes,
                retaining: [],
                fallback: retainedFallbacks
            )
            let resource = try pathFallback.prepare(
                geometry: descriptor.geometry,
                viewport: scene.viewport,
                displayScale: displayScale
            )
            retainedFallbacks.append(resource)
            preparedFallbacks[index] = PreparedFallback(
                resource: resource,
                surfacePlan: surfacePlan
            )
        }
        var maximumPreFallbackFreehandByteCount = 0
        if !retainedFallbacks.isEmpty {
            var maximumFreehandByteCount = 0
            let lastFallbackIndex = fallbackPlans.keys.max()
            for (index, item) in scene.renderItems.enumerated() {
                guard case .freehand(let descriptor) = item else { continue }
                let estimate = try freehandCoverage.estimatedCoverageByteCount(
                    geometry: descriptor.geometry,
                    using: freehandFramePlan
                )
                maximumFreehandByteCount = max(maximumFreehandByteCount, estimate)
                if let lastFallbackIndex, index < lastFallbackIndex {
                    maximumPreFallbackFreehandByteCount = max(
                        maximumPreFallbackFreehandByteCount,
                        estimate
                    )
                }
            }
            try resources.reserve(
                additionalByteCount: maximumFreehandByteCount,
                retaining: [],
                fallback: retainedFallbacks
            )
        }
        try resources.reserve(
            additionalByteCount: 0,
            retaining: [],
            fallback: retainedFallbacks
        )
        let preflightResidentBytes = try resources.combinedResidentByteCount(
            retaining: [],
            fallback: retainedFallbacks
        )
        let preflightOwnedBytes = try checkedSum([
            preflightResidentBytes,
            maximumOperationTransientByteCount,
            maximumPreFallbackFreehandByteCount,
        ])
        guard preflightOwnedBytes <= resources.budgetByteCount else {
            throw MetalCanvasError.resourceBudgetExceeded
        }
        maximumOwnedCoverageByteCount = max(
            maximumOwnedCoverageByteCount,
            preflightOwnedBytes
        )
        let texture: any MTLTexture
        if let destinationTexture {
            guard destinationTexture.width == dimensions.width,
                  destinationTexture.height == dimensions.height,
                  destinationTexture.pixelFormat == .bgra8Unorm,
                  destinationTexture.usage.contains(.renderTarget) else {
                throw MetalCanvasError.invalidResourceSize
            }
            texture = destinationTexture
        } else {
            guard let allocatedTexture = device.makeTexture(descriptor: outputPlan.descriptor) else {
                throw MetalCanvasError.invalidResourceSize
            }
            let outputByteCount = try MetalCachedResource.conservativeAllocationByteCount(
                payloadByteCount: outputPlan.payloadByteCount,
                reportedByteCount: allocatedTexture.allocatedSize
            )
            baseTransientByteCount = try checkedSum([
                outputByteCount,
                scratchCoverageByteCount,
            ])
            try resources.reserveTransient(byteCount: baseTransientByteCount)
            try resources.reserve(
                additionalByteCount: 0,
                retaining: [],
                fallback: retainedFallbacks
            )
            let actualOwnedBytes = try checkedSum([
                resources.combinedResidentByteCount(
                    retaining: [],
                    fallback: retainedFallbacks
                ),
                baseTransientByteCount,
            ])
            maximumOwnedCoverageByteCount = max(
                maximumOwnedCoverageByteCount,
                actualOwnedBytes
            )
            texture = allocatedTexture
        }
        let coverageScratch = transientFreehands.isEmpty
            ? nil
            : try freehandCoverage.makeTransientCoverage(
                maximumPointCount: maximumTransientPointCount,
                viewport: scene.viewport,
                displayScale: displayScale
            )

        if let activeElementID = freehandCoverage.activeElementID {
            let sceneRetainsActiveElement = scene.renderItems.contains { item in
                guard case .freehand(let descriptor) = item else { return false }
                return descriptor.geometry.id == activeElementID
            }
            if !sceneRetainsActiveElement {
                freehandCoverage.reset()
            }
        }
        var batch = try makeOutputBatch(
            texture: texture,
            loadAction: .clear,
            background: scene.background,
            dimensions: dimensions
        )
        for (itemIndex, item) in scene.renderItems.enumerated() {
            if case .freehand(let descriptor) = item {
                let shouldPreparePersistent: Bool
                switch descriptor.geometry.renderKey {
                case .preview:
                    shouldPreparePersistent = true
                case .committed:
                    shouldPreparePersistent = freehandCoverage.activeElementID
                        == descriptor.geometry.id
                }
                let estimatedBytes = shouldPreparePersistent
                    ? try freehandCoverage.additionalCoverageByteCount(
                        geometry: descriptor.geometry,
                        using: freehandFramePlan
                    )
                    : 0
                let ownedBytes = try ownedByteCount(
                    batch,
                    retainingFallback: retainedFallbacks
                )
                let projectedBytes = ownedBytes.addingReportingOverflow(estimatedBytes)
                guard !projectedBytes.overflow else {
                    throw MetalCanvasError.invalidResourceSize
                }
                if batch.hasRetainedResources,
                   projectedBytes.partialValue > resources.availableBudgetByteCount {
                    try finishOutputBatch(batch)
                    batch = try makeOutputBatch(
                        texture: texture,
                        loadAction: .load,
                        background: scene.background,
                        dimensions: dimensions
                    )
                }
                try resources.reserve(
                    additionalByteCount: estimatedBytes,
                    retaining: batch.retainedCoverage,
                    fallback: batch.retainedFallback + retainedFallbacks
                )
                try finishOutputBatch(batch)
                if shouldPreparePersistent {
                    try freehandCoverage.prepare(
                        geometry: descriptor.geometry,
                        using: freehandFramePlan,
                        viewport: scene.viewport,
                        displayScale: displayScale
                    )
                }
                let coverage: MetalCoverageResource
                let prepared = freehandCoverage.coverage(
                    for: descriptor.geometry,
                    viewport: scene.viewport,
                    displayScale: displayScale
                )
                if let prepared,
                   prepared.prefixVertexCount == prepared.vertexSequence.count {
                    coverage = prepared
                } else if let coverageScratch,
                          let coverageCommandBuffer = commandQueue.makeCommandBuffer() {
                    coverage = try freehandCoverage.encodeTransientCoverage(
                        geometry: descriptor.geometry,
                        using: coverageScratch,
                        framePlan: freehandFramePlan,
                        commandBuffer: coverageCommandBuffer
                    ).coverage
                    recordCoverageEncode(for: descriptor.geometry.renderKey)
                    coverageCommandBuffer.commit()
                    coverageCommandBuffer.waitUntilCompleted()
                    guard coverageCommandBuffer.status == .completed else {
                        throw MetalCanvasError.commandBufferFailed
                    }
                } else if prepared == nil {
                    batch = try makeOutputBatch(
                        texture: texture,
                        loadAction: .load,
                        background: scene.background,
                        dimensions: dimensions
                    )
                    continue
                } else {
                    throw MetalCanvasError.commandEncodingFailed
                }
                batch = try makeOutputBatch(
                    texture: texture,
                    loadAction: .load,
                    background: scene.background,
                    dimensions: dimensions
                )
                _ = try encode(
                    item,
                    viewport: scene.viewport,
                    coordinateOrigin: scene.renderCoordinateOrigin,
                    displayScale: displayScale,
                    textureSize: dimensions,
                    encoder: batch.encoder,
                    overridingCoverage: coverage
                )
                batch.retainedCoverage.append(coverage)
                try finishOutputBatch(batch)
                batch = try makeOutputBatch(
                    texture: texture,
                    loadAction: .load,
                    background: scene.background,
                    dimensions: dimensions
                )
                continue
            } else if case .fallback = item {
                guard let prepared = preparedFallbacks[itemIndex] else { continue }
                let fallback = prepared.resource
                guard !fallback.fillIndexRange.isEmpty
                    || !fallback.strokeIndexRange.isEmpty else {
                    continue
                }
                try finishOutputBatch(batch)
                let fallbackTransientByteCount = try checkedSum([
                    baseTransientByteCount,
                    prepared.surfacePlan.estimatedByteCount,
                ])
                try resources.reserveTransient(byteCount: fallbackTransientByteCount)
                do {
                    let surface = try makeFallbackSurface(
                        plan: prepared.surfacePlan,
                        retaining: retainedFallbacks,
                        transientByteCount: fallbackTransientByteCount
                    )
                    try renderFallback(
                        fallback,
                        viewport: scene.viewport,
                        displayScale: displayScale,
                        surface: surface,
                        outputDimensions: dimensions
                    )
                    batch = try makeOutputBatch(
                        texture: texture,
                        loadAction: .load,
                        background: scene.background,
                        dimensions: dimensions
                    )
                    batch.retainedFallback.append(fallback)
                    batch.retainedTextures.append(MetalInFlightTexture(
                        texture: surface.supersampleColor,
                        byteCount: surface.colorByteCount
                    ))
                    batch.retainedTextures.append(MetalInFlightTexture(
                        texture: surface.stencil,
                        byteCount: surface.stencilByteCount
                    ))
                    encodeComposite(
                        surface.supersampleColor,
                        outputRect: surface.outputRect,
                        encoder: batch.encoder
                    )
                    try finishOutputBatch(batch)
                } catch {
                    resources.restoreTransientReservation(
                        byteCount: baseTransientByteCount
                    )
                    throw error
                }
                resources.restoreTransientReservation(
                    byteCount: baseTransientByteCount
                )
                batch = try makeOutputBatch(
                    texture: texture,
                    loadAction: .load,
                    background: scene.background,
                    dimensions: dimensions
                )
                continue
            }
            if let retained = try encode(
                item,
                viewport: scene.viewport,
                coordinateOrigin: scene.renderCoordinateOrigin,
                displayScale: displayScale,
                textureSize: dimensions,
                encoder: batch.encoder
            ) {
                switch retained {
                case .coverage(let coverage):
                    batch.retainedCoverage.append(coverage)
                case .tile(let tile):
                    batch.retainedTiles.append(tile)
                }
                let ownedBytes = try ownedByteCount(
                    batch,
                    retainingFallback: retainedFallbacks
                )
                let transientBytes = resources.budgetByteCount
                    - resources.availableBudgetByteCount
                let totalOwned = ownedBytes.addingReportingOverflow(transientBytes)
                guard !totalOwned.overflow,
                      totalOwned.partialValue <= resources.budgetByteCount else {
                    throw MetalCanvasError.resourceBudgetExceeded
                }
                maximumOwnedCoverageByteCount = max(
                    maximumOwnedCoverageByteCount,
                    totalOwned.partialValue
                )
            }
        }
        try finishOutputBatch(
            batch,
            configureBeforeCommit: configureFinalOutputCommandBuffer
        )
        submissionSucceeded = true
        return texture
    }
}

private extension MetalRenderEngine {
    typealias PixelSize = (width: Int, height: Int)

    struct CommittedComposition {
        let scene: MetalCompiledScene
        let replayedTileCount: Int
        let committedCoverageEncodeCount: Int
    }

    struct TileBuildCounts {
        let tile: MetalCommittedTileResource
        let committedCoverageEncodeCount: Int
    }

    func resetCommittedTileState() {
        for key in availableTileKeys {
            resources.removeResource(for: .committedTile(key))
        }
        availableTileKeys.removeAll(keepingCapacity: false)
        tileGeneration = nil
        tileReplacementKey = nil
        tileReplacementPreviewGeneration = nil
        publishedCommittedItems = []
        publishedReplacement = nil
        tilePlanner = MetalCommittedTilePlanner()
        tileCompiler.resetDerivedRenderCaches()
    }

    func prepareCommittedComposition(
        _ scene: MetalCompiledScene,
        displayScale: Double
    ) throws -> CommittedComposition {
        guard let committedLayer = scene.committedLayer else {
            return CommittedComposition(
                scene: scene,
                replayedTileCount: 0,
                committedCoverageEncodeCount: 0
            )
        }
        let committed = committedLayer.plannerPresentation
        let generation = committed.generation
        availableTileKeys = Set(availableTileKeys.filter {
            resources.peekResource(for: .committedTile($0))?.tile != nil
        })
        let replacementKey = committedLayer.replacement?
            .replacement.geometry.renderKey
        let replacementPreviewGeneration = committedLayer.replacement == nil
            ? nil
            : scene.previewGeneration
        let mutationChanged = tileGeneration != generation
            || tileReplacementKey != replacementKey
            || tileReplacementPreviewGeneration != replacementPreviewGeneration
        if mutationChanged {
            tileCompiler.resetDerivedRenderCaches()
        }
        let dirtyKeys = try mutationChanged ? dirtyTileKeys(
            from: publishedCommittedItems,
            to: committed.items,
            oldReplacement: publishedReplacement,
            newReplacement: committed.replacement
        ) : []
        guard !committed.items.isEmpty else {
            for key in availableTileKeys {
                resources.removeResource(for: .committedTile(key))
            }
            availableTileKeys.removeAll(keepingCapacity: true)
            publishCommittedSnapshot(
                committed,
                replacementKey: replacementKey,
                replacementPreviewGeneration: replacementPreviewGeneration
            )
            return CommittedComposition(
                scene: dynamicScene(scene, tiles: []),
                replayedTileCount: 0,
                committedCoverageEncodeCount: 0
            )
        }
        let plan = try tilePlanner.plan(
            committed: committed,
            viewport: scene.viewport,
            displayScale: displayScale,
            themeSignature: 0,
            phase: scene.viewportRenderPhase,
            availableKeys: availableTileKeys.subtracting(dirtyKeys)
        )
        if let patched = try patchAppendedFreehandTiles(
            scene: scene,
            committedLayer: committedLayer,
            committed: committed,
            plan: plan,
            mutationChanged: mutationChanged,
            replacementKey: replacementKey,
            replacementPreviewGeneration: replacementPreviewGeneration
        ) {
            return patched
        }
        var replayedTileCount = 0
        var committedCoverageEncodeCount = 0
        var stagedTiles: [MetalCommittedTileResource] = []
        var stagedLeases: [MetalInFlightResourceLease] = []
        defer {
            for lease in stagedLeases {
                resources.releaseInFlight(lease)
            }
        }
        for key in plan.missingKeys {
            let counts = try buildCommittedTile(
                key,
                scene: scene,
                committedLayer: committedLayer
            )
            stagedTiles.append(counts.tile)
            stagedLeases.append(try resources.retainInFlight(
                coverage: [],
                fallback: [],
                tiles: [counts.tile],
                textures: []
            ))
            replayedTileCount += 1
            committedCoverageEncodeCount += counts.committedCoverageEncodeCount
        }
        try resources.insertAtomically(stagedTiles.map {
            (try MetalCachedResource(tile: $0), .committedTile($0.key))
        })
        for key in dirtyKeys where !plan.missingKeys.contains(key) {
            resources.removeResource(for: .committedTile(key))
            availableTileKeys.remove(key)
        }
        availableTileKeys.formUnion(plan.missingKeys)
        availableTileKeys = Set(availableTileKeys.filter {
            resources.peekResource(for: .committedTile($0))?.tile != nil
        })
        publishCommittedSnapshot(
            committed,
            replacementKey: replacementKey,
            replacementPreviewGeneration: replacementPreviewGeneration
        )
        let tiles = plan.requestedKeys.compactMap {
            resources.resource(for: .committedTile($0))?.tile
        }
        guard tiles.count == plan.requestedKeys.count else {
            return CommittedComposition(
                scene: scene,
                replayedTileCount: replayedTileCount,
                committedCoverageEncodeCount: committedCoverageEncodeCount
            )
        }
        return CommittedComposition(
            scene: dynamicScene(scene, tiles: tiles),
            replayedTileCount: replayedTileCount,
            committedCoverageEncodeCount: committedCoverageEncodeCount
        )
    }

    func patchAppendedFreehandTiles(
        scene: MetalCompiledScene,
        committedLayer: MetalCompiledCommittedLayer,
        committed: CanvasCommittedPresentation,
        plan: MetalCommittedTilePlan,
        mutationChanged: Bool,
        replacementKey: CanvasRenderKey?,
        replacementPreviewGeneration: RecognitionGeneration?
    ) throws -> CommittedComposition? {
        guard mutationChanged,
              tileGeneration != nil,
              plan.isExactScale,
              publishedReplacement == nil,
              committed.replacement == nil,
              committed.items.count == publishedCommittedItems.count + 1,
              committedLayer.items.count == committed.items.count,
              zip(publishedCommittedItems, committed.items).allSatisfy({ old, new in
                  old.documentIndex == new.documentIndex
                      && old.geometry.id == new.geometry.id
                      && old.geometry.renderKey == new.geometry.renderKey
                      && old.paintedBounds == new.paintedBounds
              }),
              let appended = committedLayer.items.last,
              case .freehand = appended.item else {
            return nil
        }
        if plan.missingKeys.isEmpty {
            publishCommittedSnapshot(
                committed,
                replacementKey: replacementKey,
                replacementPreviewGeneration: replacementPreviewGeneration
            )
            let tiles = plan.requestedKeys.compactMap {
                resources.resource(for: .committedTile($0))?.tile
            }
            guard tiles.count == plan.requestedKeys.count else { return nil }
            return CommittedComposition(
                scene: dynamicScene(scene, tiles: tiles),
                replayedTileCount: 0,
                committedCoverageEncodeCount: 0
            )
        }

        let baseTiles = plan.missingKeys.compactMap { key -> MetalCommittedTileResource? in
            resources.peekResource(for: .committedTile(key))?.tile
        }
        guard publishedCommittedItems.isEmpty
                || baseTiles.count == plan.missingKeys.count else {
            return nil
        }
        let reusableBaseKeys = Set(baseTiles.compactMap { tile in
            resources.isInFlight(tile) ? nil : tile.key
        })
        let baseLease = try resources.retainInFlight(
            coverage: [],
            fallback: [],
            tiles: baseTiles,
            textures: []
        )
        defer { resources.releaseInFlight(baseLease) }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalCanvasError.commandEncodingFailed
        }
        try freehandCoverage.commit(
            geometry: appended.geometry,
            viewport: scene.viewport,
            displayScale: plan.scale.displayScale,
            encodingOn: commandBuffer
        )
        guard let coverage = freehandCoverage.coverage(
            for: appended.geometry,
            viewport: scene.viewport,
            displayScale: plan.scale.displayScale
        ) else {
            throw MetalCanvasError.commandEncodingFailed
        }

        let baseByKey = Dictionary(uniqueKeysWithValues: baseTiles.map { ($0.key, $0) })
        let stagedTiles = try plan.missingKeys.map { key in
            try makePatchedTile(
                key: key,
                base: baseByKey[key],
                appended: appended,
                coverage: coverage,
                scene: scene,
                commandBuffer: commandBuffer,
                reusingBase: reusableBaseKeys.contains(key)
            )
        }
        let patchLease = try resources.retainInFlight(
            coverage: [coverage],
            fallback: [],
            tiles: baseTiles + stagedTiles,
            textures: [],
            protecting: Set(
                plan.requestedKeys.map(MetalResourceKey.committedTile)
            )
        )
        do {
            try resources.insertAtomically(stagedTiles.map {
                (try MetalCachedResource(tile: $0), .committedTile($0.key))
            }, protecting: Set(
                plan.requestedKeys.map(MetalResourceKey.committedTile)
            ))
        } catch {
            resources.releaseInFlight(patchLease)
            throw error
        }
        commandBuffer.addCompletedHandler { [weak self] buffer in
            let succeeded = buffer.status == .completed
            Task { @MainActor in
                guard let self else { return }
                self.resources.releaseInFlight(patchLease)
                if !succeeded {
                    self.freehandCoverage.handleMemoryPressure()
                    self.resetCommittedTileState()
                }
            }
        }
        commandBuffer.commit()
        availableTileKeys.formUnion(plan.missingKeys)
        publishCommittedSnapshot(
            committed,
            replacementKey: replacementKey,
            replacementPreviewGeneration: replacementPreviewGeneration
        )
        let tiles = plan.requestedKeys.compactMap {
            resources.resource(for: .committedTile($0))?.tile
        }
        guard tiles.count == plan.requestedKeys.count else {
            throw MetalCanvasError.resourceBudgetExceeded
        }
        return CommittedComposition(
            scene: dynamicScene(scene, tiles: tiles),
            replayedTileCount: 0,
            committedCoverageEncodeCount: 0
        )
    }

    func makePatchedTile(
        key: MetalCommittedTileKey,
        base: MetalCommittedTileResource?,
        appended: MetalCommittedDrawItem,
        coverage: MetalCoverageResource,
        scene: MetalCompiledScene,
        commandBuffer: any MTLCommandBuffer,
        reusingBase: Bool
    ) throws -> MetalCommittedTileResource {
        let tile: MetalCommittedTileResource
        if let base, reusingBase {
            tile = base
        } else {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: MetalCommittedTileGeometry.allocationPixelLength,
                height: MetalCommittedTileGeometry.allocationPixelLength,
                mipmapped: false
            )
            descriptor.storageMode = .private
            descriptor.usage = [.renderTarget, .shaderRead]
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw MetalCanvasError.invalidResourceSize
            }
            tile = try MetalCommittedTileResource(key: key, texture: texture)
        }
        let texture = tile.texture
        if let base, !reusingBase {
            guard let blit = commandBuffer.makeBlitCommandEncoder() else {
                throw MetalCanvasError.commandEncodingFailed
            }
            let size = MTLSize(
                width: MetalCommittedTileGeometry.allocationPixelLength,
                height: MetalCommittedTileGeometry.allocationPixelLength,
                depth: 1
            )
            blit.copy(
                from: base.texture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: .init(x: 0, y: 0, z: 0),
                sourceSize: size,
                to: texture,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: .init(x: 0, y: 0, z: 0)
            )
            blit.endEncoding()
        }

        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = texture
        renderPass.colorAttachments[0].loadAction = base == nil ? .clear : .load
        renderPass.colorAttachments[0].storeAction = .store
        renderPass.colorAttachments[0].clearColor = .init(red: 0, green: 0, blue: 0, alpha: 0)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
            throw MetalCanvasError.commandEncodingFailed
        }
        defer { encoder.endEncoding() }
        let allocationLength = MetalCommittedTileGeometry.allocationPixelLength
        encoder.setViewport(MTLViewport(
            originX: 0,
            originY: 0,
            width: Double(allocationLength),
            height: Double(allocationLength),
            znear: 0,
            zfar: 1
        ))
        guard try intersectsAppendedItem(appended, tileKey: key) else { return tile }
        let interior = try MetalCommittedTileGeometry.documentRect(
            for: key.coordinate,
            scale: key.scale
        )
        let documentPixelLength = 1 / (key.scale.zoom * key.scale.displayScale)
        let allocationOrigin = CanvasPoint(
            x: interior.minX - documentPixelLength,
            y: interior.minY - documentPixelLength
        )
        let sourceOrigin = SIMD2<Float>(
            try finiteFloat(
                (allocationOrigin.x * scene.viewport.zoom + scene.viewport.translation.x)
                    * key.scale.displayScale
            ),
            try finiteFloat(
                (allocationOrigin.y * scene.viewport.zoom + scene.viewport.translation.y)
                    * key.scale.displayScale
            )
        )
        var parameters = MetalMaskRegionParameters(
            color: coverage.premultipliedColor,
            sourceOrigin: sourceOrigin,
            sourceSize: SIMD2<Float>(
                Float(coverage.texture.width),
                Float(coverage.texture.height)
            )
        )
        encoder.setRenderPipelineState(pipelines.compositeMaskRegion)
        encoder.setScissorRect(MTLScissorRect(
            x: 0,
            y: 0,
            width: allocationLength,
            height: allocationLength
        ))
        encoder.setFragmentBytes(
            &parameters,
            length: MemoryLayout<MetalMaskRegionParameters>.stride,
            index: 0
        )
        encoder.setFragmentTexture(coverage.texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        return tile
    }

    func intersectsAppendedItem(
        _ item: MetalCommittedDrawItem,
        tileKey: MetalCommittedTileKey
    ) throws -> Bool {
        let interior = try MetalCommittedTileGeometry.documentRect(
            for: tileKey.coordinate,
            scale: tileKey.scale
        )
        let documentPixelLength = 1 / (tileKey.scale.zoom * tileKey.scale.displayScale)
        let allocationBounds = CanvasRect(
            x: interior.minX - documentPixelLength,
            y: interior.minY - documentPixelLength,
            width: interior.width + documentPixelLength * 2,
            height: interior.height + documentPixelLength * 2
        )
        return intersects(item.paintedBounds, allocationBounds)
    }

    func dynamicScene(
        _ scene: MetalCompiledScene,
        tiles: [MetalCommittedTileResource]
    ) -> MetalCompiledScene {
        let renderItems = scene.gridItems
            + tiles.map { .committedTile(MetalCommittedTileComposite(tile: $0)) }
            + scene.liveItems
            + scene.overlayItems
        return MetalCompiledScene(
            background: scene.background,
            items: renderItems,
            viewport: scene.viewport,
            previewGeneration: scene.previewGeneration,
            renderItems: renderItems,
            renderCoordinateOrigin: scene.renderCoordinateOrigin,
            gridItems: scene.gridItems,
            liveItems: scene.liveItems,
            overlayItems: scene.overlayItems,
            committedGeneration: nil,
            viewportRenderPhase: scene.viewportRenderPhase
        )
    }

    func committedTiles(in scene: MetalCompiledScene) -> [MetalCommittedTileResource] {
        scene.renderItems.compactMap { item in
            guard case .committedTile(let composite) = item else { return nil }
            return composite.tile
        }
    }

    func dirtyTileKeys(
        from oldItems: [CanvasCommittedItem],
        to newItems: [CanvasCommittedItem],
        oldReplacement: CanvasCommittedReplacement?,
        newReplacement: CanvasCommittedReplacement?
    ) throws -> Set<MetalCommittedTileKey> {
        var result = Set<MetalCommittedTileKey>()
        for scale in Set(availableTileKeys.map(\.scale)) {
            let coordinates = try MetalCommittedTileMutation.dirtyCoordinates(
                from: oldItems,
                to: newItems,
                oldReplacement: oldReplacement,
                newReplacement: newReplacement,
                scale: scale
            )
            result.formUnion(availableTileKeys.filter {
                $0.scale == scale && coordinates.contains($0.coordinate)
            })
        }
        return result
    }

    func publishCommittedSnapshot(
        _ committed: CanvasCommittedPresentation,
        replacementKey: CanvasRenderKey?,
        replacementPreviewGeneration: RecognitionGeneration?
    ) {
        tileGeneration = committed.generation
        tileReplacementKey = replacementKey
        tileReplacementPreviewGeneration = replacementPreviewGeneration
        publishedCommittedItems = committed.items
        publishedReplacement = committed.replacement
    }

    func buildCommittedTile(
        _ key: MetalCommittedTileKey,
        scene: MetalCompiledScene,
        committedLayer: MetalCompiledCommittedLayer
    ) throws -> TileBuildCounts {
        let interior = try MetalCommittedTileGeometry.documentRect(
            for: key.coordinate,
            scale: key.scale
        )
        let documentPixelLength = 1 / (key.scale.zoom * key.scale.displayScale)
        let allocationOrigin = CanvasPoint(
            x: interior.minX - documentPixelLength,
            y: interior.minY - documentPixelLength
        )
        let allocationLength = Double(MetalCommittedTileGeometry.allocationPixelLength)
            * documentPixelLength
        let allocationBounds = CanvasRect(
            x: allocationOrigin.x,
            y: allocationOrigin.y,
            width: allocationLength,
            height: allocationLength
        )
        let items = try committedLayer.items.compactMap { original -> MetalDrawItem? in
            let source: MetalCommittedDrawItem
            if let replacement = committedLayer.replacement,
               replacement.documentIndex == original.documentIndex {
                source = replacement.replacement
            } else {
                source = original
            }
            guard intersects(source.paintedBounds, allocationBounds) else { return nil }
            return try tileCompiler.compileCommittedItem(
                source,
                coordinateOrigin: allocationOrigin,
                zoom: key.scale.zoom,
                displayScale: key.scale.displayScale
            )
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: MetalCommittedTileGeometry.allocationPixelLength,
            height: MetalCommittedTileGeometry.allocationPixelLength,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw MetalCanvasError.invalidResourceSize
        }
        let tile = try MetalCommittedTileResource(key: key, texture: texture)
        let lease: MetalInFlightResourceLease
        do {
            lease = try resources.retainInFlight(
                coverage: [],
                fallback: [],
                tiles: [tile],
                textures: []
            )
        } catch {
            throw error
        }
        defer { resources.releaseInFlight(lease) }
        let viewport = try CanvasViewport(
            zoom: key.scale.zoom,
            translation: .init(
                x: -allocationOrigin.x * key.scale.zoom,
                y: -allocationOrigin.y * key.scale.zoom
            ),
            viewportSize: .init(
                width: Double(MetalCommittedTileGeometry.allocationPixelLength)
                    / key.scale.displayScale,
                height: Double(MetalCommittedTileGeometry.allocationPixelLength)
                    / key.scale.displayScale
            )
        )
        let tileScene = MetalCompiledScene(
            background: .zero,
            items: items,
            viewport: viewport,
            previewGeneration: nil,
            renderItems: items,
            renderCoordinateOrigin: allocationOrigin
        )
        do {
            _ = try renderLegacy(
                tileScene,
                size: .init(
                    width: viewport.viewportSize.width,
                    height: viewport.viewportSize.height
                ),
                displayScale: key.scale.displayScale,
                destinationTexture: texture
            )
        } catch {
            throw error
        }
        let coverageEncodeCount = lastCommittedCoverageEncodeCount
        return TileBuildCounts(
            tile: tile,
            committedCoverageEncodeCount: coverageEncodeCount
        )
    }

    func intersects(_ lhs: CanvasRect, _ rhs: CanvasRect) -> Bool {
        lhs.maxX >= rhs.minX && rhs.maxX >= lhs.minX
            && lhs.maxY >= rhs.minY && rhs.maxY >= lhs.minY
    }

    func resetFrameWorkStatistics() {
        lastCommittedTileReplayCount = 0
        lastCommittedCoverageEncodeCount = 0
        lastLiveCoverageEncodeCount = 0
    }

    func recordCoverageEncode(for renderKey: CanvasRenderKey) {
        switch renderKey {
        case .committed:
            lastCommittedCoverageEncodeCount += 1
        case .preview:
            lastLiveCoverageEncodeCount += 1
        }
    }

    enum RetainedResource {
        case coverage(MetalCoverageResource)
        case tile(MetalCommittedTileResource)
    }

    struct FallbackSurface {
        let supersampleColor: any MTLTexture
        let colorByteCount: Int
        let stencil: any MTLTexture
        let stencilByteCount: Int
        let dimensions: PixelSize
        let outputRect: PixelRect
    }

    struct PixelRect {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }

    struct OutputTexturePlan {
        let descriptor: MTLTextureDescriptor
        let payloadByteCount: Int
        let estimatedByteCount: Int
    }

    struct FallbackSurfacePlan {
        let colorDescriptor: MTLTextureDescriptor
        let stencilDescriptor: MTLTextureDescriptor
        let dimensions: PixelSize
        let colorPayloadByteCount: Int
        let stencilPayloadByteCount: Int
        let estimatedByteCount: Int
        let outputRect: PixelRect
    }

    struct PreparedFallback {
        let resource: MetalFallbackResource
        let surfacePlan: FallbackSurfacePlan
    }

    final class OutputBatch {
        let commandBuffer: any MTLCommandBuffer
        let encoder: any MTLRenderCommandEncoder
        var retainedCoverage: [MetalCoverageResource] = []
        var retainedFallback: [MetalFallbackResource] = []
        var retainedTiles: [MetalCommittedTileResource] = []
        var retainedTextures: [MetalInFlightTexture] = []
        var hasRetainedResources: Bool {
            !retainedCoverage.isEmpty
                || !retainedFallback.isEmpty
                || !retainedTiles.isEmpty
        }

        init(
            commandBuffer: any MTLCommandBuffer,
            encoder: any MTLRenderCommandEncoder
        ) {
            self.commandBuffer = commandBuffer
            self.encoder = encoder
        }
    }

    func renderOnscreen(
        _ scene: MetalCompiledScene,
        into texture: any MTLTexture,
        size: CGSize,
        displayScale: Double,
        configureBeforeCommit: (any MTLCommandBuffer) -> Void,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) throws {
        let composition = try prepareCommittedComposition(
            scene,
            displayScale: displayScale
        )
        let tiles = committedTiles(in: composition.scene)
        let preparationLease = try tiles.isEmpty ? nil : resources.retainInFlight(
            coverage: [],
            fallback: [],
            tiles: tiles,
            textures: []
        )
        defer {
            if let preparationLease {
                resources.releaseInFlight(preparationLease)
            }
        }
        try renderOnscreenLegacy(
            composition.scene,
            into: texture,
            size: size,
            displayScale: displayScale,
            configureBeforeCommit: configureBeforeCommit,
            completion: completion
        )
        lastCommittedTileReplayCount += composition.replayedTileCount
        lastCommittedCoverageEncodeCount += composition.committedCoverageEncodeCount
    }

    func renderOnscreenLegacy(
        _ scene: MetalCompiledScene,
        into texture: any MTLTexture,
        size: CGSize,
        displayScale: Double,
        configureBeforeCommit: (any MTLCommandBuffer) -> Void,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) throws {
        lastPreparedFreehandInputCount = 0
        resetFrameWorkStatistics()
        var submissionSucceeded = false
        defer {
            if !submissionSucceeded {
                lastPreparedFreehandInputCount = 0
                resetFrameWorkStatistics()
            }
        }
        let dimensions = try textureDimensions(size: size, displayScale: displayScale)
        guard texture.width == dimensions.width,
              texture.height == dimensions.height,
              texture.pixelFormat == .bgra8Unorm,
              texture.usage.contains(.renderTarget) else {
            throw MetalCanvasError.invalidResourceSize
        }
        let fallbackPlans = try preflightFallbackPlans(
            scene,
            displayScale: displayScale,
            outputDimensions: dimensions
        )
        let freehandGeometries = scene.renderItems.compactMap { item -> CanvasPreparedGeometry? in
            guard case .freehand(let descriptor) = item else { return nil }
            return descriptor.geometry
        }
        let freehandFramePlan = try freehandCoverage.makeFramePlan(
            geometries: freehandGeometries,
            viewport: scene.viewport,
            displayScale: displayScale
        )
        lastPreparedFreehandInputCount = freehandFramePlan.preparedInputCount
        let transientFreehands = try freehandGeometries.filter { geometry in
            try freehandCoverage.requiresTransientCoverage(
                geometry,
                using: freehandFramePlan
            )
        }
        let transientArenaPointCount = try freehandCoverage.totalPointCount(
            in: transientFreehands,
            using: freehandFramePlan
        )
        let scratchCoverageByteCount = !transientFreehands.isEmpty
            ? try freehandCoverage.transientCoverageByteCount(
                maximumPointCount: transientArenaPointCount,
                viewport: scene.viewport,
                displayScale: displayScale
            )
            : 0
        let sharedFallbackPlan = try sharedFallbackSurfacePlan(fallbackPlans)
        let transientByteCount = try checkedSum([
            scratchCoverageByteCount,
            sharedFallbackPlan?.estimatedByteCount ?? 0,
        ])
        try resources.reserveTransient(byteCount: transientByteCount)
        var transientReservationIsActive = true
        defer {
            if transientReservationIsActive {
                resources.releaseTransientReservation()
            }
        }

        do {
            var preparedFallbacks: [Int: PreparedFallback] = [:]
            var retainedFallbacks: [MetalFallbackResource] = []
            for index in fallbackPlans.keys.sorted() {
                guard case .fallback(let descriptor) = scene.renderItems[index],
                      let plan = fallbackPlans[index] else { continue }
                let additionalBytes = try pathFallback.estimatedAdditionalByteCount(
                    geometry: descriptor.geometry,
                    viewport: scene.viewport,
                    displayScale: displayScale
                )
                try resources.reserve(
                    additionalByteCount: additionalBytes,
                    retaining: [],
                    fallback: retainedFallbacks
                )
                let fallback = try pathFallback.prepare(
                    geometry: descriptor.geometry,
                    viewport: scene.viewport,
                    displayScale: displayScale
                )
                retainedFallbacks.append(fallback)
                preparedFallbacks[index] = PreparedFallback(
                    resource: fallback,
                    surfacePlan: plan
                )
            }

            if let activeElementID = freehandCoverage.activeElementID {
                let retainsActiveElement = scene.renderItems.contains { item in
                    guard case .freehand(let descriptor) = item else { return false }
                    return descriptor.geometry.id == activeElementID
                }
                if !retainsActiveElement {
                    freehandCoverage.reset()
                }
            }

            let coverageScratch = !transientFreehands.isEmpty
                ? try freehandCoverage.makeTransientCoverage(
                    maximumPointCount: transientArenaPointCount,
                    viewport: scene.viewport,
                    displayScale: displayScale
                )
                : nil
            let fallbackScratch = try sharedFallbackPlan.map {
                try makeFallbackSurface(
                    plan: $0,
                    retaining: retainedFallbacks,
                    transientByteCount: transientByteCount
                )
            }

            let residentBytes = try resources.combinedResidentByteCount(
                retaining: coverageScratch.map { [$0] } ?? [],
                fallback: retainedFallbacks
            )
            let ownedBytes = try checkedSum([
                residentBytes,
                sharedFallbackPlan?.estimatedByteCount ?? 0,
            ])
            guard ownedBytes <= resources.budgetByteCount else {
                throw MetalCanvasError.resourceBudgetExceeded
            }
            maximumOwnedCoverageByteCount = max(maximumOwnedCoverageByteCount, ownedBytes)

            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                throw MetalCanvasError.commandEncodingFailed
            }
            outputCommandBufferCount += 1
            commandBuffer.label = "Canvas ordered onscreen frame"
            var outputEncoder: (any MTLRenderCommandEncoder)?
            var outputHasBeenCleared = false
            var retainedCoverage: [MetalCoverageResource] = []
            var retainedTiles: [MetalCommittedTileResource] = []
            var retainedTextures: [MetalInFlightTexture] = []
            var transientSegmentStart = 0

            func endOutputEncoder() {
                outputEncoder?.endEncoding()
                outputEncoder = nil
            }

            func requireOutputEncoder() throws -> any MTLRenderCommandEncoder {
                if let outputEncoder { return outputEncoder }
                let renderPass = MTLRenderPassDescriptor()
                renderPass.colorAttachments[0].texture = texture
                renderPass.colorAttachments[0].loadAction = outputHasBeenCleared ? .load : .clear
                renderPass.colorAttachments[0].storeAction = .store
                renderPass.colorAttachments[0].clearColor = MTLClearColor(
                    red: Double(scene.background.x),
                    green: Double(scene.background.y),
                    blue: Double(scene.background.z),
                    alpha: Double(scene.background.w)
                )
                guard let created = commandBuffer.makeRenderCommandEncoder(
                    descriptor: renderPass
                ) else {
                    throw MetalCanvasError.commandEncodingFailed
                }
                outputHasBeenCleared = true
                created.label = "Canvas ordered onscreen output pass"
                created.setViewport(MTLViewport(
                    originX: 0,
                    originY: 0,
                    width: Double(dimensions.width),
                    height: Double(dimensions.height),
                    znear: 0,
                    zfar: 1
                ))
                outputEncoder = created
                return created
            }

            for (itemIndex, item) in scene.renderItems.enumerated() {
                switch item {
                case .freehand(let descriptor):
                    endOutputEncoder()
                    let coverage: MetalCoverageResource
                    switch descriptor.geometry.renderKey {
                    case .preview:
                        let additionalBytes = try freehandCoverage.additionalCoverageByteCount(
                            geometry: descriptor.geometry,
                            using: freehandFramePlan
                        )
                        let scratchTextureIdentity = coverageScratch.map {
                            ObjectIdentifier($0.texture as AnyObject)
                        }
                        let cachedRetainedCoverage = retainedCoverage.filter { retained in
                            ObjectIdentifier(retained.texture as AnyObject)
                                != scratchTextureIdentity
                        }
                        try resources.reserve(
                            additionalByteCount: additionalBytes,
                            retaining: cachedRetainedCoverage,
                            fallback: retainedFallbacks
                        )
                        try freehandCoverage.prepare(
                            geometry: descriptor.geometry,
                            using: freehandFramePlan,
                            viewport: scene.viewport,
                            displayScale: displayScale,
                            encodingOn: commandBuffer
                        )
                        guard let prepared = freehandCoverage.coverage(
                            for: descriptor.geometry,
                            viewport: scene.viewport,
                            displayScale: displayScale
                        ) else {
                            guard let coverageScratch else {
                                continue
                            }
                            let transient = try freehandCoverage.encodeTransientCoverage(
                                geometry: descriptor.geometry,
                                using: coverageScratch,
                                framePlan: freehandFramePlan,
                                destinationSegmentStart: transientSegmentStart,
                                commandBuffer: commandBuffer
                            )
                            transientSegmentStart += transient.encodedSegmentCount
                            recordCoverageEncode(for: descriptor.geometry.renderKey)
                            coverage = transient.coverage
                            if let prefix = transient.retainedPrefix {
                                retainedCoverage.append(prefix)
                            }
                            break
                        }
                        if prepared.prefixVertexCount == prepared.vertexSequence.count {
                            coverage = prepared
                        } else {
                            guard let coverageScratch else {
                                throw MetalCanvasError.commandEncodingFailed
                            }
                            let transient = try freehandCoverage.encodeTransientCoverage(
                                geometry: descriptor.geometry,
                                using: coverageScratch,
                                framePlan: freehandFramePlan,
                                destinationSegmentStart: transientSegmentStart,
                                commandBuffer: commandBuffer
                            )
                            transientSegmentStart += transient.encodedSegmentCount
                            recordCoverageEncode(for: descriptor.geometry.renderKey)
                            coverage = transient.coverage
                            if let prefix = transient.retainedPrefix {
                                retainedCoverage.append(prefix)
                            }
                        }
                    case .committed:
                        if freehandCoverage.activeElementID == descriptor.geometry.id {
                            try freehandCoverage.prepare(
                                geometry: descriptor.geometry,
                                using: freehandFramePlan,
                                viewport: scene.viewport,
                                displayScale: displayScale,
                                encodingOn: commandBuffer
                            )
                        }
                        if let prepared = freehandCoverage.coverage(
                            for: descriptor.geometry,
                            viewport: scene.viewport,
                            displayScale: displayScale
                        ), prepared.prefixVertexCount == prepared.vertexSequence.count {
                            coverage = prepared
                        } else {
                            guard let coverageScratch else {
                                throw MetalCanvasError.commandEncodingFailed
                            }
                            let transient = try freehandCoverage.encodeTransientCoverage(
                                geometry: descriptor.geometry,
                                using: coverageScratch,
                                framePlan: freehandFramePlan,
                                destinationSegmentStart: transientSegmentStart,
                                commandBuffer: commandBuffer
                            )
                            transientSegmentStart += transient.encodedSegmentCount
                            recordCoverageEncode(for: descriptor.geometry.renderKey)
                            coverage = transient.coverage
                            if let prefix = transient.retainedPrefix {
                                retainedCoverage.append(prefix)
                            }
                        }
                    }
                    retainedCoverage.append(coverage)
                    _ = try encode(
                        item,
                        viewport: scene.viewport,
                        coordinateOrigin: scene.renderCoordinateOrigin,
                        displayScale: displayScale,
                        textureSize: dimensions,
                        encoder: requireOutputEncoder(),
                        overridingCoverage: coverage
                    )

                case .fallback:
                    guard let prepared = preparedFallbacks[itemIndex],
                          let fallbackScratch else { continue }
                    endOutputEncoder()
                    let surface = FallbackSurface(
                        supersampleColor: fallbackScratch.supersampleColor,
                        colorByteCount: fallbackScratch.colorByteCount,
                        stencil: fallbackScratch.stencil,
                        stencilByteCount: fallbackScratch.stencilByteCount,
                        dimensions: prepared.surfacePlan.dimensions,
                        outputRect: prepared.surfacePlan.outputRect
                    )
                    try encodeFallbackPass(
                        prepared.resource,
                        viewport: scene.viewport,
                        displayScale: displayScale,
                        surface: surface,
                        outputDimensions: dimensions,
                        commandBuffer: commandBuffer
                    )
                    retainedTextures = [
                        MetalInFlightTexture(
                            texture: fallbackScratch.supersampleColor,
                            byteCount: fallbackScratch.colorByteCount
                        ),
                        MetalInFlightTexture(
                            texture: fallbackScratch.stencil,
                            byteCount: fallbackScratch.stencilByteCount
                        ),
                    ]
                    encodeComposite(
                        surface.supersampleColor,
                        outputRect: surface.outputRect,
                        encoder: try requireOutputEncoder()
                    )

                default:
                    if let retained = try encode(
                        item,
                        viewport: scene.viewport,
                        coordinateOrigin: scene.renderCoordinateOrigin,
                        displayScale: displayScale,
                        textureSize: dimensions,
                        encoder: requireOutputEncoder()
                    ) {
                        switch retained {
                        case .coverage(let coverage):
                            retainedCoverage.append(coverage)
                        case .tile(let tile):
                            retainedTiles.append(tile)
                        }
                    }
                }
            }
            _ = try requireOutputEncoder()
            endOutputEncoder()

            let finalOwnedByteCount = try resources.combinedResidentByteCount(
                retaining: retainedCoverage,
                fallback: retainedFallbacks,
                tiles: retainedTiles,
                textures: retainedTextures
            )
            guard finalOwnedByteCount <= resources.budgetByteCount else {
                throw MetalCanvasError.resourceBudgetExceeded
            }
            maximumOwnedCoverageByteCount = max(
                maximumOwnedCoverageByteCount,
                finalOwnedByteCount
            )

            resources.releaseTransientReservation()
            transientReservationIsActive = false
            let lease = try resources.retainInFlight(
                coverage: retainedCoverage,
                fallback: retainedFallbacks,
                tiles: retainedTiles,
                textures: retainedTextures
            )
            commandBuffer.addCompletedHandler { [resources, freehandCoverage] buffer in
                let succeeded = buffer.status == .completed
                Task { @MainActor in
                    if !succeeded {
                        freehandCoverage.handleMemoryPressure()
                    }
                    resources.releaseInFlight(lease)
                    completion?(succeeded)
                }
            }
            configureBeforeCommit(commandBuffer)
            commandBuffer.commit()
            submissionSucceeded = true
        } catch {
            freehandCoverage.handleMemoryPressure()
            throw error
        }
    }

    func makeOutputBatch(
        texture: any MTLTexture,
        loadAction: MTLLoadAction,
        background: SIMD4<Float>,
        dimensions: PixelSize
    ) throws -> OutputBatch {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalCanvasError.commandEncodingFailed
        }
        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = texture
        renderPass.colorAttachments[0].loadAction = loadAction
        renderPass.colorAttachments[0].storeAction = .store
        renderPass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(background.x),
            green: Double(background.y),
            blue: Double(background.z),
            alpha: Double(background.w)
        )
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
            throw MetalCanvasError.commandEncodingFailed
        }
        outputCommandBufferCount += 1
        encoder.label = "Canvas ordered offscreen pass"
        encoder.setViewport(MTLViewport(
            originX: 0,
            originY: 0,
            width: Double(dimensions.width),
            height: Double(dimensions.height),
            znear: 0,
            zfar: 1
        ))
        return OutputBatch(commandBuffer: commandBuffer, encoder: encoder)
    }

    func finishOutputBatch(
        _ batch: OutputBatch,
        configureBeforeCommit: ((any MTLCommandBuffer) -> Void)? = nil
    ) throws {
        batch.encoder.endEncoding()
        if let configureBeforeCommit {
            let lease = try resources.retainInFlight(
                coverage: batch.retainedCoverage,
                fallback: batch.retainedFallback,
                tiles: batch.retainedTiles,
                textures: batch.retainedTextures
            )
            configureBeforeCommit(batch.commandBuffer)
            batch.commandBuffer.addCompletedHandler { [resources] _ in
                Task { @MainActor in
                    resources.releaseInFlight(lease)
                }
            }
            batch.commandBuffer.commit()
            return
        }
        synchronousOutputWaitCount += 1
        withExtendedLifetime(batch.retainedCoverage) {
            withExtendedLifetime(batch.retainedFallback) {
                withExtendedLifetime(batch.retainedTiles) {
                    withExtendedLifetime(batch.retainedTextures) {
                        batch.commandBuffer.commit()
                        batch.commandBuffer.waitUntilCompleted()
                    }
                }
            }
        }
        guard batch.commandBuffer.status == .completed else {
            throw MetalCanvasError.commandBufferFailed
        }
    }

    func ownedByteCount(
        _ batch: OutputBatch,
        retainingFallback: [MetalFallbackResource] = []
    ) throws -> Int {
        try resources.combinedResidentByteCount(
            retaining: batch.retainedCoverage,
            fallback: batch.retainedFallback + retainingFallback,
            tiles: batch.retainedTiles
        )
    }

    func preflightFallbackPlans(
        _ scene: MetalCompiledScene,
        displayScale: Double,
        outputDimensions: PixelSize
    ) throws -> [Int: FallbackSurfacePlan] {
        var result: [Int: FallbackSurfacePlan] = [:]
        for (index, item) in scene.renderItems.enumerated() {
            guard case .fallback(let descriptor) = item,
                  let bounds = try pathFallback.preflightBounds(
                      geometry: descriptor.geometry,
                      viewport: scene.viewport,
                      displayScale: displayScale
                  ),
                  let outputRect = fallbackOutputRect(
                      bounds,
                      viewportScale: scene.viewport.zoom * displayScale,
                      outputDimensions: outputDimensions
                  ) else { continue }
            result[index] = try fallbackSurfacePlan(outputRect: outputRect)
        }
        return result
    }

    func sharedFallbackSurfacePlan(
        _ plans: [Int: FallbackSurfacePlan]
    ) throws -> FallbackSurfacePlan? {
        guard !plans.isEmpty else { return nil }
        let maximumWidth = plans.values.map(\.dimensions.width).max() ?? 0
        let maximumHeight = plans.values.map(\.dimensions.height).max() ?? 0
        guard maximumWidth > 0,
              maximumHeight > 0,
              maximumWidth.isMultiple(of: Self.fallbackSupersampleScale),
              maximumHeight.isMultiple(of: Self.fallbackSupersampleScale) else {
            throw MetalCanvasError.invalidResourceSize
        }
        return try fallbackSurfacePlan(outputRect: PixelRect(
            x: 0,
            y: 0,
            width: maximumWidth / Self.fallbackSupersampleScale,
            height: maximumHeight / Self.fallbackSupersampleScale
        ))
    }

    /// Converts mesh bounds to a clipped output crop, with a continuous one-device-pixel
    /// margin before integer rounding for antialias and 4x box-filter support.
    func fallbackOutputRect(
        _ bounds: CGRect,
        viewportScale: Double,
        outputDimensions: PixelSize
    ) -> PixelRect? {
        guard viewportScale.isFinite, viewportScale > 0 else { return nil }
        let x0Value = floor(bounds.minX * viewportScale - 1)
        let y0Value = floor(bounds.minY * viewportScale - 1)
        let x1Value = ceil(bounds.maxX * viewportScale + 1)
        let y1Value = ceil(bounds.maxY * viewportScale + 1)
        guard x0Value.isFinite,
              y0Value.isFinite,
              x1Value.isFinite,
              y1Value.isFinite else { return nil }
        let x0 = Int(max(0, min(Double(outputDimensions.width), x0Value)))
        let y0 = Int(max(0, min(Double(outputDimensions.height), y0Value)))
        let x1 = Int(max(0, min(Double(outputDimensions.width), x1Value)))
        let y1 = Int(max(0, min(Double(outputDimensions.height), y1Value)))
        guard x1 > x0, y1 > y0 else { return nil }
        return PixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    func outputTexturePlan(dimensions: PixelSize) throws -> OutputTexturePlan {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: dimensions.width,
            height: dimensions.height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        let payloadByteCount = try MetalCachedResource.checkedByteCount(
            width: dimensions.width,
            height: dimensions.height,
            bytesPerPixel: 4
        )
        let estimatedByteCount = try MetalCachedResource.conservativeAllocationByteCount(
            payloadByteCount: payloadByteCount,
            reportedByteCount: device.heapTextureSizeAndAlign(descriptor: descriptor).size
        )
        return OutputTexturePlan(
            descriptor: descriptor,
            payloadByteCount: payloadByteCount,
            estimatedByteCount: estimatedByteCount
        )
    }

    func fallbackSurfacePlan(outputRect: PixelRect) throws -> FallbackSurfacePlan {
        let supersampleWidth = outputRect.width.multipliedReportingOverflow(
            by: Self.fallbackSupersampleScale
        )
        let supersampleHeight = outputRect.height.multipliedReportingOverflow(
            by: Self.fallbackSupersampleScale
        )
        guard !supersampleWidth.overflow,
              !supersampleHeight.overflow,
              supersampleWidth.partialValue <= Self.maximumTextureDimension,
              supersampleHeight.partialValue <= Self.maximumTextureDimension else {
            throw MetalCanvasError.invalidResourceSize
        }
        let supersampleDimensions = (
            width: supersampleWidth.partialValue,
            height: supersampleHeight.partialValue
        )
        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: supersampleDimensions.width,
            height: supersampleDimensions.height,
            mipmapped: false
        )
        colorDescriptor.storageMode = .private
        colorDescriptor.usage = [.renderTarget, .shaderRead]
        let stencilDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .stencil8,
            width: supersampleDimensions.width,
            height: supersampleDimensions.height,
            mipmapped: false
        )
        stencilDescriptor.storageMode = .private
        stencilDescriptor.usage = .renderTarget
        let colorPayloadByteCount = try MetalCachedResource.checkedByteCount(
            width: supersampleDimensions.width,
            height: supersampleDimensions.height,
            bytesPerPixel: 4
        )
        let stencilPayloadByteCount = try MetalCachedResource.checkedByteCount(
            width: supersampleDimensions.width,
            height: supersampleDimensions.height,
            bytesPerPixel: 1
        )
        let estimates = try [
            MetalCachedResource.conservativeAllocationByteCount(
                payloadByteCount: colorPayloadByteCount,
                reportedByteCount: device.heapTextureSizeAndAlign(
                    descriptor: colorDescriptor
                ).size
            ),
            MetalCachedResource.conservativeAllocationByteCount(
                payloadByteCount: stencilPayloadByteCount,
                reportedByteCount: device.heapTextureSizeAndAlign(
                    descriptor: stencilDescriptor
                ).size
            ),
        ]
        return FallbackSurfacePlan(
            colorDescriptor: colorDescriptor,
            stencilDescriptor: stencilDescriptor,
            dimensions: supersampleDimensions,
            colorPayloadByteCount: colorPayloadByteCount,
            stencilPayloadByteCount: stencilPayloadByteCount,
            estimatedByteCount: try checkedSum(estimates),
            outputRect: outputRect
        )
    }

    func makeFallbackSurface(
        plan: FallbackSurfacePlan,
        retaining fallback: [MetalFallbackResource],
        transientByteCount: Int
    ) throws -> FallbackSurface {
        let retainedBytes = try resources.combinedResidentByteCount(
            retaining: [],
            fallback: fallback
        )
        let totalOwned = retainedBytes.addingReportingOverflow(transientByteCount)
        guard !totalOwned.overflow,
              totalOwned.partialValue <= resources.budgetByteCount else {
            throw MetalCanvasError.resourceBudgetExceeded
        }
        maximumOwnedCoverageByteCount = max(
            maximumOwnedCoverageByteCount,
            totalOwned.partialValue
        )
        guard let supersampleColor = device.makeTexture(
            descriptor: plan.colorDescriptor
        ), let stencil = device.makeTexture(descriptor: plan.stencilDescriptor) else {
            throw MetalCanvasError.invalidResourceSize
        }
        let colorByteCount = try MetalCachedResource.conservativeAllocationByteCount(
                payloadByteCount: plan.colorPayloadByteCount,
                reportedByteCount: supersampleColor.allocatedSize
            )
        let stencilByteCount = try MetalCachedResource.conservativeAllocationByteCount(
                payloadByteCount: plan.stencilPayloadByteCount,
                reportedByteCount: stencil.allocatedSize
            )
        let actualBytes = try checkedSum([colorByteCount, stencilByteCount])
        guard actualBytes <= plan.estimatedByteCount else {
            throw MetalCanvasError.resourceBudgetExceeded
        }
        return FallbackSurface(
            supersampleColor: supersampleColor,
            colorByteCount: colorByteCount,
            stencil: stencil,
            stencilByteCount: stencilByteCount,
            dimensions: plan.dimensions,
            outputRect: plan.outputRect
        )
    }

    func checkedSum(_ values: [Int]) throws -> Int {
        var result = 0
        for value in values {
            let addition = result.addingReportingOverflow(value)
            guard value >= 0, !addition.overflow else {
                throw MetalCanvasError.invalidResourceSize
            }
            result = addition.partialValue
        }
        return result
    }

    func textureDimensions(size: CGSize, displayScale: Double) throws -> PixelSize {
        guard size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0,
              displayScale.isFinite,
              displayScale > 0 else {
            throw MetalCanvasError.invalidResourceSize
        }
        let widthValue = ceil(Double(size.width) * displayScale)
        let heightValue = ceil(Double(size.height) * displayScale)
        guard widthValue.isFinite,
              heightValue.isFinite,
              widthValue >= 1,
              heightValue >= 1,
              widthValue <= Double(Self.maximumTextureDimension),
              heightValue <= Double(Self.maximumTextureDimension),
              widthValue <= Double(Int.max),
              heightValue <= Double(Int.max) else {
            throw MetalCanvasError.invalidResourceSize
        }
        let width = Int(widthValue)
        let height = Int(heightValue)
        let pixelCount = width.multipliedReportingOverflow(by: height)
        guard !pixelCount.overflow,
              pixelCount.partialValue <= CanvasMetalLimits.maximumCoveragePixelCount else {
            throw MetalCanvasError.invalidResourceSize
        }
        _ = try MetalCachedResource.checkedByteCount(
            width: width,
            height: height,
            bytesPerPixel: 4
        )
        return (width, height)
    }

    func renderFallback(
        _ fallback: MetalFallbackResource,
        viewport: CanvasViewport,
        displayScale: Double,
        surface: FallbackSurface,
        outputDimensions: PixelSize
    ) throws {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalCanvasError.commandEncodingFailed
        }
        try encodeFallbackPass(
            fallback,
            viewport: viewport,
            displayScale: displayScale,
            surface: surface,
            outputDimensions: outputDimensions,
            commandBuffer: commandBuffer
        )
        outputCommandBufferCount += 1
        withExtendedLifetime(fallback) {
            withExtendedLifetime(surface) {
                commandBuffer.commit()
                commandBuffer.waitUntilCompleted()
            }
        }
        guard commandBuffer.status == .completed else {
            throw MetalCanvasError.commandBufferFailed
        }
    }

    func encodeFallbackPass(
        _ fallback: MetalFallbackResource,
        viewport: CanvasViewport,
        displayScale: Double,
        surface: FallbackSurface,
        outputDimensions: PixelSize,
        commandBuffer: any MTLCommandBuffer
    ) throws {
        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = surface.supersampleColor
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].storeAction = .store
        renderPass.colorAttachments[0].clearColor = MTLClearColor(
            red: 0,
            green: 0,
            blue: 0,
            alpha: 0
        )
        renderPass.stencilAttachment.texture = surface.stencil
        renderPass.stencilAttachment.loadAction = .clear
        renderPass.stencilAttachment.storeAction = .dontCare
        renderPass.stencilAttachment.clearStencil = 0
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
            throw MetalCanvasError.commandEncodingFailed
        }
        encoder.label = "Canvas supersample stencil fallback pass"
        encoder.setViewport(MTLViewport(
            originX: 0,
            originY: 0,
            width: Double(surface.dimensions.width),
            height: Double(surface.dimensions.height),
            znear: 0,
            zfar: 1
        ))
        try encodeFallback(
            fallback,
            viewportScale: viewport.zoom * displayScale
                * Double(Self.fallbackSupersampleScale),
            textureSize: surface.dimensions,
            outputDimensions: outputDimensions,
            outputRect: surface.outputRect,
            encoder: encoder
        )
        encoder.endEncoding()
    }

    func encodeComposite(
        _ source: any MTLTexture,
        outputRect: PixelRect,
        encoder: any MTLRenderCommandEncoder
    ) {
        encoder.setRenderPipelineState(pipelines.compositeColor)
        encoder.setScissorRect(MTLScissorRect(
            x: outputRect.x,
            y: outputRect.y,
            width: outputRect.width,
            height: outputRect.height
        ))
        var destinationOrigin = SIMD2<UInt32>(
            UInt32(outputRect.x),
            UInt32(outputRect.y)
        )
        encoder.setFragmentBytes(
            &destinationOrigin,
            length: MemoryLayout<SIMD2<UInt32>>.stride,
            index: 0
        )
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    func encodeFallback(
        _ fallback: MetalFallbackResource,
        viewportScale: Double,
        textureSize: PixelSize,
        outputDimensions: PixelSize,
        outputRect: PixelRect,
        encoder: any MTLRenderCommandEncoder
    ) throws {
        encoder.setVertexBuffer(fallback.vertexBuffer, offset: 0, index: 0)
        var cropTransform = SIMD4<Float>(
            Float(outputDimensions.width) / Float(outputRect.width),
            Float(outputDimensions.height) / Float(outputRect.height),
            Float(outputDimensions.width - 2 * outputRect.x - outputRect.width)
                / Float(outputRect.width),
            Float(outputRect.height - outputDimensions.height + 2 * outputRect.y)
                / Float(outputRect.height)
        )
        guard cropTransform.x.isFinite,
              cropTransform.y.isFinite,
              cropTransform.z.isFinite,
              cropTransform.w.isFinite else {
            throw MetalCanvasError.invalidNumericInput
        }
        encoder.setVertexBytes(
            &cropTransform,
            length: MemoryLayout<SIMD4<Float>>.stride,
            index: 1
        )
        let supersampleOrigin = (
            width: outputRect.x * Self.fallbackSupersampleScale,
            height: outputRect.y * Self.fallbackSupersampleScale
        )
        if !fallback.fillIndexRange.isEmpty {
            encoder.setRenderPipelineState(pipelines.stencilWinding)
            encoder.setDepthStencilState(pipelines.stencilWindingState)
            encoder.setStencilReferenceValue(0)
            encoder.setScissorRect(MTLScissorRect(
                x: 0,
                y: 0,
                width: textureSize.width,
                height: textureSize.height
            ))
            try drawTriangles(
                fallback.fillIndexRange,
                resource: fallback,
                encoder: encoder
            )
            if let bounds = fallback.fillBounds,
               let fillScissor = fallbackScissor(
                   bounds,
                   viewportScale: viewportScale,
                   textureSize: textureSize,
                   pixelOrigin: supersampleOrigin
               ) {
                var parameters = MetalStencilCoverParameters(color: fallback.fillColor)
                encoder.setRenderPipelineState(pipelines.stencilCover)
                encoder.setDepthStencilState(pipelines.stencilCoverState)
                encoder.setStencilReferenceValue(0)
                encoder.setScissorRect(fillScissor)
                encoder.setFragmentBytes(
                    &parameters,
                    length: MemoryLayout<MetalStencilCoverParameters>.stride,
                    index: 0
                )
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }
        if !fallback.strokeIndexRange.isEmpty {
            encoder.setRenderPipelineState(pipelines.stencilWinding)
            encoder.setDepthStencilState(pipelines.stencilUnionState)
            encoder.setStencilReferenceValue(1)
            encoder.setScissorRect(MTLScissorRect(
                x: 0,
                y: 0,
                width: textureSize.width,
                height: textureSize.height
            ))
            try drawTriangles(
                fallback.strokeIndexRange,
                resource: fallback,
                encoder: encoder
            )
            if let bounds = fallback.strokeBounds,
               let strokeScissor = fallbackScissor(
                   bounds,
                   viewportScale: viewportScale,
                   textureSize: textureSize,
                   pixelOrigin: supersampleOrigin
               ) {
                var parameters = MetalStencilCoverParameters(color: fallback.strokeColor)
                encoder.setRenderPipelineState(pipelines.stencilCover)
                encoder.setDepthStencilState(pipelines.stencilCoverState)
                encoder.setStencilReferenceValue(0)
                encoder.setScissorRect(strokeScissor)
                encoder.setFragmentBytes(
                    &parameters,
                    length: MemoryLayout<MetalStencilCoverParameters>.stride,
                    index: 0
                )
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }
    }

    func encode(
        _ item: MetalDrawItem,
        viewport: CanvasViewport,
        coordinateOrigin: CanvasPoint,
        displayScale: Double,
        textureSize: PixelSize,
        encoder: any MTLRenderCommandEncoder,
        overridingCoverage: MetalCoverageResource? = nil
    ) throws -> RetainedResource? {
        switch item {
        case .analyticLine(var instance):
            instance = try pixelLine(
                instance,
                viewport: viewport,
                coordinateOrigin: coordinateOrigin,
                scale: displayScale
            )
            guard let scissor = lineScissor(instance, textureSize: textureSize) else { return nil }
            encoder.setRenderPipelineState(pipelines.analyticLine)
            encoder.setScissorRect(scissor)
            encoder.setFragmentBytes(
                &instance,
                length: MemoryLayout<MetalLineInstance>.stride,
                index: 0
            )
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            return nil

        case .analyticBox(var instance):
            instance = try pixelBox(
                instance,
                viewport: viewport,
                coordinateOrigin: coordinateOrigin,
                scale: displayScale
            )
            guard let scissor = boxScissor(instance, textureSize: textureSize) else { return nil }
            encoder.setRenderPipelineState(pipelines.analyticBox)
            encoder.setScissorRect(scissor)
            encoder.setFragmentBytes(
                &instance,
                length: MemoryLayout<MetalBoxInstance>.stride,
                index: 0
            )
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            return nil

        case .analyticArc(var instance):
            instance = try pixelArc(
                instance,
                viewport: viewport,
                coordinateOrigin: coordinateOrigin,
                scale: displayScale
            )
            guard let scissor = arcScissor(instance, textureSize: textureSize) else { return nil }
            encoder.setRenderPipelineState(pipelines.analyticArc)
            encoder.setScissorRect(scissor)
            encoder.setFragmentBytes(
                &instance,
                length: MemoryLayout<MetalArcInstance>.stride,
                index: 0
            )
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            return nil

        case .freehand(let descriptor):
            guard let coverage = overridingCoverage ?? freehandCoverage.coverage(
                for: descriptor.geometry,
                viewport: viewport,
                displayScale: displayScale
            ),
            coverage.texture.width == textureSize.width,
            coverage.texture.height == textureSize.height else {
                return nil
            }
            var parameters = MetalCompositeMaskParameters(
                color: coverage.premultipliedColor
            )
            encoder.setRenderPipelineState(pipelines.compositeMask)
            encoder.setScissorRect(MTLScissorRect(
                x: 0,
                y: 0,
                width: textureSize.width,
                height: textureSize.height
            ))
            encoder.setFragmentBytes(
                &parameters,
                length: MemoryLayout<MetalCompositeMaskParameters>.stride,
                index: 0
            )
            encoder.setFragmentTexture(coverage.texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            return .coverage(coverage)

        case .committedTile(let composite):
            let key = composite.tile.key
            let documentRect = try MetalCommittedTileGeometry.documentRect(
                for: key.coordinate,
                scale: key.scale
            )
            let currentScale = viewport.zoom * displayScale
            let tileScale = key.scale.zoom * key.scale.displayScale
            let sourceScale = tileScale / currentScale
            let destinationX = (
                documentRect.minX * viewport.zoom + viewport.translation.x
            ) * displayScale
            let destinationY = (
                documentRect.minY * viewport.zoom + viewport.translation.y
            ) * displayScale
            let destinationLength = Double(MetalCommittedTileGeometry.interiorPixelLength)
                / sourceScale
            guard currentScale.isFinite,
                  currentScale > 0,
                  tileScale.isFinite,
                  tileScale > 0,
                  sourceScale.isFinite,
                  sourceScale > 0,
                  destinationX.isFinite,
                  destinationY.isFinite,
                  destinationLength.isFinite,
                  destinationLength > 0,
                  let scissor = pixelCenterScissor(
                      minimumX: destinationX,
                      minimumY: destinationY,
                      maximumX: destinationX + destinationLength,
                      maximumY: destinationY + destinationLength,
                      textureSize: textureSize
                  ) else {
                return nil
            }
            var parameters = MetalTileCompositeParameters(
                destinationOrigin: SIMD2<Float>(
                    try finiteFloat(destinationX),
                    try finiteFloat(destinationY)
                ),
                sourceScale: try finiteFloat(sourceScale),
                gutter: Float(MetalCommittedTileGeometry.gutterPixelLength)
            )
            encoder.setRenderPipelineState(pipelines.compositeTile)
            encoder.setScissorRect(scissor)
            encoder.setFragmentBytes(
                &parameters,
                length: MemoryLayout<MetalTileCompositeParameters>.stride,
                index: 0
            )
            encoder.setFragmentTexture(composite.tile.texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            return .tile(composite.tile)

        case .fallback:
            throw MetalCanvasError.commandEncodingFailed
        }
    }

    func pixelCenterScissor(
        minimumX: Double,
        minimumY: Double,
        maximumX: Double,
        maximumY: Double,
        textureSize: PixelSize
    ) -> MTLScissorRect? {
        guard minimumX.isFinite,
              minimumY.isFinite,
              maximumX.isFinite,
              maximumY.isFinite else {
            return nil
        }
        let x0 = Int(max(0, min(
            Double(textureSize.width),
            ceil(minimumX - 0.5)
        )))
        let y0 = Int(max(0, min(
            Double(textureSize.height),
            ceil(minimumY - 0.5)
        )))
        let x1 = Int(max(0, min(
            Double(textureSize.width),
            ceil(maximumX - 0.5)
        )))
        let y1 = Int(max(0, min(
            Double(textureSize.height),
            ceil(maximumY - 0.5)
        )))
        guard x1 > x0, y1 > y0 else { return nil }
        return MTLScissorRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    func drawTriangles(
        _ range: Range<Int>,
        resource: MetalFallbackResource,
        encoder: any MTLRenderCommandEncoder
    ) throws {
        let indexOffset = range.lowerBound.multipliedReportingOverflow(
            by: MemoryLayout<UInt32>.stride
        )
        let minimumVertexBytes = resource.vertexCount.multipliedReportingOverflow(
            by: MemoryLayout<MetalMeshVertex>.stride
        )
        let minimumIndexBytes = resource.indexCount.multipliedReportingOverflow(
            by: MemoryLayout<UInt32>.stride
        )
        guard range.lowerBound >= 0,
              range.upperBound <= resource.indexCount,
              range.count.isMultiple(of: 3),
              !indexOffset.overflow,
              !minimumVertexBytes.overflow,
              !minimumIndexBytes.overflow,
              resource.vertexBuffer.length >= minimumVertexBytes.partialValue,
              resource.indexBuffer.length >= minimumIndexBytes.partialValue else {
            throw MetalCanvasError.invalidResourceSize
        }
        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: range.count,
            indexType: .uint32,
            indexBuffer: resource.indexBuffer,
            indexBufferOffset: indexOffset.partialValue
        )
    }

    func fallbackScissor(
        _ bounds: CGRect,
        viewportScale: Double,
        textureSize: PixelSize,
        pixelOrigin: PixelSize
    ) -> MTLScissorRect? {
        scissor(
            minimumX: bounds.minX * viewportScale - Double(pixelOrigin.width) - 1,
            minimumY: bounds.minY * viewportScale - Double(pixelOrigin.height) - 1,
            maximumX: bounds.maxX * viewportScale - Double(pixelOrigin.width) + 1,
            maximumY: bounds.maxY * viewportScale - Double(pixelOrigin.height) + 1,
            textureSize: textureSize
        )
    }

    func pixelLine(
        _ source: MetalLineInstance,
        viewport: CanvasViewport,
        coordinateOrigin: CanvasPoint,
        scale: Double
    ) throws -> MetalLineInstance {
        MetalLineInstance(
            start: try pixelPoint(
                source.start,
                viewport: viewport,
                coordinateOrigin: coordinateOrigin,
                scale: scale
            ),
            end: try pixelPoint(
                source.end,
                viewport: viewport,
                coordinateOrigin: coordinateOrigin,
                scale: scale
            ),
            color: source.color,
            lineWidth: try pixelMetric(source.lineWidth, viewport: viewport, scale: scale),
            dashLength: try pixelMetric(source.dashLength, viewport: viewport, scale: scale),
            dashPeriod: try pixelMetric(source.dashPeriod, viewport: viewport, scale: scale),
            dashOffset: try pixelMetric(source.dashOffset, viewport: viewport, scale: scale)
        )
    }

    func pixelBox(
        _ source: MetalBoxInstance,
        viewport: CanvasViewport,
        coordinateOrigin: CanvasPoint,
        scale: Double
    ) throws -> MetalBoxInstance {
        let zoomScale = try finiteFloat(viewport.zoom * scale)
        let size = source.size * zoomScale
        guard size.x.isFinite, size.y.isFinite, size.x >= 0, size.y >= 0 else {
            throw MetalCanvasError.invalidNumericInput
        }
        return MetalBoxInstance(
            origin: try pixelPoint(
                source.origin,
                viewport: viewport,
                coordinateOrigin: coordinateOrigin,
                scale: scale
            ),
            size: size,
            fillColor: source.fillColor,
            strokeColor: source.strokeColor,
            lineWidth: try pixelMetric(source.lineWidth, viewport: viewport, scale: scale)
        )
    }

    func pixelArc(
        _ source: MetalArcInstance,
        viewport: CanvasViewport,
        coordinateOrigin: CanvasPoint,
        scale: Double
    ) throws -> MetalArcInstance {
        let zoomScale = try finiteFloat(viewport.zoom * scale)
        var result = MetalArcInstance(
            start: try pixelPoint(
                source.start,
                viewport: viewport,
                coordinateOrigin: coordinateOrigin,
                scale: scale
            ),
            end: try pixelPoint(
                source.end,
                viewport: viewport,
                coordinateOrigin: coordinateOrigin,
                scale: scale
            ),
            center: try pixelPoint(
                source.center,
                viewport: viewport,
                coordinateOrigin: coordinateOrigin,
                scale: scale
            ),
            radius: source.radius * zoomScale,
            color: source.color,
            lineWidth: try pixelMetric(source.lineWidth, viewport: viewport, scale: scale)
        )
        result.sweepAngle = source.sweepAngle
        guard result.radius.isFinite,
              result.radius > 0,
              result.sweepAngle.isFinite,
              result.sweepAngle != 0 else {
            throw MetalCanvasError.invalidNumericInput
        }
        return result
    }

    func pixelPoint(
        _ point: SIMD2<Float>,
        viewport: CanvasViewport,
        coordinateOrigin: CanvasPoint,
        scale: Double
    ) throws -> SIMD2<Float> {
        let screenOriginX = coordinateOrigin.x * viewport.zoom + viewport.translation.x
        let screenOriginY = coordinateOrigin.y * viewport.zoom + viewport.translation.y
        let pixelX = (Double(point.x) * viewport.zoom + screenOriginX) * scale
        let pixelY = (Double(point.y) * viewport.zoom + screenOriginY) * scale
        let result = SIMD2<Float>(try finiteFloat(pixelX), try finiteFloat(pixelY))
        guard result.x.isFinite, result.y.isFinite else {
            throw MetalCanvasError.invalidNumericInput
        }
        return result
    }

    func pixelMetric(
        _ metric: Float,
        viewport: CanvasViewport,
        scale: Double
    ) throws -> Float {
        guard metric.isFinite, metric >= 0 else {
            throw MetalCanvasError.invalidNumericInput
        }
        let result = metric * (try finiteFloat(viewport.zoom * scale))
        guard result.isFinite, result >= 0 else {
            throw MetalCanvasError.invalidNumericInput
        }
        return result
    }

    func finiteFloat(_ value: Double) throws -> Float {
        let result = Float(value)
        guard value.isFinite, result.isFinite else {
            throw MetalCanvasError.invalidNumericInput
        }
        return result
    }

    func lineScissor(
        _ line: MetalLineInstance,
        textureSize: PixelSize
    ) -> MTLScissorRect? {
        let expansion = Double(line.lineWidth) / 2 + 2
        return scissor(
            minimumX: Double(min(line.start.x, line.end.x)) - expansion,
            minimumY: Double(min(line.start.y, line.end.y)) - expansion,
            maximumX: Double(max(line.start.x, line.end.x)) + expansion,
            maximumY: Double(max(line.start.y, line.end.y)) + expansion,
            textureSize: textureSize
        )
    }

    func boxScissor(
        _ box: MetalBoxInstance,
        textureSize: PixelSize
    ) -> MTLScissorRect? {
        let expansion = Double(box.lineWidth) / 2 + 2
        return scissor(
            minimumX: Double(box.origin.x) - expansion,
            minimumY: Double(box.origin.y) - expansion,
            maximumX: Double(box.origin.x + box.size.x) + expansion,
            maximumY: Double(box.origin.y + box.size.y) + expansion,
            textureSize: textureSize
        )
    }

    func arcScissor(
        _ arc: MetalArcInstance,
        textureSize: PixelSize
    ) -> MTLScissorRect? {
        var points = [arc.start, arc.end]
        let startAngle = atan2(
            Double(arc.start.y - arc.center.y),
            Double(arc.start.x - arc.center.x)
        )
        for angle in stride(from: 0.0, to: Double.pi * 2, by: Double.pi / 2) {
            if contains(angle: angle, start: startAngle, sweep: Double(arc.sweepAngle)) {
                points.append(SIMD2<Float>(
                    arc.center.x + cos(Float(angle)) * arc.radius,
                    arc.center.y + sin(Float(angle)) * arc.radius
                ))
            }
        }
        guard let minimumX = points.lazy.map(\.x).min(),
              let minimumY = points.lazy.map(\.y).min(),
              let maximumX = points.lazy.map(\.x).max(),
              let maximumY = points.lazy.map(\.y).max() else {
            return nil
        }
        let expansion = Double(arc.lineWidth) / 2 + 2
        return scissor(
            minimumX: Double(minimumX) - expansion,
            minimumY: Double(minimumY) - expansion,
            maximumX: Double(maximumX) + expansion,
            maximumY: Double(maximumY) + expansion,
            textureSize: textureSize
        )
    }

    func contains(angle: Double, start: Double, sweep: Double) -> Bool {
        if sweep >= 0 {
            return normalizedPositiveAngle(angle - start) <= sweep
        }
        return normalizedPositiveAngle(start - angle) <= -sweep
    }

    func normalizedPositiveAngle(_ angle: Double) -> Double {
        let fullTurn = Double.pi * 2
        let remainder = angle.truncatingRemainder(dividingBy: fullTurn)
        return remainder >= 0 ? remainder : remainder + fullTurn
    }

    func scissor(
        minimumX: Double,
        minimumY: Double,
        maximumX: Double,
        maximumY: Double,
        textureSize: PixelSize
    ) -> MTLScissorRect? {
        guard minimumX.isFinite,
              minimumY.isFinite,
              maximumX.isFinite,
              maximumY.isFinite else {
            return nil
        }
        let x0 = Int(max(0, min(Double(textureSize.width), floor(minimumX))))
        let y0 = Int(max(0, min(Double(textureSize.height), floor(minimumY))))
        let x1 = Int(max(0, min(Double(textureSize.width), ceil(maximumX))))
        let y1 = Int(max(0, min(Double(textureSize.height), ceil(maximumY))))
        guard x1 > x0, y1 > y0 else { return nil }
        return MTLScissorRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

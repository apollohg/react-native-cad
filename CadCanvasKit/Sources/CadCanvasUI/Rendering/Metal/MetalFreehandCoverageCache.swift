import CadCanvasCore
import Foundation
import Metal

struct MetalFreehandCoverageStatistics: Equatable {
    var encodedSegmentCount = 0
    var coverageDrawCallCount = 0
    var validatedPointCount = 0
    var coverageCommandBufferCount = 0
    var fullBuildCount = 0
    var commitReuseCount = 0
    var transientTailEncodeCount = 0
    var prefixToScratchCopyCount = 0
    var transientCoverageAllocationCount = 0
    var fullFlattenCount = 0
    var incrementalFlattenCount = 0
    var incrementallyFlattenedSpanCount = 0
    var incrementallyCopiedVertexCount = 0
    var incrementallyCopiedSpanEndCount = 0
    var incrementallyCopiedPointCount = 0
    var incrementallyValidatedSampleCount = 0
}

enum MetalFreehandCoverageFailurePoint: Equatable {
    case allocation
    case encoding
    case completion
}

private final class MetalCoverageStableChunk<Element> {
    let previous: MetalCoverageStableChunk<Element>?
    let startIndex: Int
    let elements: [Element]
    var endIndex: Int { startIndex + elements.count }

    init(
        previous: MetalCoverageStableChunk<Element>?,
        startIndex: Int,
        elements: [Element]
    ) {
        precondition(!elements.isEmpty)
        precondition(previous?.endIndex == startIndex || (previous == nil && startIndex == 0))
        self.previous = previous
        self.startIndex = startIndex
        self.elements = elements
    }
}

final class MetalCoverageSequence<Element> {
    private let stableTail: MetalCoverageStableChunk<Element>?
    private let stableCount: Int
    private let tail: [Element]
    let count: Int

    init(_ elements: [Element], stablePrefixCount: Int? = nil) {
        let resolvedStableCount = stablePrefixCount ?? elements.count
        precondition(resolvedStableCount >= 0 && resolvedStableCount <= elements.count)
        if resolvedStableCount > 0 {
            stableTail = MetalCoverageStableChunk(
                previous: nil,
                startIndex: 0,
                elements: Array(elements[..<resolvedStableCount])
            )
        } else {
            stableTail = nil
        }
        stableCount = resolvedStableCount
        tail = Array(elements[resolvedStableCount...])
        count = elements.count
    }

    init(
        reusing base: MetalCoverageSequence<Element>,
        retainedPrefixCount: Int,
        replacementTail: [Element]
    ) {
        precondition(retainedPrefixCount >= 0 && retainedPrefixCount <= base.count)
        precondition(retainedPrefixCount >= base.stableCount)
        let promotedCount = retainedPrefixCount - base.stableCount
        if promotedCount > 0 {
            stableTail = MetalCoverageStableChunk(
                previous: base.stableTail,
                startIndex: base.stableCount,
                elements: Array(base.tail[..<promotedCount])
            )
        } else {
            stableTail = base.stableTail
        }
        stableCount = retainedPrefixCount
        tail = replacementTail
        count = retainedPrefixCount + replacementTail.count
    }

    func slices(in requestedRange: Range<Int>) -> [ArraySlice<Element>] {
        precondition(requestedRange.lowerBound >= 0 && requestedRange.upperBound <= count)
        guard !requestedRange.isEmpty else { return [] }
        var reverseStableSlices: [ArraySlice<Element>] = []
        let stableUpperBound = min(requestedRange.upperBound, stableCount)
        var chunk = stableTail
        while let current = chunk,
              current.endIndex > requestedRange.lowerBound,
              requestedRange.lowerBound < stableUpperBound {
            if current.startIndex < stableUpperBound {
                let lower = max(requestedRange.lowerBound, current.startIndex)
                    - current.startIndex
                let upper = min(stableUpperBound, current.endIndex)
                    - current.startIndex
                reverseStableSlices.append(current.elements[lower..<upper])
            }
            chunk = current.previous
        }

        var result = Array(reverseStableSlices.reversed())
        if requestedRange.upperBound > stableCount {
            let lower = max(requestedRange.lowerBound, stableCount) - stableCount
            let upper = requestedRange.upperBound - stableCount
            result.append(tail[lower..<upper])
        }
        return result
    }

    func materialized() -> [Element] {
        var result: [Element] = []
        result.reserveCapacity(count)
        for slice in slices(in: 0..<count) {
            result.append(contentsOf: slice)
        }
        return result
    }

    func element(at index: Int) -> Element {
        precondition(index >= 0 && index < count)
        if index >= stableCount {
            return tail[index - stableCount]
        }
        var chunk = stableTail
        while let current = chunk {
            if index >= current.startIndex {
                return current.elements[index - current.startIndex]
            }
            chunk = current.previous
        }
        preconditionFailure("Stable coverage prefix is incomplete")
    }
}

extension MetalCoverageSequence where Element: Equatable {
    func elementsEqual(to other: MetalCoverageSequence<Element>) -> Bool {
        guard count == other.count else { return false }
        if self === other { return true }
        return prefixElementsEqual(to: other, count: count)
    }

    func prefixElementsEqual(
        to other: MetalCoverageSequence<Element>,
        count comparisonCount: Int
    ) -> Bool {
        guard comparisonCount >= 0,
              comparisonCount <= count,
              comparisonCount <= other.count else { return false }
        if comparisonCount == 0 || self === other { return true }
        let left = slices(in: 0..<comparisonCount)
        let right = other.slices(in: 0..<comparisonCount)
        var leftSlice = 0
        var rightSlice = 0
        var leftIndex = left.first?.startIndex ?? 0
        var rightIndex = right.first?.startIndex ?? 0
        var compared = 0
        while compared < comparisonCount {
            while leftSlice < left.count, leftIndex == left[leftSlice].endIndex {
                leftSlice += 1
                if leftSlice < left.count { leftIndex = left[leftSlice].startIndex }
            }
            while rightSlice < right.count, rightIndex == right[rightSlice].endIndex {
                rightSlice += 1
                if rightSlice < right.count { rightIndex = right[rightSlice].startIndex }
            }
            guard left[leftSlice][leftIndex] == right[rightSlice][rightIndex] else {
                return false
            }
            leftIndex += 1
            rightIndex += 1
            compared += 1
        }
        return true
    }
}

final class MetalCoverageResource {
    let texture: any MTLTexture
    let textureByteCount: Int
    let segmentBuffer: any MTLBuffer
    let segmentBufferByteCount: Int
    let segmentCapacity: Int
    let pointCount: Int
    let pointSequence: MetalCoverageSequence<CanvasPoint>
    let vertexSequence: MetalCoverageSequence<CanvasInkVertex>
    let spanEndSequence: MetalCoverageSequence<Int>
    var points: [CanvasPoint] { pointSequence.materialized() }
    var vertices: [CanvasInkVertex] { vertexSequence.materialized() }
    var spanEndVertexIndices: [Int] { spanEndSequence.materialized() }
    let prefixVertexCount: Int
    let confirmedSampleCount: Int
    let finalizedConfirmedSampleCount: Int
    let sourceInk: CanvasPreparedInk?
    let sourceGeneration: RecognitionGeneration?
    let pressureEnabled: Bool
    let preparedResourceIdentity: CanvasPreparedResourceIdentity?
    let elementID: UUID
    let styleFingerprint: UInt64
    let viewportSignature: MetalCoverageViewportSignature
    let premultipliedColor: SIMD4<Float>

    init(
        texture: any MTLTexture,
        textureByteCount: Int,
        segmentBuffer: any MTLBuffer,
        segmentBufferByteCount: Int,
        segmentCapacity: Int,
        pointCount: Int,
        points: [CanvasPoint] = [],
        vertices: [CanvasInkVertex] = [],
        spanEndVertexIndices: [Int] = [],
        pointSequence: MetalCoverageSequence<CanvasPoint>? = nil,
        vertexSequence: MetalCoverageSequence<CanvasInkVertex>? = nil,
        spanEndSequence: MetalCoverageSequence<Int>? = nil,
        prefixVertexCount: Int = 0,
        confirmedSampleCount: Int = 0,
        finalizedConfirmedSampleCount: Int = 0,
        sourceInk: CanvasPreparedInk?,
        sourceGeneration: RecognitionGeneration? = nil,
        pressureEnabled: Bool = false,
        preparedResourceIdentity: CanvasPreparedResourceIdentity? = nil,
        elementID: UUID,
        styleFingerprint: UInt64,
        viewportSignature: MetalCoverageViewportSignature,
        premultipliedColor: SIMD4<Float>
    ) {
        self.texture = texture
        self.textureByteCount = textureByteCount
        self.segmentBuffer = segmentBuffer
        self.segmentBufferByteCount = segmentBufferByteCount
        self.segmentCapacity = segmentCapacity
        self.pointCount = pointCount
        self.pointSequence = pointSequence ?? MetalCoverageSequence(points)
        self.vertexSequence = vertexSequence ?? MetalCoverageSequence(vertices)
        self.spanEndSequence = spanEndSequence ?? MetalCoverageSequence(spanEndVertexIndices)
        self.prefixVertexCount = prefixVertexCount
        self.confirmedSampleCount = confirmedSampleCount
        self.finalizedConfirmedSampleCount = finalizedConfirmedSampleCount
        self.sourceInk = sourceInk
        self.sourceGeneration = sourceGeneration
        self.pressureEnabled = pressureEnabled
        self.preparedResourceIdentity = preparedResourceIdentity
        self.elementID = elementID
        self.styleFingerprint = styleFingerprint
        self.viewportSignature = viewportSignature
        self.premultipliedColor = premultipliedColor
    }
}

struct MetalTransientCoverageEncoding {
    let coverage: MetalCoverageResource
    let retainedPrefix: MetalCoverageResource?
    let encodedSegmentCount: Int
}

struct MetalCoverageViewportSignature: Hashable {
    let zoom: Double
    let translation: CanvasPoint
    let viewportSize: CanvasSize
    let displayScale: Double
    let pixelWidth: Int
    let pixelHeight: Int

    var viewportScale: Double { zoom * displayScale }
}

private struct PreparedCoverageSource: Equatable {
    let ink: ObjectIdentifier
    let generation: RecognitionGeneration
}

@MainActor
final class MetalFreehandCoverageCache {
    private static let maximumTextureDimension = 16_384

    struct PreparedCoverageInput {
        enum CoverageReuse {
            case exact(MetalCoverageResource)
            case append(MetalCoverageResource)

            var base: MetalCoverageResource {
                switch self {
                case .exact(let resource), .append(let resource):
                    return resource
                }
            }
        }

        let sourceInk: CanvasPreparedInk
        let pointSequence: MetalCoverageSequence<CanvasPoint>
        let vertexSequence: MetalCoverageSequence<CanvasInkVertex>
        let spanEndSequence: MetalCoverageSequence<Int>
        var points: [CanvasPoint] { pointSequence.materialized() }
        var flattened: CanvasFlattenedInkCurve {
            CanvasFlattenedInkCurve(
                vertices: vertexSequence.materialized(),
                spanEndVertexIndices: spanEndSequence.materialized()
            )
        }
        let prefixVertexCount: Int
        let confirmedSampleCount: Int
        let finalizedConfirmedSampleCount: Int
        let sourceGeneration: RecognitionGeneration
        let pressureEnabled: Bool
        let preparedResourceIdentity: CanvasPreparedResourceIdentity
        let coverageReuse: CoverageReuse?
    }

    struct FramePlan {
        fileprivate let viewportSignature: MetalCoverageViewportSignature
        fileprivate let inputs: [CanvasPreparedResourceIdentity: PreparedCoverageInput]

        var preparedInputCount: Int { inputs.count }
    }

    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let coveragePipeline: any MTLRenderPipelineState
    private let resources: MetalResourceCache
    private var activeKey: MetalResourceKey?
    private var activeElementIDStorage: UUID?
    private var activePointCountStorage = 0
    private var lastViewport: CanvasViewport?
    private var lastDisplayScale: Double = 1
    private var injectedFailure: MetalFreehandCoverageFailurePoint?

    private(set) var statistics = MetalFreehandCoverageStatistics()

    convenience init(
        device: any MTLDevice,
        budgetBytes: Int = CanvasMetalLimits.resourceBudgetBytes
    ) throws {
        let pipelines = try MetalPipelineLibrary(device: device)
        try self.init(
            device: device,
            coveragePipeline: pipelines.coverageSegment,
            resourceCache: MetalResourceCache(device: device, budgetBytes: budgetBytes)
        )
    }

    init(
        device: any MTLDevice,
        coveragePipeline: any MTLRenderPipelineState,
        resourceCache: MetalResourceCache
    ) throws {
        guard let commandQueue = device.makeCommandQueue() else {
            throw MetalCanvasError.deviceUnavailable
        }
        self.device = device
        self.commandQueue = commandQueue
        self.coveragePipeline = coveragePipeline
        resources = resourceCache
    }

    var residentByteCount: Int { resources.residentByteCount }
    var budgetByteCount: Int { resources.budgetByteCount }
    var resourceCount: Int { resources.resourceCount }
    var hasActiveCoverage: Bool { activeResource != nil }
    var activeCoverageIsInFlight: Bool {
        activeResource.map(resources.isInFlight) ?? false
    }
    var activeElementID: UUID? { activeElementIDStorage }
    var activePointCount: Int { activePointCountStorage }
    var activeTexture: (any MTLTexture)? { activeResource?.texture }

    func makeFramePlan(
        geometries: [CanvasPreparedGeometry],
        viewport: CanvasViewport,
        displayScale: Double
    ) throws -> FramePlan {
        let signature = try viewportSignature(viewport, displayScale: displayScale)
        var inputs: [CanvasPreparedResourceIdentity: PreparedCoverageInput] = [:]
        var sources: [CanvasPreparedResourceIdentity: PreparedCoverageSource] = [:]
        inputs.reserveCapacity(geometries.count)
        sources.reserveCapacity(geometries.count)
        for geometry in geometries {
            let ink = try preparedInk(geometry)
            let source = PreparedCoverageSource(
                ink: ObjectIdentifier(ink),
                generation: ink.generation
            )
            if let existing = sources[geometry.resourceIdentity] {
                guard existing == source else {
                    throw MetalCanvasError.invalidNumericInput
                }
                continue
            }
            inputs[geometry.resourceIdentity] = try preparedCoverageInput(
                geometry,
                signature: signature
            )
            sources[geometry.resourceIdentity] = source
        }
        return FramePlan(viewportSignature: signature, inputs: inputs)
    }

    func estimatedCoverageByteCount(
        geometry: CanvasPreparedGeometry,
        viewport: CanvasViewport,
        displayScale: Double
    ) throws -> Int {
        let plan = try makeFramePlan(
            geometries: [geometry],
            viewport: viewport,
            displayScale: displayScale
        )
        return try estimatedCoverageByteCount(geometry: geometry, using: plan)
    }

    func estimatedCoverageByteCount(
        geometry: CanvasPreparedGeometry,
        using plan: FramePlan
    ) throws -> Int {
        let input = try preparedInput(for: geometry, using: plan)
        guard input.prefixVertexCount > 0 else { return 0 }
        return try allocationEstimateByteCount(
            pointCount: coverageSegmentCount(vertexCount: input.prefixVertexCount),
            signature: plan.viewportSignature
        )
    }

    func additionalCoverageByteCount(
        geometry: CanvasPreparedGeometry,
        viewport: CanvasViewport,
        displayScale: Double
    ) throws -> Int {
        let plan = try makeFramePlan(
            geometries: [geometry],
            viewport: viewport,
            displayScale: displayScale
        )
        return try additionalCoverageByteCount(geometry: geometry, using: plan)
    }

    func additionalCoverageByteCount(
        geometry: CanvasPreparedGeometry,
        using plan: FramePlan
    ) throws -> Int {
        let signature = plan.viewportSignature
        let input = try preparedInput(for: geometry, using: plan)
        guard input.prefixVertexCount > 0 else { return 0 }
        guard let existing = coverage(
            for: geometry,
            signature: signature
        ) else {
            return try estimatedCoverageByteCount(geometry: geometry, using: plan)
        }
        guard let reuse = input.coverageReuse,
              reuse.base === existing else {
            return try estimatedCoverageByteCount(geometry: geometry, using: plan)
        }
        if case .exact = reuse {
            return 0
        }
        if resources.isInFlight(existing) {
            return try estimatedCoverageByteCount(geometry: geometry, using: plan)
        }
        guard case .preview = geometry.renderKey else {
            return try estimatedCoverageByteCount(geometry: geometry, using: plan)
        }
        let requiredCapacity = try segmentCapacity(
            required: coverageSegmentCount(vertexCount: input.prefixVertexCount)
        )
        guard requiredCapacity > existing.segmentCapacity else {
            return 0
        }
        return try segmentBufferAllocationByteCount(
            payloadByteCount: checkedSegmentByteCount(requiredCapacity)
        )
    }

    func combinedResidentByteCount(
        retaining retainedCoverage: [MetalCoverageResource]
    ) throws -> Int {
        try resources.combinedResidentByteCount(retaining: retainedCoverage)
    }

    func update(activeGeometry: CanvasPreparedGeometry, viewport: CanvasViewport) throws {
        try update(activeGeometry: activeGeometry, viewport: viewport, displayScale: 1)
    }

    func update(
        activeGeometry: CanvasPreparedGeometry,
        viewport: CanvasViewport,
        displayScale: Double,
        encodingOn commandBuffer: (any MTLCommandBuffer)? = nil
    ) throws {
        let plan = try makeFramePlan(
            geometries: [activeGeometry],
            viewport: viewport,
            displayScale: displayScale
        )
        try update(
            activeGeometry: activeGeometry,
            using: plan,
            viewport: viewport,
            displayScale: displayScale,
            encodingOn: commandBuffer
        )
    }

    func update(
        activeGeometry: CanvasPreparedGeometry,
        using plan: FramePlan,
        viewport: CanvasViewport,
        displayScale: Double,
        encodingOn commandBuffer: (any MTLCommandBuffer)? = nil
    ) throws {
        let ink = try preparedInk(activeGeometry)
        let signature = plan.viewportSignature
        let input = try preparedInput(for: activeGeometry, using: plan)
        let pointCount = input.pointSequence.count
        let fingerprint = try styleFingerprint(activeGeometry.style)
        try validateGeometry(activeGeometry)
        let key = MetalResourceKey.ink(
            ink: ObjectIdentifier(ink),
            styleFingerprint: fingerprint,
            viewportScale: signature.viewportScale
        )

        if input.prefixVertexCount == 0 {
            resources.removeResource(for: key)
        } else if let existing = resources.peekResource(for: key)?.coverage,
           existing.viewportSignature == signature,
           existing.styleFingerprint == fingerprint,
           existing.sourceInk === ink,
           let reuse = input.coverageReuse,
           reuse.base === existing {
            statistics.validatedPointCount += max(0, pointCount - existing.pointCount)
            switch reuse {
            case .exact:
                let refreshed = resourceByReplacingMetadata(
                    existing,
                    geometry: activeGeometry,
                    input: input
                )
                try resources.insert(try MetalCachedResource(coverage: refreshed), for: key)
            case .append:
                if resources.isInFlight(existing) {
                    _ = try buildCoverage(
                        geometry: activeGeometry,
                        input: input,
                        pointSequence: input.pointSequence,
                        vertexSequence: input.vertexSequence,
                        prefixVertexCount: input.prefixVertexCount,
                        signature: signature,
                        cacheKey: key,
                        protecting: key,
                        encodingOn: commandBuffer
                    )
                    statistics.fullBuildCount += 1
                } else {
                    _ = try appendSuffix(
                        to: existing,
                        geometry: activeGeometry,
                        input: input,
                        pointSequence: input.pointSequence,
                        vertexSequence: input.vertexSequence,
                        prefixVertexCount: input.prefixVertexCount,
                        signature: signature,
                        cacheKey: key,
                        encodingOn: commandBuffer
                    )
                }
            }
        } else {
            try validatePoints(input.pointSequence)
            statistics.validatedPointCount += pointCount
            let rebuilt = try buildCoverage(
                geometry: activeGeometry,
                input: input,
                pointSequence: input.pointSequence,
                vertexSequence: input.vertexSequence,
                prefixVertexCount: input.prefixVertexCount,
                signature: signature,
                cacheKey: key,
                protecting: activeKey,
                encodingOn: commandBuffer
            )
            _ = rebuilt
            statistics.fullBuildCount += 1
        }

        if let previousKey = activeKey, previousKey != key {
            resources.removeResource(for: previousKey)
        }
        activeKey = key
        activeElementIDStorage = activeGeometry.id
        activePointCountStorage = pointCount
        lastViewport = viewport
        lastDisplayScale = displayScale
    }

    func commit(geometry: CanvasPreparedGeometry) throws {
        guard let viewport = lastViewport else {
            throw MetalCanvasError.invalidResourceSize
        }
        try commit(
            geometry: geometry,
            viewport: viewport,
            displayScale: lastDisplayScale
        )
    }

    func commit(
        geometry: CanvasPreparedGeometry,
        viewport: CanvasViewport,
        displayScale: Double,
        encodingOn commandBuffer: (any MTLCommandBuffer)? = nil
    ) throws {
        let plan = try makeFramePlan(
            geometries: [geometry],
            viewport: viewport,
            displayScale: displayScale
        )
        try commit(
            geometry: geometry,
            using: plan,
            viewport: viewport,
            displayScale: displayScale,
            encodingOn: commandBuffer
        )
    }

    func commit(
        geometry: CanvasPreparedGeometry,
        using plan: FramePlan,
        viewport: CanvasViewport,
        displayScale: Double,
        encodingOn commandBuffer: (any MTLCommandBuffer)? = nil
    ) throws {
        let signature = plan.viewportSignature
        let input = try preparedInput(for: geometry, using: plan)
        let pointCount = input.pointSequence.count
        let vertexCount = input.vertexSequence.count
        let fingerprint = try styleFingerprint(geometry.style)
        try validateGeometry(geometry)
        let destinationKey = immutableKey(
            geometry,
            viewportScale: signature.viewportScale
        )

        let matchingActive: (key: MetalResourceKey, resource: MetalCoverageResource)?
        if let sourceKey = activeKey,
           let active = resources.peekResource(for: sourceKey)?.coverage,
           active.elementID == geometry.id {
            matchingActive = (sourceKey, active)
        } else {
            matchingActive = nil
        }

        if let matchingActive,
           matchingActive.resource.styleFingerprint == fingerprint,
           matchingActive.resource.viewportSignature == signature {
            var isTrustedExactReuse = false
            var isTrustedAppendReuse = false
            if let reuse = input.coverageReuse,
               reuse.base === matchingActive.resource {
                switch reuse {
                case .exact:
                    isTrustedExactReuse = true
                case .append:
                    isTrustedAppendReuse = true
                }
            }
            let hasVerifiedColdPrefix: Bool
            if input.coverageReuse == nil,
               matchingActive.resource.prefixVertexCount <= vertexCount {
                hasVerifiedColdPrefix = matchingActive.resource.vertexSequence.prefixElementsEqual(
                    to: input.vertexSequence,
                    count: matchingActive.resource.prefixVertexCount
                )
            } else {
                hasVerifiedColdPrefix = false
            }
            if (isTrustedExactReuse || hasVerifiedColdPrefix),
               matchingActive.resource.prefixVertexCount == vertexCount {
                let refreshed = resourceByReplacingMetadata(
                    matchingActive.resource,
                    geometry: geometry,
                    input: input
                )
                try resources.insert(
                    try MetalCachedResource(coverage: refreshed),
                    for: matchingActive.key
                )
                try resources.rekeyResource(from: matchingActive.key, to: destinationKey)
                clearActiveState()
                statistics.commitReuseCount += 1
                lastViewport = viewport
                lastDisplayScale = displayScale
                return
            }
            if (isTrustedAppendReuse || hasVerifiedColdPrefix),
               !resources.isInFlight(matchingActive.resource) {
                _ = try appendSuffix(
                    to: matchingActive.resource,
                    geometry: geometry,
                    input: input,
                    pointSequence: input.pointSequence,
                    vertexSequence: input.vertexSequence,
                    prefixVertexCount: vertexCount,
                    signature: signature,
                    cacheKey: matchingActive.key,
                    encodingOn: commandBuffer
                )
                try resources.rekeyResource(from: matchingActive.key, to: destinationKey)
                clearActiveState()
                statistics.commitReuseCount += 1
                lastViewport = viewport
                lastDisplayScale = displayScale
                return
            }
        }

        if let existing = resources.peekResource(for: destinationKey)?.coverage,
           existing.viewportSignature == signature,
           existing.styleFingerprint == fingerprint,
           existing.pointSequence.elementsEqual(to: input.pointSequence),
           existing.vertexSequence.elementsEqual(to: input.vertexSequence),
           existing.prefixVertexCount == vertexCount {
            if let sourceKey = matchingActive?.key {
                resources.removeResource(for: sourceKey)
                clearActiveState()
            }
            lastViewport = viewport
            lastDisplayScale = displayScale
            return
        }
        try validatePoints(input.pointSequence)
        statistics.validatedPointCount += pointCount
        let rebuilt = try buildCoverage(
            geometry: geometry,
            input: input,
            pointSequence: input.pointSequence,
            vertexSequence: input.vertexSequence,
            prefixVertexCount: vertexCount,
            signature: signature,
            cacheKey: destinationKey,
            protecting: matchingActive?.key,
            encodingOn: commandBuffer
        )
        _ = rebuilt
        if let sourceKey = matchingActive?.key {
            resources.removeResource(for: sourceKey)
            clearActiveState()
        }
        statistics.fullBuildCount += 1
        lastViewport = viewport
        lastDisplayScale = displayScale
    }

    func prepare(
        geometry: CanvasPreparedGeometry,
        viewport: CanvasViewport,
        displayScale: Double,
        encodingOn commandBuffer: (any MTLCommandBuffer)? = nil
    ) throws {
        let plan = try makeFramePlan(
            geometries: [geometry],
            viewport: viewport,
            displayScale: displayScale
        )
        try prepare(
            geometry: geometry,
            using: plan,
            viewport: viewport,
            displayScale: displayScale,
            encodingOn: commandBuffer
        )
    }

    func prepare(
        geometry: CanvasPreparedGeometry,
        using plan: FramePlan,
        viewport: CanvasViewport,
        displayScale: Double,
        encodingOn commandBuffer: (any MTLCommandBuffer)? = nil
    ) throws {
        switch geometry.renderKey {
        case .preview:
            try update(
                activeGeometry: geometry,
                using: plan,
                viewport: viewport,
                displayScale: displayScale,
                encodingOn: commandBuffer
            )
        case .committed:
            try commit(
                geometry: geometry,
                using: plan,
                viewport: viewport,
                displayScale: displayScale,
                encodingOn: commandBuffer
            )
        }
    }

    func transientCoverageByteCount(
        maximumPointCount: Int,
        viewport: CanvasViewport,
        displayScale: Double
    ) throws -> Int {
        let signature = try viewportSignature(viewport, displayScale: displayScale)
        return try allocationEstimateByteCount(
            pointCount: coverageSegmentCount(vertexCount: maximumPointCount),
            signature: signature
        )
    }

    func maximumPointCount(
        in geometries: [CanvasPreparedGeometry],
        viewport: CanvasViewport,
        displayScale: Double
    ) throws -> Int {
        let plan = try makeFramePlan(
            geometries: geometries,
            viewport: viewport,
            displayScale: displayScale
        )
        return try maximumPointCount(in: geometries, using: plan)
    }

    func maximumPointCount(
        in geometries: [CanvasPreparedGeometry],
        using plan: FramePlan
    ) throws -> Int {
        return try geometries.reduce(into: 0) { result, geometry in
            result = max(
                result,
                try preparedInput(for: geometry, using: plan).vertexSequence.count
            )
        }
    }

    func totalPointCount(
        in geometries: [CanvasPreparedGeometry],
        using plan: FramePlan
    ) throws -> Int {
        try geometries.reduce(into: 0) { result, geometry in
            let count = try preparedInput(for: geometry, using: plan).vertexSequence.count
            let sum = result.addingReportingOverflow(count)
            guard !sum.overflow else { throw MetalCanvasError.invalidResourceSize }
            result = sum.partialValue
        }
    }

    func requiresTransientCoverage(
        _ geometry: CanvasPreparedGeometry,
        viewport: CanvasViewport,
        displayScale: Double
    ) throws -> Bool {
        let plan = try makeFramePlan(
            geometries: [geometry],
            viewport: viewport,
            displayScale: displayScale
        )
        return try requiresTransientCoverage(geometry, using: plan)
    }

    func requiresTransientCoverage(
        _ geometry: CanvasPreparedGeometry,
        using plan: FramePlan
    ) throws -> Bool {
        let signature = plan.viewportSignature
        let input = try preparedInput(for: geometry, using: plan)
        switch geometry.renderKey {
        case .preview:
            return input.prefixVertexCount < input.vertexSequence.count
        case .committed:
            if activeElementID == geometry.id {
                return false
            }
            if let cached = coverage(
                for: geometry,
                signature: signature
            ) {
                return cached.prefixVertexCount != input.vertexSequence.count
                    || !cached.vertexSequence.elementsEqual(to: input.vertexSequence)
            }
            return true
        }
    }

    func makeTransientCoverage(
        maximumPointCount: Int,
        viewport: CanvasViewport,
        displayScale: Double
    ) throws -> MetalCoverageResource {
        let signature = try viewportSignature(viewport, displayScale: displayScale)
        let capacity = try segmentCapacity(
            required: coverageSegmentCount(vertexCount: maximumPointCount)
        )
        let segmentPayloadBytes = try checkedSegmentByteCount(capacity)
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: signature.pixelWidth,
            height: signature.pixelHeight,
            mipmapped: false
        )
        textureDescriptor.storageMode = .shared
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        let texturePayloadBytes = try MetalCachedResource.checkedByteCount(
            width: signature.pixelWidth,
            height: signature.pixelHeight,
            bytesPerPixel: 1
        )
        let textureEstimate = try MetalCachedResource.conservativeAllocationByteCount(
            payloadByteCount: texturePayloadBytes,
            reportedByteCount: device.heapTextureSizeAndAlign(descriptor: textureDescriptor).size
        )
        let bufferEstimate = try segmentBufferAllocationByteCount(
            payloadByteCount: segmentPayloadBytes
        )
        try validateCombinedAllocationBytes(textureEstimate, bufferEstimate)
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            throw MetalCanvasError.invalidResourceSize
        }
        let buffer = try makeSegmentBuffer(capacity: capacity)
        let textureBytes = try MetalCachedResource.conservativeAllocationByteCount(
            payloadByteCount: texturePayloadBytes,
            reportedByteCount: texture.allocatedSize
        )
        let bufferBytes = try MetalCachedResource.conservativeAllocationByteCount(
            payloadByteCount: segmentPayloadBytes,
            reportedByteCount: buffer.allocatedSize
        )
        try validateCombinedAllocationBytes(textureBytes, bufferBytes)
        statistics.transientCoverageAllocationCount += 1
        return MetalCoverageResource(
            texture: texture,
            textureByteCount: textureBytes,
            segmentBuffer: buffer,
            segmentBufferByteCount: bufferBytes,
            segmentCapacity: capacity,
            pointCount: maximumPointCount,
            sourceInk: nil,
            elementID: UUID(),
            styleFingerprint: 0,
            viewportSignature: signature,
            premultipliedColor: .zero
        )
    }

    func encodeTransientCoverage(
        geometry: CanvasPreparedGeometry,
        using scratch: MetalCoverageResource,
        commandBuffer: any MTLCommandBuffer
    ) throws -> MetalTransientCoverageEncoding {
        let viewport = try CanvasViewport(
            zoom: scratch.viewportSignature.zoom,
            translation: scratch.viewportSignature.translation,
            viewportSize: scratch.viewportSignature.viewportSize
        )
        let plan = try makeFramePlan(
            geometries: [geometry],
            viewport: viewport,
            displayScale: scratch.viewportSignature.displayScale
        )
        return try encodeTransientCoverage(
            geometry: geometry,
            using: scratch,
            framePlan: plan,
            commandBuffer: commandBuffer
        )
    }

    func encodeTransientCoverage(
        geometry: CanvasPreparedGeometry,
        using scratch: MetalCoverageResource,
        framePlan plan: FramePlan,
        destinationSegmentStart: Int = 0,
        commandBuffer: any MTLCommandBuffer
    ) throws -> MetalTransientCoverageEncoding {
        guard plan.viewportSignature == scratch.viewportSignature else {
            throw MetalCanvasError.invalidResourceSize
        }
        let input = try preparedInput(for: geometry, using: plan)
        try validateGeometry(geometry)
        let prefix: MetalCoverageResource?
        if case .preview = geometry.renderKey {
            prefix = coverage(
                for: geometry,
                viewport: try CanvasViewport(
                    zoom: scratch.viewportSignature.zoom,
                    translation: scratch.viewportSignature.translation,
                    viewportSize: scratch.viewportSignature.viewportSize
                ),
                displayScale: scratch.viewportSignature.displayScale
            )
        } else {
            prefix = nil
        }
        let prefixVertexCount = prefix?.prefixVertexCount ?? 0
        let tailStart = prefixVertexCount > 0 ? prefixVertexCount - 1 : 0
        let tailVertexCount = input.vertexSequence.count - tailStart
        let tailSegmentCount = coverageSegmentCount(vertexCount: tailVertexCount)
        guard destinationSegmentStart >= 0,
              destinationSegmentStart + tailSegmentCount <= scratch.segmentCapacity else {
            throw MetalCanvasError.invalidResourceSize
        }
        if let prefix {
            guard let blit = commandBuffer.makeBlitCommandEncoder() else {
                throw MetalCanvasError.commandEncodingFailed
            }
            blit.copy(
                from: prefix.texture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: .init(x: 0, y: 0, z: 0),
                sourceSize: .init(
                    width: prefix.texture.width,
                    height: prefix.texture.height,
                    depth: 1
                ),
                to: scratch.texture,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: .init(x: 0, y: 0, z: 0)
            )
            blit.endEncoding()
            statistics.prefixToScratchCopyCount += 1
        }
        var encoded = false
        let canvasLineWidth = try CanvasInkCurve.lineWidthInCanvasUnits(
            lineWidth: geometry.style.lineWidth,
            viewportZoom: scratch.viewportSignature.zoom,
            widthMode: input.sourceInk.widthMode
        )
        try encode(
            vertices: input.vertexSequence,
            sourceSegmentRange: tailStart..<(tailStart + tailSegmentCount),
            destinationSegmentStart: destinationSegmentStart,
            lineWidth: canvasLineWidth,
            into: scratch,
            clear: prefix == nil,
            submitted: &encoded,
            commandBuffer: commandBuffer
        )
        statistics.transientTailEncodeCount += 1
        let coverage = MetalCoverageResource(
            texture: scratch.texture,
            textureByteCount: scratch.textureByteCount,
            segmentBuffer: scratch.segmentBuffer,
            segmentBufferByteCount: scratch.segmentBufferByteCount,
            segmentCapacity: scratch.segmentCapacity,
            pointCount: input.pointSequence.count,
            pointSequence: input.pointSequence,
            vertexSequence: input.vertexSequence,
            spanEndSequence: input.spanEndSequence,
            prefixVertexCount: prefixVertexCount,
            sourceInk: nil,
            elementID: geometry.id,
            styleFingerprint: try styleFingerprint(geometry.style),
            viewportSignature: scratch.viewportSignature,
            premultipliedColor: try premultipliedColor(geometry.style.stroke)
        )
        return MetalTransientCoverageEncoding(
            coverage: coverage,
            retainedPrefix: prefix,
            encodedSegmentCount: tailSegmentCount
        )
    }

    func coverage(
        for geometry: CanvasPreparedGeometry,
        viewport: CanvasViewport,
        displayScale: Double
    ) -> MetalCoverageResource? {
        guard let signature = try? viewportSignature(viewport, displayScale: displayScale) else {
            return nil
        }
        return coverage(for: geometry, signature: signature)
    }

    private func coverage(
        for geometry: CanvasPreparedGeometry,
        signature: MetalCoverageViewportSignature
    ) -> MetalCoverageResource? {
        guard let fingerprint = try? styleFingerprint(geometry.style),
              let ink = try? preparedInk(geometry) else {
            return nil
        }
        let key: MetalResourceKey
        switch geometry.renderKey {
        case .preview:
            key = .ink(
                ink: ObjectIdentifier(ink),
                styleFingerprint: fingerprint,
                viewportScale: signature.viewportScale
            )
        case .committed:
            key = immutableKey(geometry, viewportScale: signature.viewportScale)
        }
        guard let resource = resources.resource(for: key)?.coverage,
              resource.viewportSignature == signature,
              resource.styleFingerprint == fingerprint else {
            return nil
        }
        return resource
    }

    func hasCoverage(
        for geometry: CanvasPreparedGeometry,
        viewport: CanvasViewport
    ) -> Bool {
        coverage(for: geometry, viewport: viewport, displayScale: 1) != nil
    }

    func activeCoverage(atX x: Int, y: Int) -> UInt8 {
        guard let texture = activeResource?.texture,
              x >= 0, y >= 0, x < texture.width, y < texture.height else {
            return 0
        }
        var result: UInt8 = 0
        texture.getBytes(
            &result,
            bytesPerRow: 1,
            from: MTLRegionMake2D(x, y, 1, 1),
            mipmapLevel: 0
        )
        return result
    }

    func reset() {
        if let activeKey {
            resources.removeResource(for: activeKey)
        }
        clearActiveState()
        lastViewport = nil
    }

    func handleMemoryPressure() {
        resources.removeAll()
        clearActiveState()
        lastViewport = nil
    }

    func injectFailureOnce(_ failure: MetalFreehandCoverageFailurePoint) {
        injectedFailure = failure
    }
}

private extension MetalFreehandCoverageCache {
    var activeResource: MetalCoverageResource? {
        guard let activeKey else { return nil }
        return resources.peekResource(for: activeKey)?.coverage
    }

    func clearActiveState() {
        activeKey = nil
        activeElementIDStorage = nil
        activePointCountStorage = 0
    }

    func consumeInjectedFailure(_ failure: MetalFreehandCoverageFailurePoint) -> Bool {
        guard injectedFailure == failure else { return false }
        injectedFailure = nil
        return true
    }

    func immutableKey(
        _ geometry: CanvasPreparedGeometry,
        viewportScale: Double
    ) -> MetalResourceKey {
        .immutable(
            renderKey: geometry.renderKey,
            resourceIdentity: geometry.resourceIdentity,
            viewportScale: viewportScale
        )
    }

    func preparedInk(
        _ geometry: CanvasPreparedGeometry
    ) throws -> CanvasPreparedInk {
        guard case .ink(let ink) = geometry.path else {
            throw MetalCanvasError.invalidNumericInput
        }
        return ink
    }

    func preparedInput(
        for geometry: CanvasPreparedGeometry,
        using plan: FramePlan
    ) throws -> PreparedCoverageInput {
        guard let input = plan.inputs[geometry.resourceIdentity] else {
            throw MetalCanvasError.invalidNumericInput
        }
        return input
    }

    func preparedCoverageInput(
        _ geometry: CanvasPreparedGeometry,
        signature: MetalCoverageViewportSignature
    ) throws -> PreparedCoverageInput {
        let ink = try preparedInk(geometry)
        let snapshot = ink.snapshot()
        guard snapshot.finalizedConfirmedSampleCount >= 0,
              snapshot.finalizedConfirmedSampleCount <= snapshot.confirmed.count else {
            throw MetalCanvasError.invalidNumericInput
        }
        let fingerprint = try styleFingerprint(geometry.style)
        let reusableResource: MetalCoverageResource?
        if let cached = coverage(for: geometry, signature: signature) {
            reusableResource = cached
        } else if let activeResource,
                  activeResource.elementID == geometry.id {
            reusableResource = activeResource
        } else {
            reusableResource = nil
        }
        if let reusableResource,
           let incremental = try incrementalPreparedCoverageInput(
               geometry: geometry,
               ink: ink,
               snapshot: snapshot,
               signature: signature,
               styleFingerprint: fingerprint,
               existing: reusableResource
           ) {
            return incremental
        }

        let samples = snapshot.confirmed + snapshot.predicted
        guard samples.allSatisfy({ sample in
            sample.point.x.isFinite && sample.point.y.isFinite && sample.pressure.isFinite
        }) else {
            throw MetalCanvasError.invalidNumericInput
        }
        let canvasLineWidth = try CanvasInkCurve.lineWidthInCanvasUnits(
            lineWidth: geometry.style.lineWidth,
            viewportZoom: signature.zoom,
            widthMode: snapshot.widthMode
        )
        let pixelLineWidth = canvasLineWidth * signature.viewportScale
        let maximumWidthError = 0.5 / max(pixelLineWidth, 0.5)
        let flattened: CanvasFlattenedInkCurve
        do {
            flattened = try CanvasInkCurve.flattenWithSpanEnds(
                stroke: CanvasInkStroke(
                    samples: samples,
                    pressureEnabled: snapshot.pressureEnabled,
                    widthMode: snapshot.widthMode
                ),
                maximumError: 0.25 / signature.viewportScale,
                maximumWidthError: maximumWidthError
            )
        } catch {
            throw MetalCanvasError.invalidNumericInput
        }
        let prefixVertexCount = try prefixVertexCount(
            finalizedConfirmedSampleCount: snapshot.finalizedConfirmedSampleCount,
            flattened: flattened
        )
        guard prefixVertexCount <= flattened.vertices.count else {
            throw MetalCanvasError.invalidNumericInput
        }
        let visibleVertices: [CanvasInkVertex]
        do {
            visibleVertices = try CanvasInkVisibilityPolicy.apply(
                to: flattened.vertices,
                lineWidth: canvasLineWidth,
                pixelsPerCanvasUnit: signature.viewportScale,
                pressureEnabled: snapshot.pressureEnabled
            )
        } catch {
            throw MetalCanvasError.invalidNumericInput
        }
        let limitedVertices = CanvasInkTaperLimiter.limit(
            visibleVertices,
            lineWidth: canvasLineWidth
        )
        statistics.fullFlattenCount += 1
        return PreparedCoverageInput(
            sourceInk: ink,
            pointSequence: MetalCoverageSequence(
                samples.map(\.point),
                stablePrefixCount: snapshot.finalizedConfirmedSampleCount
            ),
            vertexSequence: MetalCoverageSequence(
                limitedVertices,
                stablePrefixCount: max(0, prefixVertexCount - 1)
            ),
            spanEndSequence: MetalCoverageSequence(
                flattened.spanEndVertexIndices,
                stablePrefixCount: max(0, snapshot.finalizedConfirmedSampleCount - 1)
            ),
            prefixVertexCount: prefixVertexCount,
            confirmedSampleCount: snapshot.confirmed.count,
            finalizedConfirmedSampleCount: snapshot.finalizedConfirmedSampleCount,
            sourceGeneration: ink.generation,
            pressureEnabled: snapshot.pressureEnabled,
            preparedResourceIdentity: geometry.resourceIdentity,
            coverageReuse: nil
        )
    }

    func incrementalPreparedCoverageInput(
        geometry: CanvasPreparedGeometry,
        ink: CanvasPreparedInk,
        snapshot: CanvasPreparedInkSnapshot,
        signature: MetalCoverageViewportSignature,
        styleFingerprint: UInt64,
        existing: MetalCoverageResource
    ) throws -> PreparedCoverageInput? {
        guard existing.sourceInk === ink,
              existing.sourceGeneration != nil,
              existing.confirmedSampleCount <= snapshot.confirmed.count,
              existing.finalizedConfirmedSampleCount
                <= snapshot.finalizedConfirmedSampleCount,
              existing.pressureEnabled == snapshot.pressureEnabled,
              existing.styleFingerprint == styleFingerprint,
              existing.viewportSignature == signature else {
            return nil
        }
        let isSameStampedInput = existing.sourceGeneration == ink.generation
        if isSameStampedInput {
            return PreparedCoverageInput(
                sourceInk: ink,
                pointSequence: existing.pointSequence,
                vertexSequence: existing.vertexSequence,
                spanEndSequence: existing.spanEndSequence,
                prefixVertexCount: existing.prefixVertexCount,
                confirmedSampleCount: existing.confirmedSampleCount,
                finalizedConfirmedSampleCount: existing.finalizedConfirmedSampleCount,
                sourceGeneration: ink.generation,
                pressureEnabled: existing.pressureEnabled,
                preparedResourceIdentity: geometry.resourceIdentity,
                coverageReuse: .exact(existing)
            )
        }
        guard existing.sourceGeneration != ink.generation else {
            return nil
        }

        let stableSpanCount = max(0, existing.finalizedConfirmedSampleCount - 1)
        guard stableSpanCount <= existing.spanEndSequence.count,
              existing.prefixVertexCount > 0,
              existing.prefixVertexCount <= existing.vertexSequence.count else {
            return nil
        }
        if stableSpanCount > 0 {
            guard existing.spanEndSequence.element(at: stableSpanCount - 1) + 1
                    == existing.prefixVertexCount else {
                return nil
            }
        } else if existing.prefixVertexCount != 1 {
            return nil
        }

        let totalSampleCount = snapshot.confirmed.count + snapshot.predicted.count
        let totalSpanCount = max(0, totalSampleCount - 1)
        guard stableSpanCount < totalSpanCount else { return nil }
        let canvasLineWidth = try CanvasInkCurve.lineWidthInCanvasUnits(
            lineWidth: geometry.style.lineWidth,
            viewportZoom: signature.zoom,
            widthMode: snapshot.widthMode
        )
        let pixelLineWidth = canvasLineWidth * signature.viewportScale
        let maximumWidthError = 0.5 / max(pixelLineWidth, 0.5)
        let tail: CanvasFlattenedInkCurve
        do {
            tail = try CanvasInkCurve.flattenSpanRange(
                confirmedPrefix: snapshot.confirmed,
                appending: snapshot.predicted,
                pressureEnabled: snapshot.pressureEnabled,
                spanRange: stableSpanCount..<totalSpanCount,
                maximumError: 0.25 / signature.viewportScale,
                maximumWidthError: maximumWidthError
            )
        } catch {
            throw MetalCanvasError.invalidNumericInput
        }
        guard !tail.vertices.isEmpty else {
            throw MetalCanvasError.invalidNumericInput
        }
        let retainedVertexCount = existing.prefixVertexCount
        let combinedVertexCount = retainedVertexCount - 1 + tail.vertices.count
        let combinedSpanCount = stableSpanCount + tail.spanEndVertexIndices.count
        guard combinedVertexCount <= 1_000_000,
              combinedSpanCount == totalSpanCount else {
            throw MetalCanvasError.invalidNumericInput
        }
        let retainedPrefixCount = retainedVertexCount - 1
        let precedingVertex = retainedPrefixCount > 0
            ? existing.vertexSequence.element(at: retainedPrefixCount - 1)
            : nil
        let visibleTail: [CanvasInkVertex]
        do {
            visibleTail = try CanvasInkVisibilityPolicy.apply(
                to: tail.vertices,
                lineWidth: canvasLineWidth,
                pixelsPerCanvasUnit: signature.viewportScale,
                pressureEnabled: snapshot.pressureEnabled
            )
        } catch {
            throw MetalCanvasError.invalidNumericInput
        }
        let replacementVertexTail = CanvasInkTaperLimiter.limit(
            visibleTail,
            lineWidth: canvasLineWidth,
            precedingVertex: precedingVertex
        )
        let replacementSpanEndTail = tail.spanEndVertexIndices.map {
            retainedVertexCount - 1 + $0
        }
        let vertexSequence = MetalCoverageSequence(
            reusing: existing.vertexSequence,
            retainedPrefixCount: retainedPrefixCount,
            replacementTail: replacementVertexTail
        )
        let spanEndSequence = MetalCoverageSequence(
            reusing: existing.spanEndSequence,
            retainedPrefixCount: stableSpanCount,
            replacementTail: replacementSpanEndTail
        )
        let prefixVertexCount = try prefixVertexCount(
            finalizedConfirmedSampleCount: snapshot.finalizedConfirmedSampleCount,
            spanEndSequence: spanEndSequence,
            vertexCount: vertexSequence.count
        )
        guard prefixVertexCount >= existing.prefixVertexCount else {
            return nil
        }
        let retainedPointCount = existing.finalizedConfirmedSampleCount
        let replacementSamples = Array(snapshot.confirmed.dropFirst(retainedPointCount))
            + snapshot.predicted
        guard replacementSamples.allSatisfy({ sample in
            sample.point.x.isFinite && sample.point.y.isFinite && sample.pressure.isFinite
        }) else {
            throw MetalCanvasError.invalidNumericInput
        }
        let replacementPoints = replacementSamples.map(\.point)
        let pointSequence = MetalCoverageSequence(
            reusing: existing.pointSequence,
            retainedPrefixCount: retainedPointCount,
            replacementTail: replacementPoints
        )
        statistics.incrementalFlattenCount += 1
        statistics.incrementallyFlattenedSpanCount += tail.spanEndVertexIndices.count
        statistics.incrementallyCopiedVertexCount += replacementVertexTail.count
        statistics.incrementallyCopiedSpanEndCount += replacementSpanEndTail.count
        statistics.incrementallyCopiedPointCount += replacementPoints.count
        statistics.incrementallyValidatedSampleCount += replacementSamples.count
        return PreparedCoverageInput(
            sourceInk: ink,
            pointSequence: pointSequence,
            vertexSequence: vertexSequence,
            spanEndSequence: spanEndSequence,
            prefixVertexCount: prefixVertexCount,
            confirmedSampleCount: snapshot.confirmed.count,
            finalizedConfirmedSampleCount: snapshot.finalizedConfirmedSampleCount,
            sourceGeneration: ink.generation,
            pressureEnabled: snapshot.pressureEnabled,
            preparedResourceIdentity: geometry.resourceIdentity,
            coverageReuse: prefixVertexCount == existing.prefixVertexCount
                ? .exact(existing)
                : .append(existing)
        )
    }

    func prefixVertexCount(
        finalizedConfirmedSampleCount: Int,
        flattened: CanvasFlattenedInkCurve
    ) throws -> Int {
        if finalizedConfirmedSampleCount == 0 { return flattened.vertices.isEmpty ? 0 : 1 }
        if finalizedConfirmedSampleCount == 1 { return 1 }
        let spanIndex = finalizedConfirmedSampleCount - 2
        guard spanIndex < flattened.spanEndVertexIndices.count else {
            throw MetalCanvasError.invalidNumericInput
        }
        return flattened.spanEndVertexIndices[spanIndex] + 1
    }

    func prefixVertexCount(
        finalizedConfirmedSampleCount: Int,
        spanEndSequence: MetalCoverageSequence<Int>,
        vertexCount: Int
    ) throws -> Int {
        if finalizedConfirmedSampleCount == 0 { return vertexCount == 0 ? 0 : 1 }
        if finalizedConfirmedSampleCount == 1 {
            guard vertexCount >= 1 else { throw MetalCanvasError.invalidNumericInput }
            return 1
        }
        let spanIndex = finalizedConfirmedSampleCount - 2
        guard spanIndex < spanEndSequence.count else {
            throw MetalCanvasError.invalidNumericInput
        }
        return spanEndSequence.element(at: spanIndex) + 1
    }

    func coverageSegmentCount(vertexCount: Int) -> Int {
        vertexCount == 0 ? 0 : max(1, vertexCount - 1)
    }

    func resourceByReplacingMetadata(
        _ existing: MetalCoverageResource,
        geometry: CanvasPreparedGeometry,
        input: PreparedCoverageInput
    ) -> MetalCoverageResource {
        MetalCoverageResource(
            texture: existing.texture,
            textureByteCount: existing.textureByteCount,
            segmentBuffer: existing.segmentBuffer,
            segmentBufferByteCount: existing.segmentBufferByteCount,
            segmentCapacity: existing.segmentCapacity,
            pointCount: input.pointSequence.count,
            pointSequence: input.pointSequence,
            vertexSequence: input.vertexSequence,
            spanEndSequence: input.spanEndSequence,
            prefixVertexCount: input.prefixVertexCount,
            confirmedSampleCount: input.confirmedSampleCount,
            finalizedConfirmedSampleCount: input.finalizedConfirmedSampleCount,
            sourceInk: input.sourceInk,
            sourceGeneration: input.sourceGeneration,
            pressureEnabled: input.pressureEnabled,
            preparedResourceIdentity: input.preparedResourceIdentity,
            elementID: geometry.id,
            styleFingerprint: existing.styleFingerprint,
            viewportSignature: existing.viewportSignature,
            premultipliedColor: existing.premultipliedColor
        )
    }

    func centrelinePoints(_ geometry: CanvasPreparedGeometry) throws -> [CanvasPoint] {
        centrelinePoints(try preparedInk(geometry))
    }

    func centrelinePoints(_ ink: CanvasPreparedInk) -> [CanvasPoint] {
        let snapshot = ink.snapshot()
        return (snapshot.confirmed + snapshot.predicted).map(\.point)
    }

    func validateGeometry(_ geometry: CanvasPreparedGeometry) throws {
        guard geometry.bounds.x.isFinite,
              geometry.bounds.y.isFinite,
              geometry.bounds.width.isFinite,
              geometry.bounds.height.isFinite,
              geometry.bounds.width >= 0,
              geometry.bounds.height >= 0,
              geometry.style.lineWidth.isFinite,
              geometry.style.lineWidth >= 0 else {
            throw MetalCanvasError.invalidNumericInput
        }
    }

    func validatePoints<C: Collection>(_ points: C) throws where C.Element == CanvasPoint {
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw MetalCanvasError.invalidNumericInput
        }
    }

    func validatePoints(_ points: MetalCoverageSequence<CanvasPoint>) throws {
        for slice in points.slices(in: 0..<points.count) {
            try validatePoints(slice)
        }
    }

    func viewportSignature(
        _ viewport: CanvasViewport,
        displayScale: Double
    ) throws -> MetalCoverageViewportSignature {
        guard viewport.zoom.isFinite,
              viewport.zoom > 0,
              viewport.translation.x.isFinite,
              viewport.translation.y.isFinite,
              viewport.viewportSize.width.isFinite,
              viewport.viewportSize.height.isFinite,
              viewport.viewportSize.width > 0,
              viewport.viewportSize.height > 0,
              displayScale.isFinite,
              displayScale > 0 else {
            throw MetalCanvasError.invalidResourceSize
        }
        let widthValue = ceil(viewport.viewportSize.width * displayScale)
        let heightValue = ceil(viewport.viewportSize.height * displayScale)
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
            bytesPerPixel: 1
        )
        let viewportScale = viewport.zoom * displayScale
        guard viewportScale.isFinite else { throw MetalCanvasError.invalidResourceSize }
        return MetalCoverageViewportSignature(
            zoom: viewport.zoom,
            translation: viewport.translation,
            viewportSize: viewport.viewportSize,
            displayScale: displayScale,
            pixelWidth: width,
            pixelHeight: height
        )
    }

    func styleFingerprint(_ style: CanvasStyle) throws -> UInt64 {
        let values = [
            style.stroke.red,
            style.stroke.green,
            style.stroke.blue,
            style.stroke.alpha,
            style.fill?.red ?? -1,
            style.fill?.green ?? -1,
            style.fill?.blue ?? -1,
            style.fill?.alpha ?? -1,
            style.lineWidth,
        ]
        guard values.allSatisfy(\.isFinite) else {
            throw MetalCanvasError.invalidNumericInput
        }
        var result: UInt64 = 0xcbf2_9ce4_8422_2325
        for value in values {
            result ^= value.bitPattern
            result &*= 0x0000_0100_0000_01b3
        }
        return result
    }

    func premultipliedColor(_ color: CanvasColor) throws -> SIMD4<Float> {
        guard color.red.isFinite,
              color.green.isFinite,
              color.blue.isFinite,
              color.alpha.isFinite else {
            throw MetalCanvasError.invalidNumericInput
        }
        let alpha = min(1, max(0, color.alpha))
        return SIMD4<Float>(
            Float(min(1, max(0, color.red)) * alpha),
            Float(min(1, max(0, color.green)) * alpha),
            Float(min(1, max(0, color.blue)) * alpha),
            Float(alpha)
        )
    }

    func buildCoverage(
        geometry: CanvasPreparedGeometry,
        input: PreparedCoverageInput,
        pointSequence: MetalCoverageSequence<CanvasPoint>,
        vertexSequence: MetalCoverageSequence<CanvasInkVertex>,
        prefixVertexCount: Int,
        signature: MetalCoverageViewportSignature,
        cacheKey: MetalResourceKey,
        protecting protectedKey: MetalResourceKey?,
        encodingOn commandBuffer: (any MTLCommandBuffer)? = nil
    ) throws -> MetalCoverageResource {
        let segmentCount = coverageSegmentCount(vertexCount: prefixVertexCount)
        let capacity = try segmentCapacity(required: segmentCount)
        let segmentByteCount = try checkedSegmentByteCount(capacity)
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: signature.pixelWidth,
            height: signature.pixelHeight,
            mipmapped: false
        )
        textureDescriptor.storageMode = .shared
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        let texturePayloadBytes = try MetalCachedResource.checkedByteCount(
            width: signature.pixelWidth,
            height: signature.pixelHeight,
            bytesPerPixel: 1
        )
        let textureEstimate = try MetalCachedResource.conservativeAllocationByteCount(
            payloadByteCount: texturePayloadBytes,
            reportedByteCount: device.heapTextureSizeAndAlign(
                descriptor: textureDescriptor
            ).size
        )
        let bufferEstimate = try segmentBufferAllocationByteCount(
            payloadByteCount: segmentByteCount
        )
        try validateCombinedAllocationBytes(textureEstimate, bufferEstimate)
        let allocationEstimate = textureEstimate.addingReportingOverflow(bufferEstimate)
        guard !allocationEstimate.overflow else {
            throw MetalCanvasError.invalidResourceSize
        }
        try resources.reserve(
            additionalByteCount: allocationEstimate.partialValue,
            protecting: protectedKey
        )
        if consumeInjectedFailure(.allocation) {
            throw MetalCanvasError.invalidResourceSize
        }
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            throw MetalCanvasError.invalidResourceSize
        }
        let buffer = try makeSegmentBuffer(capacity: capacity)
        let textureAllocationBytes = try MetalCachedResource.conservativeAllocationByteCount(
            payloadByteCount: texturePayloadBytes,
            reportedByteCount: max(texture.allocatedSize, textureEstimate)
        )
        let bufferAllocationBytes = try MetalCachedResource.conservativeAllocationByteCount(
            payloadByteCount: segmentByteCount,
            reportedByteCount: max(buffer.allocatedSize, bufferEstimate)
        )
        try validateCombinedAllocationBytes(textureAllocationBytes, bufferAllocationBytes)
        let resource = MetalCoverageResource(
            texture: texture,
            textureByteCount: textureAllocationBytes,
            segmentBuffer: buffer,
            segmentBufferByteCount: bufferAllocationBytes,
            segmentCapacity: capacity,
            pointCount: pointSequence.count,
            pointSequence: pointSequence,
            vertexSequence: vertexSequence,
            spanEndSequence: input.spanEndSequence,
            prefixVertexCount: prefixVertexCount,
            confirmedSampleCount: input.confirmedSampleCount,
            finalizedConfirmedSampleCount: input.finalizedConfirmedSampleCount,
            sourceInk: input.sourceInk,
            sourceGeneration: input.sourceGeneration,
            pressureEnabled: input.pressureEnabled,
            preparedResourceIdentity: input.preparedResourceIdentity,
            elementID: geometry.id,
            styleFingerprint: try styleFingerprint(geometry.style),
            viewportSignature: signature,
            premultipliedColor: try premultipliedColor(geometry.style.stroke)
        )
        var encodingWasSubmitted = false
        let canvasLineWidth = try CanvasInkCurve.lineWidthInCanvasUnits(
            lineWidth: geometry.style.lineWidth,
            viewportZoom: signature.zoom,
            widthMode: input.sourceInk.widthMode
        )
        try encode(
            vertices: vertexSequence,
            sourceSegmentRange: 0..<segmentCount,
            destinationSegmentStart: 0,
            lineWidth: canvasLineWidth,
            into: resource,
            clear: true,
            submitted: &encodingWasSubmitted,
            commandBuffer: commandBuffer
        )
        try resources.insert(
            try MetalCachedResource(coverage: resource),
            for: cacheKey,
            protecting: protectedKey
        )
        statistics.encodedSegmentCount += segmentCount
        return resource
    }

    func appendSuffix(
        to existing: MetalCoverageResource,
        geometry: CanvasPreparedGeometry,
        input: PreparedCoverageInput,
        pointSequence: MetalCoverageSequence<CanvasPoint>,
        vertexSequence: MetalCoverageSequence<CanvasInkVertex>,
        prefixVertexCount: Int,
        signature: MetalCoverageViewportSignature,
        cacheKey: MetalResourceKey,
        encodingOn commandBuffer: (any MTLCommandBuffer)? = nil
    ) throws -> MetalCoverageResource {
        let firstSegment = max(0, existing.prefixVertexCount - 1)
        let segmentCount = coverageSegmentCount(vertexCount: prefixVertexCount)
        guard firstSegment <= segmentCount else {
            return try buildCoverage(
                geometry: geometry,
                input: input,
                pointSequence: pointSequence,
                vertexSequence: vertexSequence,
                prefixVertexCount: prefixVertexCount,
                signature: signature,
                cacheKey: cacheKey,
                protecting: cacheKey,
                encodingOn: commandBuffer
            )
        }
        var encodingWasSubmitted = false
        do {
            let requiredCapacity = try segmentCapacity(required: segmentCount)
            let buffer: any MTLBuffer
            let bufferAllocationBytes: Int
            if requiredCapacity > existing.segmentCapacity {
                let requiredBufferBytes = try checkedSegmentByteCount(requiredCapacity)
                let bufferEstimate = try segmentBufferAllocationByteCount(
                    payloadByteCount: requiredBufferBytes
                )
                try validateCombinedAllocationBytes(
                    existing.textureByteCount,
                    bufferEstimate
                )
                try resources.reserve(
                    additionalByteCount: bufferEstimate,
                    protecting: cacheKey
                )
                if consumeInjectedFailure(.allocation) {
                    throw MetalCanvasError.invalidResourceSize
                }
                buffer = try makeSegmentBuffer(capacity: requiredCapacity)
                buffer.contents().copyMemory(
                    from: existing.segmentBuffer.contents(),
                    byteCount: min(existing.segmentBuffer.length, buffer.length)
                )
                bufferAllocationBytes = try MetalCachedResource.conservativeAllocationByteCount(
                    payloadByteCount: requiredBufferBytes,
                    reportedByteCount: max(buffer.allocatedSize, bufferEstimate)
                )
            } else {
                buffer = existing.segmentBuffer
                bufferAllocationBytes = existing.segmentBufferByteCount
            }
            try validateCombinedAllocationBytes(
                existing.textureByteCount,
                bufferAllocationBytes
            )
            let resource = MetalCoverageResource(
                texture: existing.texture,
                textureByteCount: existing.textureByteCount,
                segmentBuffer: buffer,
                segmentBufferByteCount: bufferAllocationBytes,
                segmentCapacity: max(existing.segmentCapacity, requiredCapacity),
                pointCount: pointSequence.count,
                pointSequence: pointSequence,
                vertexSequence: vertexSequence,
                spanEndSequence: input.spanEndSequence,
                prefixVertexCount: prefixVertexCount,
                confirmedSampleCount: input.confirmedSampleCount,
                finalizedConfirmedSampleCount: input.finalizedConfirmedSampleCount,
                sourceInk: input.sourceInk,
                sourceGeneration: input.sourceGeneration,
                pressureEnabled: input.pressureEnabled,
                preparedResourceIdentity: input.preparedResourceIdentity,
                elementID: geometry.id,
                styleFingerprint: existing.styleFingerprint,
                viewportSignature: signature,
                premultipliedColor: existing.premultipliedColor
            )
            let canvasLineWidth = try CanvasInkCurve.lineWidthInCanvasUnits(
                lineWidth: geometry.style.lineWidth,
                viewportZoom: signature.zoom,
                widthMode: input.sourceInk.widthMode
            )
            try encode(
                vertices: vertexSequence,
                sourceSegmentRange: firstSegment..<segmentCount,
                destinationSegmentStart: firstSegment,
                lineWidth: canvasLineWidth,
                into: resource,
                clear: false,
                submitted: &encodingWasSubmitted,
                commandBuffer: commandBuffer
            )
            try resources.insert(
                try MetalCachedResource(coverage: resource),
                for: cacheKey
            )
            statistics.encodedSegmentCount += segmentCount - firstSegment
            return resource
        } catch {
            if encodingWasSubmitted {
                resources.removeResource(for: cacheKey)
                if activeKey == cacheKey {
                    clearActiveState()
                }
            }
            throw error
        }
    }

    func segmentCapacity(required: Int) throws -> Int {
        guard required >= 0 else { throw MetalCanvasError.invalidResourceSize }
        var capacity = 1
        while capacity < required {
            let doubled = capacity.multipliedReportingOverflow(by: 2)
            guard !doubled.overflow else { throw MetalCanvasError.invalidResourceSize }
            capacity = doubled.partialValue
        }
        _ = try checkedSegmentByteCount(capacity)
        return capacity
    }

    func validateCombinedAllocationBytes(_ textureBytes: Int, _ bufferBytes: Int) throws {
        guard textureBytes > 0, bufferBytes > 0 else {
            throw MetalCanvasError.invalidResourceSize
        }
        let totalByteCount = textureBytes.addingReportingOverflow(bufferBytes)
        guard !totalByteCount.overflow else {
            throw MetalCanvasError.invalidResourceSize
        }
        guard totalByteCount.partialValue <= resources.budgetByteCount else {
            throw MetalCanvasError.resourceBudgetExceeded
        }
    }

    func checkedSegmentByteCount(_ count: Int) throws -> Int {
        guard count >= 0 else { throw MetalCanvasError.invalidResourceSize }
        let bytes = count.multipliedReportingOverflow(
            by: MemoryLayout<MetalCoverageSegment>.stride
        )
        guard !bytes.overflow else { throw MetalCanvasError.invalidResourceSize }
        return bytes.partialValue
    }

    func allocationEstimateByteCount(
        pointCount: Int,
        signature: MetalCoverageViewportSignature
    ) throws -> Int {
        let capacity = try segmentCapacity(required: pointCount)
        let bufferPayloadBytes = try checkedSegmentByteCount(capacity)
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: signature.pixelWidth,
            height: signature.pixelHeight,
            mipmapped: false
        )
        textureDescriptor.storageMode = .shared
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        let texturePayloadBytes = try MetalCachedResource.checkedByteCount(
            width: signature.pixelWidth,
            height: signature.pixelHeight,
            bytesPerPixel: 1
        )
        let textureBytes = try MetalCachedResource.conservativeAllocationByteCount(
            payloadByteCount: texturePayloadBytes,
            reportedByteCount: device.heapTextureSizeAndAlign(
                descriptor: textureDescriptor
            ).size
        )
        let bufferBytes = try segmentBufferAllocationByteCount(
            payloadByteCount: bufferPayloadBytes
        )
        let total = textureBytes.addingReportingOverflow(bufferBytes)
        guard !total.overflow else { throw MetalCanvasError.invalidResourceSize }
        return total.partialValue
    }

    func segmentBufferAllocationByteCount(payloadByteCount: Int) throws -> Int {
        try MetalCachedResource.conservativeAllocationByteCount(
            payloadByteCount: payloadByteCount,
            reportedByteCount: device.heapBufferSizeAndAlign(
                length: payloadByteCount,
                options: .storageModeShared
            ).size
        )
    }

    func makeSegmentBuffer(capacity: Int) throws -> any MTLBuffer {
        let byteCount = try checkedSegmentByteCount(capacity)
        guard byteCount > 0,
              let buffer = device.makeBuffer(length: byteCount, options: .storageModeShared) else {
            throw MetalCanvasError.invalidResourceSize
        }
        return buffer
    }

    func encode(
        vertices: MetalCoverageSequence<CanvasInkVertex>,
        sourceSegmentRange: Range<Int>,
        destinationSegmentStart: Int,
        lineWidth: Double,
        into resource: MetalCoverageResource,
        clear: Bool,
        submitted: inout Bool,
        commandBuffer suppliedCommandBuffer: (any MTLCommandBuffer)? = nil
    ) throws {
        submitted = false
        if consumeInjectedFailure(.encoding) {
            throw MetalCanvasError.commandEncodingFailed
        }
        guard let commandBuffer = suppliedCommandBuffer ?? commandQueue.makeCommandBuffer() else {
            throw MetalCanvasError.commandEncodingFailed
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = resource.texture
        pass.colorAttachments[0].loadAction = clear ? .clear : .load
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw MetalCanvasError.commandEncodingFailed
        }
        encoder.label = "Canvas freehand coverage suffix"
        encoder.setRenderPipelineState(coveragePipeline)

        let signature = resource.viewportSignature
        let pixelLineWidthValue = lineWidth * signature.viewportScale
        guard pixelLineWidthValue.isFinite,
              pixelLineWidthValue >= 0,
              pixelLineWidthValue <= Double(Float.greatestFiniteMagnitude) else {
            encoder.endEncoding()
            throw MetalCanvasError.invalidNumericInput
        }
        let pixelLineWidth = Float(pixelLineWidthValue)
        let base = resource.segmentBuffer.contents().bindMemory(
            to: MetalCoverageSegment.self,
            capacity: resource.segmentCapacity
        )
        let sourceSegmentCount = coverageSegmentCount(vertexCount: vertices.count)
        guard sourceSegmentRange.lowerBound >= 0,
              sourceSegmentRange.upperBound <= sourceSegmentCount,
              destinationSegmentStart >= 0,
              destinationSegmentStart + sourceSegmentRange.count
                <= resource.segmentCapacity else {
            encoder.endEncoding()
            throw MetalCanvasError.invalidResourceSize
        }

        func encodeSegment(
            startVertex: CanvasInkVertex,
            endVertex: CanvasInkVertex,
            destinationIndex: Int
        ) throws {
            let start = try pixelPoint(startVertex.point, signature: signature)
            let end = try pixelPoint(endVertex.point, signature: signature)
            let startWidth = pixelLineWidth * Float(startVertex.widthFactor)
            let endWidth = pixelLineWidth * Float(endVertex.widthFactor)
            guard startWidth.isFinite, endWidth.isFinite,
                  startWidth >= 0, endWidth >= 0 else {
                encoder.endEncoding()
                throw MetalCanvasError.invalidNumericInput
            }
            base[destinationIndex] = MetalCoverageSegment(
                start: start,
                end: end,
                startWidth: startWidth,
                endWidth: endWidth
            )
        }

        var encodedSegmentCount = 0
        if !sourceSegmentRange.isEmpty {
            let vertexRange: Range<Int>
            if vertices.count == 1 {
                vertexRange = 0..<1
            } else {
                vertexRange = sourceSegmentRange.lowerBound..<(sourceSegmentRange.upperBound + 1)
            }
            var previous: CanvasInkVertex?
            for slice in vertices.slices(in: vertexRange) {
                for vertex in slice {
                    if let previous {
                        try encodeSegment(
                            startVertex: previous,
                            endVertex: vertex,
                            destinationIndex: destinationSegmentStart + encodedSegmentCount
                        )
                        encodedSegmentCount += 1
                    }
                    previous = vertex
                }
            }
            if vertices.count == 1, let previous {
                try encodeSegment(
                    startVertex: previous,
                    endVertex: previous,
                    destinationIndex: destinationSegmentStart
                )
                encodedSegmentCount = 1
            }
            guard encodedSegmentCount == sourceSegmentRange.count else {
                encoder.endEncoding()
                throw MetalCanvasError.commandEncodingFailed
            }
        }
        if encodedSegmentCount > 0 {
            let segmentOffset = destinationSegmentStart
                * MemoryLayout<MetalCoverageSegment>.stride
            var uniforms = MetalCanvasUniforms(
                viewportSize: SIMD2(Float(signature.pixelWidth), Float(signature.pixelHeight)),
                inverseViewportSize: SIMD2(
                    1 / Float(signature.pixelWidth),
                    1 / Float(signature.pixelHeight)
                )
            )
            encoder.setVertexBuffer(resource.segmentBuffer, offset: segmentOffset, index: 0)
            encoder.setVertexBytes(
                &uniforms,
                length: MemoryLayout<MetalCanvasUniforms>.stride,
                index: 1
            )
            encoder.setFragmentBuffer(resource.segmentBuffer, offset: segmentOffset, index: 0)
            encoder.drawPrimitives(
                type: .triangleStrip,
                vertexStart: 0,
                vertexCount: 4,
                instanceCount: encodedSegmentCount
            )
            statistics.coverageDrawCallCount += 1
        }
        encoder.endEncoding()
        if suppliedCommandBuffer != nil {
            submitted = true
            return
        }
        commandBuffer.commit()
        submitted = true
        commandBuffer.waitUntilCompleted()
        if consumeInjectedFailure(.completion) {
            throw MetalCanvasError.commandBufferFailed
        }
        guard commandBuffer.status == .completed else {
            throw MetalCanvasError.commandBufferFailed
        }
        statistics.coverageCommandBufferCount += 1
    }

    func pixelPoint(
        _ point: CanvasPoint,
        signature: MetalCoverageViewportSignature
    ) throws -> SIMD2<Float> {
        let x = (point.x * signature.zoom + signature.translation.x)
            * signature.displayScale
        let y = (point.y * signature.zoom + signature.translation.y)
            * signature.displayScale
        let result = SIMD2<Float>(Float(x), Float(y))
        guard x.isFinite,
              y.isFinite,
              result.x.isFinite,
              result.y.isFinite else {
            throw MetalCanvasError.invalidNumericInput
        }
        return result
    }

}

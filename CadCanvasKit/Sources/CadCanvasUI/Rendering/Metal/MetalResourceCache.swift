import CadCanvasCore
import Foundation
import Metal

struct MetalInFlightTexture {
    let texture: any MTLTexture
    let byteCount: Int
}

final class MetalInFlightResourceLease: @unchecked Sendable {
    fileprivate let id = UUID()
    fileprivate let coverage: [MetalCoverageResource]
    fileprivate let fallback: [MetalFallbackResource]
    fileprivate let tiles: [MetalCommittedTileResource]
    fileprivate let textures: [MetalInFlightTexture]

    fileprivate init(
        coverage: [MetalCoverageResource],
        fallback: [MetalFallbackResource],
        tiles: [MetalCommittedTileResource],
        textures: [MetalInFlightTexture]
    ) {
        self.coverage = coverage
        self.fallback = fallback
        self.tiles = tiles
        self.textures = textures
    }
}

enum MetalResourceKey: Hashable {
    case immutable(
        renderKey: CanvasRenderKey,
        resourceIdentity: CanvasPreparedResourceIdentity,
        viewportScale: Double
    )
    case ink(
        ink: ObjectIdentifier,
        styleFingerprint: UInt64,
        viewportScale: Double
    )
    case fallback(
        renderKey: CanvasRenderKey,
        resourceIdentity: CanvasPreparedResourceIdentity,
        styleFingerprint: UInt64,
        viewportZoom: Double,
        displayScale: Double,
        viewportSize: CanvasSize,
        viewportTranslation: CanvasPoint,
        coordinateOrigin: CanvasPoint
    )
    case committedTile(MetalCommittedTileKey)
}

struct MetalCachedResource {
    fileprivate enum Storage {
        case buffer(any MTLBuffer)
        case coverage(MetalCoverageResource)
        case fallback(MetalFallbackResource)
        case tile(MetalCommittedTileResource)
    }

    fileprivate let storage: Storage
    let byteCount: Int

    init(buffer: any MTLBuffer) throws {
        storage = .buffer(buffer)
        byteCount = try Self.conservativeAllocationByteCount(
            payloadByteCount: buffer.length,
            reportedByteCount: buffer.allocatedSize
        )
    }

    init(coverage: MetalCoverageResource) throws {
        storage = .coverage(coverage)
        byteCount = try Self.checkedSum(
            coverage.textureByteCount,
            coverage.segmentBufferByteCount
        )
    }

    init(fallback: MetalFallbackResource) throws {
        storage = .fallback(fallback)
        byteCount = try Self.checkedSum(
            fallback.vertexBufferByteCount,
            fallback.indexBufferByteCount
        )
    }

    init(tile: MetalCommittedTileResource) throws {
        storage = .tile(tile)
        byteCount = tile.byteCount
    }

    var coverage: MetalCoverageResource? {
        guard case .coverage(let coverage) = storage else { return nil }
        return coverage
    }

    var fallback: MetalFallbackResource? {
        guard case .fallback(let fallback) = storage else { return nil }
        return fallback
    }

    var tile: MetalCommittedTileResource? {
        guard case .tile(let tile) = storage else { return nil }
        return tile
    }

    static func checkedByteCount(
        width: Int,
        height: Int,
        bytesPerPixel: Int
    ) throws -> Int {
        guard width > 0, height > 0, bytesPerPixel > 0 else {
            throw MetalCanvasError.invalidResourceSize
        }
        let pixels = width.multipliedReportingOverflow(by: height)
        guard !pixels.overflow else { throw MetalCanvasError.invalidResourceSize }
        let bytes = pixels.partialValue.multipliedReportingOverflow(by: bytesPerPixel)
        guard !bytes.overflow else { throw MetalCanvasError.invalidResourceSize }
        return bytes.partialValue
    }

    static func conservativeAllocationByteCount(
        payloadByteCount: Int,
        reportedByteCount: Int = 0
    ) throws -> Int {
        guard payloadByteCount > 0, reportedByteCount >= 0 else {
            throw MetalCanvasError.invalidResourceSize
        }
        // Shared resources report allocatedSize as zero on some simulator
        // devices. A 16 KiB allocation-page rounding is conservative for the
        // supported Apple platforms, while a non-zero Metal estimate wins.
        let allocationAlignment = 16 * 1_024
        let padded = payloadByteCount.addingReportingOverflow(
            allocationAlignment - 1
        )
        guard !padded.overflow else { throw MetalCanvasError.invalidResourceSize }
        let pageCount = padded.partialValue / allocationAlignment
        let rounded = pageCount.multipliedReportingOverflow(by: allocationAlignment)
        guard !rounded.overflow else { throw MetalCanvasError.invalidResourceSize }
        return max(reportedByteCount, rounded.partialValue)
    }

    private static func checkedSum(_ lhs: Int, _ rhs: Int) throws -> Int {
        guard lhs >= 0, rhs >= 0 else { throw MetalCanvasError.invalidResourceSize }
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { throw MetalCanvasError.invalidResourceSize }
        return result.partialValue
    }
}

@MainActor
final class MetalResourceCache {
    private struct Entry {
        let resource: MetalCachedResource
        var lastAccess: UInt64
    }

    private let device: any MTLDevice
    private let budgetBytes: Int
    private var entries: [MetalResourceKey: Entry] = [:]
    private var inFlightLeases: [UUID: MetalInFlightResourceLease] = [:]
    private var accessSequence: UInt64 = 0
    private var transientByteCount = 0
    private(set) var residentByteCount = 0

    init(
        device: any MTLDevice,
        budgetBytes: Int = CanvasMetalLimits.resourceBudgetBytes
    ) {
        self.device = device
        self.budgetBytes = min(
            max(0, budgetBytes),
            CanvasMetalLimits.resourceBudgetBytes
        )
    }

    var resourceCount: Int { entries.count }
    var inFlightLeaseCount: Int { inFlightLeases.count }
    var budgetByteCount: Int { budgetBytes }
    var availableBudgetByteCount: Int { budgetBytes - transientByteCount }

    func resource(for key: MetalResourceKey) -> MetalCachedResource? {
        guard var entry = entries[key] else { return nil }
        entry.lastAccess = nextAccessSequence()
        entries[key] = entry
        return entry.resource
    }

    func peekResource(for key: MetalResourceKey) -> MetalCachedResource? {
        entries[key]?.resource
    }

    func insert(
        _ resource: MetalCachedResource,
        for key: MetalResourceKey,
        protecting protectedKey: MetalResourceKey? = nil
    ) throws {
        let availableBudget = availableBudgetByteCount
        guard resource.byteCount >= 0, resource.byteCount <= availableBudget else {
            throw MetalCanvasError.resourceBudgetExceeded
        }

        let originalEntries = entries
        let originalResidentByteCount = residentByteCount
        removeResource(for: key)
        do {
            try evictUntilAvailable(
                additionalResources: [resource],
                protecting: protectedKey.map { [$0] } ?? []
            )
            let addition = residentByteCount.addingReportingOverflow(resource.byteCount)
            guard !addition.overflow else { throw MetalCanvasError.invalidResourceSize }
            residentByteCount = addition.partialValue
            entries[key] = Entry(resource: resource, lastAccess: nextAccessSequence())
        } catch {
            entries = originalEntries
            residentByteCount = originalResidentByteCount
            throw error
        }
        _ = device
    }

    func insertAtomically(
        _ insertions: [(resource: MetalCachedResource, key: MetalResourceKey)],
        protecting protectedKeys: Set<MetalResourceKey> = []
    ) throws {
        guard Set(insertions.map(\.key)).count == insertions.count else {
            throw MetalCanvasError.invalidResourceSize
        }
        let originalEntries = entries
        let originalResidentByteCount = residentByteCount
        do {
            for insertion in insertions {
                removeResource(for: insertion.key)
            }
            try evictUntilAvailable(
                additionalResources: insertions.map(\.resource),
                protecting: protectedKeys
            )
            for insertion in insertions {
                let addition = residentByteCount.addingReportingOverflow(
                    insertion.resource.byteCount
                )
                guard !addition.overflow else {
                    throw MetalCanvasError.invalidResourceSize
                }
                residentByteCount = addition.partialValue
                entries[insertion.key] = Entry(
                    resource: insertion.resource,
                    lastAccess: nextAccessSequence()
                )
            }
        } catch {
            entries = originalEntries
            residentByteCount = originalResidentByteCount
            throw error
        }
        _ = device
    }

    func reserve(
        additionalByteCount: Int,
        protecting protectedKey: MetalResourceKey? = nil
    ) throws {
        let availableBudget = availableBudgetByteCount
        guard additionalByteCount >= 0, additionalByteCount <= availableBudget else {
            throw MetalCanvasError.resourceBudgetExceeded
        }
        try evictUntilAvailable(
            additionalByteCount: additionalByteCount,
            protecting: protectedKey.map { [$0] } ?? []
        )
    }

    /// Evicts cached entries until cached plus externally retained in-flight resources can
    /// accommodate an additional allocation. Retained objects are identity-deduplicated by
    /// `combinedResidentByteCount`, so evicting their cache entries cannot hide live bytes.
    func reserve(
        additionalByteCount: Int,
        retaining retainedCoverage: [MetalCoverageResource],
        fallback retainedFallback: [MetalFallbackResource],
        tiles retainedTiles: [MetalCommittedTileResource] = []
    ) throws {
        let availableBudget = availableBudgetByteCount
        guard additionalByteCount >= 0, additionalByteCount <= availableBudget else {
            throw MetalCanvasError.resourceBudgetExceeded
        }
        let originalEntries = entries
        let originalResidentByteCount = residentByteCount
        do {
            while try combinedResidentByteCount(
                retaining: retainedCoverage,
                fallback: retainedFallback,
                tiles: retainedTiles
            ) > availableBudget - additionalByteCount {
                guard let evictionKey = entries.min(by: {
                    $0.value.lastAccess < $1.value.lastAccess
                })?.key else {
                    throw MetalCanvasError.resourceBudgetExceeded
                }
                removeResource(for: evictionKey)
            }
        } catch {
            entries = originalEntries
            residentByteCount = originalResidentByteCount
            throw error
        }
    }

    func reserveTransient(byteCount: Int) throws {
        guard byteCount >= 0, byteCount <= budgetBytes else {
            throw MetalCanvasError.resourceBudgetExceeded
        }
        let previousTransientByteCount = transientByteCount
        transientByteCount = byteCount
        do {
            try reserve(additionalByteCount: 0)
        } catch {
            transientByteCount = previousTransientByteCount
            throw error
        }
    }

    /// Restores a smaller reservation after a synchronized transient scope completes.
    /// No eviction is required because lowering the reservation only increases capacity.
    func restoreTransientReservation(byteCount: Int) {
        precondition(byteCount >= 0 && byteCount <= transientByteCount)
        transientByteCount = byteCount
    }

    func releaseTransientReservation() {
        transientByteCount = 0
    }

    func combinedResidentByteCount(
        retaining retainedCoverage: [MetalCoverageResource],
        fallback retainedFallback: [MetalFallbackResource] = [],
        tiles retainedTiles: [MetalCommittedTileResource] = [],
        textures retainedTextures: [MetalInFlightTexture] = []
    ) throws -> Int {
        try combinedResidentByteCount(
            retaining: retainedCoverage,
            fallback: retainedFallback,
            tiles: retainedTiles,
            textures: retainedTextures,
            additionalResources: []
        )
    }

    func retainInFlight(
        coverage: [MetalCoverageResource],
        fallback: [MetalFallbackResource],
        tiles: [MetalCommittedTileResource] = [],
        textures: [MetalInFlightTexture],
        protecting protectedKeys: Set<MetalResourceKey> = []
    ) throws -> MetalInFlightResourceLease {
        let lease = MetalInFlightResourceLease(
            coverage: coverage,
            fallback: fallback,
            tiles: tiles,
            textures: textures
        )
        let originalEntries = entries
        let originalResidentByteCount = residentByteCount
        do {
            while try combinedResidentByteCount(
                retaining: coverage,
                fallback: fallback,
                tiles: tiles,
                textures: textures,
                additionalResources: []
            ) > availableBudgetByteCount {
                guard let evictionKey = entries
                    .filter({ !protectedKeys.contains($0.key) })
                    .min(by: { $0.value.lastAccess < $1.value.lastAccess })?
                    .key else {
                    throw MetalCanvasError.resourceBudgetExceeded
                }
                removeResource(for: evictionKey)
            }
        } catch {
            entries = originalEntries
            residentByteCount = originalResidentByteCount
            throw error
        }
        inFlightLeases[lease.id] = lease
        return lease
    }

    func releaseInFlight(_ lease: MetalInFlightResourceLease) {
        inFlightLeases.removeValue(forKey: lease.id)
    }

    func isInFlight(_ coverage: MetalCoverageResource) -> Bool {
        let textureIdentity = ObjectIdentifier(coverage.texture as AnyObject)
        let segmentBufferIdentity = ObjectIdentifier(coverage.segmentBuffer as AnyObject)
        return inFlightLeases.values.contains { lease in
            lease.coverage.contains { retained in
                ObjectIdentifier(retained.texture as AnyObject) == textureIdentity
                    || ObjectIdentifier(retained.segmentBuffer as AnyObject)
                        == segmentBufferIdentity
            }
        }
    }

    func isInFlight(_ tile: MetalCommittedTileResource) -> Bool {
        let textureIdentity = ObjectIdentifier(tile.texture as AnyObject)
        return inFlightLeases.values.contains { lease in
            lease.tiles.contains { retained in
                ObjectIdentifier(retained.texture as AnyObject) == textureIdentity
            }
        }
    }

    private func combinedResidentByteCount(
        retaining retainedCoverage: [MetalCoverageResource],
        fallback retainedFallback: [MetalFallbackResource],
        tiles retainedTiles: [MetalCommittedTileResource],
        textures retainedTextures: [MetalInFlightTexture],
        additionalResources: [MetalCachedResource]
    ) throws -> Int {
        var componentBytes: [ObjectIdentifier: Int] = [:]
        func retain(_ resource: AnyObject, byteCount: Int) {
            let identity = ObjectIdentifier(resource)
            componentBytes[identity] = max(componentBytes[identity] ?? 0, byteCount)
        }

        for entry in entries.values {
            retainCachedResource(entry.resource, into: &componentBytes)
        }
        for resource in additionalResources {
            retainCachedResource(resource, into: &componentBytes)
        }
        for lease in inFlightLeases.values {
            for coverage in lease.coverage {
                retain(
                    coverage.texture as AnyObject,
                    byteCount: coverage.textureByteCount
                )
                retain(
                    coverage.segmentBuffer as AnyObject,
                    byteCount: coverage.segmentBufferByteCount
                )
            }
            for fallback in lease.fallback {
                retain(
                    fallback.vertexBuffer as AnyObject,
                    byteCount: fallback.vertexBufferByteCount
                )
                retain(
                    fallback.indexBuffer as AnyObject,
                    byteCount: fallback.indexBufferByteCount
                )
            }
            for tile in lease.tiles {
                retain(tile.texture as AnyObject, byteCount: tile.byteCount)
            }
            for texture in lease.textures {
                retain(texture.texture as AnyObject, byteCount: texture.byteCount)
            }
        }
        for coverage in retainedCoverage {
            retain(
                coverage.texture as AnyObject,
                byteCount: coverage.textureByteCount
            )
            retain(
                coverage.segmentBuffer as AnyObject,
                byteCount: coverage.segmentBufferByteCount
            )
        }
        for fallback in retainedFallback {
            retain(
                fallback.vertexBuffer as AnyObject,
                byteCount: fallback.vertexBufferByteCount
            )
            retain(
                fallback.indexBuffer as AnyObject,
                byteCount: fallback.indexBufferByteCount
            )
        }
        for tile in retainedTiles {
            retain(tile.texture as AnyObject, byteCount: tile.byteCount)
        }
        for texture in retainedTextures {
            retain(texture.texture as AnyObject, byteCount: texture.byteCount)
        }

        var total = 0
        for byteCount in componentBytes.values {
            total = try Self.checkedAddition(total, byteCount)
        }
        return total
    }

    private func retainCachedResource(
        _ resource: MetalCachedResource,
        into componentBytes: inout [ObjectIdentifier: Int]
    ) {
        func retain(_ resource: AnyObject, byteCount: Int) {
            let identity = ObjectIdentifier(resource)
            componentBytes[identity] = max(componentBytes[identity] ?? 0, byteCount)
        }
        switch resource.storage {
        case .buffer(let buffer):
            retain(buffer as AnyObject, byteCount: resource.byteCount)
        case .coverage(let coverage):
            retain(
                coverage.texture as AnyObject,
                byteCount: coverage.textureByteCount
            )
            retain(
                coverage.segmentBuffer as AnyObject,
                byteCount: coverage.segmentBufferByteCount
            )
        case .fallback(let fallback):
            retain(
                fallback.vertexBuffer as AnyObject,
                byteCount: fallback.vertexBufferByteCount
            )
            retain(
                fallback.indexBuffer as AnyObject,
                byteCount: fallback.indexBufferByteCount
            )
        case .tile(let tile):
            retain(tile.texture as AnyObject, byteCount: tile.byteCount)
        }
    }

    private func evictUntilAvailable(
        additionalByteCount: Int = 0,
        additionalResources: [MetalCachedResource] = [],
        protecting protectedKeys: Set<MetalResourceKey>
    ) throws {
        let originalEntries = entries
        let originalResidentByteCount = residentByteCount
        let candidates = entries
            .filter { !protectedKeys.contains($0.key) }
            .sorted { $0.value.lastAccess < $1.value.lastAccess }
            .map(\.key)
        var candidateIndex = 0
        do {
            while true {
                let residentBytes = try combinedResidentByteCount(
                    retaining: [],
                    fallback: [],
                    tiles: [],
                    textures: [],
                    additionalResources: additionalResources
                )
                let projected = residentBytes.addingReportingOverflow(additionalByteCount)
                guard !projected.overflow else {
                    throw MetalCanvasError.invalidResourceSize
                }
                if projected.partialValue <= availableBudgetByteCount { return }
                guard candidateIndex < candidates.count else {
                    throw MetalCanvasError.resourceBudgetExceeded
                }
                removeResource(for: candidates[candidateIndex])
                candidateIndex += 1
            }
        } catch {
            entries = originalEntries
            residentByteCount = originalResidentByteCount
            throw error
        }
    }

    @discardableResult
    func removeResource(for key: MetalResourceKey) -> MetalCachedResource? {
        guard let removed = entries.removeValue(forKey: key) else { return nil }
        residentByteCount -= removed.resource.byteCount
        return removed.resource
    }

    func rekeyResource(from source: MetalResourceKey, to destination: MetalResourceKey) throws {
        guard source != destination, let sourceEntry = entries[source] else { return }
        let destinationBytes = entries[destination]?.resource.byteCount ?? 0
        let afterRemoval = residentByteCount - sourceEntry.resource.byteCount - destinationBytes
        let finalCount = afterRemoval.addingReportingOverflow(sourceEntry.resource.byteCount)
        guard !finalCount.overflow,
              finalCount.partialValue <= availableBudgetByteCount else {
            throw MetalCanvasError.resourceBudgetExceeded
        }
        entries.removeValue(forKey: source)
        entries.removeValue(forKey: destination)
        residentByteCount = finalCount.partialValue
        entries[destination] = Entry(
            resource: sourceEntry.resource,
            lastAccess: nextAccessSequence()
        )
    }

    func removeAll() {
        entries.removeAll(keepingCapacity: false)
        residentByteCount = 0
    }

    private func nextAccessSequence() -> UInt64 {
        accessSequence &+= 1
        return accessSequence
    }

    private static func checkedAddition(_ lhs: Int, _ rhs: Int) throws -> Int {
        guard lhs >= 0, rhs >= 0 else { throw MetalCanvasError.invalidResourceSize }
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { throw MetalCanvasError.invalidResourceSize }
        return result.partialValue
    }
}

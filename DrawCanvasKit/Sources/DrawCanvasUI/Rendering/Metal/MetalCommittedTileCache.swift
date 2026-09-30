import DrawCanvasCore
import Foundation
import Metal

struct MetalTileCoordinate: Hashable, Comparable {
    let x: Int
    let y: Int

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.y == rhs.y ? lhs.x < rhs.x : lhs.y < rhs.y
    }
}

struct MetalTileScaleKey: Hashable {
    let zoomBits: UInt64
    let displayScaleBits: UInt64

    init(zoom: Double, displayScale: Double) throws {
        guard zoom.isFinite, zoom.isNormal, zoom > 0,
              displayScale.isFinite, displayScale.isNormal, displayScale > 0 else {
            throw MetalCanvasError.invalidNumericInput
        }
        zoomBits = zoom.bitPattern
        displayScaleBits = displayScale.bitPattern
    }

    var zoom: Double { Double(bitPattern: zoomBits) }
    var displayScale: Double { Double(bitPattern: displayScaleBits) }
}

struct MetalCommittedTileKey: Hashable {
    let coordinate: MetalTileCoordinate
    let scale: MetalTileScaleKey
    let themeSignature: UInt64
}

struct MetalCommittedTileResource {
    let key: MetalCommittedTileKey
    let texture: any MTLTexture
    let byteCount: Int

    init(key: MetalCommittedTileKey, texture: any MTLTexture) throws {
        guard texture.width == MetalCommittedTileGeometry.allocationPixelLength,
              texture.height == MetalCommittedTileGeometry.allocationPixelLength,
              texture.pixelFormat == .bgra8Unorm,
              texture.usage.contains(.renderTarget),
              texture.usage.contains(.shaderRead) else {
            throw MetalCanvasError.invalidResourceSize
        }
        let payloadByteCount = try MetalCachedResource.checkedByteCount(
            width: texture.width,
            height: texture.height,
            bytesPerPixel: 4
        )
        self.key = key
        self.texture = texture
        byteCount = try MetalCachedResource.conservativeAllocationByteCount(
            payloadByteCount: payloadByteCount,
            reportedByteCount: texture.allocatedSize
        )
    }
}

enum MetalCommittedTileGeometry {
    static let interiorPixelLength = 256
    static let gutterPixelLength = 1
    static let allocationPixelLength = interiorPixelLength + gutterPixelLength * 2
    private static let maximumCoordinateCount = 1_000_000

    static func documentTileLength(for scale: MetalTileScaleKey) throws -> Double {
        let pixelsPerDocumentUnit = scale.zoom * scale.displayScale
        let length = Double(interiorPixelLength) / pixelsPerDocumentUnit
        guard pixelsPerDocumentUnit.isFinite,
              pixelsPerDocumentUnit > 0,
              length.isFinite,
              length.isNormal,
              length > 0 else {
            throw MetalCanvasError.invalidNumericInput
        }
        return length
    }

    static func coordinates(
        intersecting bounds: CanvasRect,
        scale: MetalTileScaleKey
    ) throws -> Set<MetalTileCoordinate> {
        guard bounds.isFinite,
              bounds.width >= 0,
              bounds.height >= 0,
              bounds.maxX.isFinite,
              bounds.maxY.isFinite else {
            throw MetalCanvasError.invalidNumericInput
        }
        let tileLength = try documentTileLength(for: scale)
        let maximumX = bounds.maxX > bounds.minX ? bounds.maxX.nextDown : bounds.maxX
        let maximumY = bounds.maxY > bounds.minY ? bounds.maxY.nextDown : bounds.maxY
        let minimumTileX = try coordinate(bounds.minX, tileLength: tileLength)
        let maximumTileX = try coordinate(maximumX, tileLength: tileLength)
        let minimumTileY = try coordinate(bounds.minY, tileLength: tileLength)
        let maximumTileY = try coordinate(maximumY, tileLength: tileLength)
        let width = maximumTileX.subtractingReportingOverflow(minimumTileX)
        let height = maximumTileY.subtractingReportingOverflow(minimumTileY)
        guard !width.overflow, !height.overflow, width.partialValue >= 0,
              height.partialValue >= 0 else {
            throw MetalCanvasError.invalidResourceSize
        }
        let columnCount = width.partialValue.addingReportingOverflow(1)
        let rowCount = height.partialValue.addingReportingOverflow(1)
        guard !columnCount.overflow, !rowCount.overflow else {
            throw MetalCanvasError.invalidResourceSize
        }
        let count = columnCount.partialValue.multipliedReportingOverflow(
            by: rowCount.partialValue
        )
        guard !count.overflow, count.partialValue <= maximumCoordinateCount else {
            throw MetalCanvasError.invalidResourceSize
        }
        var result = Set<MetalTileCoordinate>()
        result.reserveCapacity(count.partialValue)
        for y in minimumTileY ... maximumTileY {
            for x in minimumTileX ... maximumTileX {
                result.insert(.init(x: x, y: y))
            }
        }
        return result
    }

    static func dirtyCoordinates(
        oldBounds: CanvasRect?,
        newBounds: CanvasRect?,
        scale: MetalTileScaleKey
    ) throws -> Set<MetalTileCoordinate> {
        var result = Set<MetalTileCoordinate>()
        if let oldBounds {
            result.formUnion(try coordinates(intersecting: oldBounds, scale: scale))
        }
        if let newBounds {
            result.formUnion(try coordinates(intersecting: newBounds, scale: scale))
        }
        return result
    }

    static func documentRect(
        for coordinate: MetalTileCoordinate,
        scale: MetalTileScaleKey
    ) throws -> CanvasRect {
        let length = try documentTileLength(for: scale)
        let x = Double(coordinate.x) * length
        let y = Double(coordinate.y) * length
        guard x.isFinite, y.isFinite else {
            throw MetalCanvasError.invalidNumericInput
        }
        return CanvasRect(x: x, y: y, width: length, height: length)
    }

    private static func coordinate(_ value: Double, tileLength: Double) throws -> Int {
        let quotient = floor(value / tileLength)
        guard quotient.isFinite,
              quotient > Double(Int.min),
              quotient < Double(Int.max) else {
            throw MetalCanvasError.invalidNumericInput
        }
        return Int(quotient)
    }
}

enum MetalCommittedTileMutation {
    static func dirtyCoordinates(
        from oldItems: [CanvasCommittedItem],
        to newItems: [CanvasCommittedItem],
        oldReplacement: CanvasCommittedReplacement?,
        newReplacement: CanvasCommittedReplacement?,
        scale: MetalTileScaleKey
    ) throws -> Set<MetalTileCoordinate> {
        let oldByID = Dictionary(uniqueKeysWithValues: oldItems.map {
            ($0.geometry.id, $0)
        })
        let newByID = Dictionary(uniqueKeysWithValues: newItems.map {
            ($0.geometry.id, $0)
        })
        var bounds: [CanvasRect] = []
        for id in Set(oldByID.keys).union(newByID.keys) {
            let old = oldByID[id]
            let new = newByID[id]
            guard old?.geometry.renderKey != new?.geometry.renderKey
                    || old?.paintedBounds != new?.paintedBounds
                    || old?.documentIndex != new?.documentIndex else {
                continue
            }
            if let old { bounds.append(old.paintedBounds) }
            if let new { bounds.append(new.paintedBounds) }
        }
        if replacementIdentity(oldReplacement) != replacementIdentity(newReplacement) {
            appendReplacementBounds(oldReplacement, to: &bounds)
            appendReplacementBounds(newReplacement, to: &bounds)
        }
        var result = Set<MetalTileCoordinate>()
        for bound in bounds {
            result.formUnion(try MetalCommittedTileGeometry.coordinates(
                intersecting: bound,
                scale: scale
            ))
        }
        return result
    }

    private static func replacementIdentity(
        _ replacement: CanvasCommittedReplacement?
    ) -> ReplacementIdentity? {
        replacement.map {
            ReplacementIdentity(
                documentIndex: $0.documentIndex,
                originalRenderKey: $0.originalGeometry.renderKey,
                originalBounds: $0.originalPaintedBounds,
                replacementRenderKey: $0.replacementGeometry.renderKey,
                replacementBounds: $0.replacementPaintedBounds
            )
        }
    }

    private static func appendReplacementBounds(
        _ replacement: CanvasCommittedReplacement?,
        to bounds: inout [CanvasRect]
    ) {
        guard let replacement else { return }
        bounds.append(replacement.originalPaintedBounds)
        bounds.append(replacement.replacementPaintedBounds)
    }

    private struct ReplacementIdentity: Equatable {
        let documentIndex: Int
        let originalRenderKey: CanvasRenderKey
        let originalBounds: CanvasRect
        let replacementRenderKey: CanvasRenderKey
        let replacementBounds: CanvasRect
    }
}

struct MetalCommittedItemIndex {
    private var generation: CanvasCommittedGeneration?
    private var items: [CanvasCommittedItem] = []
    private var buckets: [MetalTileCoordinate: [Int]] = [:]
    private(set) var rebuildCount = 0

    mutating func update(
        generation: CanvasCommittedGeneration,
        items: [CanvasCommittedItem]
    ) throws {
        guard self.generation != generation else { return }
        let indexScale = try MetalTileScaleKey(zoom: 1, displayScale: 1)
        var candidateBuckets: [MetalTileCoordinate: [Int]] = [:]
        for (position, item) in items.enumerated() {
            for coordinate in try MetalCommittedTileGeometry.coordinates(
                intersecting: item.paintedBounds,
                scale: indexScale
            ) {
                candidateBuckets[coordinate, default: []].append(position)
            }
        }
        self.generation = generation
        self.items = items
        buckets = candidateBuckets
        rebuildCount += 1
    }

    func itemDocumentIndices(
        intersecting coordinate: MetalTileCoordinate,
        scale: MetalTileScaleKey
    ) throws -> [Int] {
        let tileRect = try MetalCommittedTileGeometry.documentRect(
            for: coordinate,
            scale: scale
        )
        let indexScale = try MetalTileScaleKey(zoom: 1, displayScale: 1)
        let indexCoordinates = try MetalCommittedTileGeometry.coordinates(
            intersecting: tileRect,
            scale: indexScale
        )
        var candidatePositions = Set<Int>()
        for indexCoordinate in indexCoordinates {
            candidatePositions.formUnion(buckets[indexCoordinate] ?? [])
        }
        return candidatePositions
            .filter { intersects(items[$0].paintedBounds, tileRect) }
            .map { items[$0].documentIndex }
            .sorted()
    }

    private func intersects(_ lhs: CanvasRect, _ rhs: CanvasRect) -> Bool {
        lhs.maxX >= rhs.minX && rhs.maxX >= lhs.minX
            && lhs.maxY >= rhs.minY && rhs.maxY >= lhs.minY
    }
}

struct MetalCommittedTilePlan {
    let scale: MetalTileScaleKey
    let isExactScale: Bool
    let requestedKeys: [MetalCommittedTileKey]
    let reusableKeys: [MetalCommittedTileKey]
    let missingKeys: [MetalCommittedTileKey]
}

struct MetalCommittedTilePlanner {
    struct Statistics: Equatable {
        var indexRebuildCount = 0
        var visibleRequestCount = 0
        var reusedTileCount = 0
        var dirtyTileCount = 0
    }

    private var index = MetalCommittedItemIndex()
    private(set) var statistics = Statistics()

    mutating func plan(
        committed: CanvasCommittedPresentation,
        viewport: CanvasViewport,
        displayScale: Double,
        themeSignature: UInt64,
        phase: CanvasViewportRenderPhase,
        availableKeys: Set<MetalCommittedTileKey>
    ) throws -> MetalCommittedTilePlan {
        try index.update(generation: committed.generation, items: committed.items)
        statistics.indexRebuildCount = index.rebuildCount
        let exactScale = try MetalTileScaleKey(
            zoom: viewport.zoom,
            displayScale: displayScale
        )
        let selectedScale: MetalTileScaleKey
        let requestedKeys: [MetalCommittedTileKey]
        if phase == .interactive,
           let nearest = try nearestCompleteBucket(
               to: exactScale,
               viewport: viewport,
               themeSignature: themeSignature,
               availableKeys: availableKeys
           ) {
            selectedScale = nearest.scale
            requestedKeys = nearest.keys
        } else {
            selectedScale = exactScale
            requestedKeys = try keys(
                for: selectedScale,
                viewport: viewport,
                themeSignature: themeSignature
            )
        }
        let reusableKeys = requestedKeys.filter(availableKeys.contains)
        let missingKeys = phase == .interactive
            ? []
            : requestedKeys.filter { !availableKeys.contains($0) }
        statistics.visibleRequestCount += requestedKeys.count
        statistics.reusedTileCount += reusableKeys.count
        return MetalCommittedTilePlan(
            scale: selectedScale,
            isExactScale: phase == .settled,
            requestedKeys: requestedKeys,
            reusableKeys: reusableKeys,
            missingKeys: missingKeys
        )
    }

    private func nearestCompleteBucket(
        to target: MetalTileScaleKey,
        viewport: CanvasViewport,
        themeSignature: UInt64,
        availableKeys: Set<MetalCommittedTileKey>
    ) throws -> (scale: MetalTileScaleKey, keys: [MetalCommittedTileKey])? {
        let scales = Set(availableKeys.lazy.compactMap { key -> MetalTileScaleKey? in
            guard key.themeSignature == themeSignature,
                  key.scale.displayScaleBits == target.displayScaleBits else {
                return nil
            }
            return key.scale
        })
        let complete = try scales.compactMap { scale -> (
            scale: MetalTileScaleKey,
            keys: [MetalCommittedTileKey]
        )? in
            let bucketKeys = try keys(
                for: scale,
                viewport: viewport,
                themeSignature: themeSignature
            )
            return bucketKeys.allSatisfy(availableKeys.contains)
                ? (scale, bucketKeys)
                : nil
        }
        return complete.min { lhs, rhs in
            let leftDistance = abs(log(lhs.scale.zoom / target.zoom))
            let rightDistance = abs(log(rhs.scale.zoom / target.zoom))
            if leftDistance == rightDistance {
                return lhs.scale.zoom < rhs.scale.zoom
            }
            return leftDistance < rightDistance
        }
    }

    private func keys(
        for scale: MetalTileScaleKey,
        viewport: CanvasViewport,
        themeSignature: UInt64
    ) throws -> [MetalCommittedTileKey] {
        try MetalCommittedTileGeometry.coordinates(
            intersecting: viewport.visibleCanvasRect,
            scale: scale
        ).sorted().map {
            MetalCommittedTileKey(
                coordinate: $0,
                scale: scale,
                themeSignature: themeSignature
            )
        }
    }
}

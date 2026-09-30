import CoreGraphics
import CadCanvasCore
import Foundation
import Metal

enum MetalFallbackFillStrategy: Equatable {
    case none
    case orientedStencilWindingThenBoundsCover
}

struct MetalFallbackContour {
    let points: [CanvasPoint]
    let isClosed: Bool
}

struct MetalFallbackMesh {
    let vertices: [MetalMeshVertex]
    let indices: [UInt32]
    let fillIndexRange: Range<Int>
    let strokeIndexRange: Range<Int>
    let fillBounds: CGRect?
    let strokeBounds: CGRect?
    let fillColor: SIMD4<Float>
    let strokeColor: SIMD4<Float>
    let contours: [MetalFallbackContour]
    let fillStrategy: MetalFallbackFillStrategy
    let roundCapCount: Int
    let roundJoinCount: Int
}

final class MetalFallbackResource {
    let vertexBuffer: any MTLBuffer
    let indexBuffer: any MTLBuffer
    let vertexCount: Int
    let indexCount: Int
    let vertexBufferByteCount: Int
    let indexBufferByteCount: Int
    let fillIndexRange: Range<Int>
    let strokeIndexRange: Range<Int>
    let fillBounds: CGRect?
    let strokeBounds: CGRect?
    let fillColor: SIMD4<Float>
    let strokeColor: SIMD4<Float>

    init(
        vertexBuffer: any MTLBuffer,
        indexBuffer: any MTLBuffer,
        vertexBufferByteCount: Int,
        indexBufferByteCount: Int,
        mesh: MetalFallbackMesh
    ) {
        self.vertexBuffer = vertexBuffer
        self.indexBuffer = indexBuffer
        vertexCount = mesh.vertices.count
        indexCount = mesh.indices.count
        self.vertexBufferByteCount = vertexBufferByteCount
        self.indexBufferByteCount = indexBufferByteCount
        fillIndexRange = mesh.fillIndexRange
        strokeIndexRange = mesh.strokeIndexRange
        fillBounds = mesh.fillBounds
        strokeBounds = mesh.strokeBounds
        fillColor = mesh.fillColor
        strokeColor = mesh.strokeColor
    }
}

@MainActor
enum MetalPathFallback {
    private static let maximumSubdivisionDepth = 32
    private static let maximumPointCount = 1_000_000
    static let cachedMaximumDeviceError = 0.0625

    static func compile(
        path: CanvasPreparedPath,
        style: CanvasStyle,
        viewport: CanvasViewport,
        maximumDeviceError: Double = 0.25
    ) throws -> MetalFallbackMesh {
        try compile(
            path: path,
            style: style,
            viewport: viewport,
            displayScale: 1,
            maximumDeviceError: maximumDeviceError
        )
    }

    static func resourceKey(
        for geometry: CanvasPreparedGeometry,
        viewport: CanvasViewport,
        displayScale: Double
    ) throws -> MetalResourceKey {
        let scale = viewport.zoom * displayScale
        guard scale.isFinite, scale > 0 else {
            throw MetalCanvasError.invalidNumericInput
        }
        let origin = viewport.visibleCanvasRect.origin
        guard origin.x.isFinite,
              origin.y.isFinite,
              viewport.viewportSize.width.isFinite,
              viewport.viewportSize.height.isFinite,
              viewport.viewportSize.width > 0,
              viewport.viewportSize.height > 0,
              viewport.translation.x.isFinite,
              viewport.translation.y.isFinite else {
            throw MetalCanvasError.invalidNumericInput
        }
        return .fallback(
            renderKey: geometry.renderKey,
            resourceIdentity: geometry.resourceIdentity,
            styleFingerprint: try styleFingerprint(geometry.style),
            viewportZoom: viewport.zoom,
            displayScale: displayScale,
            viewportSize: viewport.viewportSize,
            viewportTranslation: viewport.translation,
            coordinateOrigin: origin
        )
    }

    static func styleFingerprint(_ style: CanvasStyle) throws -> UInt64 {
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
        guard values.allSatisfy(\.isFinite), style.lineWidth >= 0 else {
            throw MetalCanvasError.invalidNumericInput
        }
        var result: UInt64 = 0xcbf2_9ce4_8422_2325
        for value in values {
            result ^= value.bitPattern
            result &*= 0x0000_0100_0000_01b3
        }
        return result
    }

    static func compile(
        path: CanvasPreparedPath,
        style: CanvasStyle,
        viewport: CanvasViewport,
        displayScale: Double,
        maximumDeviceError: Double = 0.25
    ) throws -> MetalFallbackMesh {
        let viewportScale = viewport.zoom * displayScale
        guard viewport.zoom.isFinite,
              viewport.zoom > 0,
              displayScale.isFinite,
              displayScale > 0,
              viewportScale.isFinite,
              maximumDeviceError.isFinite,
              maximumDeviceError > 0,
              style.lineWidth.isFinite,
              style.lineWidth >= 0 else {
            throw MetalCanvasError.invalidNumericInput
        }
        _ = try styleFingerprint(style)
        let maximumCanvasError = maximumDeviceError / viewportScale
        guard maximumCanvasError.isFinite, maximumCanvasError > 0 else {
            throw MetalCanvasError.invalidNumericInput
        }

        let coordinateOrigin = viewport.visibleCanvasRect.origin
        guard coordinateOrigin.x.isFinite, coordinateOrigin.y.isFinite else {
            throw MetalCanvasError.invalidNumericInput
        }
        let contours = try flatten(
            path,
            maximumError: maximumCanvasError,
            coordinateOrigin: coordinateOrigin
        )
        var builder = MeshBuilder(coordinateOrigin: .init(x: 0, y: 0))
        let fillColor = try premultiplied(
            style.fill ?? .init(red: 0, green: 0, blue: 0, alpha: 0)
        )
        let strokeColor = try premultiplied(style.stroke)
        var fillBounds: CGRect?
        let hasFill = fillColor.w > 0

        if hasFill {
            let fillContours = contours.filter { $0.points.count >= 2 }
            try validateMaximumWinding(fillContours)
            let closedPoints = fillContours
                .flatMap(\.points)
            if let first = closedPoints.first {
                var minimumX = first.x
                var minimumY = first.y
                var maximumX = first.x
                var maximumY = first.y
                for point in closedPoints.dropFirst() {
                    minimumX = min(minimumX, point.x)
                    minimumY = min(minimumY, point.y)
                    maximumX = max(maximumX, point.x)
                    maximumY = max(maximumY, point.y)
                }
                let bounds = CGRect(
                    x: minimumX,
                    y: minimumY,
                    width: maximumX - minimumX,
                    height: maximumY - minimumY
                )
                guard bounds.origin.x.isFinite,
                      bounds.origin.y.isFinite,
                      bounds.width.isFinite,
                      bounds.height.isFinite else {
                    throw MetalCanvasError.invalidNumericInput
                }
                fillBounds = bounds
                let anchor = CanvasPoint(
                    x: minimumX + (maximumX - minimumX) / 2,
                    y: minimumY + (maximumY - minimumY) / 2
                )
                for contour in fillContours {
                    for (start, end) in zip(contour.points, contour.points.dropFirst())
                    where start != end {
                        try builder.appendTriangle(anchor, start, end, color: fillColor)
                    }
                    if let first = contour.points.first,
                       let last = contour.points.last,
                       first != last {
                        try builder.appendTriangle(anchor, last, first, color: fillColor)
                    }
                }
            }
        }
        let fillEnd = builder.indices.count

        var roundCapCount = 0
        var roundJoinCount = 0
        if strokeColor.w > 0, style.lineWidth > 0 {
            let radius = style.lineWidth / viewport.zoom / 2
            let arcSegments = try roundSegmentCount(
                radius: radius,
                viewportScale: viewportScale,
                maximumDeviceError: maximumDeviceError
            )
            for contour in contours {
                let points = contour.points
                guard points.count >= 2 else { continue }
                for (start, end) in zip(points, points.dropFirst()) where start != end {
                    try builder.appendStrokeSegment(
                        start: start,
                        end: end,
                        radius: radius,
                        color: strokeColor
                    )
                }
                if contour.isClosed {
                    let uniquePoints = points.dropLast()
                    for point in uniquePoints {
                        try builder.appendDisk(
                            center: point,
                            radius: radius,
                            segmentCount: arcSegments,
                            color: strokeColor
                        )
                        roundJoinCount += 1
                    }
                } else {
                    if let first = points.first, let last = points.last {
                        try builder.appendDisk(
                            center: first,
                            radius: radius,
                            segmentCount: arcSegments,
                            color: strokeColor
                        )
                        try builder.appendDisk(
                            center: last,
                            radius: radius,
                            segmentCount: arcSegments,
                            color: strokeColor
                        )
                        roundCapCount += 2
                    }
                    for point in points.dropFirst().dropLast() {
                        try builder.appendDisk(
                            center: point,
                            radius: radius,
                            segmentCount: arcSegments,
                            color: strokeColor
                        )
                        roundJoinCount += 1
                    }
                }
            }
        }

        let strokeBounds = bounds(
            for: builder.vertices,
            indexedBy: builder.indices[fillEnd...]
        )
        return MetalFallbackMesh(
            vertices: builder.vertices,
            indices: builder.indices,
            fillIndexRange: 0..<fillEnd,
            strokeIndexRange: fillEnd..<builder.indices.count,
            fillBounds: fillBounds,
            strokeBounds: strokeBounds,
            fillColor: fillColor,
            strokeColor: strokeColor,
            contours: contours,
            fillStrategy: fillBounds == nil
                ? .none
                : .orientedStencilWindingThenBoundsCover,
            roundCapCount: roundCapCount,
            roundJoinCount: roundJoinCount
        )
    }

    static func bounds(
        for vertices: [MetalMeshVertex],
        indexedBy indices: ArraySlice<UInt32>
    ) -> CGRect? {
        guard let firstIndex = indices.first else { return nil }
        let first = vertices[Int(firstIndex)].position
        var minimumX = first.x
        var minimumY = first.y
        var maximumX = first.x
        var maximumY = first.y
        for index in indices.dropFirst() {
            let point = vertices[Int(index)].position
            minimumX = min(minimumX, point.x)
            minimumY = min(minimumY, point.y)
            maximumX = max(maximumX, point.x)
            maximumY = max(maximumY, point.y)
        }
        return CGRect(
            x: Double(minimumX),
            y: Double(minimumY),
            width: Double(maximumX - minimumX),
            height: Double(maximumY - minimumY)
        )
    }
}

@MainActor
final class MetalPathFallbackCache {
    private let device: any MTLDevice
    private let resources: MetalResourceCache

    init(device: any MTLDevice, resourceCache: MetalResourceCache) {
        self.device = device
        resources = resourceCache
    }

    func prepare(
        geometry: CanvasPreparedGeometry,
        viewport: CanvasViewport,
        displayScale: Double
    ) throws -> MetalFallbackResource {
        let key = try MetalPathFallback.resourceKey(
            for: geometry,
            viewport: viewport,
            displayScale: displayScale
        )
        if let cached = resources.resource(for: key)?.fallback {
            return cached
        }
        let mesh = try MetalPathFallback.compile(
            path: geometry.path,
            style: geometry.style,
            viewport: viewport,
            displayScale: displayScale,
            maximumDeviceError: MetalPathFallback.cachedMaximumDeviceError
        )
        let estimates = try allocationEstimates(for: mesh)
        let totalEstimate = try checkedAddition(estimates.vertex, estimates.index)
        try resources.reserve(additionalByteCount: totalEstimate)

        let gpuVertices = try clipSpaceVertices(mesh.vertices, viewport: viewport)
        guard let vertexBuffer = makeBuffer(gpuVertices),
              let indexBuffer = makeBuffer(mesh.indices) else {
            throw MetalCanvasError.invalidResourceSize
        }
        let vertexBytes = try MetalCachedResource.conservativeAllocationByteCount(
            payloadByteCount: max(1, mesh.vertices.count) * MemoryLayout<MetalMeshVertex>.stride,
            reportedByteCount: max(vertexBuffer.allocatedSize, estimates.vertex)
        )
        let indexBytes = try MetalCachedResource.conservativeAllocationByteCount(
            payloadByteCount: max(1, mesh.indices.count) * MemoryLayout<UInt32>.stride,
            reportedByteCount: max(indexBuffer.allocatedSize, estimates.index)
        )
        let totalBytes = try checkedAddition(vertexBytes, indexBytes)
        guard totalBytes <= resources.availableBudgetByteCount else {
            throw MetalCanvasError.resourceBudgetExceeded
        }
        let resource = MetalFallbackResource(
            vertexBuffer: vertexBuffer,
            indexBuffer: indexBuffer,
            vertexBufferByteCount: vertexBytes,
            indexBufferByteCount: indexBytes,
            mesh: mesh
        )
        try resources.insert(try MetalCachedResource(fallback: resource), for: key)
        return resource
    }

    func resource(
        for geometry: CanvasPreparedGeometry,
        viewport: CanvasViewport,
        displayScale: Double
    ) -> MetalFallbackResource? {
        guard let key = try? MetalPathFallback.resourceKey(
            for: geometry,
            viewport: viewport,
            displayScale: displayScale
        ) else { return nil }
        return resources.resource(for: key)?.fallback
    }

    func estimatedAdditionalByteCount(
        geometry: CanvasPreparedGeometry,
        viewport: CanvasViewport,
        displayScale: Double
    ) throws -> Int {
        if resource(for: geometry, viewport: viewport, displayScale: displayScale) != nil {
            return 0
        }
        let mesh = try MetalPathFallback.compile(
            path: geometry.path,
            style: geometry.style,
            viewport: viewport,
            displayScale: displayScale,
            maximumDeviceError: MetalPathFallback.cachedMaximumDeviceError
        )
        let estimates = try allocationEstimates(for: mesh)
        return try checkedAddition(estimates.vertex, estimates.index)
    }

    func preflightBounds(
        geometry: CanvasPreparedGeometry,
        viewport: CanvasViewport,
        displayScale: Double
    ) throws -> CGRect? {
        if let cached = resource(
            for: geometry,
            viewport: viewport,
            displayScale: displayScale
        ) {
            return union(cached.fillBounds, cached.strokeBounds)
        }
        let mesh = try MetalPathFallback.compile(
            path: geometry.path,
            style: geometry.style,
            viewport: viewport,
            displayScale: displayScale,
            maximumDeviceError: MetalPathFallback.cachedMaximumDeviceError
        )
        return union(mesh.fillBounds, mesh.strokeBounds)
    }

    private func union(_ first: CGRect?, _ second: CGRect?) -> CGRect? {
        return switch (first, second) {
        case (.none, .none): nil
        case (.some(let bounds), .none), (.none, .some(let bounds)): bounds
        case (.some(let first), .some(let second)): first.union(second)
        }
    }

    private func allocationEstimates(
        for mesh: MetalFallbackMesh
    ) throws -> (vertex: Int, index: Int) {
        let vertexPayload = try checkedProduct(
            max(1, mesh.vertices.count),
            MemoryLayout<MetalMeshVertex>.stride
        )
        let indexPayload = try checkedProduct(
            max(1, mesh.indices.count),
            MemoryLayout<UInt32>.stride
        )
        return (
            try MetalCachedResource.conservativeAllocationByteCount(
                payloadByteCount: vertexPayload,
                reportedByteCount: device.heapBufferSizeAndAlign(
                    length: vertexPayload,
                    options: .storageModeShared
                ).size
            ),
            try MetalCachedResource.conservativeAllocationByteCount(
                payloadByteCount: indexPayload,
                reportedByteCount: device.heapBufferSizeAndAlign(
                    length: indexPayload,
                    options: .storageModeShared
                ).size
            )
        )
    }

    private func clipSpaceVertices(
        _ vertices: [MetalMeshVertex],
        viewport: CanvasViewport
    ) throws -> [MetalMeshVertex] {
        guard viewport.viewportSize.width.isFinite,
              viewport.viewportSize.height.isFinite,
              viewport.viewportSize.width > 0,
              viewport.viewportSize.height > 0 else {
            throw MetalCanvasError.invalidNumericInput
        }
        let xScale = viewport.zoom / viewport.viewportSize.width * 2
        let yScale = viewport.zoom / viewport.viewportSize.height * 2
        return try vertices.map { vertex in
            let x = Double(vertex.position.x) * xScale - 1
            let y = 1 - Double(vertex.position.y) * yScale
            let position = SIMD2<Float>(Float(x), Float(y))
            guard x.isFinite, y.isFinite, position.x.isFinite, position.y.isFinite else {
                throw MetalCanvasError.invalidNumericInput
            }
            return MetalMeshVertex(position: position, color: vertex.color)
        }
    }

    private func makeBuffer<T>(_ values: [T]) -> (any MTLBuffer)? {
        if values.isEmpty {
            return device.makeBuffer(length: 1, options: .storageModeShared)
        }
        return values.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return nil }
            return device.makeBuffer(
                bytes: baseAddress,
                length: bytes.count,
                options: .storageModeShared
            )
        }
    }

    private func checkedProduct(_ lhs: Int, _ rhs: Int) throws -> Int {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        guard lhs > 0, rhs > 0, !result.overflow else {
            throw MetalCanvasError.invalidResourceSize
        }
        return result.partialValue
    }

    private func checkedAddition(_ lhs: Int, _ rhs: Int) throws -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        guard lhs > 0, rhs > 0, !result.overflow else {
            throw MetalCanvasError.invalidResourceSize
        }
        return result.partialValue
    }
}

private extension MetalPathFallback {
    struct WindingBoundsEvent {
        let y: Double
        let minimumX: Double
        let maximumX: Double
        let weightDelta: Int
    }

    struct WindingSegment {
        let index: Int
        let start: CanvasPoint
        let end: CanvasPoint
        let minimumX: Double
        let minimumY: Double
        let maximumX: Double
        let maximumY: Double
    }

    struct WindingRangeMaximum {
        private var maximum: [Int]
        private var lazy: [Int]

        init(intervalCount: Int) throws {
            let storageCount = intervalCount.multipliedReportingOverflow(by: 4)
            guard intervalCount > 0, !storageCount.overflow else {
                throw MetalCanvasError.invalidResourceSize
            }
            maximum = [Int](repeating: 0, count: storageCount.partialValue)
            lazy = [Int](repeating: 0, count: storageCount.partialValue)
        }

        var value: Int { maximum[1] }

        mutating func add(
            _ delta: Int,
            to range: Range<Int>,
            intervalCount: Int
        ) throws {
            guard range.lowerBound >= 0,
                  range.upperBound <= intervalCount,
                  !range.isEmpty else {
                throw MetalCanvasError.invalidResourceSize
            }
            try add(
                delta,
                to: range,
                node: 1,
                nodeRange: 0..<intervalCount
            )
        }

        private mutating func add(
            _ delta: Int,
            to range: Range<Int>,
            node: Int,
            nodeRange: Range<Int>
        ) throws {
            if range.lowerBound <= nodeRange.lowerBound,
               nodeRange.upperBound <= range.upperBound {
                maximum[node] = try checkedAdd(maximum[node], delta)
                lazy[node] = try checkedAdd(lazy[node], delta)
                return
            }
            let midpoint = nodeRange.lowerBound
                + (nodeRange.upperBound - nodeRange.lowerBound) / 2
            let left = node * 2
            let right = left + 1
            if range.lowerBound < midpoint {
                try add(
                    delta,
                    to: range,
                    node: left,
                    nodeRange: nodeRange.lowerBound..<midpoint
                )
            }
            if range.upperBound > midpoint {
                try add(
                    delta,
                    to: range,
                    node: right,
                    nodeRange: midpoint..<nodeRange.upperBound
                )
            }
            maximum[node] = try checkedAdd(max(maximum[left], maximum[right]), lazy[node])
        }

        private func checkedAdd(_ lhs: Int, _ rhs: Int) throws -> Int {
            let result = lhs.addingReportingOverflow(rhs)
            guard !result.overflow else { throw MetalCanvasError.invalidResourceSize }
            return result.partialValue
        }
    }

    struct PendingContour {
        var points: [CanvasPoint]
        var isClosed: Bool
    }

    struct MeshBuilder {
        let coordinateOrigin: CanvasPoint
        var vertices: [MetalMeshVertex] = []
        var indices: [UInt32] = []

        mutating func appendTriangle(
            _ first: CanvasPoint,
            _ second: CanvasPoint,
            _ third: CanvasPoint,
            color: SIMD4<Float>
        ) throws {
            let base = try vertexIndex(forAdditionalVertexCount: 3)
            vertices.append(try vertex(first, color: color))
            vertices.append(try vertex(second, color: color))
            vertices.append(try vertex(third, color: color))
            indices.append(base)
            indices.append(base + 1)
            indices.append(base + 2)
        }

        mutating func appendStrokeSegment(
            start: CanvasPoint,
            end: CanvasPoint,
            radius: Double,
            color: SIMD4<Float>
        ) throws {
            let dx = end.x - start.x
            let dy = end.y - start.y
            let length = hypot(dx, dy)
            guard length.isFinite else { throw MetalCanvasError.invalidNumericInput }
            guard length > 0 else { return }
            let normal = CanvasPoint(x: -dy / length * radius, y: dx / length * radius)
            let startLeft = CanvasPoint(x: start.x + normal.x, y: start.y + normal.y)
            let startRight = CanvasPoint(x: start.x - normal.x, y: start.y - normal.y)
            let endLeft = CanvasPoint(x: end.x + normal.x, y: end.y + normal.y)
            let endRight = CanvasPoint(x: end.x - normal.x, y: end.y - normal.y)
            try appendTriangle(startLeft, startRight, endLeft, color: color)
            try appendTriangle(startRight, endRight, endLeft, color: color)
        }

        mutating func appendDisk(
            center: CanvasPoint,
            radius: Double,
            segmentCount: Int,
            color: SIMD4<Float>
        ) throws {
            guard segmentCount >= 3 else { throw MetalCanvasError.invalidResourceSize }
            for segment in 0..<segmentCount {
                let firstAngle = Double(segment) / Double(segmentCount) * Double.pi * 2
                let secondAngle = Double(segment + 1) / Double(segmentCount) * Double.pi * 2
                try appendTriangle(
                    center,
                    .init(
                        x: center.x + cos(firstAngle) * radius,
                        y: center.y + sin(firstAngle) * radius
                    ),
                    .init(
                        x: center.x + cos(secondAngle) * radius,
                        y: center.y + sin(secondAngle) * radius
                    ),
                    color: color
                )
            }
        }

        func vertex(_ point: CanvasPoint, color: SIMD4<Float>) throws -> MetalMeshVertex {
            let x = point.x - coordinateOrigin.x
            let y = point.y - coordinateOrigin.y
            let position = SIMD2<Float>(Float(x), Float(y))
            guard x.isFinite,
                  y.isFinite,
                  position.x.isFinite,
                  position.y.isFinite else {
                throw MetalCanvasError.invalidNumericInput
            }
            return MetalMeshVertex(position: position, color: color)
        }

        func vertexIndex(forAdditionalVertexCount count: Int) throws -> UInt32 {
            let finalCount = vertices.count.addingReportingOverflow(count)
            guard count >= 0,
                  !finalCount.overflow,
                  finalCount.partialValue <= 1_000_000,
                  vertices.count <= Int(UInt32.max) else {
                throw MetalCanvasError.invalidResourceSize
            }
            return UInt32(vertices.count)
        }
    }

    static func flatten(
        _ path: CanvasPreparedPath,
        maximumError: Double,
        coordinateOrigin: CanvasPoint
    ) throws -> [MetalFallbackContour] {
        switch path {
        case .ink(let ink):
            let snapshot = ink.snapshot()
            let centreline = (snapshot.confirmed + snapshot.predicted).map(\.point)
            try validate(centreline)
            guard centreline.count <= maximumPointCount else {
                throw MetalCanvasError.invalidResourceSize
            }
            let points = try centreline.map {
                try rebased($0, coordinateOrigin: coordinateOrigin)
            }
            return points.isEmpty
                ? []
                : [MetalFallbackContour(points: points, isClosed: false)]

        case .immutable(let immutable):
            var contours: [MetalFallbackContour] = []
            var pending: PendingContour?
            func finish(_ pending: inout PendingContour?) {
                guard let contour = pending, !contour.points.isEmpty else {
                    pending = nil
                    return
                }
                contours.append(MetalFallbackContour(
                    points: contour.points,
                    isClosed: contour.isClosed
                ))
                pending = nil
            }

            for command in immutable.commands {
                switch command {
                case .move(let destination):
                    try validate(destination)
                    let destination = try rebased(
                        destination,
                        coordinateOrigin: coordinateOrigin
                    )
                    finish(&pending)
                    pending = PendingContour(points: [destination], isClosed: false)

                case .line(let destination):
                    try validate(destination)
                    let destination = try rebased(
                        destination,
                        coordinateOrigin: coordinateOrigin
                    )
                    if pending == nil {
                        pending = PendingContour(points: [destination], isClosed: false)
                    } else {
                        try append(destination, to: &pending)
                    }

                case .quad(let control, let end):
                    try validate(control)
                    try validate(end)
                    let control = try rebased(
                        control,
                        coordinateOrigin: coordinateOrigin
                    )
                    let end = try rebased(end, coordinateOrigin: coordinateOrigin)
                    guard let start = pending?.points.last else {
                        pending = PendingContour(points: [end], isClosed: false)
                        continue
                    }
                    try appendFlattenedQuadratic(
                        start: start,
                        control: control,
                        end: end,
                        maximumError: maximumError,
                        depth: 0,
                        to: &pending
                    )

                case .cubic(let control1, let control2, let end):
                    try validate(control1)
                    try validate(control2)
                    try validate(end)
                    let control1 = try rebased(
                        control1,
                        coordinateOrigin: coordinateOrigin
                    )
                    let control2 = try rebased(
                        control2,
                        coordinateOrigin: coordinateOrigin
                    )
                    let end = try rebased(end, coordinateOrigin: coordinateOrigin)
                    guard let start = pending?.points.last else {
                        pending = PendingContour(points: [end], isClosed: false)
                        continue
                    }
                    try appendFlattenedCubic(
                        start: start,
                        control1: control1,
                        control2: control2,
                        end: end,
                        maximumError: maximumError,
                        depth: 0,
                        to: &pending
                    )

                case .close:
                    guard var contour = pending,
                          let first = contour.points.first else { continue }
                    if contour.points.last != first {
                        guard contour.points.count < maximumPointCount else {
                            throw MetalCanvasError.invalidResourceSize
                        }
                        contour.points.append(first)
                    }
                    contour.isClosed = true
                    pending = contour
                    finish(&pending)
                }
            }
            finish(&pending)
            return contours
        }
    }

    static func appendFlattenedQuadratic(
        start: CanvasPoint,
        control: CanvasPoint,
        end: CanvasPoint,
        maximumError: Double,
        depth: Int,
        to contour: inout PendingContour?
    ) throws {
        let flatness = try pointSegmentDistance(control, start: start, end: end)
        guard flatness > maximumError else {
            try append(end, to: &contour)
            return
        }
        guard depth < maximumSubdivisionDepth else {
            throw MetalCanvasError.invalidResourceSize
        }
        let startControl = try midpoint(start, control)
        let controlEnd = try midpoint(control, end)
        let split = try midpoint(startControl, controlEnd)
        try appendFlattenedQuadratic(
            start: start,
            control: startControl,
            end: split,
            maximumError: maximumError,
            depth: depth + 1,
            to: &contour
        )
        try appendFlattenedQuadratic(
            start: split,
            control: controlEnd,
            end: end,
            maximumError: maximumError,
            depth: depth + 1,
            to: &contour
        )
    }

    static func appendFlattenedCubic(
        start: CanvasPoint,
        control1: CanvasPoint,
        control2: CanvasPoint,
        end: CanvasPoint,
        maximumError: Double,
        depth: Int,
        to contour: inout PendingContour?
    ) throws {
        let flatness = try max(
            pointSegmentDistance(control1, start: start, end: end),
            pointSegmentDistance(control2, start: start, end: end)
        )
        guard flatness > maximumError else {
            try append(end, to: &contour)
            return
        }
        guard depth < maximumSubdivisionDepth else {
            throw MetalCanvasError.invalidResourceSize
        }
        let startControl1 = try midpoint(start, control1)
        let control1Control2 = try midpoint(control1, control2)
        let control2End = try midpoint(control2, end)
        let leftControl2 = try midpoint(startControl1, control1Control2)
        let rightControl1 = try midpoint(control1Control2, control2End)
        let split = try midpoint(leftControl2, rightControl1)
        try appendFlattenedCubic(
            start: start,
            control1: startControl1,
            control2: leftControl2,
            end: split,
            maximumError: maximumError,
            depth: depth + 1,
            to: &contour
        )
        try appendFlattenedCubic(
            start: split,
            control1: rightControl1,
            control2: control2End,
            end: end,
            maximumError: maximumError,
            depth: depth + 1,
            to: &contour
        )
    }

    static func append(_ point: CanvasPoint, to contour: inout PendingContour?) throws {
        guard var value = contour,
              value.points.count < maximumPointCount else {
            throw MetalCanvasError.invalidResourceSize
        }
        if value.points.last != point {
            value.points.append(point)
        }
        contour = value
    }

    static func validateMaximumWinding(
        _ contours: [MetalFallbackContour]
    ) throws {
        var events: [WindingBoundsEvent] = []
        var xCoordinates: [Double] = []
        for contour in contours {
            var points = contour.points
            if let first = points.first, points.last != first {
                points.append(first)
            }
            guard let first = points.first else { continue }
            var minimumX = first.x
            var minimumY = first.y
            var maximumX = first.x
            var maximumY = first.y
            var upwardEdgeCount = 0
            var downwardEdgeCount = 0
            for point in points.dropFirst() {
                guard point.x.isFinite, point.y.isFinite else {
                    throw MetalCanvasError.invalidNumericInput
                }
                minimumX = min(minimumX, point.x)
                minimumY = min(minimumY, point.y)
                maximumX = max(maximumX, point.x)
                maximumY = max(maximumY, point.y)
            }
            for (start, end) in zip(points, points.dropFirst()) where start.y != end.y {
                if end.y > start.y {
                    upwardEdgeCount = try checkedWindingAddition(upwardEdgeCount, 1)
                } else {
                    downwardEdgeCount = try checkedWindingAddition(downwardEdgeCount, 1)
                }
            }
            let conservativeWeight = min(upwardEdgeCount, downwardEdgeCount)
            let weight = conservativeWeight >= 256 && isProvablySimplePolygon(points)
                ? 1
                : conservativeWeight
            guard weight > 0,
                  minimumX < maximumX,
                  minimumY < maximumY else { continue }
            xCoordinates.append(minimumX)
            xCoordinates.append(maximumX)
            events.append(.init(
                y: minimumY,
                minimumX: minimumX,
                maximumX: maximumX,
                weightDelta: weight
            ))
            events.append(.init(
                y: maximumY,
                minimumX: minimumX,
                maximumX: maximumX,
                weightDelta: -weight
            ))
        }
        guard events.count >= 2 else { return }

        // A proven simple contour contributes at most one by the Jordan curve theorem.
        // Every uncertain, touching, overlapping, or self-intersecting contour retains the
        // conservative smaller upward/downward edge count. A contour contributes zero
        // outside its 2D bounds, so the maximum weighted overlap remains a sound upper bound.
        // The bounds sweep is O(E + C log C); proving a high-weight contour simple uses
        // sweep-and-prune candidate rejection with O(E²) worst-case time and O(E) memory.
        xCoordinates.sort()
        var uniqueXCoordinates: [Double] = []
        uniqueXCoordinates.reserveCapacity(xCoordinates.count)
        for value in xCoordinates where uniqueXCoordinates.last != value {
            uniqueXCoordinates.append(value)
        }
        xCoordinates = uniqueXCoordinates
        guard xCoordinates.count >= 2 else { return }
        let coordinateIndices = Dictionary(
            uniqueKeysWithValues: xCoordinates.enumerated().map { ($0.element, $0.offset) }
        )
        let intervalCount = xCoordinates.count - 1
        var rangeMaximum = try WindingRangeMaximum(intervalCount: intervalCount)
        events.sort { lhs, rhs in lhs.y < rhs.y }
        var index = 0
        while index < events.count {
            let y = events[index].y
            while index < events.count, events[index].y == y {
                let event = events[index]
                guard let lower = coordinateIndices[event.minimumX],
                      let upper = coordinateIndices[event.maximumX],
                      lower < upper else {
                    throw MetalCanvasError.invalidResourceSize
                }
                try rangeMaximum.add(
                    event.weightDelta,
                    to: lower..<upper,
                    intervalCount: intervalCount
                )
                index += 1
            }
            if rangeMaximum.value >= 256 {
                throw MetalCanvasError.invalidResourceSize
            }
        }
    }

    static func checkedWindingAddition(_ lhs: Int, _ rhs: Int) throws -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        guard lhs >= 0, rhs >= 0, !result.overflow else {
            throw MetalCanvasError.invalidResourceSize
        }
        return result.partialValue
    }

    /// Returns true only when every polygon edge is finite and nondegenerate, adjacent
    /// edges have a reliably non-collinear turn, and every nonadjacent pair is proven
    /// disjoint. Filtered orientation uncertainty is conservative and returns false.
    static func isProvablySimplePolygon(_ closedPoints: [CanvasPoint]) -> Bool {
        var points = closedPoints
        if points.count > 1, points.first == points.last {
            points.removeLast()
        }
        guard points.count >= 3 else { return false }

        for index in points.indices {
            let previous = points[(index + points.count - 1) % points.count]
            let current = points[index]
            let next = points[(index + 1) % points.count]
            guard current != next,
                  reliableOrientation(previous, current, next) != nil else {
                return false
            }
        }

        var segments: [WindingSegment] = []
        segments.reserveCapacity(points.count)
        for index in points.indices {
            let start = points[index]
            let end = points[(index + 1) % points.count]
            guard start.x.isFinite,
                  start.y.isFinite,
                  end.x.isFinite,
                  end.y.isFinite else { return false }
            segments.append(.init(
                index: index,
                start: start,
                end: end,
                minimumX: min(start.x, end.x),
                minimumY: min(start.y, end.y),
                maximumX: max(start.x, end.x),
                maximumY: max(start.y, end.y)
            ))
        }
        segments.sort {
            if $0.minimumX != $1.minimumX { return $0.minimumX < $1.minimumX }
            return $0.minimumY < $1.minimumY
        }

        var active: [WindingSegment] = []
        for segment in segments {
            active.removeAll { $0.maximumX < segment.minimumX }
            for candidate in active
            where !segmentsAreAdjacent(
                segment.index,
                candidate.index,
                segmentCount: points.count
            ) {
                guard segmentsAreProvablyDisjoint(segment, candidate) else {
                    return false
                }
            }
            active.append(segment)
        }
        return true
    }

    static func segmentsAreAdjacent(
        _ first: Int,
        _ second: Int,
        segmentCount: Int
    ) -> Bool {
        (first + 1) % segmentCount == second
            || (second + 1) % segmentCount == first
    }

    static func segmentsAreProvablyDisjoint(
        _ first: WindingSegment,
        _ second: WindingSegment
    ) -> Bool {
        if first.maximumX < second.minimumX
            || second.maximumX < first.minimumX
            || first.maximumY < second.minimumY
            || second.maximumY < first.minimumY {
            return true
        }
        if let startSide = reliableOrientation(first.start, first.end, second.start),
           let endSide = reliableOrientation(first.start, first.end, second.end),
           startSide == endSide {
            return true
        }
        if let startSide = reliableOrientation(second.start, second.end, first.start),
           let endSide = reliableOrientation(second.start, second.end, first.end),
           startSide == endSide {
            return true
        }
        return false
    }

    /// A conservative floating-point orientation filter. The scale-squared error bound
    /// covers coordinate subtraction, products, and determinant subtraction. Near-zero
    /// or unrepresentable results are deliberately uncertain rather than guessed.
    static func reliableOrientation(
        _ first: CanvasPoint,
        _ second: CanvasPoint,
        _ third: CanvasPoint
    ) -> Int? {
        let firstX = second.x - first.x
        let firstY = second.y - first.y
        let secondX = third.x - first.x
        let secondY = third.y - first.y
        guard firstX.isFinite,
              firstY.isFinite,
              secondX.isFinite,
              secondY.isFinite else { return nil }
        let firstProduct = firstX * secondY
        let secondProduct = firstY * secondX
        let determinant = firstProduct - secondProduct
        var coordinateScale = 1.0
        coordinateScale = max(coordinateScale, abs(first.x))
        coordinateScale = max(coordinateScale, abs(first.y))
        coordinateScale = max(coordinateScale, abs(second.x))
        coordinateScale = max(coordinateScale, abs(second.y))
        coordinateScale = max(coordinateScale, abs(third.x))
        coordinateScale = max(coordinateScale, abs(third.y))
        let squaredScale = coordinateScale * coordinateScale
        let errorBound = squaredScale * Double.ulpOfOne * 64
        guard firstProduct.isFinite,
              secondProduct.isFinite,
              determinant.isFinite,
              squaredScale.isFinite,
              errorBound.isFinite else { return nil }
        if determinant > errorBound { return 1 }
        if determinant < -errorBound { return -1 }
        return nil
    }

    static func validate(_ points: [CanvasPoint]) throws {
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw MetalCanvasError.invalidNumericInput
        }
    }

    static func validate(_ point: CanvasPoint) throws {
        guard point.x.isFinite, point.y.isFinite else {
            throw MetalCanvasError.invalidNumericInput
        }
    }

    static func midpoint(_ first: CanvasPoint, _ second: CanvasPoint) throws -> CanvasPoint {
        let point = CanvasPoint(
            x: first.x / 2 + second.x / 2,
            y: first.y / 2 + second.y / 2
        )
        try validate(point)
        return point
    }

    static func pointSegmentDistance(
        _ point: CanvasPoint,
        start: CanvasPoint,
        end: CanvasPoint
    ) throws -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let pointDX = point.x - start.x
        let pointDY = point.y - start.y
        guard dx.isFinite, dy.isFinite, pointDX.isFinite, pointDY.isFinite else {
            throw MetalCanvasError.invalidNumericInput
        }
        let length = hypot(dx, dy)
        guard length.isFinite else { throw MetalCanvasError.invalidNumericInput }
        if length == 0 {
            let distance = hypot(pointDX, pointDY)
            guard distance.isFinite else { throw MetalCanvasError.invalidNumericInput }
            return distance
        }
        let unitX = dx / length
        let unitY = dy / length
        let projection = pointDX * unitX + pointDY * unitY
        guard projection.isFinite else { throw MetalCanvasError.invalidNumericInput }
        let clampedProjection = min(length, max(0, projection))
        let offsetX = pointDX - clampedProjection * unitX
        let offsetY = pointDY - clampedProjection * unitY
        let distance = hypot(offsetX, offsetY)
        guard distance.isFinite else { throw MetalCanvasError.invalidNumericInput }
        return distance
    }

    static func rebased(
        _ point: CanvasPoint,
        coordinateOrigin: CanvasPoint
    ) throws -> CanvasPoint {
        let result = CanvasPoint(
            x: point.x - coordinateOrigin.x,
            y: point.y - coordinateOrigin.y
        )
        try validate(result)
        return result
    }

    static func roundSegmentCount(
        radius: Double,
        viewportScale: Double,
        maximumDeviceError: Double
    ) throws -> Int {
        let deviceRadius = radius * viewportScale
        guard deviceRadius.isFinite, deviceRadius > 0,
              deviceRadius <= Double(Float.greatestFiniteMagnitude) else {
            throw MetalCanvasError.invalidNumericInput
        }
        if deviceRadius <= maximumDeviceError { return 8 }
        let cosine = max(-1, min(1, 1 - maximumDeviceError / deviceRadius))
        let maximumHalfAngle = acos(cosine)
        guard maximumHalfAngle.isFinite, maximumHalfAngle > 0 else {
            throw MetalCanvasError.invalidResourceSize
        }
        let count = ceil(Double.pi / maximumHalfAngle)
        guard count.isFinite, count <= Double(maximumPointCount / 3) else {
            throw MetalCanvasError.invalidResourceSize
        }
        let minimumCount = max(8, Int(count))
        let rounded = minimumCount.addingReportingOverflow(3)
        guard !rounded.overflow else { throw MetalCanvasError.invalidResourceSize }
        return rounded.partialValue / 4 * 4
    }

    static func premultiplied(_ color: CanvasColor) throws -> SIMD4<Float> {
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
}

private extension CanvasRect {
    var origin: CanvasPoint { .init(x: x, y: y) }
}

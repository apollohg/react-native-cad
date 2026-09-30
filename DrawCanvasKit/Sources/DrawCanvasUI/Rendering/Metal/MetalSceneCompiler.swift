import DrawCanvasCore
import Foundation
import simd

enum MetalDrawItem {
    case analyticLine(MetalLineInstance)
    case analyticBox(MetalBoxInstance)
    case analyticArc(MetalArcInstance)
    case freehand(MetalFreehandDescriptor)
    case fallback(MetalFallbackDescriptor)
    case committedTile(MetalCommittedTileComposite)
}

struct MetalFreehandDescriptor {
    let geometry: CanvasPreparedGeometry
}

struct MetalFallbackDescriptor {
    let geometry: CanvasPreparedGeometry
}

struct MetalCommittedTileComposite {
    let tile: MetalCommittedTileResource
}

struct MetalCommittedDrawItem {
    let documentIndex: Int
    let geometry: CanvasPreparedGeometry
    let paintedBounds: CanvasRect
    let item: MetalDrawItem
}

struct MetalCompiledReplacement {
    let documentIndex: Int
    let original: MetalCommittedDrawItem
    let replacement: MetalCommittedDrawItem
}

struct MetalCommittedCompilationKey: Equatable {
    let generation: CanvasCommittedGeneration
    let zoomBits: UInt64
    let displayScaleBits: UInt64
    let originXBits: UInt64
    let originYBits: UInt64
    let replacementKey: CanvasRenderKey?
}

final class MetalCompiledCommittedLayer {
    let key: MetalCommittedCompilationKey
    let items: [MetalCommittedDrawItem]
    let directItems: [MetalDrawItem]
    let plannerPresentation: CanvasCommittedPresentation
    let replacement: MetalCompiledReplacement?

    init(
        key: MetalCommittedCompilationKey,
        items: [MetalCommittedDrawItem],
        directItems: [MetalDrawItem],
        plannerPresentation: CanvasCommittedPresentation,
        replacement: MetalCompiledReplacement?
    ) {
        self.key = key
        self.items = items
        self.directItems = directItems
        self.plannerPresentation = plannerPresentation
        self.replacement = replacement
    }
}

struct MetalCompiledScene {
    let background: SIMD4<Float>
    let viewport: CanvasViewport
    let previewGeneration: RecognitionGeneration?
    let renderCoordinateOrigin: CanvasPoint
    let gridItems: [MetalDrawItem]
    let liveItems: [MetalDrawItem]
    let overlayItems: [MetalDrawItem]
    let committedLayer: MetalCompiledCommittedLayer?
    let viewportRenderPhase: CanvasViewportRenderPhase
    private let explicitItems: [MetalDrawItem]?
    private let explicitRenderItems: [MetalDrawItem]?
    private let explicitCommittedItems: [MetalCommittedDrawItem]
    private let explicitCommittedGeneration: CanvasCommittedGeneration?
    private let explicitReplacement: MetalCompiledReplacement?

    var renderItems: [MetalDrawItem] {
        if let explicitRenderItems { return explicitRenderItems }
        return gridItems
            + (committedLayer?.directItems ?? [])
            + liveItems
            + overlayItems
    }

    var items: [MetalDrawItem] { explicitItems ?? renderItems }
    var committedItems: [MetalCommittedDrawItem] {
        committedLayer?.items ?? explicitCommittedItems
    }
    var committedGeneration: CanvasCommittedGeneration? {
        committedLayer?.plannerPresentation.generation ?? explicitCommittedGeneration
    }
    var replacement: MetalCompiledReplacement? {
        committedLayer?.replacement ?? explicitReplacement
    }

    init(
        background: SIMD4<Float>,
        items: [MetalDrawItem],
        viewport: CanvasViewport,
        previewGeneration: RecognitionGeneration?
    ) {
        self.background = background
        self.viewport = viewport
        self.previewGeneration = previewGeneration
        renderCoordinateOrigin = .init(x: 0, y: 0)
        gridItems = []
        liveItems = []
        overlayItems = []
        committedLayer = nil
        viewportRenderPhase = .settled
        explicitItems = items
        explicitRenderItems = items
        explicitCommittedItems = []
        explicitCommittedGeneration = nil
        explicitReplacement = nil
    }

    init(
        background: SIMD4<Float>,
        items: [MetalDrawItem]?,
        viewport: CanvasViewport,
        previewGeneration: RecognitionGeneration?,
        renderItems: [MetalDrawItem]?,
        renderCoordinateOrigin: CanvasPoint,
        gridItems: [MetalDrawItem] = [],
        committedItems: [MetalCommittedDrawItem] = [],
        liveItems: [MetalDrawItem] = [],
        overlayItems: [MetalDrawItem] = [],
        committedLayer: MetalCompiledCommittedLayer? = nil,
        committedGeneration: CanvasCommittedGeneration? = nil,
        replacement: MetalCompiledReplacement? = nil,
        viewportRenderPhase: CanvasViewportRenderPhase = .settled
    ) {
        self.background = background
        self.viewport = viewport
        self.previewGeneration = previewGeneration
        self.renderCoordinateOrigin = renderCoordinateOrigin
        self.gridItems = gridItems
        self.liveItems = liveItems
        self.overlayItems = overlayItems
        self.committedLayer = committedLayer
        self.viewportRenderPhase = viewportRenderPhase
        explicitItems = items
        explicitRenderItems = renderItems
        explicitCommittedItems = committedItems
        explicitCommittedGeneration = committedGeneration
        explicitReplacement = replacement
    }
}

extension MetalArcInstance {
    /// Signed circular sweep in radians. This uses Task 1's reserved 32-bit geometry slot,
    /// retaining the validated 64-byte Swift/Metal ABI while carrying the direction needed
    /// to distinguish the two arcs sharing the same endpoints and center.
    var sweepAngle: Float {
        get { geometryPadding }
        set { geometryPadding = newValue }
    }
}

@MainActor
final class MetalSceneCompiler {
    struct Statistics: Equatable {
        var compiledGeometryCount = 0
        var validatedFreehandPointCount = 0
        var preparedFreehandCandidateCount = 0
        var committedItemVisitCount = 0
    }

    private enum FreehandValidationKey: Hashable {
        case preview(ObjectIdentifier)
        case committed(CanvasPreparedResourceIdentity)
    }

    private struct FreehandValidationRecord {
        let sourceInk: CanvasPreparedInk?
        let inkGeneration: RecognitionGeneration
        let confirmedSampleCount: Int
    }

    private struct FreehandCompileCandidate {
        let sourceInk: CanvasPreparedInk
        let inkGeneration: RecognitionGeneration
        let snapshot: CanvasPreparedInkSnapshot
    }

    private var freehandValidationRecords: [
        FreehandValidationKey: FreehandValidationRecord
    ] = [:]
    private var committedCompilationCache: MetalCompiledCommittedLayer?
    private var retainedCommittedGeneration: CanvasCommittedGeneration?
    private var retainedPreviewInkIdentities = Set<ObjectIdentifier>()
    private(set) var statistics = Statistics()

    func resetDerivedRenderCaches() {
        freehandValidationRecords.removeAll(keepingCapacity: false)
        committedCompilationCache = nil
        retainedCommittedGeneration = nil
        retainedPreviewInkIdentities.removeAll(keepingCapacity: false)
    }

    func compile(
        _ scene: CanvasPreparedScene,
        displayScale: Double = 1
    ) throws -> MetalCompiledScene {
        try compile(scene, presentation: nil, displayScale: displayScale)
    }

    func compile(
        _ presentation: CanvasPreparedPresentation,
        displayScale: Double = 1
    ) throws -> MetalCompiledScene {
        try compile(
            presentation.scene,
            presentation: presentation,
            displayScale: displayScale
        )
    }

    func compileCommittedItem(
        _ committedItem: MetalCommittedDrawItem,
        coordinateOrigin: CanvasPoint,
        zoom: Double,
        displayScale: Double
    ) throws -> MetalDrawItem {
        let previousValidationRecords = freehandValidationRecords
        let previousStatistics = statistics
        do {
            var freehandCandidates: [ObjectIdentifier: FreehandCompileCandidate] = [:]
            return try compile(
                committedItem.geometry,
                zoom: finiteFloat(zoom),
                displayScale: displayScale,
                coordinateOrigin: coordinateOrigin,
                freehandCandidates: &freehandCandidates
            ).item
        } catch {
            freehandValidationRecords = previousValidationRecords
            statistics = previousStatistics
            throw error
        }
    }

    private func compile(
        _ scene: CanvasPreparedScene,
        presentation: CanvasPreparedPresentation?,
        displayScale: Double
    ) throws -> MetalCompiledScene {
        let previousValidationRecords = freehandValidationRecords
        let previousCommittedCompilationCache = committedCompilationCache
        let previousRetainedCommittedGeneration = retainedCommittedGeneration
        let previousRetainedPreviewInkIdentities = retainedPreviewInkIdentities
        let previousStatistics = statistics
        do {
            try validate(scene.viewport)
            try validateDisplayScale(displayScale)
            let background = try premultiplied(scene.theme.background)
            var freehandCandidates: [ObjectIdentifier: FreehandCompileCandidate] = [:]
            if let presentation {
                return try compilePresentation(
                    presentation,
                    background: background,
                    displayScale: displayScale,
                    freehandCandidates: &freehandCandidates
                )
            }
            let items = try compileItems(
                scene,
                geometry: scene.geometry,
                displayScale: displayScale,
                coordinateOrigin: .init(x: 0, y: 0),
                freehandCandidates: &freehandCandidates
            )
            let visibleRect = scene.viewport.visibleCanvasRect
            try validate(visibleRect)
            let renderCoordinateOrigin = CanvasPoint(x: visibleRect.x, y: visibleRect.y)
            let renderItems = try compileItems(
                scene,
                geometry: scene.geometry,
                displayScale: displayScale,
                coordinateOrigin: renderCoordinateOrigin,
                freehandCandidates: &freehandCandidates
            )
            retainValidationRecords(for: scene.geometry)
            return MetalCompiledScene(
                background: background,
                items: items,
                viewport: scene.viewport,
                previewGeneration: scene.previewGeneration,
                renderItems: renderItems,
                renderCoordinateOrigin: renderCoordinateOrigin
            )
        } catch {
            freehandValidationRecords = previousValidationRecords
            committedCompilationCache = previousCommittedCompilationCache
            retainedCommittedGeneration = previousRetainedCommittedGeneration
            retainedPreviewInkIdentities = previousRetainedPreviewInkIdentities
            statistics = previousStatistics
            throw error
        }
    }

    private func compilePresentation(
        _ presentation: CanvasPreparedPresentation,
        background: SIMD4<Float>,
        displayScale: Double,
        freehandCandidates: inout [ObjectIdentifier: FreehandCompileCandidate]
    ) throws -> MetalCompiledScene {
        let scene = presentation.scene
        let visibleRect = scene.viewport.visibleCanvasRect
        try validate(visibleRect)
        let renderCoordinateOrigin = CanvasPoint(x: visibleRect.x, y: visibleRect.y)
        let dynamicGeometry: [CanvasPreparedGeometry]
        if presentation.committedSnapshot == nil {
            dynamicGeometry = scene.geometry.filter {
                if case .preview = $0.renderKey { return true }
                return false
            }
        } else {
            dynamicGeometry = scene.dynamicGeometry
        }
        let dynamicItems = try compileItems(
            scene,
            geometry: dynamicGeometry,
            displayScale: displayScale,
            coordinateOrigin: renderCoordinateOrigin,
            freehandCandidates: &freehandCandidates
        )
        let layers = try compileLayers(
            presentation,
            dynamicGeometry: dynamicGeometry,
            dynamicItems: dynamicItems,
            displayScale: displayScale,
            coordinateOrigin: renderCoordinateOrigin,
            freehandCandidates: &freehandCandidates
        )
        retainValidationRecordsIfNeeded(
            presentation: presentation,
            dynamicGeometry: dynamicGeometry
        )
        return MetalCompiledScene(
            background: background,
            items: nil,
            viewport: scene.viewport,
            previewGeneration: scene.previewGeneration,
            renderItems: nil,
            renderCoordinateOrigin: renderCoordinateOrigin,
            gridItems: layers.grid,
            liveItems: layers.live,
            overlayItems: layers.overlay,
            committedLayer: layers.committedLayer,
            viewportRenderPhase: presentation.viewportRenderPhase
        )
    }

    private func compileItems(
        _ scene: CanvasPreparedScene,
        geometry: [CanvasPreparedGeometry],
        displayScale: Double,
        coordinateOrigin: CanvasPoint,
        freehandCandidates: inout [ObjectIdentifier: FreehandCompileCandidate]
    ) throws -> [MetalDrawItem] {
        let selectionColor = try premultiplied(scene.theme.selection)
        let guideColor = try premultiplied(scene.theme.guides)
        let zoom = try finiteFloat(scene.viewport.zoom)
        let selectionLineWidth = try screenMetric(
            scene.theme.selectionLineWidth,
            zoom: zoom
        )
        let handleSize = try screenMetric(scene.theme.handleSize, zoom: zoom)
        var items: [MetalDrawItem] = []
        items.reserveCapacity(
            scene.gridLines.count + geometry.count + scene.guides.count + 5
        )

        for gridLine in scene.gridLines {
            let style = scene.theme.gridStyle(for: gridLine.tier)
            items.append(contentsOf: try decoratedLine(MetalLineInstance(
                start: try point(gridLine.start, relativeTo: coordinateOrigin),
                end: try point(gridLine.end, relativeTo: coordinateOrigin),
                color: try premultiplied(style.color),
                lineWidth: try screenMetric(style.width, zoom: zoom)
            ), pattern: style.dash, zoom: zoom))
        }

        for geometry in geometry {
            items.append(try compile(
                geometry,
                zoom: zoom,
                displayScale: displayScale,
                coordinateOrigin: coordinateOrigin,
                freehandCandidates: &freehandCandidates
            ).item)
        }

        if let bounds = scene.selectionBounds {
            let box = try boxGeometry(scene.theme.selectionRect(bounds, zoom: Double(zoom)), relativeTo: coordinateOrigin)
            let halfHandle = handleSize / 2
            let corners = [
                box.origin,
                SIMD2<Float>(box.origin.x + box.size.x, box.origin.y),
                box.origin + box.size,
                SIMD2<Float>(box.origin.x, box.origin.y + box.size.y),
            ]
            let perimeter = [corners[0], corners[1], corners[2], corners[3], corners[0]]
            var offset: Float = 0
            for index in 0 ..< perimeter.count - 1 {
                items.append(contentsOf: try decoratedLine(MetalLineInstance(
                    start: perimeter[index], end: perimeter[index + 1], color: selectionColor,
                    lineWidth: selectionLineWidth
                ), pattern: scene.theme.selectionDashPattern, zoom: zoom, pathOffset: offset))
                offset += simd_distance(perimeter[index], perimeter[index + 1])
            }
            let handleFill = try premultiplied(scene.theme.selectionHandleFill)
            for corner in corners where scene.theme.showsSelectionHandles {
                items.append(.analyticBox(MetalBoxInstance(
                    origin: corner - SIMD2<Float>(repeating: halfHandle),
                    size: SIMD2<Float>(repeating: handleSize),
                    fillColor: handleFill,
                    strokeColor: .zero,
                    lineWidth: 0
                )))
            }
        }

        let visibleRect = scene.viewport.visibleCanvasRect
        _ = try boxGeometry(visibleRect, relativeTo: coordinateOrigin)
        for guide in scene.guides {
            let endpoints: (CanvasPoint, CanvasPoint)
            switch guide {
            case .vertical(let canvasX):
                endpoints = (
                    .init(x: canvasX, y: visibleRect.minY),
                    .init(x: canvasX, y: visibleRect.maxY)
                )
            case .horizontal(let canvasY):
                endpoints = (
                    .init(x: visibleRect.minX, y: canvasY),
                    .init(x: visibleRect.maxX, y: canvasY)
                )
            }
            items.append(contentsOf: try decoratedLine(MetalLineInstance(
                start: try point(endpoints.0, relativeTo: coordinateOrigin),
                end: try point(endpoints.1, relativeTo: coordinateOrigin),
                color: guideColor,
                lineWidth: selectionLineWidth
            ), pattern: scene.theme.guideDashPattern, zoom: zoom))
        }
        return items
    }

    private func decoratedLine(
        _ line: MetalLineInstance,
        pattern: [Double],
        zoom: Float,
        pathOffset: Float = 0
    ) throws -> [MetalDrawItem] {
        let pattern = CanvasThemeSnapshot.validDashPattern(pattern)
        guard !pattern.isEmpty else { return [.analyticLine(line)] }
        let period = try screenMetric(pattern.reduce(0, +), zoom: zoom)
        var offset: Float = 0
        var result: [MetalDrawItem] = []
        for index in stride(from: 0, to: pattern.count, by: 2) {
            var dash = line
            dash.dashLength = try screenMetric(pattern[index], zoom: zoom)
            dash.dashPeriod = period
            dash.dashOffset = ((offset - pathOffset).truncatingRemainder(dividingBy: period) + period)
                .truncatingRemainder(dividingBy: period)
            result.append(.analyticLine(dash))
            offset += try screenMetric(pattern[index] + pattern[index + 1], zoom: zoom)
        }
        return result
    }

    private struct CompiledLayers {
        let grid: [MetalDrawItem]
        let committedLayer: MetalCompiledCommittedLayer
        let live: [MetalDrawItem]
        let overlay: [MetalDrawItem]
    }

    private func compileLayers(
        _ presentation: CanvasPreparedPresentation,
        dynamicGeometry: [CanvasPreparedGeometry],
        dynamicItems: [MetalDrawItem],
        displayScale: Double,
        coordinateOrigin: CanvasPoint,
        freehandCandidates: inout [ObjectIdentifier: FreehandCompileCandidate]
    ) throws -> CompiledLayers {
        let scene = presentation.scene
        let gridEnd = scene.gridLines.reduce(0) { count, line in
            count + max(1, scene.theme.gridStyle(for: line.tier).dash.count / 2)
        }
        let geometryEnd = gridEnd + dynamicGeometry.count
        let grid = Array(dynamicItems[..<gridEnd])
        let renderedGeometry = dynamicItems[gridEnd..<geometryEnd]
        let replacementIdentity = presentation.committed.replacement?
            .replacementGeometry.resourceIdentity
        var live: [MetalDrawItem] = []
        for (geometry, item) in zip(dynamicGeometry, renderedGeometry) {
            guard geometry.resourceIdentity != replacementIdentity else {
                continue
            }
            live.append(item)
        }
        let overlay = Array(dynamicItems[geometryEnd...])
        let committedLayer = try compileCommittedLayer(
            presentation.committed,
            viewport: scene.viewport,
            displayScale: displayScale,
            coordinateOrigin: coordinateOrigin,
            freehandCandidates: &freehandCandidates
        )

        return CompiledLayers(
            grid: grid,
            committedLayer: committedLayer,
            live: live,
            overlay: overlay
        )
    }

    private func compileCommittedLayer(
        _ committed: CanvasCommittedPresentation,
        viewport: CanvasViewport,
        displayScale: Double,
        coordinateOrigin: CanvasPoint,
        freehandCandidates: inout [ObjectIdentifier: FreehandCompileCandidate]
    ) throws -> MetalCompiledCommittedLayer {
        let key = MetalCommittedCompilationKey(
            generation: committed.generation,
            zoomBits: viewport.zoom.bitPattern,
            displayScaleBits: displayScale.bitPattern,
            originXBits: coordinateOrigin.x.bitPattern,
            originYBits: coordinateOrigin.y.bitPattern,
            replacementKey: committed.replacement?.replacementGeometry.renderKey
        )
        if let cache = committedCompilationCache, cache.key == key {
            return cache
        }
        let zoom = try finiteFloat(viewport.zoom)
        var items: [MetalCommittedDrawItem] = []
        items.reserveCapacity(committed.items.count)
        for source in committed.items {
            statistics.committedItemVisitCount += 1
            let compilation = try compile(
                source.geometry,
                zoom: zoom,
                displayScale: displayScale,
                coordinateOrigin: coordinateOrigin,
                freehandCandidates: &freehandCandidates
            )
            items.append(MetalCommittedDrawItem(
                documentIndex: source.documentIndex,
                geometry: source.geometry,
                paintedBounds: compilation.paintedBounds,
                item: compilation.item
            ))
        }
        let replacement: MetalCompiledReplacement?
        if let source = committed.replacement {
            guard let original = items.first(where: {
                $0.documentIndex == source.documentIndex
            }) else {
                throw MetalCanvasError.invalidNumericInput
            }
            let compilation = try compile(
                source.replacementGeometry,
                zoom: zoom,
                displayScale: displayScale,
                coordinateOrigin: coordinateOrigin,
                freehandCandidates: &freehandCandidates
            )
            replacement = MetalCompiledReplacement(
                documentIndex: source.documentIndex,
                original: original,
                replacement: MetalCommittedDrawItem(
                    documentIndex: source.documentIndex,
                    geometry: source.replacementGeometry,
                    paintedBounds: compilation.paintedBounds,
                    item: compilation.item
                )
            )
        } else {
            replacement = nil
        }
        let directItems = items.map { item in
            if let replacement,
               replacement.documentIndex == item.documentIndex {
                return replacement.replacement.item
            }
            return item.item
        }
        let layer = MetalCompiledCommittedLayer(
            key: key,
            items: items,
            directItems: directItems,
            plannerPresentation: committed,
            replacement: replacement
        )
        committedCompilationCache = layer
        return layer
    }

    private func retainValidationRecordsIfNeeded(
        presentation: CanvasPreparedPresentation,
        dynamicGeometry: [CanvasPreparedGeometry]
    ) {
        let previewInkIdentities: Set<ObjectIdentifier> = Set(
            dynamicGeometry.compactMap { geometry in
                guard case .ink(let ink) = geometry.path else { return nil }
                return ObjectIdentifier(ink)
            }
        )
        let committedGenerationChanged = retainedCommittedGeneration
            != presentation.committed.generation
        guard committedGenerationChanged
                || retainedPreviewInkIdentities != previewInkIdentities else {
            return
        }
        if committedGenerationChanged {
            retainValidationRecords(
                for: presentation.committed.items.map(\.geometry)
                    + dynamicGeometry
                    + [presentation.committed.replacement?.replacementGeometry]
                        .compactMap { $0 }
            )
        } else {
            for identity in retainedPreviewInkIdentities.subtracting(previewInkIdentities) {
                freehandValidationRecords.removeValue(forKey: .preview(identity))
            }
        }
        retainedCommittedGeneration = presentation.committed.generation
        retainedPreviewInkIdentities = previewInkIdentities
    }
}

private extension MetalSceneCompiler {
    struct GeometryCompilation {
        let item: MetalDrawItem
        let paintedBounds: CanvasRect
    }

    struct BoxGeometry {
        let origin: SIMD2<Float>
        let size: SIMD2<Float>
    }

    struct CircularPath {
        let start: CanvasPoint
        let end: CanvasPoint
        let center: CanvasPoint
        let radius: Double
        let sweepAngle: Double
    }

    private func compile(
        _ geometry: CanvasPreparedGeometry,
        zoom: Float,
        displayScale: Double,
        coordinateOrigin: CanvasPoint,
        freehandCandidates: inout [ObjectIdentifier: FreehandCompileCandidate]
    ) throws -> GeometryCompilation {
        statistics.compiledGeometryCount += 1
        try validate(geometry.bounds)
        let stroke = try premultiplied(geometry.style.stroke)
        let fill = try geometry.style.fill.map(premultiplied) ?? .zero
        let lineWidth = try screenMetric(geometry.style.lineWidth, zoom: zoom)
        let paintedBounds = try paintedBounds(
            for: geometry,
            zoom: zoom,
            displayScale: displayScale
        )

        switch geometry.path {
        case .ink(let ink):
            try validateFreehand(
                ink,
                geometry: geometry,
                freehandCandidates: &freehandCandidates
            )
            return GeometryCompilation(
                item: .freehand(MetalFreehandDescriptor(geometry: geometry)),
                paintedBounds: paintedBounds
            )

        case .immutable(let path):
            try validate(path)
            if let endpoints = lineEndpoints(path) {
                return GeometryCompilation(
                    item: .analyticLine(MetalLineInstance(
                        start: try point(endpoints.0, relativeTo: coordinateOrigin),
                        end: try point(endpoints.1, relativeTo: coordinateOrigin),
                        color: stroke,
                        lineWidth: lineWidth
                    )),
                    paintedBounds: paintedBounds
                )
            }
            if let rect = rectangle(path) {
                let box = try boxGeometry(rect, relativeTo: coordinateOrigin)
                return GeometryCompilation(
                    item: .analyticBox(MetalBoxInstance(
                        origin: box.origin,
                        size: box.size,
                        fillColor: fill,
                        strokeColor: stroke,
                        lineWidth: lineWidth
                    )),
                    paintedBounds: paintedBounds
                )
            }
            if let arc = circularPath(path) {
                guard fill.w == 0 else {
                    return GeometryCompilation(
                        item: .fallback(MetalFallbackDescriptor(geometry: geometry)),
                        paintedBounds: paintedBounds
                    )
                }
                var instance = MetalArcInstance(
                    start: try point(arc.start, relativeTo: coordinateOrigin),
                    end: try point(arc.end, relativeTo: coordinateOrigin),
                    center: try point(arc.center, relativeTo: coordinateOrigin),
                    radius: try finiteFloat(arc.radius),
                    color: stroke,
                    lineWidth: lineWidth
                )
                instance.sweepAngle = try finiteFloat(arc.sweepAngle)
                return GeometryCompilation(
                    item: .analyticArc(instance),
                    paintedBounds: paintedBounds
                )
            }
            return GeometryCompilation(
                item: .fallback(MetalFallbackDescriptor(geometry: geometry)),
                paintedBounds: paintedBounds
            )
        }
    }

    func validateDisplayScale(_ displayScale: Double) throws {
        guard displayScale.isFinite, displayScale > 0 else {
            throw MetalCanvasError.invalidNumericInput
        }
    }

    func paintedBounds(
        for geometry: CanvasPreparedGeometry,
        zoom: Float,
        displayScale: Double
    ) throws -> CanvasRect {
        try validateDisplayScale(displayScale)
        let zoom = Double(zoom)
        let inkExpansion: Double
        switch geometry.path {
        case .ink(let ink):
            let inkWidth = try CanvasInkCurve.lineWidthInCanvasUnits(
                lineWidth: geometry.style.lineWidth,
                viewportZoom: zoom,
                widthMode: ink.widthMode
            )
            inkExpansion = inkWidth * CanvasInkCurve.maximumWidthFactor(
                pressureEnabled: ink.pressureEnabled
            ) / 2
        case .immutable:
            inkExpansion = geometry.style.lineWidth / zoom / 2
        }
        let expansion = inkExpansion + 1 / (displayScale * zoom)
        let minimumX = geometry.bounds.minX - expansion
        let minimumY = geometry.bounds.minY - expansion
        let maximumX = geometry.bounds.maxX + expansion
        let maximumY = geometry.bounds.maxY + expansion
        let bounds = CanvasRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX,
            height: maximumY - minimumY
        )
        try validate(bounds)
        return bounds
    }

    private func validateFreehand(
        _ ink: CanvasPreparedInk,
        geometry: CanvasPreparedGeometry,
        freehandCandidates: inout [ObjectIdentifier: FreehandCompileCandidate]
    ) throws {
        let identity = ObjectIdentifier(ink)
        let key = validationKey(for: geometry, ink: ink)
        if let candidate = freehandCandidates[identity] {
            guard candidate.sourceInk === ink,
                  candidate.inkGeneration == ink.generation else {
                throw MetalCanvasError.invalidNumericInput
            }
            if freehandValidationRecords[key] == nil {
                freehandValidationRecords[key] = validationRecord(
                    for: candidate,
                    geometry: geometry
                )
            }
            return
        }

        let record = freehandValidationRecords[key]
        if let record,
           record.inkGeneration == ink.generation,
           record.sourceInk == nil || record.sourceInk === ink {
            return
        }

        let candidate = FreehandCompileCandidate(
            sourceInk: ink,
            inkGeneration: ink.generation,
            snapshot: ink.snapshot()
        )
        statistics.preparedFreehandCandidateCount += 1

        let confirmedStartIndex: Int
        let validatePredictions: Bool
        if let record {
            if record.sourceInk === ink,
               record.confirmedSampleCount <= candidate.snapshot.confirmed.count {
                confirmedStartIndex = record.confirmedSampleCount
                validatePredictions = true
            } else {
                confirmedStartIndex = 0
                validatePredictions = true
            }
        } else {
            confirmedStartIndex = 0
            validatePredictions = true
        }

        let confirmedToValidate = candidate.snapshot.confirmed.dropFirst(
            confirmedStartIndex
        )
        for sample in confirmedToValidate {
            guard sample.pressure.isFinite else {
                throw MetalCanvasError.invalidNumericInput
            }
            _ = try point(sample.point)
        }
        if validatePredictions {
            for sample in candidate.snapshot.predicted {
                guard sample.pressure.isFinite else {
                    throw MetalCanvasError.invalidNumericInput
                }
                _ = try point(sample.point)
            }
        }
        statistics.validatedFreehandPointCount += confirmedToValidate.count
            + (validatePredictions ? candidate.snapshot.predicted.count : 0)
        freehandValidationRecords[key] = validationRecord(
            for: candidate,
            geometry: geometry
        )
        freehandCandidates[identity] = candidate
    }

    private func validationKey(
        for geometry: CanvasPreparedGeometry,
        ink: CanvasPreparedInk
    ) -> FreehandValidationKey {
        switch geometry.renderKey {
        case .preview:
            .preview(ObjectIdentifier(ink))
        case .committed:
            .committed(geometry.resourceIdentity)
        }
    }

    private func validationRecord(
        for candidate: FreehandCompileCandidate,
        geometry: CanvasPreparedGeometry
    ) -> FreehandValidationRecord {
        FreehandValidationRecord(
            sourceInk: {
                if case .preview = geometry.renderKey {
                    return candidate.sourceInk
                }
                return nil
            }(),
            inkGeneration: candidate.inkGeneration,
            confirmedSampleCount: candidate.snapshot.confirmed.count
        )
    }

    func retainValidationRecords(for geometry: [CanvasPreparedGeometry]) {
        var retainedKeys = Set<FreehandValidationKey>()
        retainedKeys.reserveCapacity(geometry.count)
        for item in geometry {
            guard case .ink(let ink) = item.path else { continue }
            switch item.renderKey {
            case .preview:
                retainedKeys.insert(.preview(ObjectIdentifier(ink)))
            case .committed:
                retainedKeys.insert(.committed(item.resourceIdentity))
            }
        }
        freehandValidationRecords = freehandValidationRecords.filter {
            retainedKeys.contains($0.key)
        }
    }

    func lineEndpoints(_ path: CanvasPath) -> (CanvasPoint, CanvasPoint)? {
        guard path.commands.count == 2,
              case .move(let start) = path.commands[0],
              case .line(let end) = path.commands[1] else {
            return nil
        }
        return (start, end)
    }

    func rectangle(_ path: CanvasPath) -> CanvasRect? {
        guard path.commands.count == 5,
              case .move(let first) = path.commands[0],
              case .line(let second) = path.commands[1],
              case .line(let third) = path.commands[2],
              case .line(let fourth) = path.commands[3],
              case .close = path.commands[4],
              first.y == second.y,
              second.x == third.x,
              third.y == fourth.y,
              fourth.x == first.x else {
            return nil
        }
        let minimumX = min(first.x, third.x)
        let minimumY = min(first.y, third.y)
        return CanvasRect(
            x: minimumX,
            y: minimumY,
            width: max(first.x, third.x) - minimumX,
            height: max(first.y, third.y) - minimumY
        )
    }

    func circularPath(_ path: CanvasPath) -> CircularPath? {
        guard path.commands.count >= 2,
              path.commands.count <= 5,
              case .move(let start) = path.commands[0] else {
            return nil
        }
        var segments: [(CanvasPoint, CanvasPoint, CanvasPoint, CanvasPoint)] = []
        var current = start
        for command in path.commands.dropFirst() {
            guard case .cubic(let control1, let control2, let end) = command else {
                return nil
            }
            segments.append((current, control1, control2, end))
            current = end
        }
        guard let first = segments.first,
              let center = tangentCenter(
                start: first.0,
                startControl: first.1,
                endControl: first.2,
                end: first.3
              ) else {
            return nil
        }
        let radius = hypot(start.x - center.x, start.y - center.y)
        guard radius.isFinite, radius > 0 else { return nil }
        let firstTangent = CanvasPoint(
            x: first.1.x - first.0.x,
            y: first.1.y - first.0.y
        )
        let firstRadial = CanvasPoint(x: first.0.x - center.x, y: first.0.y - center.y)
        let direction = cross(firstRadial, firstTangent) >= 0 ? 1.0 : -1.0
        var sweepAngle = 0.0
        let tolerance = max(0.000_001, radius * 0.000_001)

        for segment in segments {
            let points = [segment.0, segment.3]
            guard points.allSatisfy({ point in
                abs(hypot(point.x - center.x, point.y - center.y) - radius) <= tolerance
            }) else {
                return nil
            }
            let startAngle = atan2(segment.0.y - center.y, segment.0.x - center.x)
            let endAngle = atan2(segment.3.y - center.y, segment.3.x - center.x)
            let magnitude = direction > 0
                ? normalizedPositiveAngle(endAngle - startAngle)
                : normalizedPositiveAngle(startAngle - endAngle)
            guard magnitude > 0, magnitude <= Double.pi / 2 + 0.000_001 else {
                return nil
            }
            let segmentSweep = direction * magnitude
            let tangentScale = 4 / 3 * tan(segmentSweep / 4) * radius
            let expectedControl1 = CanvasPoint(
                x: segment.0.x - sin(startAngle) * tangentScale,
                y: segment.0.y + cos(startAngle) * tangentScale
            )
            let expectedControl2 = CanvasPoint(
                x: segment.3.x + sin(endAngle) * tangentScale,
                y: segment.3.y - cos(endAngle) * tangentScale
            )
            guard distance(segment.1, expectedControl1) <= tolerance,
                  distance(segment.2, expectedControl2) <= tolerance else {
                return nil
            }
            sweepAngle += segmentSweep
        }
        guard sweepAngle.isFinite,
              abs(sweepAngle) <= Double.pi * 2 + 0.000_001 else {
            return nil
        }
        return CircularPath(
            start: start,
            end: current,
            center: center,
            radius: radius,
            sweepAngle: sweepAngle
        )
    }

    func tangentCenter(
        start: CanvasPoint,
        startControl: CanvasPoint,
        endControl: CanvasPoint,
        end: CanvasPoint
    ) -> CanvasPoint? {
        let startTangent = CanvasPoint(
            x: startControl.x - start.x,
            y: startControl.y - start.y
        )
        let endTangent = CanvasPoint(x: end.x - endControl.x, y: end.y - endControl.y)
        let startNormal = CanvasPoint(x: -startTangent.y, y: startTangent.x)
        let endNormal = CanvasPoint(x: -endTangent.y, y: endTangent.x)
        let denominator = cross(startNormal, endNormal)
        guard denominator.isFinite, abs(denominator) > Double.ulpOfOne else {
            return nil
        }
        let displacement = CanvasPoint(x: end.x - start.x, y: end.y - start.y)
        let scale = cross(displacement, endNormal) / denominator
        let center = CanvasPoint(
            x: start.x + startNormal.x * scale,
            y: start.y + startNormal.y * scale
        )
        return center.x.isFinite && center.y.isFinite ? center : nil
    }

    func cross(_ first: CanvasPoint, _ second: CanvasPoint) -> Double {
        first.x * second.y - first.y * second.x
    }

    func distance(_ first: CanvasPoint, _ second: CanvasPoint) -> Double {
        hypot(first.x - second.x, first.y - second.y)
    }

    func normalizedPositiveAngle(_ angle: Double) -> Double {
        let fullTurn = Double.pi * 2
        let remainder = angle.truncatingRemainder(dividingBy: fullTurn)
        return remainder >= 0 ? remainder : remainder + fullTurn
    }

    func validate(_ viewport: CanvasViewport) throws {
        guard viewport.zoom.isFinite,
              viewport.zoom > 0,
              viewport.translation.x.isFinite,
              viewport.translation.y.isFinite,
              viewport.viewportSize.width.isFinite,
              viewport.viewportSize.height.isFinite,
              viewport.viewportSize.width >= 0,
              viewport.viewportSize.height >= 0 else {
            throw MetalCanvasError.invalidNumericInput
        }
        _ = try point(viewport.translation)
        _ = try finiteFloat(viewport.viewportSize.width)
        _ = try finiteFloat(viewport.viewportSize.height)
    }

    func validate(_ rect: CanvasRect) throws {
        guard rect.x.isFinite,
              rect.y.isFinite,
              rect.width.isFinite,
              rect.height.isFinite,
              rect.width >= 0,
              rect.height >= 0,
              rect.maxX.isFinite,
              rect.maxY.isFinite else {
            throw MetalCanvasError.invalidNumericInput
        }
        _ = try boxGeometry(rect, relativeTo: .init(x: 0, y: 0))
    }

    func validate(_ path: CanvasPath) throws {
        for command in path.commands {
            switch command {
            case .move(let value), .line(let value):
                _ = try point(value)
            case .quad(let control, let end):
                _ = try point(control)
                _ = try point(end)
            case .cubic(let control1, let control2, let end):
                _ = try point(control1)
                _ = try point(control2)
                _ = try point(end)
            case .close:
                break
            }
        }
    }

    func boxGeometry(
        _ rect: CanvasRect,
        relativeTo coordinateOrigin: CanvasPoint
    ) throws -> BoxGeometry {
        let origin = try point(
            .init(x: rect.x, y: rect.y),
            relativeTo: coordinateOrigin
        )
        let size = SIMD2<Float>(
            try finiteFloat(rect.width),
            try finiteFloat(rect.height)
        )
        guard (origin + size).x.isFinite, (origin + size).y.isFinite else {
            throw MetalCanvasError.invalidNumericInput
        }
        return BoxGeometry(origin: origin, size: size)
    }

    func point(
        _ value: CanvasPoint,
        relativeTo coordinateOrigin: CanvasPoint = .init(x: 0, y: 0)
    ) throws -> SIMD2<Float> {
        let x = value.x - coordinateOrigin.x
        let y = value.y - coordinateOrigin.y
        guard x.isFinite, y.isFinite else {
            throw MetalCanvasError.invalidNumericInput
        }
        return SIMD2<Float>(try finiteFloat(x), try finiteFloat(y))
    }

    func finiteFloat(_ value: Double) throws -> Float {
        let result = Float(value)
        guard value.isFinite, result.isFinite else {
            throw MetalCanvasError.invalidNumericInput
        }
        return result
    }

    func screenMetric(_ value: Double, zoom: Float) throws -> Float {
        let metric = try finiteFloat(value)
        guard metric > 0, zoom.isFinite, zoom > 0 else {
            throw MetalCanvasError.invalidNumericInput
        }
        let result = metric / zoom
        guard result.isFinite, result > 0 else {
            throw MetalCanvasError.invalidNumericInput
        }
        return result
    }

    func premultiplied(_ color: CanvasColor) throws -> SIMD4<Float> {
        guard color.red.isFinite,
              color.green.isFinite,
              color.blue.isFinite,
              color.alpha.isFinite else {
            throw MetalCanvasError.invalidNumericInput
        }
        let alpha = Float(min(1, max(0, color.alpha)))
        return SIMD4<Float>(
            Float(min(1, max(0, color.red))) * alpha,
            Float(min(1, max(0, color.green))) * alpha,
            Float(min(1, max(0, color.blue))) * alpha,
            alpha
        )
    }
}

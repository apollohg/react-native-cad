import CoreGraphics
import UIKit
import CadCanvasCore

struct CanvasGridLine {
    let start: CanvasPoint
    let end: CanvasPoint
    var dashPattern: [Double] = []
}

enum CoreGraphicsRenderCommand {
    case background(CanvasColor)
    case grid(CanvasGridLine, CanvasColor, lineWidth: Double)
    case element(
        id: UUID,
        path: CGPath,
        stroke: CanvasColor,
        fill: CanvasColor?,
        lineWidth: Double
    )
    case selection(
        bounds: CanvasRect,
        color: CanvasColor,
        lineWidth: Double,
        handleSize: Double
    )
    case guide(SnapGuide, CanvasColor, lineWidth: Double)
}

@MainActor
public final class CoreGraphicsCanvasRenderer:
    CanvasTimestampedDisplayReportingRenderer,
    CanvasRenderCacheResetting,
    CanvasRenderDismantling
{
    struct Statistics: Equatable {
        let fullPathBuildCount: Int
        let appendedPointCount: Int
        let validatedPointCount: Int
        let cachedPathCount: Int
    }

    private enum InkGeometryCacheKey: Hashable {
        case centerline(viewportScaleBucket: Double)
        case compound(viewportScale: Double, lineWidth: Double)
    }

    private enum BackendPathCacheKey: Hashable {
        case immutable(CanvasRenderKey, CanvasPreparedResourceIdentity)
        case ink(
            CanvasPreparedResourceIdentity,
            RecognitionGeneration,
            InkGeometryCacheKey
        )
    }

    private struct CachedPath {
        let sourceInk: ObjectIdentifier?
        let generation: RecognitionGeneration?
        let samples: [CanvasInkSample]
        let pressureEnabled: Bool
        let points: [CanvasPoint]
        let path: CGPath
        let inkRenderingMode: CanvasInkRenderingMode?

        var pointCount: Int { points.count }
    }

    private struct CachedPathLookup {
        let key: BackendPathCacheKey
        let path: CGPath
        let inkRenderingMode: CanvasInkRenderingMode?
    }

    private static let maximumBitmapDimension = 16_384
    private static let maximumBitmapPixelCount = 64 * 1_024 * 1_024
    private static let absoluteMaximumScreenMetric = 1_000_000.0

    private var pathCache: [BackendPathCacheKey: CachedPath] = [:]
    private var inkPathKeyBySource: [ObjectIdentifier: BackendPathCacheKey] = [:]
    private(set) var pathBuildCount = 0
    private(set) var pathPointAppendCount = 0
    private(set) var pathPointValidationCount = 0
    private(set) var inkOutlineBuildCount = 0
    private(set) var inkSourceIndexProbeCount = 0

    var cachedPathCount: Int { pathCache.count }
    var statistics: Statistics {
        Statistics(
            fullPathBuildCount: pathBuildCount,
            appendedPointCount: pathPointAppendCount,
            validatedPointCount: pathPointValidationCount,
            cachedPathCount: cachedPathCount
        )
    }

    public init() {}

    public func makeRenderView(
        displayCompletion: @escaping (RecognitionGeneration, TimeInterval) -> Void
    ) -> UIView {
        CanvasRenderView(
            renderer: self,
            displayCompletion: displayCompletion
        )
    }

    public func update(_ scene: CanvasPreparedScene, in renderView: UIView) {
        guard let renderView = renderView as? CanvasRenderView,
              renderView.isOwned(by: self) else {
            return
        }
        pruneCache(for: scene)
        renderView.enqueue(scene)
    }

    func clearCache() {
        pathCache.removeAll(keepingCapacity: false)
        inkPathKeyBySource.removeAll(keepingCapacity: false)
    }

    func resetDerivedRenderCaches() {
        clearCache()
    }

    func dismantleRenderView(_ renderView: UIView) {
        guard let renderView = renderView as? CanvasRenderView,
              renderView.isOwned(by: self) else {
            return
        }
        resetDerivedRenderCaches()
    }

    func cachedPointCount(for ink: CanvasPreparedInk) -> Int? {
        guard let key = inkPathKeyBySource[ObjectIdentifier(ink)] else { return nil }
        return pathCache[key]?.pointCount
    }

    func hasImmutableCachedPath(for renderKey: CanvasRenderKey) -> Bool {
        pathCache.keys.contains { key in
            guard case .immutable(let cachedRenderKey, _) = key else { return false }
            return cachedRenderKey == renderKey
        }
    }

    func renderCommands(
        scene: CanvasPreparedScene,
        bounds: CGRect,
        displayScale: Double
    ) -> [CoreGraphicsRenderCommand] {
        guard isValidRenderBounds(bounds),
              isValidDisplayScale(displayScale),
              isValidViewport(scene.viewport) else {
            return []
        }

        let zoom = scene.viewport.zoom
        let theme = scene.theme
        let fallbackScreenMetric = 1 / displayScale
        let maximumScreenMetric = maximumMetric(for: bounds)
        let overlayLineWidth = boundedMetric(
            theme.selectionLineWidth,
            fallback: fallbackScreenMetric,
            maximum: maximumScreenMetric
        ) / zoom
        let handleSize = boundedMetric(
            theme.handleSize,
            fallback: fallbackScreenMetric,
            maximum: maximumScreenMetric
        ) / zoom
        var commands: [CoreGraphicsRenderCommand] = [
            .background(validColor(theme.background, fallback: .black)),
        ]
        var retainedKeys: Set<BackendPathCacheKey> = []

        for line in scene.gridLines where isFinite(line.start) && isFinite(line.end) {
            let style = theme.gridStyle(for: line.tier)
            commands.append(.grid(
                CanvasGridLine(start: line.start, end: line.end, dashPattern: style.dash.map { $0 / zoom }),
                validColor(style.color, fallback: theme.grid),
                lineWidth: boundedMetric(style.width, fallback: fallbackScreenMetric, maximum: maximumScreenMetric) / zoom
            ))
        }

        for geometry in scene.geometry {
            let configuredLineWidth = boundedMetric(
                geometry.style.lineWidth,
                fallback: fallbackScreenMetric,
                maximum: maximumScreenMetric
            )
            let lineWidth: Double
            if case .ink(let ink) = geometry.path {
                guard let resolvedWidth = try? CanvasInkCurve.lineWidthInCanvasUnits(
                    lineWidth: configuredLineWidth,
                    viewportZoom: zoom,
                    widthMode: ink.widthMode
                ) else {
                    continue
                }
                lineWidth = resolvedWidth
            } else {
                lineWidth = configuredLineWidth / zoom
            }
            let viewportScale = zoom * displayScale
            guard isValidCanvasRect(geometry.bounds),
                  let cached = cachedPath(
                    for: geometry,
                    viewportScale: viewportScale,
                    lineWidth: lineWidth
                  ) else {
                continue
            }
            retainedKeys.insert(cached.key)
            let stroke = validColor(geometry.style.stroke, fallback: theme.stroke)
            let fill: CanvasColor?
            let commandLineWidth: Double
            switch cached.inkRenderingMode {
            case .centerline(let widthFactor):
                fill = nil
                commandLineWidth = lineWidth * widthFactor
            case .compound:
                fill = stroke
                commandLineWidth = 0
            case nil:
                fill = geometry.style.fill.flatMap(validColor)
                commandLineWidth = lineWidth
            }
            commands.append(.element(
                id: geometry.id,
                path: cached.path,
                stroke: stroke,
                fill: fill,
                lineWidth: commandLineWidth
            ))
        }

        if let selectionBounds = scene.selectionBounds,
           isValidCanvasRect(selectionBounds) {
            commands.append(.selection(
                bounds: theme.selectionRect(selectionBounds, zoom: zoom),
                color: validColor(theme.selection, fallback: theme.stroke),
                lineWidth: overlayLineWidth,
                handleSize: theme.showsSelectionHandles ? handleSize : 0
            ))
        }

        let guideColor = validColor(theme.guides, fallback: theme.stroke)
        for guide in scene.guides where isFinite(guide) {
            commands.append(.guide(guide, guideColor, lineWidth: overlayLineWidth))
        }
        pruneCache(retaining: retainedKeys)
        return commands
    }

    func makeBitmap(
        scene: CanvasPreparedScene,
        bounds: CGRect,
        displayScale: Double
    ) -> CGImage? {
        guard isValidRenderBounds(bounds),
              isValidDisplayScale(displayScale) else {
            return nil
        }
        let pixelWidthValue = ceil(Double(bounds.width) * displayScale)
        let pixelHeightValue = ceil(Double(bounds.height) * displayScale)
        guard pixelWidthValue.isFinite,
              pixelHeightValue.isFinite,
              pixelWidthValue >= 1,
              pixelHeightValue >= 1,
              pixelWidthValue <= Double(Self.maximumBitmapDimension),
              pixelHeightValue <= Double(Self.maximumBitmapDimension) else {
            return nil
        }
        let pixelWidth = Int(pixelWidthValue)
        let pixelHeight = Int(pixelHeightValue)
        guard pixelHeight > 0,
              pixelWidth <= Self.maximumBitmapPixelCount / pixelHeight,
              let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        context.scaleBy(x: displayScale, y: displayScale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        draw(scene: scene, in: context, bounds: bounds, displayScale: displayScale)
        return context.makeImage()
    }

    func draw(
        scene: CanvasPreparedScene,
        in context: CGContext,
        bounds: CGRect,
        displayScale: Double
    ) {
        defer { pruneCache(for: scene) }
        let commands = renderCommands(scene: scene, bounds: bounds, displayScale: displayScale)
        guard !commands.isEmpty else { return }

        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: bounds)

        for command in commands {
            context.saveGState()
            if case .background = command {
                drawBackground(command, in: context, bounds: bounds)
            } else {
                context.concatenate(viewportTransform(scene.viewport))
                drawModelCommand(
                    command,
                    in: context,
                    visibleRect: scene.viewport.visibleCanvasRect,
                    theme: scene.theme,
                    zoom: scene.viewport.zoom
                )
            }
            context.restoreGState()
        }
    }
}

private extension CoreGraphicsCanvasRenderer {
    func pruneCache(for scene: CanvasPreparedScene) {
        let immutableKeys = Set(scene.geometry.compactMap { geometry -> BackendPathCacheKey? in
            guard case .immutable = geometry.path else { return nil }
            return .immutable(geometry.renderKey, geometry.resourceIdentity)
        })
        let inkTargets = Dictionary(uniqueKeysWithValues: scene.geometry.compactMap {
            geometry -> (
                ObjectIdentifier,
                (
                    identity: CanvasPreparedResourceIdentity,
                    generation: RecognitionGeneration,
                    samples: [CanvasInkSample],
                    pressureEnabled: Bool
                )
            )? in
            guard case .ink(let ink) = geometry.path else { return nil }
            let snapshot = ink.snapshot()
            return (
                ObjectIdentifier(ink),
                (
                    geometry.resourceIdentity,
                    ink.generation,
                    snapshot.confirmed + snapshot.predicted,
                    snapshot.pressureEnabled
                )
            )
        })
        var rekeyed = pathCache
        var rekeyedIndex = inkPathKeyBySource
        for (sourceInk, target) in inkTargets {
            guard let key = inkPathKeyBySource[sourceInk],
                  let cached = pathCache[key],
                  cached.sourceInk == sourceInk,
                  case .ink(
                    let cachedIdentity,
                    let generation,
                    let geometryKey
                  ) = key else {
                continue
            }
            let exactContentMatch = cached.samples == target.samples
                && cached.pressureEnabled == target.pressureEnabled
                && cachedIdentity != target.identity
            guard target.generation == generation || exactContentMatch else { continue }
            let replacement = BackendPathCacheKey.ink(
                target.identity,
                target.generation,
                geometryKey
            )
            if replacement != key {
                rekeyed.removeValue(forKey: key)
                rekeyed[replacement] = CachedPath(
                    sourceInk: cached.sourceInk,
                    generation: target.generation,
                    samples: cached.samples,
                    pressureEnabled: cached.pressureEnabled,
                    points: cached.points,
                    path: cached.path,
                    inkRenderingMode: cached.inkRenderingMode
                )
                rekeyedIndex[sourceInk] = replacement
            }
        }
        let retainedInkIdentities = Set(inkTargets.values.map(\.identity))
        pathCache = rekeyed.filter { key, _ in
            switch key {
            case .immutable:
                immutableKeys.contains(key)
            case .ink(let identity, _, _):
                retainedInkIdentities.contains(identity)
            }
        }
        inkPathKeyBySource = rekeyedIndex.filter { pathCache[$0.value] != nil }
    }

    private func pruneCache(retaining retained: Set<BackendPathCacheKey>) {
        pathCache = pathCache.filter { retained.contains($0.key) }
        inkPathKeyBySource = inkPathKeyBySource.filter { retained.contains($0.value) }
    }

    private func cachedPath(
        for geometry: CanvasPreparedGeometry,
        viewportScale: Double,
        lineWidth: Double
    ) -> CachedPathLookup? {
        switch geometry.path {
        case .immutable(let canvasPath):
            let key = BackendPathCacheKey.immutable(
                geometry.renderKey,
                geometry.resourceIdentity
            )
            if let cached = pathCache[key] {
                return CachedPathLookup(
                    key: key,
                    path: cached.path,
                    inkRenderingMode: nil
                )
            }
            guard let path = makePath(canvasPath) else { return nil }
            pathCache[key] = CachedPath(
                sourceInk: nil,
                generation: nil,
                samples: [],
                pressureEnabled: false,
                points: [],
                path: path,
                inkRenderingMode: nil
            )
            pathBuildCount += 1
            return CachedPathLookup(key: key, path: path, inkRenderingMode: nil)

        case .ink(let ink):
            let snapshot = ink.snapshot()
            let samples = snapshot.confirmed + snapshot.predicted
            let points = samples.map(\.point)
            let sourceInk = ObjectIdentifier(ink)
            inkSourceIndexProbeCount += 1
            let priorKey = inkPathKeyBySource[sourceInk]
            let prior = priorKey.flatMap { pathCache[$0] }
            if let priorKey,
               let prior,
               prior.sourceInk == sourceInk,
               prior.samples == samples,
               prior.pressureEnabled == snapshot.pressureEnabled,
               let mode = prior.inkRenderingMode,
               let targetKey = inkBackendKey(
                identity: geometry.resourceIdentity,
                generation: ink.generation,
                mode: mode,
                viewportScale: viewportScale,
                lineWidth: lineWidth
              ) {
                if targetKey == priorKey {
                    return CachedPathLookup(
                        key: priorKey,
                        path: prior.path,
                        inkRenderingMode: mode
                    )
                }
                if inkGeometryKey(in: targetKey) == inkGeometryKey(in: priorKey) {
                    pathCache.removeValue(forKey: priorKey)
                    pathCache[targetKey] = CachedPath(
                        sourceInk: sourceInk,
                        generation: ink.generation,
                        samples: samples,
                        pressureEnabled: snapshot.pressureEnabled,
                        points: points,
                        path: prior.path,
                        inkRenderingMode: mode
                    )
                    inkPathKeyBySource[sourceInk] = targetKey
                    return CachedPathLookup(
                        key: targetKey,
                        path: prior.path,
                        inkRenderingMode: mode
                    )
                }
            }

            if let prior,
               prior.pointCount <= points.count,
               zip(prior.points, points).allSatisfy({ $0.0 == $0.1 }) {
                let suffix = points[prior.pointCount...]
                pathPointValidationCount += suffix.count
                guard suffix.allSatisfy(isFinite) else { return nil }
                pathPointAppendCount += points.count - prior.pointCount
            } else {
                pathPointValidationCount += points.count
                pathPointAppendCount += points.count
                guard points.allSatisfy(isFinite) else { return nil }
            }

            guard let uniformViewportScale = conservativeScaleBucket(viewportScale),
                  let renderPath = try? CanvasInkOutlineBuilder.makeRenderPath(
                snapshot: snapshot,
                viewportScale: viewportScale,
                lineWidth: lineWidth,
                uniformViewportScale: uniformViewportScale
                  ),
                  let key = inkBackendKey(
                    identity: geometry.resourceIdentity,
                    generation: ink.generation,
                    mode: renderPath.mode,
                    viewportScale: viewportScale,
                    lineWidth: lineWidth
                  ) else { return nil }
            let isFirstBuildForPreparedInk = prior == nil
            if let priorKey { pathCache.removeValue(forKey: priorKey) }
            pathCache[key] = CachedPath(
                sourceInk: sourceInk,
                generation: ink.generation,
                samples: samples,
                pressureEnabled: snapshot.pressureEnabled,
                points: points,
                path: renderPath.path,
                inkRenderingMode: renderPath.mode
            )
            inkPathKeyBySource[sourceInk] = key
            inkOutlineBuildCount += 1
            if isFirstBuildForPreparedInk { pathBuildCount += 1 }
            return CachedPathLookup(
                key: key,
                path: renderPath.path,
                inkRenderingMode: renderPath.mode
            )
        }
    }

    private func inkBackendKey(
        identity: CanvasPreparedResourceIdentity,
        generation: RecognitionGeneration,
        mode: CanvasInkRenderingMode,
        viewportScale: Double,
        lineWidth: Double
    ) -> BackendPathCacheKey? {
        let geometryKey: InkGeometryCacheKey
        switch mode {
        case .centerline:
            guard let bucket = conservativeScaleBucket(viewportScale) else { return nil }
            geometryKey = .centerline(viewportScaleBucket: bucket)
        case .compound:
            geometryKey = .compound(viewportScale: viewportScale, lineWidth: lineWidth)
        }
        return .ink(identity, generation, geometryKey)
    }

    private func inkGeometryKey(in key: BackendPathCacheKey) -> InkGeometryCacheKey? {
        guard case .ink(_, _, let geometryKey) = key else { return nil }
        return geometryKey
    }

    private func conservativeScaleBucket(_ viewportScale: Double) -> Double? {
        guard viewportScale.isFinite, viewportScale > 0 else { return nil }
        let exponent = floor(log2(viewportScale))
        guard exponent.isFinite else { return nil }
        var bucket = pow(2, exponent)
        guard bucket.isFinite, bucket > 0 else { return nil }
        if bucket < viewportScale {
            guard bucket <= Double.greatestFiniteMagnitude / 2 else { return nil }
            bucket *= 2
        }
        let maximumError = 0.25 / bucket
        guard bucket.isFinite,
              bucket >= viewportScale,
              maximumError.isFinite,
              maximumError > 0 else { return nil }
        return bucket
    }

    func makePath(_ path: CanvasPath) -> CGMutablePath? {
        guard isValidPath(path) else { return nil }
        let result = CGMutablePath()
        for command in path.commands {
            switch command {
            case .move(let point):
                result.move(to: cgPoint(point))
            case .line(let point):
                result.addLine(to: cgPoint(point))
            case .quad(let control, let end):
                result.addQuadCurve(to: cgPoint(end), control: cgPoint(control))
            case .cubic(let control1, let control2, let end):
                result.addCurve(
                    to: cgPoint(end),
                    control1: cgPoint(control1),
                    control2: cgPoint(control2)
                )
            case .close:
                result.closeSubpath()
            }
        }
        return result
    }

    func viewportTransform(_ viewport: CanvasViewport) -> CGAffineTransform {
        CGAffineTransform(
            a: viewport.zoom,
            b: 0,
            c: 0,
            d: viewport.zoom,
            tx: viewport.translation.x,
            ty: viewport.translation.y
        )
    }

    func drawBackground(
        _ command: CoreGraphicsRenderCommand,
        in context: CGContext,
        bounds: CGRect
    ) {
        guard case .background(let color) = command else { return }
        context.setFillColor(cgColor(color))
        context.fill(bounds)
    }

    func drawModelCommand(
        _ command: CoreGraphicsRenderCommand,
        in context: CGContext,
        visibleRect: CanvasRect,
        theme: CanvasThemeSnapshot,
        zoom: Double
    ) {
        context.saveGState()
        defer { context.restoreGState() }
        switch command {
        case .background:
            return

        case .grid(let line, let color, let lineWidth):
            context.setLineDash(phase: 0, lengths: line.dashPattern.map { CGFloat($0) })
            context.setStrokeColor(cgColor(color))
            context.setLineWidth(lineWidth)
            context.beginPath()
            context.move(to: cgPoint(line.start))
            context.addLine(to: cgPoint(line.end))
            context.strokePath()

        case .element(_, let path, let stroke, let fill, let lineWidth):
            context.addPath(path)
            if let fill, lineWidth == 0 {
                context.setFillColor(cgColor(fill))
                context.fillPath(using: .winding)
            } else {
                context.setStrokeColor(cgColor(stroke))
                context.setLineWidth(lineWidth)
                context.setLineJoin(.round)
                context.setLineCap(.round)
                if let fill {
                    context.setFillColor(cgColor(fill))
                    context.drawPath(using: .fillStroke)
                } else {
                    context.strokePath()
                }
            }

        case .selection(let bounds, let color, let lineWidth, let handleSize):
            guard let rect = cgRect(bounds) else { return }
            context.setStrokeColor(cgColor(color))
            context.setFillColor(cgColor(validColor(theme.selectionHandleFill, fallback: color)))
            context.setLineWidth(lineWidth)
            context.setLineJoin(.round)
            context.setLineDash(phase: 0, lengths: CanvasThemeSnapshot.validDashPattern(theme.selectionDashPattern).map { $0 / zoom })
            context.stroke(rect)
            context.setLineDash(phase: 0, lengths: [])
            for handleRect in selectionHandleRects(around: rect, handleSize: handleSize) {
                context.fill(handleRect)
            }

        case .guide(let guide, let color, let lineWidth):
            context.setLineDash(phase: 0, lengths: CanvasThemeSnapshot.validDashPattern(theme.guideDashPattern).map { $0 / zoom })
            guard isValidCanvasRect(visibleRect) else { return }
            context.setStrokeColor(cgColor(color))
            context.setLineWidth(lineWidth)
            context.beginPath()
            switch guide {
            case .vertical(let x):
                context.move(to: CGPoint(x: x, y: visibleRect.minY))
                context.addLine(to: CGPoint(x: x, y: visibleRect.maxY))
            case .horizontal(let y):
                context.move(to: CGPoint(x: visibleRect.minX, y: y))
                context.addLine(to: CGPoint(x: visibleRect.maxX, y: y))
            }
            context.strokePath()
        }
    }

    func isValidRenderBounds(_ bounds: CGRect) -> Bool {
        bounds.origin.x.isFinite
            && bounds.origin.y.isFinite
            && bounds.width.isFinite
            && bounds.height.isFinite
            && bounds.maxX.isFinite
            && bounds.maxY.isFinite
            && bounds.width > 0
            && bounds.height > 0
    }

    func isValidDisplayScale(_ displayScale: Double) -> Bool {
        displayScale.isFinite && displayScale.isNormal && displayScale > 0
    }

    func isValidViewport(_ viewport: CanvasViewport) -> Bool {
        viewport.zoom.isFinite
            && viewport.zoom.isNormal
            && viewport.zoom > 0
            && viewport.translation.x.isFinite
            && viewport.translation.y.isFinite
    }

    func isValidCanvasRect(_ rect: CanvasRect) -> Bool {
        rect.isFinite
            && rect.minX.isFinite
            && rect.maxX.isFinite
            && rect.minY.isFinite
            && rect.maxY.isFinite
            && rect.width >= 0
            && rect.height >= 0
    }

    func maximumMetric(for bounds: CGRect) -> Double {
        let viewRelativeMaximum = max(Double(bounds.width), Double(bounds.height)) * 2
        guard viewRelativeMaximum.isFinite, viewRelativeMaximum > 0 else {
            return Self.absoluteMaximumScreenMetric
        }
        return min(viewRelativeMaximum, Self.absoluteMaximumScreenMetric)
    }

    func boundedMetric(_ value: Double, fallback: Double, maximum: Double) -> Double {
        let positiveValue = value.isFinite && value > 0 ? value : fallback
        return min(positiveValue, maximum)
    }

    func validColor(_ color: CanvasColor, fallback: CanvasColor) -> CanvasColor {
        validColor(color) ?? validColor(fallback) ?? .black
    }

    func validColor(_ color: CanvasColor) -> CanvasColor? {
        guard color.red.isFinite,
              color.green.isFinite,
              color.blue.isFinite,
              color.alpha.isFinite else {
            return nil
        }
        return CanvasColor(
            red: min(1, max(0, color.red)),
            green: min(1, max(0, color.green)),
            blue: min(1, max(0, color.blue)),
            alpha: min(1, max(0, color.alpha))
        )
    }

    func isValidPath(_ path: CanvasPath) -> Bool {
        path.commands.allSatisfy { command in
            switch command {
            case .move(let point), .line(let point):
                isFinite(point)
            case .quad(let control, let end):
                isFinite(control) && isFinite(end)
            case .cubic(let control1, let control2, let end):
                isFinite(control1) && isFinite(control2) && isFinite(end)
            case .close:
                true
            }
        }
    }

    func isFinite(_ point: CanvasPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }

    func isFinite(_ guide: SnapGuide) -> Bool {
        switch guide {
        case .vertical(let canvasX):
            canvasX.isFinite
        case .horizontal(let canvasY):
            canvasY.isFinite
        }
    }

    func cgPoint(_ point: CanvasPoint) -> CGPoint {
        CGPoint(x: point.x, y: point.y)
    }

    func cgRect(_ rect: CanvasRect) -> CGRect? {
        guard isValidCanvasRect(rect) else { return nil }
        let result = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        guard result.origin.x.isFinite,
              result.origin.y.isFinite,
              result.width.isFinite,
              result.height.isFinite,
              result.maxX.isFinite,
              result.maxY.isFinite else {
            return nil
        }
        return result
    }

    func selectionHandleRects(around rect: CGRect, handleSize: Double) -> [CGRect] {
        guard rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.width.isFinite,
              rect.height.isFinite,
              rect.minX.isFinite,
              rect.maxX.isFinite,
              rect.minY.isFinite,
              rect.maxY.isFinite,
              handleSize.isFinite,
              handleSize > 0 else {
            return []
        }
        let half = handleSize / 2
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY),
        ]
        return corners.compactMap { point in
            let handle = CGRect(
                x: point.x - half,
                y: point.y - half,
                width: handleSize,
                height: handleSize
            )
            guard handle.origin.x.isFinite,
                  handle.origin.y.isFinite,
                  handle.maxX.isFinite,
                  handle.maxY.isFinite else {
                return nil
            }
            return handle
        }
    }

    func cgColor(_ color: CanvasColor) -> CGColor {
        CGColor(
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            components: [color.red, color.green, color.blue, color.alpha]
        ) ?? UIColor.black.cgColor
    }
}

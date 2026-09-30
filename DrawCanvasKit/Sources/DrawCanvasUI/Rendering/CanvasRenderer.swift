import UIKit
import DrawCanvasCore

public struct CanvasThemeSnapshot: Hashable, Sendable {
    public var showsGrid = true
    public var showsSelectionHandles = true
    public var background: CanvasColor
    public var grid: CanvasColor
    public var stroke: CanvasColor
    public var selection: CanvasColor
    public var guides: CanvasColor
    public var eraserTarget: CanvasColor
    public var gridMajor: CanvasColor
    public var axis: CanvasColor
    public var selectionHandleFill: CanvasColor
    public var gridMinorDashPattern: [Double]
    public var selectionDashPattern: [Double]
    public var guideDashPattern: [Double]
    public var gridLineWidth: Double
    public var gridMajorLineWidth: Double
    public var axisLineWidth: Double
    public var selectionLineWidth: Double
    public var handleSize: Double
    public var selectionOutset: Double
    public var eraserTargetLineWidth: Double

    public init(
        background: CanvasColor,
        grid: CanvasColor,
        stroke: CanvasColor,
        selection: CanvasColor,
        guides: CanvasColor,
        gridLineWidth: Double,
        selectionLineWidth: Double,
        handleSize: Double,
        gridMajor: CanvasColor = .init(red: 0.72, green: 0.73, blue: 0.76),
        gridMajorLineWidth: Double = 1,
        axis: CanvasColor = .init(red: 0.58, green: 0.6, blue: 0.65),
        axisLineWidth: Double = 1,
        selectionOutset: Double = 4,
        selectionHandleFill: CanvasColor = .init(red: 1, green: 1, blue: 1),
        gridMinorDashPattern: [Double] = [1, 3],
        selectionDashPattern: [Double] = [4, 3],
        guideDashPattern: [Double] = [3, 4],
        eraserTarget: CanvasColor = .init(red: 0.95, green: 0.18, blue: 0.18, alpha: 0.9),
        eraserTargetLineWidth: Double = 4
    ) {
        self.background = background
        self.grid = grid
        self.stroke = stroke
        self.selection = selection
        self.guides = guides
        self.eraserTarget = eraserTarget
        self.gridMajor = gridMajor
        self.axis = axis
        self.selectionHandleFill = selectionHandleFill
        self.gridMinorDashPattern = gridMinorDashPattern
        self.selectionDashPattern = selectionDashPattern
        self.guideDashPattern = guideDashPattern
        self.gridLineWidth = gridLineWidth
        self.gridMajorLineWidth = gridMajorLineWidth
        self.axisLineWidth = axisLineWidth
        self.selectionLineWidth = selectionLineWidth
        self.handleSize = handleSize
        self.selectionOutset = selectionOutset
        self.eraserTargetLineWidth = eraserTargetLineWidth
    }
}

extension CanvasThemeSnapshot {
    func gridStyle(for tier: CanvasGridTier) -> (color: CanvasColor, width: Double, dash: [Double]) {
        switch tier {
        case .minor: (grid, gridLineWidth, Self.validDashPattern(gridMinorDashPattern))
        case .major: (gridMajor, gridMajorLineWidth, [])
        case .axis: (axis, axisLineWidth, [])
        }
    }

    static func validDashPattern(_ pattern: [Double]) -> [Double] {
        guard !pattern.isEmpty, pattern.allSatisfy({ $0.isFinite && $0 > 0 }),
              pattern.reduce(0, +).isFinite else { return [] }
        return pattern.count.isMultiple(of: 2) ? pattern : pattern + pattern
    }

    func selectionRect(_ bounds: CanvasRect, zoom: Double) -> CanvasRect {
        let inset = selectionOutset.isFinite && selectionOutset >= 0 ? selectionOutset / zoom : 0
        let expanded = CanvasRect(x: bounds.x - inset, y: bounds.y - inset,
                                  width: bounds.width + inset * 2, height: bounds.height + inset * 2)
        return expanded.isFinite ? expanded : bounds
    }
}

/// A view-backed renderer for backend-neutral prepared canvas scenes.
///
/// Prepared paths and geometry bounds are expressed in canvas coordinates. The scene's
/// viewport and theme contain the information needed to transform and style one display
/// pass. Text is intentionally absent: `DrawCanvasUI` owns all text display and editing in
/// UIKit overlays outside the renderer's view.
///
/// A geometry's ``CanvasPreparedGeometry/renderKey`` is its public model identity and may be
/// reused after content leaves and later re-enters a document. Custom backends must key derived
/// resources by ``CanvasPreparedGeometry/resourceIdentity``, which is stable while a prepared
/// node is reused and changes on every rebuild. Ink backends may additionally retain resources
/// by ``CanvasPreparedInk`` object identity to reuse finalized confirmed prefixes.
/// A renderer must update only a view returned by its own `makeRenderView` call and must ignore
/// any other view. Renderers that can confirm actual display completion should additionally
/// conform to ``CanvasDisplayReportingRenderer``.
@MainActor
public protocol CanvasRenderer: AnyObject {
    /// Creates a view owned by this renderer.
    func makeRenderView() -> UIView

    /// Enqueues a prepared scene for display in a view created by this renderer.
    ///
    /// The renderer must ignore `renderView` when it does not own that view.
    func update(_ scene: CanvasPreparedScene, in renderView: UIView)
}

@MainActor
protocol CanvasPreparedPresentationRendering: AnyObject {
    func update(_ presentation: CanvasPreparedPresentation, in renderView: UIView)
}

@MainActor
protocol CanvasRenderDismantling: AnyObject {
    func dismantleRenderView(_ renderView: UIView)
}

@MainActor
protocol CanvasRenderCacheResetting: AnyObject {
    func resetDerivedRenderCaches()
}

/// A canvas renderer that reports when a preview generation has completed its display pass.
///
/// `DrawCanvasUI` records input-to-display latency only for renderers conforming to this
/// protocol. This keeps the base ``CanvasRenderer`` contract source-compatible and prevents
/// non-reporting backends from accumulating intervals they cannot complete.
@MainActor
public protocol CanvasDisplayReportingRenderer: CanvasRenderer {
    /// Creates a renderer-owned view and installs its display-completion callback.
    ///
    /// After a display pass draws a scene with a non-`nil` preview generation, the renderer
    /// must invoke `displayCompletion` with that generation. Coalesced updates may
    /// report only the newest generation that was drawn because a cumulative preview also
    /// contains every earlier pending Pencil batch. The renderer must not report an enqueued,
    /// prepared, cancelled, or otherwise undisplayed generation as displayed.
    func makeRenderView(
        displayCompletion: @escaping (RecognitionGeneration) -> Void
    ) -> UIView
}

public extension CanvasDisplayReportingRenderer {
    /// Creates a renderer-owned view when the caller does not observe preview display latency.
    func makeRenderView() -> UIView {
        makeRenderView(displayCompletion: { _ in })
    }
}

/// A display-reporting renderer that also supplies a host-time completion timestamp.
///
/// Metal backends should report native drawable presentation time. Backends without a native
/// presentation callback may report the host time at which their drawing pass completed. A
/// physical acceptance gate must independently verify that its active backend uses native
/// presentation timestamps before treating this value as compositor-visible latency.
@MainActor
public protocol CanvasTimestampedDisplayReportingRenderer: CanvasDisplayReportingRenderer {
    func makeRenderView(
        displayCompletion: @escaping (RecognitionGeneration, TimeInterval) -> Void
    ) -> UIView
}

public extension CanvasTimestampedDisplayReportingRenderer {
    func makeRenderView(
        displayCompletion: @escaping (RecognitionGeneration) -> Void
    ) -> UIView {
        makeRenderView { generation, _ in displayCompletion(generation) }
    }
}

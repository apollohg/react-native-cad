import SwiftUI
import DrawCanvasCore

public struct CanvasDimensionStyle: Codable, Hashable, Sendable {
    public var labelFontSize = 12.0
    public var labelPadding = 3.0
    public var extensionOpacity = 0.2
    public var extensionLineWidthScale = 0.5
    public var edgeInset = 8.0
    public var laneGap = 8.0
    public var labelGap = 4.0
    public var extensionGap = 4.0
    public var extensionOvershoot = 4.0
    public var terminatorHalfLength = 5.0
    public var labelColor: CanvasColor?
    public var labelBackground: CanvasColor?
    public var extensionColor: CanvasColor?

    public init() {}

    var resolved: Self {
        var result = self
        let defaults = Self()
        for key in [\Self.labelFontSize, \.labelPadding, \.extensionLineWidthScale, \.edgeInset, \.laneGap, \.labelGap, \.extensionGap, \.extensionOvershoot, \.terminatorHalfLength] {
            let value = result[keyPath: key]
            if !value.isFinite || value < 0 || (key == \Self.labelFontSize && value == 0) {
                result[keyPath: key] = defaults[keyPath: key]
            }
        }
        result.extensionOpacity = extensionOpacity.isFinite ? min(1, max(0, extensionOpacity)) : defaults.extensionOpacity
        return result
    }
}

public struct CanvasTheme: Codable, Hashable, Sendable {
    public var dimensionStyle = CanvasDimensionStyle()
    public var controlTint: CanvasColor?
    public var inactiveToolTint: CanvasColor?
    public var background: CanvasColor
    public var grid: CanvasColor
    public var stroke: CanvasColor
    public var selection: CanvasColor
    public var guides: CanvasColor
    public var gridMajor: CanvasColor
    public var axis: CanvasColor
    public var selectionHandleFill: CanvasColor
    public var gridMinorDashPattern: [Double]
    public var selectionDashPattern: [Double]
    public var guideDashPattern: [Double]
    public var eraserTarget: CanvasColor
    public var dimensions: CanvasColor
    public var controlSpacing: Double
    public var gridLineWidth: Double
    public var gridMajorLineWidth: Double
    public var axisLineWidth: Double
    public var selectionLineWidth: Double
    public var dimensionLineWidth: Double
    public var handleSize: Double
    public var selectionOutset: Double
    public var eraserTargetLineWidth: Double

    public init(
        background: CanvasColor,
        grid: CanvasColor,
        stroke: CanvasColor,
        selection: CanvasColor,
        guides: CanvasColor,
        dimensions: CanvasColor,
        controlSpacing: Double,
        gridLineWidth: Double,
        selectionLineWidth: Double,
        dimensionLineWidth: Double,
        handleSize: Double,
        gridMajor: CanvasColor,
        axis: CanvasColor,
        gridMajorLineWidth: Double,
        axisLineWidth: Double,
        selectionOutset: Double = 4,
        selectionHandleFill: CanvasColor,
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
        self.gridMajor = gridMajor
        self.axis = axis
        self.selectionHandleFill = selectionHandleFill
        self.gridMinorDashPattern = gridMinorDashPattern
        self.selectionDashPattern = selectionDashPattern
        self.guideDashPattern = guideDashPattern
        self.eraserTarget = eraserTarget
        self.dimensions = dimensions
        self.controlSpacing = controlSpacing
        self.gridLineWidth = gridLineWidth
        self.gridMajorLineWidth = gridMajorLineWidth
        self.axisLineWidth = axisLineWidth
        self.selectionLineWidth = selectionLineWidth
        self.dimensionLineWidth = dimensionLineWidth
        self.handleSize = handleSize
        self.selectionOutset = selectionOutset
        self.eraserTargetLineWidth = eraserTargetLineWidth
    }

    public static let `default` = CanvasTheme(
        background: .init(red: 1, green: 1, blue: 1),
        grid: .init(red: 0.91, green: 0.91, blue: 0.93),
        stroke: .black,
        selection: .init(red: 0.1, green: 0.45, blue: 1),
        guides: .init(red: 0.95, green: 0.25, blue: 0.25),
        dimensions: .init(red: 0.16, green: 0.34, blue: 0.62),
        controlSpacing: 8,
        gridLineWidth: 1,
        selectionLineWidth: 1,
        dimensionLineWidth: 1,
        handleSize: 10,
        gridMajor: .init(red: 0.79, green: 0.8, blue: 0.83),
        axis: .init(red: 0.62, green: 0.64, blue: 0.69),
        gridMajorLineWidth: 1,
        axisLineWidth: 1,
        selectionHandleFill: .init(red: 1, green: 1, blue: 1)
    )

    public static let dark = CanvasTheme(
        background: .init(red: 0.08, green: 0.09, blue: 0.11),
        grid: .init(red: 0.16, green: 0.18, blue: 0.22),
        stroke: .init(red: 0.92, green: 0.93, blue: 0.95),
        selection: .init(red: 0.35, green: 0.65, blue: 1),
        guides: .init(red: 1, green: 0.4, blue: 0.4),
        dimensions: .init(red: 0.55, green: 0.72, blue: 1),
        controlSpacing: 8,
        gridLineWidth: 1,
        selectionLineWidth: 1,
        dimensionLineWidth: 1,
        handleSize: 10,
        gridMajor: .init(red: 0.27, green: 0.3, blue: 0.35),
        axis: .init(red: 0.42, green: 0.46, blue: 0.53),
        gridMajorLineWidth: 1,
        axisLineWidth: 1,
        selectionHandleFill: .init(red: 0.14, green: 0.16, blue: 0.2)
    )

    public var renderSnapshot: CanvasThemeSnapshot {
        CanvasThemeSnapshot(
            background: background,
            grid: grid,
            stroke: stroke,
            selection: selection,
            guides: guides,
            gridLineWidth: positiveOrDefault(gridLineWidth, default: 1),
            selectionLineWidth: positiveOrDefault(selectionLineWidth, default: 1),
            handleSize: positiveOrDefault(handleSize, default: 10),
            gridMajor: gridMajor,
            gridMajorLineWidth: positiveOrDefault(gridMajorLineWidth, default: 1),
            axis: axis,
            axisLineWidth: positiveOrDefault(axisLineWidth, default: 1),
            selectionOutset: positiveOrDefault(selectionOutset, default: 4),
            selectionHandleFill: selectionHandleFill,
            gridMinorDashPattern: gridMinorDashPattern,
            selectionDashPattern: selectionDashPattern,
            guideDashPattern: guideDashPattern,
            eraserTarget: eraserTarget,
            eraserTargetLineWidth: positiveOrDefault(eraserTargetLineWidth, default: 4)
        )
    }

    var safeControlSpacing: Double {
        positiveOrDefault(controlSpacing, default: Self.default.controlSpacing)
    }

    var safeDimensionLineWidth: Double {
        positiveOrDefault(dimensionLineWidth, default: Self.default.dimensionLineWidth)
    }
}

private func positiveOrDefault(_ value: Double, default fallback: Double) -> Double {
    value.isFinite && value > 0 ? value : fallback
}

private struct CanvasThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue = CanvasTheme.default
}

public extension EnvironmentValues {
    var canvasTheme: CanvasTheme {
        get { self[CanvasThemeEnvironmentKey.self] }
        set { self[CanvasThemeEnvironmentKey.self] = newValue }
    }
}

public extension View {
    func canvasTheme(_ theme: CanvasTheme) -> some View {
        environment(\.canvasTheme, theme)
    }
}

extension Color {
    init(canvasColor: CanvasColor) {
        self.init(
            .sRGB,
            red: canvasColor.red,
            green: canvasColor.green,
            blue: canvasColor.blue,
            opacity: canvasColor.alpha
        )
    }
}

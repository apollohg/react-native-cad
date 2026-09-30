import CadCanvasCore
import Foundation

public enum CanvasInputMode: String, Codable, CaseIterable, Hashable, Sendable {
    case pencil, touch, both
}

public enum CanvasFeature: String, Codable, CaseIterable, Hashable, Sendable {
    case measurements, dimensionEditing, calibration, grid, snapping, shapeRecognition
    case panning, zooming, selectionMovement, selectionResizing
    case deletion, duplication, clearing, history
    case strokeStyling, textStyling, inkStyling, pencilShortcuts
}

public enum CanvasControl: String, Codable, CaseIterable, Hashable, Sendable {
    case strokeColor, lineWidth, fill, pressure, widthScaling
    case textColor, fontFamily, fontSize
    case snapToGrid, gridSpacing, snapDistance
    case undo, redo, delete, duplicate, calibrate, zoomToFit, clear

    var requiredFeature: CanvasFeature {
        switch self {
        case .strokeColor, .lineWidth, .fill: .strokeStyling
        case .pressure, .widthScaling: .inkStyling
        case .textColor, .fontFamily, .fontSize: .textStyling
        case .snapToGrid, .snapDistance: .snapping
        case .gridSpacing: .grid
        case .undo, .redo: .history
        case .delete: .deletion
        case .duplicate: .duplication
        case .calibrate: .calibration
        case .zoomToFit: .zooming
        case .clear: .clearing
        }
    }
}

public struct CanvasControlRange: Codable, Hashable, Sendable {
    public var bounds: ClosedRange<Double>
    public var step: Double

    public init(_ bounds: ClosedRange<Double>, step: Double) {
        self.bounds = bounds
        self.step = step
    }

    func validate(field: String, allowsZero: Bool = false) throws {
        guard bounds.lowerBound.isFinite, bounds.upperBound.isFinite,
            allowsZero ? bounds.lowerBound >= 0 : bounds.lowerBound > 0,
            step.isFinite, step > 0
        else {
            throw CanvasValidationError(field: field, reason: "requires finite positive bounds and step")
        }
    }
}

public enum CanvasControlButtonAppearance: String, Codable, CaseIterable, Hashable, Sendable {
    case bordered, borderless, prominent
}

public struct CanvasControlsConfiguration: Codable, Hashable, Sendable {
    public var visibleTools: [CanvasTool] = CanvasTool.allCases
    public var visibleControls: Set<CanvasControl> = Set(CanvasControl.allCases)
    public var lineWidth = CanvasControlRange(0.5...20, step: 0.5)
    public var fontSize = CanvasControlRange(8...72, step: 1)
    public var gridSpacing = CanvasControlRange(2...200, step: 1)
    public var snapDistance = CanvasControlRange(0...32, step: 1)
    public var fontFamilies = ["Helvetica", "Helvetica Neue", "Avenir Next"]
    public var buttonAppearance: CanvasControlButtonAppearance = .bordered
    public var confirmsClear = true

    public init() {}

    func validate() throws {
        try lineWidth.validate(field: "controls.lineWidth")
        try fontSize.validate(field: "controls.fontSize")
        try gridSpacing.validate(field: "controls.gridSpacing")
        try snapDistance.validate(field: "controls.snapDistance", allowsZero: true)
        guard !fontFamilies.isEmpty,
            fontFamilies.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
            Set(fontFamilies).count == fontFamilies.count,
            Set(visibleTools).count == visibleTools.count
        else {
            throw CanvasValidationError(
                field: "controls", reason: "requires unique tools and nonempty unique font names")
        }
    }
}

public enum CanvasMeasurementUnit: String, Codable, CaseIterable, Hashable, Sendable {
    case millimeters, centimeters, meters, inches, feet

    public var symbol: String {
        switch self {
        case .millimeters: "mm"
        case .centimeters: "cm"
        case .meters: "m"
        case .inches: "in"
        case .feet: "ft"
        }
    }

    public var millimetersPerUnit: Double {
        switch self {
        case .millimeters: 1
        case .centimeters: 10
        case .meters: 1_000
        case .inches: 25.4
        case .feet: 304.8
        }
    }
}

public struct CanvasMeasurementsConfiguration: Codable, Hashable, Sendable {
    public var axes: Set<DimensionAxis> = [.horizontal, .vertical]
    public var roles: Set<DimensionRole> = [.element, .gap, .merged, .overall]
    public var showsExtensionLines = true
    public var allowsHiding = true
    public var unit: CanvasMeasurementUnit = .millimeters
    public var fractionDigits = 2

    public init() {}

    func validate() throws {
        guard (0...Self.maximumFractionDigits).contains(fractionDigits) else {
            throw CanvasValidationError(
                field: "measurements.fractionDigits", reason: "must be between 0 and \(Self.maximumFractionDigits)")
        }
    }

    private static let maximumFractionDigits = 6
}

public struct CanvasConfiguration: Codable, Hashable, Sendable {
    public var inputMode: CanvasInputMode = .pencil
    public var enabledTools: Set<CanvasTool> = Set(CanvasTool.allCases)
    public var enabledFeatures: Set<CanvasFeature> = Set(CanvasFeature.allCases)
    public var controls = CanvasControlsConfiguration()
    public var measurements = CanvasMeasurementsConfiguration()
    public var showsSnapGuides = true
    public var showsSelection = true
    public var showsEraserTarget = true

    public init() {}

    public static let `default` = CanvasConfiguration()

    public func allows(_ feature: CanvasFeature) -> Bool {
        enabledFeatures.contains(feature)
    }

    public func allows(_ tool: CanvasTool) -> Bool {
        enabledTools.contains(tool) && (tool != .eraser || allows(.deletion))
    }

    public func shows(_ control: CanvasControl) -> Bool {
        controls.visibleControls.contains(control) && allows(control.requiredFeature)
    }

    public var availableTools: [CanvasTool] {
        controls.visibleTools.filter { allows($0) }
    }

    public func validate() throws {
        try controls.validate()
        try measurements.validate()
    }
}

extension CanvasTool {
    static func tool(for geometry: CanvasGeometry) -> CanvasTool {
        switch geometry {
        case .line: .line
        case .rectangle: .rectangle
        case .arch: .arch
        case .freehand: .freehand
        case .text: .text
        }
    }
}

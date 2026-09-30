import Foundation

public enum DimensionAxis: String, Codable, Hashable, Sendable {
    case horizontal
    case vertical
}

public enum DimensionRole: String, Codable, Hashable, Sendable {
    case element
    case gap
    case merged
    case overall
}

public struct DimensionKey: Hashable, Sendable {
    public var axis: DimensionAxis
    public var role: DimensionRole
    public var elementIDs: [UUID] {
        didSet {
            elementIDs = Self.sortedIDs(elementIDs)
        }
    }
    public var startEdge: Double {
        didSet {
            startEdge = Self.quantizedEdge(startEdge)
        }
    }
    public var endEdge: Double {
        didSet {
            endEdge = Self.quantizedEdge(endEdge)
        }
    }

    public init(
        axis: DimensionAxis,
        role: DimensionRole,
        elementIDs: [UUID],
        startEdge: Double,
        endEdge: Double
    ) {
        self.axis = axis
        self.role = role
        self.elementIDs = Self.sortedIDs(elementIDs)
        self.startEdge = Self.quantizedEdge(startEdge)
        self.endEdge = Self.quantizedEdge(endEdge)
    }

    private static func sortedIDs(_ ids: [UUID]) -> [UUID] {
        ids.sorted { $0.uuidString < $1.uuidString }
    }

    private static func quantizedEdge(_ value: Double) -> Double {
        guard value.isFinite else {
            return value
        }

        let scale = 1_000_000.0
        guard abs(value) <= Double.greatestFiniteMagnitude / scale else {
            return value
        }

        let quantized = (value * scale).rounded() / scale
        return quantized == 0 ? 0 : quantized
    }
}

public struct ProjectedDimension: Hashable, Sendable {
    public var key: DimensionKey
    public var canvasLength: Double
    public var millimeters: Double
    public var screenStart: CanvasPoint
    public var screenEnd: CanvasPoint
    public var isEditable: Bool

    public init(
        key: DimensionKey,
        canvasLength: Double,
        millimeters: Double,
        screenStart: CanvasPoint,
        screenEnd: CanvasPoint,
        isEditable: Bool
    ) {
        self.key = key
        self.canvasLength = canvasLength
        self.millimeters = millimeters
        self.screenStart = screenStart
        self.screenEnd = screenEnd
        self.isEditable = isEditable
    }

    public var isGap: Bool { key.role == .gap }
    public var isMerged: Bool { key.role == .merged }
    public var isOverall: Bool { key.role == .overall }
}

public struct CanvasDimensionSpan: Hashable, Sendable {
    public let key: DimensionKey
    public let canvasStart: CanvasPoint
    public let canvasEnd: CanvasPoint
    public let millimeters: Double
    public let isEditable: Bool
    public let extensionStart: CanvasPoint?
    public let extensionEnd: CanvasPoint?

    public init(
        key: DimensionKey,
        canvasStart: CanvasPoint,
        canvasEnd: CanvasPoint,
        millimeters: Double,
        isEditable: Bool,
        extensionStart: CanvasPoint? = nil,
        extensionEnd: CanvasPoint? = nil
    ) {
        self.key = key
        self.canvasStart = canvasStart
        self.canvasEnd = canvasEnd
        self.millimeters = millimeters
        self.isEditable = isEditable
        self.extensionStart = extensionStart
        self.extensionEnd = extensionEnd
    }

    public var canvasLength: Double {
        switch key.axis {
        case .horizontal: abs(canvasEnd.x - canvasStart.x)
        case .vertical: abs(canvasEnd.y - canvasStart.y)
        }
    }
}

public struct CanvasDimensionStructure: Hashable, Sendable {
    public let horizontal: [CanvasDimensionSpan]
    public let vertical: [CanvasDimensionSpan]

    public var all: [CanvasDimensionSpan] { horizontal + vertical }

    public init(horizontal: [CanvasDimensionSpan], vertical: [CanvasDimensionSpan]) {
        self.horizontal = horizontal
        self.vertical = vertical
    }
}

public struct DimensionLayout: Hashable, Sendable {
    public var horizontal: [ProjectedDimension]
    public var vertical: [ProjectedDimension]

    public var all: [ProjectedDimension] {
        horizontal + vertical
    }

    public init(horizontal: [ProjectedDimension], vertical: [ProjectedDimension]) {
        self.horizontal = horizontal
        self.vertical = vertical
    }
}

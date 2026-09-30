import Foundation

public struct CanvasLine: Codable, Hashable, Sendable {
    public var start: CanvasPoint
    public var end: CanvasPoint

    public init(start: CanvasPoint, end: CanvasPoint) {
        self.start = start
        self.end = end
    }
}

public struct CanvasRectangle: Codable, Hashable, Sendable {
    public var rect: CanvasRect

    public init(rect: CanvasRect) {
        self.rect = rect
    }
}

public struct CanvasArch: Codable, Hashable, Sendable {
    public var start: CanvasPoint
    public var end: CanvasPoint
    public var sagitta: Double

    public init(start: CanvasPoint, end: CanvasPoint, sagitta: Double) {
        self.start = start
        self.end = end
        self.sagitta = sagitta
    }
}

public struct CanvasText: Codable, Hashable, Sendable {
    public var frame: CanvasRect
    public var text: String
    public var font: CanvasFont
    public var color: CanvasColor

    public init(frame: CanvasRect, text: String, font: CanvasFont, color: CanvasColor) {
        self.frame = frame
        self.text = text
        self.font = font
        self.color = color
    }
}

public enum CanvasGeometry: Codable, Hashable, Sendable {
    case line(CanvasLine)
    case rectangle(CanvasRectangle)
    case arch(CanvasArch)
    case freehand(CanvasInkStroke)
    case text(CanvasText)
}

public struct CanvasStyle: Codable, Hashable, Sendable {
    public var stroke: CanvasColor
    public var fill: CanvasColor?
    public var lineWidth: Double

    public init(stroke: CanvasColor, fill: CanvasColor? = nil, lineWidth: Double) {
        self.stroke = stroke
        self.fill = fill
        self.lineWidth = lineWidth
    }

    public static let `default`: CanvasStyle = .init(stroke: .black, lineWidth: 1)
}

public struct CanvasElement: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var contentRevision: UInt64
    public var geometry: CanvasGeometry
    public var style: CanvasStyle

    public init(
        id: UUID,
        contentRevision: UInt64 = 0,
        geometry: CanvasGeometry,
        style: CanvasStyle = .default
    ) {
        self.id = id
        self.contentRevision = contentRevision
        self.geometry = geometry
        self.style = style
    }

    public static func rectangle(
        id: UUID,
        rect: CanvasRect,
        style: CanvasStyle = .default
    ) -> CanvasElement {
        CanvasElement(id: id, geometry: .rectangle(.init(rect: rect)), style: style)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

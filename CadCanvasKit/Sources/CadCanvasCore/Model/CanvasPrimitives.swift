import Foundation

public struct CanvasValidationError: Swift.Error, CustomStringConvertible, Equatable, Sendable {
    public let field: String
    public let reason: String

    public init(field: String, reason: String) {
        self.field = field
        self.reason = reason
    }

    public var description: String { "\(field): \(reason)" }
}

@inline(__always)
func requireFinite(_ value: Double, field: String) throws {
    guard value.isFinite else {
        throw CanvasValidationError(field: field, reason: "must be finite")
    }
}

public struct CanvasPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public init(validatingX x: Double, y: Double) throws {
        try requireFinite(x, field: "x")
        try requireFinite(y, field: "y")
        self.init(x: x, y: y)
    }
}

public struct CanvasSize: Codable, Hashable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct CanvasRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public var minX: Double { x }
    public var maxX: Double { x + width }
    public var minY: Double { y }
    public var maxY: Double { y + height }

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct CanvasColor: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let black: CanvasColor = .init(red: 0, green: 0, blue: 0)
}

public struct CanvasFont: Codable, Hashable, Sendable {
    public var familyName: String
    public var pointSize: Double

    public init(familyName: String, pointSize: Double) {
        self.familyName = familyName
        self.pointSize = pointSize
    }
}

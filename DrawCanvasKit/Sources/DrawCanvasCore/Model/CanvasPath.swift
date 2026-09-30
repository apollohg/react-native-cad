import Foundation

public enum CanvasPathCommand: Codable, Hashable, Sendable {
    case move(CanvasPoint)
    case line(CanvasPoint)
    case quad(control: CanvasPoint, end: CanvasPoint)
    case cubic(control1: CanvasPoint, control2: CanvasPoint, end: CanvasPoint)
    case close
}

public struct CanvasPath: Codable, Hashable, Sendable {
    public var commands: [CanvasPathCommand]

    public init(commands: [CanvasPathCommand]) {
        self.commands = commands
    }
}

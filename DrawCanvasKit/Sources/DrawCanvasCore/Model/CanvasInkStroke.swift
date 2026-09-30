import Foundation

public struct CanvasInkSample: Codable, Hashable, Sendable {
    public var point: CanvasPoint
    public var pressure: Double

    public init(point: CanvasPoint, pressure: Double) {
        self.point = point
        self.pressure = pressure
    }
}

public enum CanvasInkWidthMode: String, Codable, Hashable, Sendable {
    case canvasScaled
    case screenConstant
}

public struct CanvasInkStroke: Codable, Hashable, Sendable {
    public var samples: [CanvasInkSample]
    public var pressureEnabled: Bool
    public var widthMode: CanvasInkWidthMode

    private enum CodingKeys: String, CodingKey {
        case samples
        case pressureEnabled
        case widthMode
        case commands
    }

    public init(
        samples: [CanvasInkSample],
        pressureEnabled: Bool,
        widthMode: CanvasInkWidthMode = .canvasScaled
    ) {
        self.samples = samples
        self.pressureEnabled = pressureEnabled
        self.widthMode = widthMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard !container.contains(.commands) else {
            throw DecodingError.dataCorruptedError(
                forKey: .commands,
                in: container,
                debugDescription: "Legacy freehand commands are not supported"
            )
        }
        samples = try container.decode([CanvasInkSample].self, forKey: .samples)
        pressureEnabled = try container.decode(Bool.self, forKey: .pressureEnabled)
        widthMode = try container.decodeIfPresent(CanvasInkWidthMode.self, forKey: .widthMode) ?? .canvasScaled
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(samples, forKey: .samples)
        try container.encode(pressureEnabled, forKey: .pressureEnabled)
        try container.encode(widthMode, forKey: .widthMode)
    }

    public var points: [CanvasPoint] { samples.map(\.point) }

    public var bounds: CanvasRect {
        guard let first = samples.first?.point else {
            return CanvasRect(x: 0, y: 0, width: 0, height: 0)
        }

        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for sample in samples.dropFirst() {
            minX = min(minX, sample.point.x)
            maxX = max(maxX, sample.point.x)
            minY = min(minY, sample.point.y)
            maxY = max(maxY, sample.point.y)
        }
        return CanvasRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

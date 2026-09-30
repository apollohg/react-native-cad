import Foundation

private enum TaggedCodingKeys: String, CodingKey, CaseIterable {
    case type
    case line
    case rectangle
    case arch
    case freehand
    case text
    case move
    case end
    case control
    case control1
    case control2
}

private enum GeometryTag: String, Codable {
    case line
    case rectangle
    case arch
    case freehand
    case text
}

private enum PathCommandTag: String, Codable {
    case move
    case line
    case quad
    case cubic
    case close
}

extension CanvasGeometry {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: TaggedCodingKeys.self)
        let tag = try container.decode(GeometryTag.self, forKey: .type)
        let payloadKeys: Set<TaggedCodingKeys> = [.line, .rectangle, .arch, .freehand, .text]
        let presentPayloads = Set(payloadKeys.filter(container.contains))
        let expectedKey: TaggedCodingKeys

        switch tag {
        case .line:
            expectedKey = .line
        case .rectangle:
            expectedKey = .rectangle
        case .arch:
            expectedKey = .arch
        case .freehand:
            expectedKey = .freehand
        case .text:
            expectedKey = .text
        }

        guard presentPayloads == [expectedKey] else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Geometry tag and payload must match exactly"
            )
        }

        switch tag {
        case .line:
            self = .line(try container.decode(CanvasLine.self, forKey: .line))
        case .rectangle:
            self = .rectangle(try container.decode(CanvasRectangle.self, forKey: .rectangle))
        case .arch:
            self = .arch(try container.decode(CanvasArch.self, forKey: .arch))
        case .freehand:
            self = .freehand(try container.decode(CanvasInkStroke.self, forKey: .freehand))
        case .text:
            self = .text(try container.decode(CanvasText.self, forKey: .text))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: TaggedCodingKeys.self)
        switch self {
        case .line(let value):
            try container.encode(GeometryTag.line, forKey: .type)
            try container.encode(value, forKey: .line)
        case .rectangle(let value):
            try container.encode(GeometryTag.rectangle, forKey: .type)
            try container.encode(value, forKey: .rectangle)
        case .arch(let value):
            try container.encode(GeometryTag.arch, forKey: .type)
            try container.encode(value, forKey: .arch)
        case .freehand(let value):
            try container.encode(GeometryTag.freehand, forKey: .type)
            try container.encode(value, forKey: .freehand)
        case .text(let value):
            try container.encode(GeometryTag.text, forKey: .type)
            try container.encode(value, forKey: .text)
        }
    }
}

extension CanvasPathCommand {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: TaggedCodingKeys.self)
        let tag = try container.decode(PathCommandTag.self, forKey: .type)
        let payloadKeys: Set<TaggedCodingKeys> = [.move, .end, .control, .control1, .control2]
        let presentPayloads = Set(payloadKeys.filter(container.contains))
        let expectedPayloads: Set<TaggedCodingKeys>

        switch tag {
        case .move:
            expectedPayloads = [.move]
        case .line:
            expectedPayloads = [.end]
        case .quad:
            expectedPayloads = [.control, .end]
        case .cubic:
            expectedPayloads = [.control1, .control2, .end]
        case .close:
            expectedPayloads = []
        }

        guard presentPayloads == expectedPayloads else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Path command tag and payload must match exactly"
            )
        }

        switch tag {
        case .move:
            self = .move(try container.decode(CanvasPoint.self, forKey: .move))
        case .line:
            self = .line(try container.decode(CanvasPoint.self, forKey: .end))
        case .quad:
            self = .quad(
                control: try container.decode(CanvasPoint.self, forKey: .control),
                end: try container.decode(CanvasPoint.self, forKey: .end)
            )
        case .cubic:
            self = .cubic(
                control1: try container.decode(CanvasPoint.self, forKey: .control1),
                control2: try container.decode(CanvasPoint.self, forKey: .control2),
                end: try container.decode(CanvasPoint.self, forKey: .end)
            )
        case .close:
            self = .close
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: TaggedCodingKeys.self)
        switch self {
        case .move(let point):
            try container.encode(PathCommandTag.move, forKey: .type)
            try container.encode(point, forKey: .move)
        case .line(let point):
            try container.encode(PathCommandTag.line, forKey: .type)
            try container.encode(point, forKey: .end)
        case .quad(let control, let end):
            try container.encode(PathCommandTag.quad, forKey: .type)
            try container.encode(control, forKey: .control)
            try container.encode(end, forKey: .end)
        case .cubic(let control1, let control2, let end):
            try container.encode(PathCommandTag.cubic, forKey: .type)
            try container.encode(control1, forKey: .control1)
            try container.encode(control2, forKey: .control2)
            try container.encode(end, forKey: .end)
        case .close:
            try container.encode(PathCommandTag.close, forKey: .type)
        }
    }
}

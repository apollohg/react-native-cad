import Foundation

public struct CanvasCalibration: Codable, Hashable, Sendable {
    public var millimetersPerPoint: Double

    public init(millimetersPerPoint: Double) {
        self.millimetersPerPoint = millimetersPerPoint
    }

    public init(validatingMillimetersPerPoint value: Double) throws {
        try requireFinite(value, field: "millimetersPerPoint")
        guard value > 0 else {
            throw CanvasValidationError(field: "millimetersPerPoint", reason: "must be greater than zero")
        }
        self.init(millimetersPerPoint: value)
    }
}

public struct CanvasDocument: Codable, Sendable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public let id: UUID
    public var revision: UInt64
    public var elements: [CanvasElement]
    public var calibration: CanvasCalibration

    public init(
        schemaVersion: Int = CanvasDocument.currentSchemaVersion,
        id: UUID = UUID(),
        revision: UInt64 = 0,
        elements: [CanvasElement] = [],
        calibration: CanvasCalibration = .init(millimetersPerPoint: 1)
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.revision = revision
        self.elements = elements
        self.calibration = calibration
    }

    public static func empty() -> CanvasDocument {
        CanvasDocument()
    }

    public func validate() throws {
        try validateEnvelope()

        var elementIDs = Set<UUID>()
        for (index, element) in elements.enumerated() {
            let field = "elements[\(index)]"
            guard elementIDs.insert(element.id).inserted else {
                throw CanvasValidationError(field: "\(field).id", reason: "must be unique")
            }
            try element.validate(field: field)
        }
    }

    package func validateInsertion(at index: Int) throws {
        try validateEnvelope()
        guard elements.indices.contains(index) else {
            throw CanvasCommandError.invalidIndex(index)
        }
        let element = elements[index]
        guard elements.enumerated().allSatisfy({ offset, candidate in
            offset == index || candidate.id != element.id
        }) else {
            throw CanvasCommandError.duplicateElement(element.id)
        }
        try element.validate(field: "elements[\(index)]")
    }

    package func validateEnvelope() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw CanvasValidationError(field: "schemaVersion", reason: "must equal \(Self.currentSchemaVersion)")
        }
        guard revision != .max else {
            throw CanvasValidationError(field: "revision", reason: "must allow a subsequent increment")
        }
        try calibration.validate(field: "calibration")
    }
}

extension UInt64 {
    var nextValidCanvasRevision: UInt64? {
        guard self < UInt64.max - 1 else {
            return nil
        }
        return self + 1
    }
}

private extension CanvasCalibration {
    func validate(field: String) throws {
        try requireFinite(millimetersPerPoint, field: "\(field).millimetersPerPoint")
        guard millimetersPerPoint > 0 else {
            throw CanvasValidationError(field: "\(field).millimetersPerPoint", reason: "must be greater than zero")
        }
    }
}

private extension CanvasElement {
    func validate(field: String) throws {
        guard contentRevision != .max else {
            throw CanvasValidationError(field: "\(field).contentRevision", reason: "must allow a subsequent increment")
        }
        try geometry.validate(field: "\(field).geometry")
        try style.validate(field: "\(field).style")
    }
}

private extension CanvasGeometry {
    func validate(field: String) throws {
        switch self {
        case .line(let line):
            try line.start.validate(field: "\(field).line.start")
            try line.end.validate(field: "\(field).line.end")
        case .rectangle(let rectangle):
            try rectangle.rect.validate(field: "\(field).rectangle.rect")
        case .arch(let arch):
            try arch.start.validate(field: "\(field).arch.start")
            try arch.end.validate(field: "\(field).arch.end")
            try requireFinite(arch.sagitta, field: "\(field).arch.sagitta")
            guard (try? ArchGeometry.parameters(for: arch)) != nil,
                  let bounds = try? ArchGeometry.bounds(for: arch),
                  bounds.isFinite else {
                throw CanvasValidationError(
                    field: "\(field).arch",
                    reason: "must describe a renderable arch"
                )
            }
        case .freehand(let stroke):
            for (index, sample) in stroke.samples.enumerated() {
                let sampleField = "\(field).freehand.samples[\(index)]"
                try sample.point.validate(field: "\(sampleField).point")
                try requireFinite(sample.pressure, field: "\(sampleField).pressure")
                guard (0 ... 1).contains(sample.pressure) else {
                    throw CanvasValidationError(
                        field: "\(sampleField).pressure",
                        reason: "must be between zero and one"
                    )
                }
            }
        case .text(let text):
            try text.frame.validate(field: "\(field).text.frame")
            try text.font.validate(field: "\(field).text.font")
            try text.color.validate(field: "\(field).text.color")
        }
    }
}

extension CanvasStyle {
    public func validate() throws {
        try validate(field: "style")
    }

    func validate(field: String) throws {
        try stroke.validate(field: "\(field).stroke")
        try fill?.validate(field: "\(field).fill")
        try requireFinite(lineWidth, field: "\(field).lineWidth")
        guard lineWidth > 0 else {
            throw CanvasValidationError(field: "\(field).lineWidth", reason: "must be greater than zero")
        }
    }
}

private extension CanvasPoint {
    func validate(field: String) throws {
        try requireFinite(x, field: "\(field).x")
        try requireFinite(y, field: "\(field).y")
    }
}

private extension CanvasRect {
    func validate(field: String) throws {
        try requireFinite(x, field: "\(field).x")
        try requireFinite(y, field: "\(field).y")
        try requireFinite(width, field: "\(field).width")
        try requireFinite(height, field: "\(field).height")
        guard width >= 0 else {
            throw CanvasValidationError(field: "\(field).width", reason: "must not be negative")
        }
        guard height >= 0 else {
            throw CanvasValidationError(field: "\(field).height", reason: "must not be negative")
        }
        guard maxX.isFinite, maxY.isFinite else {
            throw CanvasValidationError(field: field, reason: "derived bounds must be finite")
        }
    }
}

extension CanvasColor {
    public func validate() throws {
        try validate(field: "color")
    }

    func validate(field: String) throws {
        try validate(red, field: "\(field).red")
        try validate(green, field: "\(field).green")
        try validate(blue, field: "\(field).blue")
        try validate(alpha, field: "\(field).alpha")
    }

    func validate(_ component: Double, field: String) throws {
        try requireFinite(component, field: field)
        guard (0 ... 1).contains(component) else {
            throw CanvasValidationError(field: field, reason: "must be between zero and one")
        }
    }
}

extension CanvasFont {
    public func validate() throws {
        try validate(field: "font")
    }

    func validate(field: String) throws {
        try requireFinite(pointSize, field: "\(field).pointSize")
        guard pointSize > 0 else {
            throw CanvasValidationError(field: "\(field).pointSize", reason: "must be greater than zero")
        }
    }
}

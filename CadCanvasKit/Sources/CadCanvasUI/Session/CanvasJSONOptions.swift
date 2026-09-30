import CadCanvasCore
import Foundation

public struct CanvasJSONOptions: Codable, Sendable {
    public var configuration: CanvasConfiguration = .default
    public var theme: CanvasTheme = .default
    public var strokeStyle: CanvasStyle = .default
    public var inkConfiguration: CanvasInkConfiguration = .default
    public var textStyle: CanvasTextStyle = .default
    public var snapConfiguration = SnapConfiguration(screenThreshold: 8, gridSpacing: 10, snapToGrid: false)

    public init() {}

    public static func decode(_ json: String) throws -> Self {
        let data = Data(json.utf8)
        guard let overrides = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CanvasValidationError(field: "options", reason: "requires a JSON object")
        }
        let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Self())) as! [String: Any]
        let merged = merge(defaults, overrides)
        let result = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: merged))
        try result.validate()
        return result
    }

    public func validate() throws {
        try configuration.validate()
        try strokeStyle.validate()
        try textStyle.validate()
        try snapConfiguration.validate()
    }

    @MainActor
    public func apply(to session: CanvasSession) throws {
        // Validate everything before changing any live session state.
        try validate()
        try session.setConfiguration(configuration)
        try session.setStrokeStyle(strokeStyle)
        session.setInkConfiguration(inkConfiguration)
        try session.setTextStyle(textStyle)
        try session.setSnapConfiguration(snapConfiguration)
    }

    private static func merge(_ defaults: [String: Any], _ overrides: [String: Any]) -> [String: Any] {
        var result = defaults
        for (key, value) in overrides {
            if let object = value as? [String: Any], let base = defaults[key] as? [String: Any] {
                result[key] = merge(base, object)
            } else {
                result[key] = value
            }
        }
        return result
    }
}

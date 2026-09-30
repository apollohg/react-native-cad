import Foundation

package enum CanvasDecimalParser {
    package static func parsePositiveFinite(
        _ text: String,
        locale: Locale = .current
    ) -> Double? {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return nil }
        let style = FloatingPointFormatStyle<Double>(locale: locale)
        guard let value = try? Double(source, format: style, lenient: false),
              value.isFinite, value > 0 else { return nil }
        return value
    }
}

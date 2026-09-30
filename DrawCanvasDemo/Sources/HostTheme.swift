import SwiftUI
import DrawCanvasCore
import DrawCanvasUI

struct HostCreationStyles: Equatable {
    let stroke: CanvasStyle
    let text: CanvasTextStyle
}

enum HostTheme: String, CaseIterable, Identifiable {
    case light
    case dark

    var id: Self { self }
    var label: String { rawValue.capitalized }

    var canvasTheme: CanvasTheme {
        switch self {
        case .light: .default
        case .dark: .dark
        }
    }

    var colorScheme: ColorScheme {
        switch self {
        case .light: .light
        case .dark: .dark
        }
    }

    var creationStyles: HostCreationStyles {
        switch self {
        case .light:
            .init(stroke: .default, text: .default)
        case .dark:
            .init(
                stroke: .init(
                    stroke: .init(red: 0.92, green: 0.93, blue: 0.95),
                    lineWidth: 1
                ),
                text: .init(
                    font: CanvasTextStyle.default.font,
                    color: .init(red: 0.92, green: 0.93, blue: 0.95)
                )
            )
        }
    }
}

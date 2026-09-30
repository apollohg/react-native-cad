import SwiftUI

enum CanvasControlStyleSection: Hashable {
    case none
    case stroke(allowsFill: Bool)
    case freehand
    case text
}

enum CanvasControlSectionKind: Hashable {
    case tools
    case style(CanvasControlStyleSection)
    case gridAndSnap
    case edit
    case clear
}

enum CanvasControlLayoutPolicy {
    static func columnCount(for dynamicTypeSize: DynamicTypeSize) -> Int {
        dynamicTypeSize.isAccessibilitySize ? 1 : 2
    }

    static func columns(
        for dynamicTypeSize: DynamicTypeSize,
        spacing: CGFloat = 8
    ) -> [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: spacing, alignment: .top),
            count: columnCount(for: dynamicTypeSize)
        )
    }

    static func styleSection(for tool: CanvasTool) -> CanvasControlStyleSection {
        switch tool {
        case .select, .eraser:
            .none
        case .line:
            .stroke(allowsFill: false)
        case .freehand:
            .freehand
        case .rectangle, .arch:
            .stroke(allowsFill: true)
        case .text:
            .text
        }
    }

    static func symbolName(for tool: CanvasTool) -> String {
        switch tool {
        case .select:
            "cursorarrow"
        case .line:
            "line.diagonal"
        case .rectangle:
            "rectangle"
        case .arch:
            "rainbow"
        case .freehand:
            "pencil.tip"
        case .text:
            "textformat"
        case .eraser:
            "eraser.fill"
        }
    }

    static func pressureAccessibilityValue(isEnabled: Bool) -> String {
        isEnabled ? "On" : "Off"
    }

    static func sections(for tool: CanvasTool, configuration: CanvasConfiguration = .default) -> [CanvasControlSectionKind] {
        var result: [CanvasControlSectionKind] = [.tools]
        let style = styleSection(for: tool)
        if style != .none {
            result.append(.style(style))
        }
        result.append(contentsOf: [.gridAndSnap, .edit, .clear])
        return result.filter { section in
            let controls: [CanvasControl]
            switch section {
            case .tools: return !configuration.availableTools.isEmpty
            case .style(.none): return false
            case .style(.stroke(let fill)): controls = [.strokeColor, .lineWidth] + (fill ? [.fill] : [])
            case .style(.freehand): controls = [.strokeColor, .lineWidth, .pressure, .widthScaling]
            case .style(.text): controls = [.textColor, .fontFamily, .fontSize]
            case .gridAndSnap: controls = [.snapToGrid, .gridSpacing, .snapDistance]
            case .edit: controls = [.undo, .redo, .delete, .duplicate, .calibrate, .zoomToFit]
            case .clear: controls = [.clear]
            }
            return controls.contains { configuration.shows($0) }
        }
    }
}

public enum CanvasInspectorPresentationPolicy {
    public static func shouldPresent(
        for horizontalSizeClass: UserInterfaceSizeClass?
    ) -> Bool {
        horizontalSizeClass == .regular
    }

    public static func shouldPlaceSupplementaryContentInInspector(
        for contentWidth: CGFloat,
        dynamicTypeSize: DynamicTypeSize
    ) -> Bool {
        if dynamicTypeSize.isAccessibilitySize {
            return true
        }

        let minimumInlineWidth: CGFloat
        switch dynamicTypeSize {
        case .xLarge, .xxLarge, .xxxLarge:
            minimumInlineWidth = 720
        default:
            minimumInlineWidth = 600
        }

        return contentWidth < minimumInlineWidth
    }
}

import SwiftUI

package enum CanvasPencilInkControlKind: Equatable {
    case stroke(allowsFill: Bool)
    case text
}

@MainActor
package struct CanvasPencilInkPalette: View {
    private let actions: CanvasActions
    @Environment(\.canvasTheme) private var theme

    package init(actions: CanvasActions, styleTool _: CanvasTool) {
        self.actions = actions
    }

    package var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.safeControlSpacing) {
                Text("Ink Attributes")
                    .font(.headline)
                switch Self.controlKind(for: effectiveStyleTool) {
                case .stroke(let allowsFill):
                    CanvasStrokeStyleControls(
                        actions: actions,
                        allowsFill: allowsFill,
                        showsPressure: effectiveStyleTool == .freehand
                    )
                case .text:
                    CanvasTextStyleControls(actions: actions)
                }
            }
            .padding(theme.safeControlSpacing * 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
    }

    package static func controlKind(for tool: CanvasTool) -> CanvasPencilInkControlKind {
        switch tool {
        case .line, .freehand:
            .stroke(allowsFill: false)
        case .rectangle, .arch:
            .stroke(allowsFill: true)
        case .text:
            .text
        case .select, .eraser:
            .stroke(allowsFill: false)
        }
    }

    private var effectiveStyleTool: CanvasTool {
        switch actions.session.activeTool {
        case .line, .rectangle, .arch, .freehand, .text:
            actions.session.activeTool
        case .select, .eraser:
            actions.session.mostRecentStyleTool
        }
    }
}

package struct CanvasPencilContextualAvailability: Equatable {
    package let canUndo: Bool
    package let canRedo: Bool
    package let canDelete: Bool
    package let canDuplicate: Bool
}

@MainActor
package struct CanvasPencilContextualPalette: View {
    private let actions: CanvasActions
    @Environment(\.canvasTheme) private var theme

    package init(actions: CanvasActions) {
        self.actions = actions
    }

    package var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.safeControlSpacing * 2) {
                Text("Canvas Tools")
                    .font(.headline)
                CanvasToolControls(actions: actions)
                Divider()
                CanvasHistoryControls(actions: actions)
                let availability = Self.availability(for: actions)
                if availability.canDelete || availability.canDuplicate {
                    HStack {
                        if availability.canDelete {
                            Button(role: .destructive) {
                                actions.deleteSelection()
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        if availability.canDuplicate {
                            Button {
                                actions.duplicateSelection()
                            } label: {
                                Label("Duplicate", systemImage: "plus.square.on.square")
                            }
                        }
                    }
                    .modifier(CanvasControlButtonStyle(appearance: actions.session.configuration.controls.buttonAppearance))
                }
            }
            .padding(theme.safeControlSpacing * 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
    }

    package static func availability(
        for actions: CanvasActions
    ) -> CanvasPencilContextualAvailability {
        CanvasPencilContextualAvailability(
            canUndo: actions.session.configuration.shows(.undo) && actions.canUndo,
            canRedo: actions.session.configuration.shows(.redo) && actions.canRedo,
            canDelete: actions.session.configuration.shows(.delete) && actions.canDeleteSelection,
            canDuplicate: actions.session.configuration.shows(.duplicate) && actions.canDuplicateSelection
        )
    }
}

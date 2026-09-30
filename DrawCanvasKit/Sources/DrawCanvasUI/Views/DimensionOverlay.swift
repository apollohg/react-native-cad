import SwiftUI
import DrawCanvasCore

@MainActor
public struct DimensionOverlay: View {
    private let actions: CanvasActions
    @Environment(\.canvasTheme) private var theme
    @Environment(\.locale) private var locale
    @ScaledMetric(relativeTo: .caption) private var labelScale = 1.0
    @State private var dimensionBeingEdited: PresentedDimension?
    @State private var editText = ""
    @State private var validationMessage: String?

    public init(actions: CanvasActions) {
        self.actions = actions
    }

    public var body: some View {
        let style = theme.dimensionStyle.resolved
        let labelFontSize = style.labelFontSize * labelScale
        GeometryReader { geometry in
            let dimensions = actions.presentedDimensions(
                availableSize: .init(
                    width: Double(geometry.size.width),
                    height: Double(geometry.size.height)
                ),
                labelFontSize: labelFontSize,
                style: style,
                locale: locale
            )
            ZStack {
                DimensionLines(dimensions: dimensions, extensions: true, terminatorHalfLength: style.terminatorHalfLength)
                    .stroke(
                        Color(canvasColor: style.extensionColor ?? theme.dimensions).opacity(style.extensionOpacity),
                        lineWidth: theme.safeDimensionLineWidth * style.extensionLineWidthScale
                    )
                    .allowsHitTesting(false)
                DimensionLines(dimensions: dimensions, extensions: false, terminatorHalfLength: style.terminatorHalfLength)
                    .stroke(Color(canvasColor: theme.dimensions), lineWidth: theme.safeDimensionLineWidth)
                    .allowsHitTesting(false)
                ForEach(dimensions) { dimension in
                    DimensionMark(
                        dimension: dimension,
                        color: Color(canvasColor: style.labelColor ?? theme.dimensions),
                        background: Color(canvasColor: style.labelBackground ?? theme.background),
                        fontSize: labelFontSize,
                        canEdit: actions.canEditDimension(dimension.projectedDimension),
                        canHide: actions.session.configuration.measurements.allowsHiding,
                        hide: { actions.hideDimension(dimension.projectedDimension) },
                        edit: {
                            editText = (dimension.dimension.millimeters / actions.session.configuration.measurements.unit.millimetersPerUnit).formatted(
                                .number.locale(locale).precision(.fractionLength(0 ... actions.session.configuration.measurements.fractionDigits))
                            )
                            dimensionBeingEdited = dimension
                        }
                    )
                }

                VStack {
                    HStack {
                        if hasHiddenDimensions(on: .horizontal) {
                            Button("Show Horizontal Dimensions") {
                                actions.showAllDimensions(on: .horizontal)
                            }
                        }
                        Spacer()
                        if hasHiddenDimensions(on: .vertical) {
                            Button("Show Vertical Dimensions") {
                                actions.showAllDimensions(on: .vertical)
                            }
                        }
                    }
                    Spacer()
                }
                .padding(style.labelPadding)
            }
        }
        .allowsHitTesting(true)
        .alert(
            "Edit Dimension",
            isPresented: Binding(
                get: { dimensionBeingEdited != nil },
                set: { presented in
                    if !presented, validationMessage == nil { dimensionBeingEdited = nil }
                }
            )
        ) {
            TextField("Length (\(actions.session.configuration.measurements.unit.symbol))", text: $editText)
                .keyboardType(.decimalPad)
            Button("Cancel", role: .cancel) {
                validationMessage = nil
                dimensionBeingEdited = nil
            }
            Button("Apply") {
                if let dimensionBeingEdited {
                    let applied = actions.editDimension(
                        dimensionBeingEdited.projectedDimension,
                        to: editText,
                        unit: actions.session.configuration.measurements.unit,
                        locale: locale
                    )
                    if !applied {
                        validationMessage = "Enter a valid positive length."
                        return
                    }
                }
                validationMessage = nil
                dimensionBeingEdited = nil
            }
        } message: {
            if let validationMessage { Text(validationMessage) }
        }
    }

    private func hasHiddenDimensions(on axis: DimensionAxis) -> Bool {
        actions.session.configuration.allows(.measurements)
            && actions.session.configuration.measurements.allowsHiding
            && actions.session.configuration.measurements.axes.contains(axis)
            && actions.session.hiddenDimensionKeys.contains { $0.axis == axis }
    }
}

@MainActor
private struct DimensionMark: View {
    let dimension: PresentedDimension
    let color: Color
    let background: Color
    let fontSize: Double
    let canEdit: Bool
    let canHide: Bool
    let hide: () -> Void
    let edit: () -> Void

    var body: some View {
        if let labelPosition {
            Text(dimension.labelText)
                .font(.system(size: fontSize).monospacedDigit())
                .foregroundStyle(color)
                .fixedSize()
                .rotationEffect(dimension.id.axis == .vertical ? .degrees(-90) : .zero)
                .frame(width: dimension.labelSize.width, height: dimension.labelSize.height)
                .background(background)
                .contentShape(Rectangle())
                .position(labelPosition)
                .contextMenu {
                    if canEdit {
                        Button("Edit", systemImage: "pencil", action: edit)
                    }
                    if canHide { Button("Hide", systemImage: "eye.slash", action: hide) }
                }
        }
    }

    private var labelPosition: CGPoint? {
        dimension.labelPosition.map { CGPoint(x: $0.x, y: $0.y) }
    }
}

private struct DimensionLines: Shape {
    let dimensions: [PresentedDimension]
    let extensions: Bool
    let terminatorHalfLength: Double

    func path(in rect: CGRect) -> Path {
        Path { path in
            for dimension in dimensions {
                for line in extensions ? dimension.extensionLines : dimension.dimensionLines {
                    path.move(to: CGPoint(x: line.start.x, y: line.start.y))
                    path.addLine(to: CGPoint(x: line.end.x, y: line.end.y))
                }
                if !extensions {
                    if dimension.showsStartTick { addTick(to: &path, at: dimension.clippedStart, axis: dimension.id.axis) }
                    if dimension.showsEndTick { addTick(to: &path, at: dimension.clippedEnd, axis: dimension.id.axis) }
                }
            }
        }
    }

    private func addTick(to path: inout Path, at point: CanvasPoint, axis: DimensionAxis) {
        let slash = CanvasDimensionTerminator.slash(at: point, axis: axis, halfLength: terminatorHalfLength)
        path.move(to: CGPoint(x: slash.start.x, y: slash.start.y))
        path.addLine(to: CGPoint(x: slash.end.x, y: slash.end.y))
    }
}

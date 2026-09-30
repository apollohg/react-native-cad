import CadCanvasCore
import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
public final class CanvasActions {
    public let session: CanvasSession

    @ObservationIgnored private let makeElementID: @MainActor () -> UUID
    @ObservationIgnored private let dimensionPresenter = CanvasDimensionPresenter()

    public init(
        session: CanvasSession,
        makeElementID: @escaping @MainActor () -> UUID = UUID.init
    ) {
        self.session = session
        self.makeElementID = makeElementID
    }

    public var canUndo: Bool { session.canUndo }
    public var canRedo: Bool { session.canRedo }
    public var canDeleteSelection: Bool { session.configuration.allows(.deletion) && selectedElement != nil }
    public var canDuplicateSelection: Bool { session.configuration.allows(.duplication) && selectedElement != nil }

    public var canCalibrateSelection: Bool {
        session.configuration.allows(.calibration) && selectedLineLength != nil
    }

    package var dimensionPresentationMetrics: CanvasDimensionPresentationMetrics {
        dimensionPresenter.metrics
    }

    public var dimensionLayout: DimensionLayout {
        guard session.configuration.allows(.measurements) else { return .init(horizontal: [], vertical: []) }
        let presentationDocument = session.presentationDocument
        let structure = dimensionPresenter.structure(
            document: presentationDocument,
            replacementGeneration: session.documentReplacementGeneration,
            previewRevision: session.dimensionPresentationRevision,
            committedFreehandHandoff: session.committedFreehandHandoff
        )
        return DimensionEngine.project(structure: structure, viewport: session.viewport)
    }

    public var visibleDimensions: [ProjectedDimension] {
        dimensionLayout.all.filter {
            !session.hiddenDimensionKeys.contains($0.key)
                && session.configuration.measurements.axes.contains($0.key.axis)
                && session.configuration.measurements.roles.contains($0.key.role)
        }
    }

    package func presentedDimensions(
        availableSize: CanvasSize,
        labelFontSize: Double = CanvasDimensionStyle().labelFontSize,
        style: CanvasDimensionStyle = .init(),
        locale: Locale = .current
    ) -> [PresentedDimension] {
        guard session.configuration.allows(.measurements) else { return [] }
        return dimensionPresenter.present(
            document: session.presentationDocument,
            replacementGeneration: session.documentReplacementGeneration,
            previewRevision: session.dimensionPresentationRevision,
            committedFreehandHandoff: session.committedFreehandHandoff,
            viewport: session.viewport,
            hiddenKeys: session.hiddenDimensionKeys,
            availableSize: availableSize,
            labelFontSize: labelFontSize,
            measurements: session.configuration.measurements,
            style: style,
            locale: locale
        )
    }

    public func selectTool(_ tool: CanvasTool) {
        session.selectTool(tool)
    }

    public func setStrokeStyle(_ style: CanvasStyle) throws {
        guard session.configuration.allows(.strokeStyling) else { throw CanvasSessionError.featureDisabled }
        try session.setStrokeStyle(style)
    }

    public func setTextStyle(_ style: CanvasTextStyle) throws {
        guard session.configuration.allows(.textStyling) else { throw CanvasSessionError.featureDisabled }
        try session.setTextStyle(style)
    }

    public func setSnapConfiguration(_ configuration: SnapConfiguration) throws {
        guard session.configuration.allows(.snapping) || session.configuration.allows(.grid) else {
            throw CanvasSessionError.featureDisabled
        }
        try session.setSnapConfiguration(configuration)
    }

    public func setInkConfiguration(_ configuration: CanvasInkConfiguration) {
        guard session.configuration.allows(.inkStyling) else { return }
        session.setInkConfiguration(configuration)
    }

    @discardableResult
    public func undo() -> Bool {
        guard session.canUndo else { return false }
        do {
            try session.undo()
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public func redo() -> Bool {
        guard session.canRedo else { return false }
        do {
            try session.redo()
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public func clear() -> Bool {
        guard session.configuration.allows(.clearing), !session.document.elements.isEmpty else { return false }
        return perform(.clear)
    }

    @discardableResult
    public func deleteSelection() -> Bool {
        guard canDeleteSelection, let id = session.selectedElementID,
            session.document.elements.contains(where: { $0.id == id })
        else {
            return false
        }
        return perform(.remove(id: id))
    }

    @discardableResult
    public func duplicateSelection() -> Bool {
        guard canDuplicateSelection, let element = selectedElement else { return false }
        let duplicate = CanvasElement(
            id: makeElementID(),
            contentRevision: element.contentRevision,
            geometry: element.geometry,
            style: element.style
        )
        guard perform(.insert(duplicate, at: session.document.elements.endIndex)) else {
            return false
        }
        session.selectedElementID = duplicate.id
        return true
    }

    public func hideDimension(_ dimension: ProjectedDimension) {
        guard session.configuration.allows(.measurements), session.configuration.measurements.allowsHiding else {
            return
        }
        session.hiddenDimensionKeys.insert(dimension.key)
    }

    public func showAllDimensions(on axis: DimensionAxis) {
        guard session.configuration.allows(.measurements), session.configuration.measurements.allowsHiding else {
            return
        }
        session.hiddenDimensionKeys = Set(
            session.hiddenDimensionKeys.filter { $0.axis != axis }
        )
    }

    public func canEditDimension(_ dimension: ProjectedDimension) -> Bool {
        session.configuration.allows(.measurements)
            && session.configuration.allows(.dimensionEditing)
            && dimension.isEditable
            && dimension.key.role == .element
            && dimension.key.elementIDs.count == 1
    }

    @discardableResult
    public func editDimension(
        _ dimension: ProjectedDimension,
        toMillimeters text: String,
        locale: Locale = .current
    ) -> Bool {
        editDimension(dimension, to: text, unit: .millimeters, locale: locale)
    }

    @discardableResult
    public func editDimension(
        _ dimension: ProjectedDimension,
        to text: String,
        unit: CanvasMeasurementUnit,
        locale: Locale = .current
    ) -> Bool {
        guard canEditDimension(dimension),
            let millimeters = CanvasDecimalParser.parsePositiveFinite(text, locale: locale),
            let command = try? DimensionEngine.resizeCommand(
                for: dimension,
                newMillimeters: millimeters * unit.millimetersPerUnit,
                in: session.document
            )
        else {
            return false
        }
        return perform(command)
    }

    @discardableResult
    public func calibrateSelectedLine(
        toMillimeters text: String,
        locale: Locale = .current
    ) -> Bool {
        calibrateSelectedLine(to: text, unit: .millimeters, locale: locale)
    }

    @discardableResult
    public func calibrateSelectedLine(
        to text: String,
        unit: CanvasMeasurementUnit,
        locale: Locale = .current
    ) -> Bool {
        guard canCalibrateSelection, let canvasLength = selectedLineLength,
            let millimeters = CanvasDecimalParser.parsePositiveFinite(text, locale: locale)
        else {
            return false
        }
        let millimetersPerPoint = millimeters * unit.millimetersPerUnit / canvasLength
        guard millimetersPerPoint.isFinite, millimetersPerPoint > 0,
            let calibration = try? CanvasCalibration(
                validatingMillimetersPerPoint: millimetersPerPoint
            )
        else {
            return false
        }
        return perform(.setCalibration(calibration))
    }

    @discardableResult
    public func zoomToFit(padding: Double = 32) -> Bool {
        guard session.configuration.allows(.zooming) else { return false }
        let size = session.viewport.viewportSize
        guard padding.isFinite, padding >= 0,
            size.width.isFinite, size.height.isFinite,
            size.width > padding * 2, size.height > padding * 2,
            let bounds = finiteContentBounds()
        else {
            return false
        }

        let availableWidth = size.width - padding * 2
        let availableHeight = size.height - padding * 2
        var candidates: [Double] = []
        if bounds.width > 0 {
            let ratio = availableWidth / bounds.width
            candidates.append(ratio.isFinite ? ratio : CanvasViewport.zoomRange.upperBound)
        }
        if bounds.height > 0 {
            let ratio = availableHeight / bounds.height
            candidates.append(ratio.isFinite ? ratio : CanvasViewport.zoomRange.upperBound)
        }
        let requestedZoom = candidates.min() ?? CanvasViewport.zoomRange.lowerBound
        guard requestedZoom.isFinite, requestedZoom > 0 else { return false }

        let zoom = min(
            CanvasViewport.zoomRange.upperBound,
            max(CanvasViewport.zoomRange.lowerBound, requestedZoom)
        )
        let centerX = bounds.minX + bounds.width / 2
        let centerY = bounds.minY + bounds.height / 2
        let translation = CanvasPoint(
            x: size.width / 2 - centerX * zoom,
            y: size.height / 2 - centerY * zoom
        )
        guard centerX.isFinite, centerY.isFinite,
            translation.x.isFinite, translation.y.isFinite
        else {
            return false
        }

        guard
            let viewport = try? CanvasViewport(
                zoom: zoom,
                translation: translation,
                viewportSize: size
            )
        else { return false }
        session.setViewport(viewport)
        return true
    }
}

extension CanvasActions {
    fileprivate var selectedElement: CanvasElement? {
        guard let id = session.selectedElementID else { return nil }
        return session.document.elements.first { $0.id == id }
    }

    fileprivate var selectedLineLength: Double? {
        guard let selectedElement,
            case .line(let line) = selectedElement.geometry
        else {
            return nil
        }
        let length = line.start.distance(to: line.end)
        return length.isFinite && length > 0 ? length : nil
    }

    fileprivate func perform(_ command: CanvasCommand) -> Bool {
        do {
            try session.perform(command)
            return true
        } catch {
            return false
        }
    }

    fileprivate func finiteContentBounds() -> CanvasRect? {
        var minX: Double?
        var maxX: Double?
        var minY: Double?
        var maxY: Double?

        for element in session.document.elements {
            let bounds = element.bounds
            let elementMaxX = bounds.maxX
            let elementMaxY = bounds.maxY
            guard bounds.isFinite,
                bounds.width >= 0, bounds.height >= 0,
                elementMaxX.isFinite, elementMaxY.isFinite
            else {
                continue
            }
            minX = minX.map { min($0, bounds.minX) } ?? bounds.minX
            maxX = maxX.map { max($0, elementMaxX) } ?? elementMaxX
            minY = minY.map { min($0, bounds.minY) } ?? bounds.minY
            maxY = maxY.map { max($0, elementMaxY) } ?? elementMaxY
        }

        guard let minX, let maxX, let minY, let maxY else { return nil }
        let width = maxX - minX
        let height = maxY - minY
        guard width.isFinite, height.isFinite, width >= 0, height >= 0 else {
            return nil
        }
        return CanvasRect(x: minX, y: minY, width: width, height: height)
    }
}

@MainActor
public struct CanvasToolControls: View {
    private let actions: CanvasActions
    @Environment(\.canvasTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(actions: CanvasActions) {
        self.actions = actions
    }

    public var body: some View {
        LazyVGrid(
            columns: CanvasControlLayoutPolicy.columns(for: dynamicTypeSize, spacing: theme.safeControlSpacing),
            spacing: theme.safeControlSpacing
        ) {
            ForEach(actions.session.configuration.availableTools, id: \.rawValue) { tool in
                Button {
                    actions.selectTool(tool)
                } label: {
                    Label(
                        tool.rawValue.capitalized,
                        systemImage: CanvasControlLayoutPolicy.symbolName(for: tool)
                    )
                    .frame(maxWidth: .infinity)
                }
                .modifier(CanvasControlButtonStyle(appearance: actions.session.configuration.controls.buttonAppearance))
                .tint(
                    actions.session.activeTool == tool
                        ? theme.controlTint.map(Color.init(canvasColor:)) ?? Color.accentColor
                        : theme.inactiveToolTint.map(Color.init(canvasColor:)) ?? Color.secondary
                )
                .accessibilityAddTraits(
                    actions.session.activeTool == tool ? .isSelected : []
                )
            }
        }
    }
}

@MainActor
public struct CanvasHistoryControls: View {
    private let actions: CanvasActions
    @Environment(\.canvasTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(actions: CanvasActions) {
        self.actions = actions
    }

    public var body: some View {
        LazyVGrid(
            columns: CanvasControlLayoutPolicy.columns(for: dynamicTypeSize, spacing: theme.safeControlSpacing),
            spacing: theme.safeControlSpacing
        ) {
            if actions.session.configuration.shows(.undo) {
                Button {
                    actions.undo()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!actions.canUndo)
            }
            if actions.session.configuration.shows(.redo) {
                Button {
                    actions.redo()
                } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .disabled(!actions.canRedo)
            }
        }
        .modifier(CanvasControlButtonStyle(appearance: actions.session.configuration.controls.buttonAppearance))
        .tint(theme.controlTint.map(Color.init(canvasColor:)))
    }
}

@MainActor
public struct CanvasSelectionControls: View {
    private let actions: CanvasActions
    @Environment(\.canvasTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    @State private var showsCalibration = false
    @State private var calibrationText = ""
    @State private var calibrationValidation: String?

    public init(actions: CanvasActions) {
        self.actions = actions
    }

    public var body: some View {
        LazyVGrid(
            columns: CanvasControlLayoutPolicy.columns(for: dynamicTypeSize, spacing: theme.safeControlSpacing),
            spacing: theme.safeControlSpacing
        ) {
            if actions.session.configuration.shows(.delete) {
                Button {
                    actions.deleteSelection()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(!actions.canDeleteSelection)
            }
            if actions.session.configuration.shows(.duplicate) {
                Button {
                    actions.duplicateSelection()
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                .disabled(!actions.canDuplicateSelection)
            }
            if actions.session.configuration.shows(.calibrate) {
                Button {
                    showsCalibration = true
                } label: {
                    Label("Calibrate", systemImage: "ruler")
                }
                .disabled(!actions.canCalibrateSelection)
            }
        }
        .modifier(CanvasControlButtonStyle(appearance: actions.session.configuration.controls.buttonAppearance))
        .tint(theme.controlTint.map(Color.init(canvasColor:)))
        .alert(
            "Calibrate selected line",
            isPresented: Binding(
                get: { showsCalibration },
                set: { presented in
                    if presented || calibrationValidation == nil { showsCalibration = presented }
                }
            )
        ) {
            TextField("Length (\(actions.session.configuration.measurements.unit.symbol))", text: $calibrationText)
                .keyboardType(.decimalPad)
            Button("Cancel", role: .cancel) {
                calibrationValidation = nil
                showsCalibration = false
            }
            Button("Apply") {
                if actions.calibrateSelectedLine(
                    to: calibrationText,
                    unit: actions.session.configuration.measurements.unit,
                    locale: locale
                ) {
                    calibrationValidation = nil
                    showsCalibration = false
                } else {
                    calibrationValidation = "Enter a valid positive length."
                }
            }
        } message: {
            if let calibrationValidation { Text(calibrationValidation) }
        }
    }
}

@MainActor
public struct CanvasViewportControls: View {
    private let actions: CanvasActions
    @Environment(\.canvasTheme) private var theme

    public init(actions: CanvasActions) {
        self.actions = actions
    }

    public var body: some View {
        if actions.session.configuration.shows(.zoomToFit) {
            Button {
                actions.zoomToFit()
            } label: {
                Label("Zoom to Fit", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .modifier(CanvasControlButtonStyle(appearance: actions.session.configuration.controls.buttonAppearance))
            .tint(theme.controlTint.map(Color.init(canvasColor:)))
        }
    }
}

@MainActor
public struct CanvasStrokeStyleControls: View {
    private let actions: CanvasActions
    @Environment(\.canvasTheme) private var theme
    private let allowsFill: Bool
    private let showsPressure: Bool

    public init(
        actions: CanvasActions,
        allowsFill: Bool = true,
        showsPressure: Bool = false
    ) {
        self.actions = actions
        self.allowsFill = allowsFill
        self.showsPressure = showsPressure
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.safeControlSpacing) {
            if actions.session.configuration.shows(.strokeColor) {
                ColorPicker(selection: strokeColor) {
                    Text("Stroke color")
                }
            }
            if actions.session.configuration.shows(.lineWidth) {
                Stepper(
                    value: lineWidth, in: actions.session.configuration.controls.lineWidth.bounds,
                    step: actions.session.configuration.controls.lineWidth.step
                ) {
                    Text(
                        "Width \(actions.session.strokeStyle.lineWidth, format: .number.precision(.fractionLength(1))) pt"
                    )
                }
                .controlSize(.large)
            }
            if showsPressure {
                if actions.session.configuration.shows(.pressure) {
                    HStack {
                        Text("Pressure Sensitive")
                        Spacer()
                        CanvasPressureSwitch(
                            isOn: Binding(
                                get: { actions.session.inkConfiguration.pressureEnabled },
                                set: { isEnabled in
                                    var configuration = actions.session.inkConfiguration
                                    configuration.pressureEnabled = isEnabled
                                    actions.setInkConfiguration(configuration)
                                }
                            ))
                    }
                }
                if actions.session.configuration.shows(.widthScaling) {
                    Toggle(
                        "Scale width with canvas",
                        isOn: Binding(
                            get: { actions.session.inkConfiguration.widthMode == .canvasScaled },
                            set: { scalesWithCanvas in
                                var configuration = actions.session.inkConfiguration
                                configuration.widthMode = scalesWithCanvas ? .canvasScaled : .screenConstant
                                actions.setInkConfiguration(configuration)
                            }
                        ))
                }
            }
            if allowsFill && actions.session.configuration.shows(.fill) {
                Toggle(isOn: usesFill) {
                    Text("Fill")
                }
                if actions.session.strokeStyle.fill != nil {
                    ColorPicker(selection: fillColor) {
                        Text("Fill color")
                    }
                }
            }
        }
        .tint(theme.controlTint.map(Color.init(canvasColor:)))
    }

    private var strokeColor: Binding<Color> {
        colorBinding(
            get: { actions.session.strokeStyle.stroke },
            set: { color in
                var style = actions.session.strokeStyle
                style.stroke = color
                applyConstrainedControlUpdate { try actions.setStrokeStyle(style) }
            }
        )
    }

    private var fillColor: Binding<Color> {
        colorBinding(
            get: { actions.session.strokeStyle.fill ?? .black },
            set: { color in
                var style = actions.session.strokeStyle
                style.fill = color
                applyConstrainedControlUpdate { try actions.setStrokeStyle(style) }
            }
        )
    }

    private var lineWidth: Binding<Double> {
        Binding(
            get: { actions.session.strokeStyle.lineWidth },
            set: { width in
                var style = actions.session.strokeStyle
                style.lineWidth = width
                applyConstrainedControlUpdate { try actions.setStrokeStyle(style) }
            }
        )
    }

    private var usesFill: Binding<Bool> {
        Binding(
            get: { actions.session.strokeStyle.fill != nil },
            set: { isEnabled in
                var style = actions.session.strokeStyle
                style.fill = isEnabled ? (style.fill ?? .black) : nil
                applyConstrainedControlUpdate { try actions.setStrokeStyle(style) }
            }
        )
    }
}

@MainActor
private struct CanvasPressureSwitch: UIViewRepresentable {
    @Binding var isOn: Bool
    @Environment(\.canvasTheme) private var theme

    func makeCoordinator() -> CanvasPressureSwitchCoordinator {
        CanvasPressureSwitchCoordinator(isOn: $isOn)
    }

    func makeUIView(context: Context) -> CanvasPressureSwitchControl {
        CanvasPressureSwitchWiring.makeControl(coordinator: context.coordinator)
    }

    func updateUIView(_ control: CanvasPressureSwitchControl, context: Context) {
        context.coordinator.isOn = $isOn
        control.onTintColor = theme.controlTint.map { UIColor(Color(canvasColor: $0)) }
        control.update(isOn: isOn)
    }
}

@MainActor
final class CanvasPressureSwitchCoordinator: NSObject {
    var isOn: Binding<Bool>

    init(isOn: Binding<Bool>) {
        self.isOn = isOn
    }

    func valueChanged(isOn: Bool) {
        self.isOn.wrappedValue = isOn
    }
}

@MainActor
enum CanvasPressureSwitchWiring {
    static func makeControl(
        coordinator: CanvasPressureSwitchCoordinator
    ) -> CanvasPressureSwitchControl {
        let control = CanvasPressureSwitchControl()
        control.onValueChanged = { coordinator.valueChanged(isOn: $0) }
        return control
    }
}

@MainActor
final class CanvasPressureSwitchControl: UISwitch {
    var onValueChanged: ((Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityLabel = "Pressure Sensitive"
        addTarget(self, action: #selector(relayValueChanged), for: .valueChanged)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        accessibilityLabel = "Pressure Sensitive"
        addTarget(self, action: #selector(relayValueChanged), for: .valueChanged)
    }

    func update(isOn: Bool) {
        self.isOn = isOn
        accessibilityValue = CanvasControlLayoutPolicy.pressureAccessibilityValue(isEnabled: isOn)
    }

    @objc func relayValueChanged() {
        onValueChanged?(isOn)
    }
}

@MainActor
public struct CanvasTextStyleControls: View {
    private let actions: CanvasActions
    @Environment(\.canvasTheme) private var theme

    public init(actions: CanvasActions) {
        self.actions = actions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.safeControlSpacing) {
            if actions.session.configuration.shows(.textColor) {
                ColorPicker(selection: textColor) {
                    Text("Text color")
                }
            }
            if actions.session.configuration.shows(.fontFamily) {
                Menu {
                    Picker(selection: fontFamily) {
                        ForEach(actions.session.configuration.controls.fontFamilies, id: \.self) {
                            Text($0).tag($0)
                        }
                    } label: {
                        Text("Font")
                    }
                } label: {
                    HStack {
                        Text("Font")
                        Spacer()
                        Text(actions.session.textStyle.font.familyName)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Font")
                .accessibilityValue(actions.session.textStyle.font.familyName)
            }
            if actions.session.configuration.shows(.fontSize) {
                Stepper(
                    value: pointSize, in: actions.session.configuration.controls.fontSize.bounds,
                    step: actions.session.configuration.controls.fontSize.step
                ) {
                    Text("Text size \(actions.session.textStyle.font.pointSize, format: .number) pt")
                }
                .controlSize(.large)
            }
        }
        .tint(theme.controlTint.map(Color.init(canvasColor:)))
    }

    private var textColor: Binding<Color> {
        colorBinding(
            get: { actions.session.textStyle.color },
            set: { color in
                var style = actions.session.textStyle
                style.color = color
                applyConstrainedControlUpdate { try actions.setTextStyle(style) }
            }
        )
    }

    private var fontFamily: Binding<String> {
        Binding(
            get: { actions.session.textStyle.font.familyName },
            set: { familyName in
                var style = actions.session.textStyle
                style.font.familyName = familyName
                applyConstrainedControlUpdate { try actions.setTextStyle(style) }
            }
        )
    }

    private var pointSize: Binding<Double> {
        Binding(
            get: { actions.session.textStyle.font.pointSize },
            set: { pointSize in
                var style = actions.session.textStyle
                style.font.pointSize = pointSize
                applyConstrainedControlUpdate { try actions.setTextStyle(style) }
            }
        )
    }
}

@MainActor
public struct CanvasGridAndSnapControls: View {
    private let actions: CanvasActions
    @Environment(\.canvasTheme) private var theme

    public init(actions: CanvasActions) {
        self.actions = actions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.safeControlSpacing) {
            if actions.session.configuration.shows(.snapToGrid) {
                Toggle(isOn: snapToGrid) {
                    Text("Snap to grid")
                }
            }
            if actions.session.configuration.shows(.gridSpacing) {
                Stepper(
                    value: gridSpacing, in: actions.session.configuration.controls.gridSpacing.bounds,
                    step: actions.session.configuration.controls.gridSpacing.step
                ) {
                    Text("Grid spacing \(actions.session.snapConfiguration.gridSpacing, format: .number) pt")
                }
                .controlSize(.large)
            }
            if actions.session.configuration.shows(.snapDistance) {
                Stepper(
                    value: snapThreshold, in: actions.session.configuration.controls.snapDistance.bounds,
                    step: actions.session.configuration.controls.snapDistance.step
                ) {
                    Text("Snap distance \(actions.session.snapConfiguration.screenThreshold, format: .number) pt")
                }
                .controlSize(.large)
            }
        }
        .tint(theme.controlTint.map(Color.init(canvasColor:)))
    }

    private var snapToGrid: Binding<Bool> {
        Binding(
            get: { actions.session.snapConfiguration.snapToGrid },
            set: { enabled in
                var configuration = actions.session.snapConfiguration
                configuration.snapToGrid = enabled
                applyConstrainedControlUpdate { try actions.setSnapConfiguration(configuration) }
            }
        )
    }

    private var gridSpacing: Binding<Double> {
        Binding(
            get: { actions.session.snapConfiguration.gridSpacing },
            set: { spacing in
                var configuration = actions.session.snapConfiguration
                configuration.gridSpacing = spacing
                applyConstrainedControlUpdate { try actions.setSnapConfiguration(configuration) }
            }
        )
    }

    private var snapThreshold: Binding<Double> {
        Binding(
            get: { actions.session.snapConfiguration.screenThreshold },
            set: { threshold in
                var configuration = actions.session.snapConfiguration
                configuration.screenThreshold = threshold
                applyConstrainedControlUpdate { try actions.setSnapConfiguration(configuration) }
            }
        )
    }
}

@MainActor
private func applyConstrainedControlUpdate(_ update: () throws -> Void) {
    do {
        try update()
    } catch CanvasSessionError.featureDisabled {
        return
    } catch {
        assertionFailure("A constrained CadCanvas control produced an invalid value: \(error)")
    }
}

@MainActor
public struct CadCanvasControls: View {
    private let actions: CanvasActions
    @Environment(\.canvasTheme) private var theme
    @State private var confirmsClear = false

    public init(actions: CanvasActions) {
        self.actions = actions
    }

    public var body: some View {
        let sections = CanvasControlLayoutPolicy.sections(
            for: actions.session.activeTool, configuration: actions.session.configuration)

        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: theme.safeControlSpacing * 2) {
                ForEach(sections, id: \.self) { section in
                    sectionContent(section)
                    if section != sections.last {
                        Divider()
                    }
                }
            }
            .padding(theme.safeControlSpacing * 2)
        }
        .tint(theme.controlTint.map(Color.init(canvasColor:)))
        .scrollIndicators(.visible)
        .confirmationDialog(
            "Clear the canvas?",
            isPresented: $confirmsClear,
            titleVisibility: .visible
        ) {
            Button("Clear Canvas", role: .destructive) { actions.clear() }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func sectionContent(_ section: CanvasControlSectionKind) -> some View {
        switch section {
        case .tools:
            CanvasControlSection("Tools") {
                CanvasToolControls(actions: actions)
            }
        case .style(.stroke(let allowsFill)):
            CanvasControlSection("Stroke Style") {
                CanvasStrokeStyleControls(
                    actions: actions,
                    allowsFill: allowsFill
                )
            }
        case .style(.freehand):
            CanvasControlSection("Stroke Style") {
                CanvasStrokeStyleControls(
                    actions: actions,
                    allowsFill: false,
                    showsPressure: true
                )
            }
        case .style(.text):
            CanvasControlSection("Text Style") {
                CanvasTextStyleControls(actions: actions)
            }
        case .style(.none):
            EmptyView()
        case .gridAndSnap:
            CanvasControlSection("Grid and Snap") {
                CanvasGridAndSnapControls(actions: actions)
            }
        case .edit:
            CanvasControlSection("Edit") {
                VStack(alignment: .leading, spacing: theme.safeControlSpacing) {
                    if [.undo, .redo].contains(where: actions.session.configuration.shows) {
                        CanvasHistoryControls(actions: actions)
                    }
                    if [.delete, .duplicate, .calibrate].contains(where: actions.session.configuration.shows) {
                        CanvasSelectionControls(actions: actions)
                    }
                    CanvasViewportControls(actions: actions)
                }
            }
        case .clear:
            Button(role: .destructive) {
                if actions.session.configuration.controls.confirmsClear {
                    confirmsClear = true
                } else {
                    actions.clear()
                }
            } label: {
                Label("Clear Canvas", systemImage: "trash.slash")
            }
            .modifier(CanvasControlButtonStyle(appearance: actions.session.configuration.controls.buttonAppearance))
            .disabled(actions.session.document.elements.isEmpty)
        }
    }
}

private struct CanvasControlSection<Content: View>: View {
    @Environment(\.canvasTheme) private var theme
    private let title: LocalizedStringKey
    private let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.safeControlSpacing * 1.5) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
private func colorBinding(
    get: @escaping () -> CanvasColor,
    set: @escaping (CanvasColor) -> Void
) -> Binding<Color> {
    Binding(
        get: {
            Color(uiColor: get().uiColor)
        },
        set: { color in
            guard let resolved = CanvasColor(uiColor: UIColor(color)) else { return }
            set(resolved)
        }
    )
}

struct CanvasControlButtonStyle: ViewModifier {
    let appearance: CanvasControlButtonAppearance

    @ViewBuilder func body(content: Content) -> some View {
        switch appearance {
        case .bordered: content.buttonStyle(.bordered)
        case .borderless: content.buttonStyle(.borderless)
        case .prominent: content.buttonStyle(.borderedProminent)
        }
    }
}

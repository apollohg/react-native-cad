import Observation
import SwiftUI
import UIKit
import CadCanvasCore
import CadCanvasUI

@MainActor
struct ContentView: View {
    let session: CanvasSession
    let actions: CanvasActions
    let commandActions: CanvasCommandActions
    let rendererStatus: CanvasRendererStatus

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var statistics = HostStatistics()
    @State private var themeChoice = HostTheme.light
    @State private var presentedError: HostWorkflowError?
    @State private var showsInspector = false
    @State private var status = "Ready"
    @State private var contentWidth: CGFloat = 0

    var body: some View {
        VStack(spacing: 12) {
            workflowBar
            if !placesStatisticsInInspector {
                statisticsBar
            }

            ZStack {
                CadCanvasView(
                    commandActions: commandActions,
                    rendererStatus: rendererStatus
                )
                DimensionOverlay(actions: actions)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.separator, lineWidth: 1)
            }
        }
        .padding()
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.width
        } action: { newWidth in
            contentWidth = newWidth
        }
        .canvasTheme(themeChoice.canvasTheme)
        .preferredColorScheme(themeChoice.colorScheme)
        .inspector(isPresented: $showsInspector) {
            VStack(spacing: 0) {
                CadCanvasControls(actions: actions)
                    .frame(maxHeight: .infinity)

                if placesStatisticsInInspector {
                    Divider()
                    inspectorStatisticsFooter
                }
            }
            .inspectorColumnWidth(min: 320, ideal: 340, max: 380)
        }
        .onAppear {
            applyCreationStyles(for: themeChoice)
            installDocumentCallback()
            showsInspector = CanvasInspectorPresentationPolicy.shouldPresent(
                for: horizontalSizeClass
            )
        }
        .onChange(of: horizontalSizeClass) { _, newSizeClass in
            showsInspector = CanvasInspectorPresentationPolicy.shouldPresent(
                for: newSizeClass
            )
        }
        .onChange(of: themeChoice) { _, newTheme in
            applyCreationStyles(for: newTheme)
        }
        .onDisappear {
            session.onDocumentChange = nil
        }
        .alert(item: $presentedError) { error in
            Alert(
                title: Text("Workflow failed"),
                message: Text(error.errorDescription ?? "The operation could not be completed."),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var placesStatisticsInInspector: Bool {
        CanvasInspectorPresentationPolicy.shouldPlaceSupplementaryContentInInspector(
            for: contentWidth,
            dynamicTypeSize: dynamicTypeSize
        )
    }

    private var workflowBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Button(action: makeNewDocument) {
                    Label("New", systemImage: "doc.badge.plus")
                }
                Button(action: loadStressDocument) {
                    Label("Stress", systemImage: "gauge.with.dots.needle.67percent")
                }
                Divider().frame(height: 24)
                Button(action: copyJSON) {
                    Label("Copy JSON", systemImage: "doc.on.doc")
                }
                Button(action: pasteJSON) {
                    Label("Paste JSON", systemImage: "doc.on.clipboard")
                }
                controlsButton
                configurationMenu

                Spacer()

                Picker(selection: $themeChoice) {
                    ForEach(HostTheme.allCases) { theme in
                        Text(theme.label)
                            .tag(theme)
                    }
                } label: {
                    Text("Theme")
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }

            if dynamicTypeSize.isAccessibilitySize {
                accessibilityWorkflowBar
            } else {
                compactWorkflowBar
            }
        }
        .buttonStyle(.bordered)
    }

    private var compactWorkflowBar: some View {
        HStack(spacing: 10) {
            workflowMenu
            controlsButton
            configurationMenu

            Spacer()

            themeMenu()
        }
    }

    private var accessibilityWorkflowBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                workflowMenu
                Spacer()
                controlsButton
            }

            HStack {
                themeMenu()
                configurationMenu
            }
        }
    }

    private var configurationMenu: some View {
        Menu {
            Toggle("Measurements", isOn: featureBinding(.measurements))
            Toggle("Dimension extension lines", isOn: Binding(
                get: { session.configuration.measurements.showsExtensionLines },
                set: { enabled in updateConfiguration { $0.measurements.showsExtensionLines = enabled } }
            ))
            Toggle("Grid", isOn: featureBinding(.grid))
            Toggle("Snapping", isOn: featureBinding(.snapping))
            Picker("Measurement units", selection: Binding(
                get: { session.configuration.measurements.unit },
                set: { unit in updateConfiguration { $0.measurements.unit = unit } }
            )) {
                ForEach(CanvasMeasurementUnit.allCases, id: \.self) { unit in
                    Text(unit.symbol).tag(unit)
                }
            }
            Divider()
            Button("Read-only canvas") {
                updateConfiguration {
                    $0.enabledTools = []
                    $0.enabledFeatures = [.measurements, .grid, .panning, .zooming]
                    $0.measurements.allowsHiding = false
                }
            }
            Button("Restore full editor") { updateConfiguration { $0 = .default } }
        } label: {
            Label("Configuration", systemImage: "gearshape")
        }
        .labelStyle(.iconOnly)
    }

    private func featureBinding(_ feature: CanvasFeature) -> Binding<Bool> {
        Binding(
            get: { session.configuration.allows(feature) },
            set: { enabled in
                updateConfiguration {
                    if enabled { $0.enabledFeatures.insert(feature) }
                    else { $0.enabledFeatures.remove(feature) }
                }
            }
        )
    }

    private func updateConfiguration(_ change: (inout CanvasConfiguration) -> Void) {
        perform("Updated canvas configuration") {
            var configuration = session.configuration
            change(&configuration)
            try session.setConfiguration(configuration)
        }
    }

    private func themeMenu() -> some View {
        Menu {
            Picker(selection: $themeChoice) {
                ForEach(HostTheme.allCases) { theme in
                    Text(theme.label).tag(theme)
                }
            } label: {
                Text("Theme")
            }
        } label: {
            Label(themeChoice.label, systemImage: "circle.lefthalf.filled")
        }
        .accessibilityLabel("Theme")
        .accessibilityValue(themeChoice.label)
    }

    private var workflowMenu: some View {
        Menu {
            Button(action: makeNewDocument) {
                Label("New", systemImage: "doc.badge.plus")
            }
            Button(action: loadStressDocument) {
                Label("Stress", systemImage: "gauge.with.dots.needle.67percent")
            }
            Divider()
            Button(action: copyJSON) {
                Label("Copy JSON", systemImage: "doc.on.doc")
            }
            Button(action: pasteJSON) {
                Label("Paste JSON", systemImage: "doc.on.clipboard")
            }
        } label: {
            Label("Workflows", systemImage: "ellipsis.circle")
        }
    }

    private var controlsButton: some View {
        Button {
            showsInspector.toggle()
        } label: {
            Label("Controls", systemImage: "slider.horizontal.3")
        }
        .labelStyle(.iconOnly)
        .accessibilityLabel(showsInspector ? "Hide controls" : "Show controls")
    }

    private var statisticsBar: some View {
        HStack(spacing: 16) {
            Label("Revision \(statistics.revision)", systemImage: "number")
            Label("\(statistics.elementCount) elements", systemImage: "square.3.layers.3d")
            Label(statistics.payloadDescription, systemImage: "externaldrive")
            Label("\(statistics.callbackCount) callbacks", systemImage: "waveform.path.ecg")
            rendererStatusLabel
            Spacer()
            Text(status)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(.footnote.monospacedDigit())
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    private var inspectorStatisticsFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Revision \(statistics.revision)", systemImage: "number")
            Label("\(statistics.elementCount) elements", systemImage: "square.3.layers.3d")
            Label(statistics.payloadDescription, systemImage: "externaldrive")
            Label("\(statistics.callbackCount) callbacks", systemImage: "waveform.path.ecg")
            rendererStatusLabel
            Text(status)
                .foregroundStyle(.secondary)
        }
        .font(.footnote.monospacedDigit())
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .accessibilityElement(children: .combine)
    }

    private var rendererStatusLabel: some View {
        Label(rendererStatusText, systemImage: rendererStatusSymbol)
            .foregroundStyle(rendererStatusColor)
    }

    private var rendererStatusText: String {
        switch rendererStatus.backend {
        case .initializing:
            "Starting renderer"
        case .metal:
            "Metal"
        case .coreGraphics(.initialization):
            "Core Graphics — Metal unavailable"
        case .coreGraphics(.permanentRuntime):
            "Core Graphics — Metal failed"
        case .coreGraphics(.temporaryDrawableUnavailable):
            "Core Graphics"
        }
    }

    private var rendererStatusSymbol: String {
        switch rendererStatus.backend {
        case .initializing:
            "hourglass"
        case .metal:
            "checkmark.circle.fill"
        case .coreGraphics:
            "exclamationmark.triangle.fill"
        }
    }

    private var rendererStatusColor: Color {
        switch rendererStatus.backend {
        case .initializing:
            .secondary
        case .metal:
            .green
        case .coreGraphics:
            .red
        }
    }

    private func installDocumentCallback() {
        statistics.update(from: session.document, countAsCallback: false)
        session.onDocumentChange = { [weak statistics] document in
            statistics?.update(from: document, countAsCallback: true)
        }
    }

    private func applyCreationStyles(for theme: HostTheme) {
        let styles = theme.creationStyles
        try? session.setStrokeStyle(styles.stroke)
        try? session.setTextStyle(styles.text)
    }

    private func makeNewDocument() {
        perform("Created a new document") {
            try session.replaceDocument(.empty())
        }
    }

    private func loadStressDocument() {
        perform("Loaded deterministic stress document") {
            let document = try StressDocument.make()
            try session.replaceDocument(document)
        }
    }

    private func copyJSON() {
        perform("Copied exact document JSON") {
            let payload: String
            do {
                payload = try CanvasDocumentCodec.encodeString(session.document)
            } catch let error as CanvasDocumentCodec.Error {
                throw HostWorkflowError.codec(error)
            }
            UIPasteboard.general.string = payload
        }
    }

    private func pasteJSON() {
        perform("Replaced document from pasted JSON") {
            guard let payload = UIPasteboard.general.string, !payload.isEmpty else {
                throw HostWorkflowError.clipboardHasNoString
            }

            let decodedDocument: CanvasDocument
            do {
                decodedDocument = try CanvasDocumentCodec.decode(payload)
            } catch let error as CanvasDocumentCodec.Error {
                throw HostWorkflowError.codec(error)
            }

            try session.replaceDocument(decodedDocument)
        }
    }

    private func perform(_ successStatus: String, operation: () throws -> Void) {
        do {
            try operation()
            status = successStatus
        } catch let error as HostWorkflowError {
            presentedError = error
            status = "Operation failed"
        } catch {
            presentedError = .operationFailed(String(describing: error))
            status = "Operation failed"
        }
    }
}

private enum HostWorkflowError: LocalizedError, Identifiable {
    case clipboardHasNoString
    case codec(CanvasDocumentCodec.Error)
    case operationFailed(String)

    var id: String { errorDescription ?? "workflow-error" }

    var errorDescription: String? {
        switch self {
        case .clipboardHasNoString:
            "The pasteboard does not contain a JSON string."
        case .codec(.malformedDocument):
            "The JSON is malformed or cannot be represented as a document."
        case .codec(.unsupportedVersion(let version)):
            "Document schema version \(version) is not supported."
        case .codec(.invalidDocument(let reason)):
            "The document is invalid: \(reason)"
        case .operationFailed(let reason):
            "The operation failed: \(reason)"
        }
    }
}

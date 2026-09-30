import CadCanvasCore
import Metal
import SwiftUI
import XCTest

@testable import CadCanvasUI

@MainActor
final class CanvasConfigurationTests: XCTestCase {
    func testEraserHighlightUsesConfiguredColourWithoutResizeHandles() throws {
        let element = CanvasElement.rectangle(id: UUID(), rect: .init(x: 20, y: 20, width: 100, height: 80))
        var theme = CanvasTheme.default.renderSnapshot
        theme.eraserTarget = .init(red: 0.7, green: 0.2, blue: 0.8)
        theme.eraserTargetLineWidth = 3
        let input = CanvasPresentationInput(
            document: CanvasDocument(elements: [element]), replacementGeneration: .zero, presentationRevision: .zero,
            preview: nil, transientPreview: nil, transientPreviewRevision: .zero,
            viewport: try .identity(size: .init(width: 300, height: 200)), selectedElementID: nil,
            guides: [], gridSpacing: 10, theme: theme, eraserTargetID: element.id, viewportRenderPhase: .settled
        )
        let presentation = try CanvasPresentationPreparer().prepare(input)
        XCTAssertEqual(presentation.scene.theme.selection, theme.eraserTarget)
        XCTAssertEqual(presentation.scene.theme.selectionLineWidth, theme.eraserTargetLineWidth)
        XCTAssertFalse(presentation.scene.theme.showsSelectionHandles)
        let metal = try MetalSceneCompiler().compile(presentation)
        XCTAssertFalse(metal.overlayItems.contains { if case .analyticBox = $0 { return true }; return false })
    }

    func testMoveAndResizeCanBeDisabledIndependently() throws {
        let element = CanvasElement.rectangle(id: UUID(), rect: .init(x: 20, y: 20, width: 100, height: 80))
        let session = try CanvasSession(document: CanvasDocument(elements: [element]))
        let coordinator = CadCanvasCoordinator(
            session: session, recognizer: nil, renderer: CoreGraphicsCanvasRenderer())
        defer { coordinator.dismantle() }
        var configuration = CanvasConfiguration()
        configuration.enabledFeatures.remove(.selectionMovement)
        try session.setConfiguration(configuration)
        session.selectedElementID = element.id
        coordinator.receive(.manipulationBegan(point: .init(x: 70, y: 60)))
        XCTAssertNil(session.preview)
        coordinator.receive(.manipulationBegan(point: .init(x: 120, y: 100)))
        XCTAssertNotNil(session.preview, "Resize remains available when movement is disabled")
        coordinator.cancelActiveInteraction()
        configuration.enabledFeatures.insert(.selectionMovement)
        configuration.enabledFeatures.remove(.selectionResizing)
        try session.setConfiguration(configuration)
        coordinator.receive(.manipulationBegan(point: .init(x: 120, y: 100)))
        XCTAssertNil(session.preview)
        coordinator.receive(.manipulationBegan(point: .init(x: 70, y: 60)))
        XCTAssertNotNil(session.preview, "Movement remains available when resizing is disabled")
    }

    func testLateRecognitionCannotIntroduceDisabledGeometry() throws {
        let points = [CanvasPoint(x: 0, y: 0), .init(x: 50, y: 10), .init(x: 100, y: 0)]
        let element = CanvasElement(
            id: UUID(),
            geometry: .freehand(.init(samples: points.map { .init(point: $0, pressure: 1) }, pressureEnabled: false)))
        let document = CanvasDocument(elements: [element])
        var context = CanvasInteractionContext(
            documentID: document.id, viewport: try .identity(size: .init(width: 800, height: 600)),
            elements: [element], selectedElementID: nil, proposedElementID: UUID(),
            documentReplacementGeneration: .zero, documentRevision: document.revision,
            snapConfiguration: .init(screenThreshold: 8, gridSpacing: 10, snapToGrid: false)
        )
        let request = RecognitionRequest(
            fingerprint: .init(
                documentID: document.id, replacementGeneration: .zero, elementID: element.id,
                contentRevision: element.contentRevision), points: points, recognitionGeneration: .zero)
        let result = RecognitionResult(geometry: .line(.init(start: points[0], end: points[2])), confidence: 1)
        var reducer = CanvasInteractionReducer(activeTool: .freehand)
        XCTAssertFalse(reducer.reduce(.recognitionCompleted(request: request, result: result), in: context).isEmpty)
        context.configuration.enabledTools.remove(.line)
        XCTAssertTrue(reducer.reduce(.recognitionCompleted(request: request, result: result), in: context).isEmpty)
        context.configuration.enabledTools.insert(.line)
        context.configuration.enabledFeatures.remove(.shapeRecognition)
        XCTAssertTrue(reducer.reduce(.recognitionCompleted(request: request, result: result), in: context).isEmpty)
    }

    func testConfiguredRendererTokensReachBothBackends() throws {
        let viewport = try CanvasViewport.identity(size: .init(width: 300, height: 200))
        var theme = CanvasTheme.default.renderSnapshot
        theme.grid = .init(red: 1, green: 0, blue: 0)
        theme.gridMajor = .init(red: 0, green: 1, blue: 0)
        theme.axis = .init(red: 0, green: 0, blue: 1)
        theme.gridMinorDashPattern = [2, 3, 4, 5]
        theme.selectionHandleFill = .init(red: 1, green: 1, blue: 0)
        theme.selectionOutset = 7
        let scene = CanvasPreparedScene(
            geometry: [],
            gridLines: [
                .init(start: .init(x: 10, y: 0), end: .init(x: 10, y: 200), tier: .minor),
                .init(start: .init(x: 50, y: 0), end: .init(x: 50, y: 200), tier: .major),
                .init(start: .init(x: 0, y: 0), end: .init(x: 0, y: 200), tier: .axis),
            ],
            selectionBounds: .init(x: 60, y: 60, width: 100, height: 80),
            guides: [.horizontal(canvasY: 30)], viewport: viewport, theme: theme, previewGeneration: nil
        )
        let metal = try MetalSceneCompiler().compile(scene)
        let lines = metal.items.compactMap { item -> MetalLineInstance? in
            if case .analyticLine(let line) = item { return line }
            return nil
        }
        XCTAssertEqual(lines[0].dashLength, 2)
        XCTAssertEqual(lines[0].dashPeriod, 14)
        XCTAssertEqual(lines[1].dashLength, 4)
        XCTAssertEqual(lines[1].dashOffset, 5)
        XCTAssertEqual(lines[2].color, SIMD4<Float>(0, 1, 0, 1))
        XCTAssertEqual(lines[3].color, SIMD4<Float>(0, 0, 1, 1))
        let handles = metal.items.compactMap { item -> MetalBoxInstance? in
            if case .analyticBox(let box) = item { return box }
            return nil
        }
        XCTAssertEqual(handles.count, 4)
        XCTAssertTrue(handles.allSatisfy { $0.fillColor == SIMD4<Float>(1, 1, 0, 1) })
        let commands = CoreGraphicsCanvasRenderer().renderCommands(
            scene: scene, bounds: CGRect(x: 0, y: 0, width: 300, height: 200), displayScale: 2)
        let grids = commands.compactMap { command -> (CanvasGridLine, CanvasColor)? in
            if case .grid(let line, let color, _) = command { return (line, color) }
            return nil
        }
        XCTAssertEqual(grids.map { $0.1 }, [theme.grid, theme.gridMajor, theme.axis])
        XCTAssertEqual(grids[0].0.dashPattern, theme.gridMinorDashPattern)
        let bounds = commands.compactMap { command -> CanvasRect? in
            if case .selection(let rect, _, _, _) = command { return rect }
            return nil
        }
        XCTAssertEqual(bounds, [.init(x: 53, y: 53, width: 114, height: 94)])
    }

    func testConfiguredControlsVisualEvidence() async throws {
        let session = CanvasSession()
        session.selectTool(.freehand)
        var configuration = CanvasConfiguration()
        configuration.controls.visibleTools = [.freehand, .line, .select]
        configuration.controls.visibleControls = [.strokeColor, .lineWidth, .pressure, .widthScaling, .undo, .redo]
        try session.setConfiguration(configuration)
        var theme = CanvasTheme.default
        theme.controlTint = .init(red: 0.1, green: 0.5, blue: 0.3)
        let controller = UIHostingController(
            rootView: CadCanvasControls(actions: CanvasActions(session: session))
                .canvasTheme(theme).environment(\.colorScheme, .light))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 340, height: 650)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(100))
        controller.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            XCTAssertTrue(controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "configured-inspector"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testMetalShaderDrawsConfiguredDashAndGapWithoutChangingLineWidth() throws {
        let size = CGSize(width: 128, height: 128)
        let viewport = try CanvasViewport.identity(size: .init(width: size.width, height: size.height))
        var theme = CanvasTheme.default.renderSnapshot
        theme.grid = .black
        theme.gridLineWidth = 4
        theme.gridMinorDashPattern = [8, 8]
        let scene = CanvasPreparedScene(
            geometry: [], gridLines: [.init(start: .init(x: 0, y: 32), end: .init(x: 128, y: 32))],
            selectionBounds: nil, guides: [], viewport: viewport, theme: theme, previewGeneration: nil)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let engine = try MetalRenderEngine(device: device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 128, height: 128, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var submitted: (any MTLCommandBuffer)?
        try engine.renderPresentedFrame(
            MetalSceneCompiler().compile(scene), into: texture, size: size, displayScale: 1,
            configureBeforeCommit: { submitted = $0 }, completion: { _ in })
        let command = try XCTUnwrap(submitted)
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        var pixels = [UInt8](repeating: 0, count: 128 * 128 * 4)
        texture.getBytes(&pixels, bytesPerRow: 128 * 4, from: MTLRegionMake2D(0, 0, 128, 128), mipmapLevel: 0)
        XCTAssertLessThan(pixels[(32 * 128 + 4) * 4], 10, "Dash interior must be ink")
        XCTAssertGreaterThan(pixels[(32 * 128 + 12) * 4], 245, "Gap interior must be background")
        XCTAssertGreaterThan(pixels[(36 * 128 + 4) * 4], 245, "Dash must retain the configured thickness")
    }

    func testMeasurementFiltersUnitsAndExtensionVisibilityApplyTogether() throws {
        let element = CanvasElement.rectangle(id: UUID(), rect: .init(x: 50, y: 50, width: 254, height: 127))
        let session = try CanvasSession(document: CanvasDocument(elements: [element]))
        let size = CanvasSize(width: 800, height: 600)
        session.setViewport(try .identity(size: size))
        let actions = CanvasActions(session: session)
        var configuration = CanvasConfiguration()
        configuration.measurements.axes = [.horizontal]
        configuration.measurements.roles = [.element]
        configuration.measurements.unit = .inches
        configuration.measurements.showsExtensionLines = false
        try session.setConfiguration(configuration)
        let dimensions = actions.presentedDimensions(availableSize: size, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(dimensions.count, 1)
        let dimension = try XCTUnwrap(dimensions.first)
        XCTAssertEqual(dimension.labelText, "10 in")
        XCTAssertTrue(dimension.extensionLines.isEmpty)
        XCTAssertTrue(actions.visibleDimensions.allSatisfy { $0.key.axis == .horizontal && $0.key.role == .element })
        XCTAssertTrue(actions.editDimension(dimension.projectedDimension, to: "20", unit: .inches))
        XCTAssertEqual(session.document.elements[0].bounds.width, 508, accuracy: 0.001)
    }

    func testDisabledMeasurementPresentationDoesNotBuildGeometry() throws {
        let session = CanvasSession()
        let actions = CanvasActions(session: session)
        var configuration = CanvasConfiguration()
        configuration.enabledFeatures.remove(.measurements)
        try session.setConfiguration(configuration)
        XCTAssertTrue(actions.presentedDimensions(availableSize: .init(width: 800, height: 600)).isEmpty)
        XCTAssertTrue(actions.dimensionLayout.all.isEmpty)
        XCTAssertEqual(actions.dimensionPresentationMetrics.structureBuildCount, 0)
    }

    func testGridToggleInvalidatesPreparedSceneAndPreservesDrawing() throws {
        let document = CanvasDocument(elements: [
            .rectangle(id: UUID(), rect: .init(x: 20, y: 20, width: 100, height: 80))
        ])
        let preparer = CanvasScenePreparer()
        let viewport = try CanvasViewport.identity(size: .init(width: 800, height: 600))
        func prepare(_ theme: CanvasThemeSnapshot) throws -> CanvasPreparedPresentation {
            try preparer.prepare(
                document: document, preview: nil, viewport: viewport, selectedElementID: nil, editingTextIDs: [],
                guides: [], gridSpacing: 10, theme: theme)
        }
        var theme = CanvasTheme.default.renderSnapshot
        let visible = try prepare(theme)
        XCTAssertFalse(visible.scene.gridLines.isEmpty)
        theme.showsGrid = false
        let hidden = try prepare(theme)
        XCTAssertTrue(hidden.scene.gridLines.isEmpty)
        XCTAssertEqual(hidden.scene.geometry.count, visible.scene.geometry.count)
        theme.showsGrid = true
        XCTAssertEqual(try prepare(theme).scene.gridLines.count, visible.scene.gridLines.count)
    }

    func testTextToolAndSnappingRespectFeatureConfiguration() throws {
        let session = CanvasSession()
        session.selectTool(.text)
        let coordinator = CanvasTextCoordinator(
            session: session, snapConfiguration: .init(screenThreshold: 8, gridSpacing: 10, snapToGrid: true))
        var configuration = CanvasConfiguration()
        configuration.enabledFeatures.remove(.snapping)
        try session.setConfiguration(configuration)
        let id = try XCTUnwrap(coordinator.createText(atCanvasPoint: .init(x: 13, y: 17), focus: false))
        let text = try XCTUnwrap(session.presentationDocument.elements.first { $0.id == id })
        XCTAssertEqual(text.bounds.x, 13)
        XCTAssertEqual(text.bounds.y, 17)
        configuration.enabledTools.remove(.text)
        try session.setConfiguration(configuration)
        XCTAssertNil(coordinator.createText(atCanvasPoint: .init(x: 20, y: 20), focus: false))
        XCTAssertFalse(coordinator.beginEditing(id: id))
        XCTAssertFalse(coordinator.moveElement(id: id, toCanvasPoint: .init(x: 30, y: 30)))
        XCTAssertTrue(session.document.elements.isEmpty, "Disabling text cancels the uncommitted draft")
        XCTAssertNil(session.preview)
    }

    func testHiddenControlsRemoveEmptySectionsButLeaveEnabledActionsAvailable() throws {
        var configuration = CanvasConfiguration()
        configuration.controls.visibleTools = []
        configuration.controls.visibleControls = [.pressure]
        XCTAssertEqual(
            CanvasControlLayoutPolicy.sections(for: .freehand, configuration: configuration), [.style(.freehand)])
        XCTAssertTrue(CanvasControlLayoutPolicy.sections(for: .text, configuration: configuration).isEmpty)
        configuration.enabledFeatures.remove(.inkStyling)
        XCTAssertTrue(CanvasControlLayoutPolicy.sections(for: .freehand, configuration: configuration).isEmpty)
    }

    func testDisabledToolsAndGesturesCannotMutateThroughCoordinator() throws {
        let session = CanvasSession()
        var configuration = CanvasConfiguration()
        configuration.enabledTools = []
        configuration.enabledFeatures = []
        try session.setConfiguration(configuration)
        let coordinator = CadCanvasCoordinator(
            session: session, recognizer: nil, renderer: CoreGraphicsCanvasRenderer())
        let viewport = session.viewport
        coordinator.receive(.pencilDown(.init(x: 10, y: 10)))
        coordinator.receive(.pencilMoved(.init(x: 80, y: 80)))
        coordinator.receive(.pencilUp(.init(x: 100, y: 100)))
        coordinator.receive(.panBegan(.init(x: 10, y: 10)))
        coordinator.receive(.panChanged(cumulativeScreenDelta: .init(x: 100, y: 100)))
        coordinator.receive(.panEnded(screenVelocity: .init(x: 0, y: 0)))
        coordinator.receive(.pinchBegan(canvasAnchor: .init(x: 20, y: 20), screenCentroid: .init(x: 20, y: 20)))
        coordinator.receive(.pinchChanged(scaleFromStart: 2, currentScreenCentroid: .init(x: 20, y: 20)))
        coordinator.receive(.pinchEnded)
        XCTAssertTrue(session.document.elements.isEmpty)
        XCTAssertEqual(session.viewport, viewport)
        coordinator.dismantle()
    }

    func testDisablingPencilShortcutsDoesNotInvokeHostHandler() throws {
        let session = CanvasSession()
        var handled = false
        let coordinator = CadCanvasCoordinator(
            session: session, recognizer: nil, renderer: CoreGraphicsCanvasRenderer(),
            pencilShortcutHandler: { _ in
                handled = true
                return .handled
            }
        )
        var configuration = CanvasConfiguration()
        configuration.enabledFeatures.remove(.pencilShortcuts)
        try session.setConfiguration(configuration)
        coordinator.dispatchPencilShortcut(.init(action: .switchEraser, screenAnchor: .init(x: 0, y: 0)))
        XCTAssertFalse(handled)
        XCTAssertEqual(session.activeTool, .select)
        coordinator.dismantle()
    }

    func testDisabledToolsCannotBeSelectedOrRestoredByPencilShortcut() throws {
        let session = CanvasSession()
        session.selectTool(.freehand)
        session.selectTool(.eraser)
        var configuration = CanvasConfiguration()
        configuration.enabledTools = [.line]
        try session.setConfiguration(configuration)

        XCTAssertEqual(session.activeTool, .line)
        session.selectTool(.text)
        session.toggleEraser()
        session.selectPreviousTool()
        XCTAssertEqual(session.activeTool, .line)
    }

    func testDisabledFeaturesAreBlockedByActionsAndKeyboardCommands() throws {
        let element = CanvasElement.rectangle(id: UUID(), rect: .init(x: 10, y: 20, width: 100, height: 80))
        let session = try CanvasSession(document: CanvasDocument(elements: [element]))
        session.selectedElementID = element.id
        let actions = CanvasActions(session: session)
        let keyboard = CanvasCommandActions(session: session)
        let dimension = try XCTUnwrap(actions.dimensionLayout.horizontal.first)
        let viewport = session.viewport
        var configuration = CanvasConfiguration()
        configuration.enabledFeatures = []
        try session.setConfiguration(configuration)

        XCTAssertFalse(actions.deleteSelection())
        XCTAssertFalse(actions.duplicateSelection())
        XCTAssertFalse(actions.clear())
        XCTAssertFalse(actions.editDimension(dimension, toMillimeters: "200"))
        XCTAssertFalse(keyboard.deleteSelection())
        XCTAssertFalse(keyboard.duplicateSelection())
        XCTAssertFalse(keyboard.zoomIn())
        XCTAssertFalse(keyboard.zoomOut())
        XCTAssertFalse(keyboard.zoomToFitOrReset())
        XCTAssertTrue(actions.presentedDimensions(availableSize: viewport.viewportSize).isEmpty)
        XCTAssertEqual(session.document.elements, [element])
        XCTAssertEqual(session.viewport, viewport)
    }

    func testConfigurationChangeCancelsAnInFlightStrokeWithoutSavingIt() throws {
        let session = CanvasSession()
        session.selectTool(.freehand)
        let token = try session.acquirePreview(.freehand(elementID: UUID()))
        var configuration = CanvasConfiguration()
        configuration.enabledTools = []
        try session.setConfiguration(configuration)

        XCTAssertNil(session.preview)
        XCTAssertThrowsError(try session.commitPreview(token: token))
        XCTAssertTrue(session.document.elements.isEmpty)
    }

    func testInvalidConfigurationIsRejectedAtomically() throws {
        let session = CanvasSession()
        let original = session.configuration
        var invalid = original
        invalid.controls.lineWidth.step = .nan
        XCTAssertThrowsError(try session.setConfiguration(invalid))
        XCTAssertEqual(session.configuration, original)
    }

    func testHidingAControlDoesNotDisableItsCapability() throws {
        let session = CanvasSession()
        var configuration = CanvasConfiguration()
        configuration.controls.visibleTools = [.line]
        configuration.controls.visibleControls = []
        try session.setConfiguration(configuration)
        session.selectTool(.freehand)
        XCTAssertEqual(session.activeTool, .freehand)
        XCTAssertEqual(session.configuration.availableTools, [.line])
    }
}

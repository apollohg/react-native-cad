import UIKit
import XCTest
import DrawCanvasCore
@testable import DrawCanvasUI

@MainActor
final class AdaptiveCanvasRendererTests: XCTestCase {
    func testBackendStatusTracksMetalAndPermanentRuntimeFallback() {
        let metal = AdaptiveRecordingRenderer()
        let coreGraphics = AdaptiveRecordingRenderer()
        let status = CanvasRendererStatus()
        var reportFailure: ((MetalCanvasError, MetalFailurePermanence) -> Void)?
        let renderer = AdaptiveCanvasRenderer(
            metalFactory: { handler in
                reportFailure = handler
                return metal
            },
            coreGraphicsFactory: { coreGraphics },
            status: status
        )

        XCTAssertEqual(status.backend, .initializing)
        _ = renderer.makeRenderView(displayCompletion: { _, _ in })
        XCTAssertEqual(status.backend, .metal)

        reportFailure?(.commandBufferFailed, .permanent)

        XCTAssertEqual(status.backend, .coreGraphics(.permanentRuntime))
    }

    func testBackendStatusReportsInitializationFallback() {
        let status = CanvasRendererStatus()
        let renderer = AdaptiveCanvasRenderer(
            metalFactory: { _ in throw MetalCanvasError.deviceUnavailable },
            coreGraphicsFactory: { AdaptiveRecordingRenderer() },
            status: status
        )

        _ = renderer.makeRenderView(displayCompletion: { _, _ in })

        XCTAssertEqual(status.backend, .coreGraphics(.initialization))
    }

    func testBackendStatusIgnoresTemporaryMetalFailure() {
        let status = CanvasRendererStatus()
        var reportFailure: ((MetalCanvasError, MetalFailurePermanence) -> Void)?
        let renderer = AdaptiveCanvasRenderer(
            metalFactory: { handler in
                reportFailure = handler
                return AdaptiveRecordingRenderer()
            },
            coreGraphicsFactory: { AdaptiveRecordingRenderer() },
            status: status
        )
        _ = renderer.makeRenderView(displayCompletion: { _, _ in })

        reportFailure?(.commandBufferFailed, .temporary)

        XCTAssertEqual(status.backend, .metal)
    }

    func testDrawCanvasUsesMetalByDefaultWhenInitializationSucceeds() throws {
        let session = CanvasSession()
        let configuredView = DrawCanvasView(session: session, recognizer: nil)
        let configuredRenderer = Mirror(reflecting: configuredView).children.first {
            $0.label == "renderer"
        }?.value

        XCTAssertTrue(configuredRenderer is AdaptiveCanvasRenderer)

        let metal = AdaptiveRecordingRenderer()
        let coreGraphics = AdaptiveRecordingRenderer()
        let renderer = AdaptiveCanvasRenderer(
            metalFactory: { _ in metal },
            coreGraphicsFactory: { coreGraphics }
        )
        let container = renderer.makeRenderView(displayCompletion: { _, _ in })
        renderer.update(try preparedScene(generationValue: 1), in: container)

        XCTAssertEqual(metal.scenes.count, 1)
        XCTAssertTrue(coreGraphics.scenes.isEmpty)
        XCTAssertFalse(metal.view.isHidden)
        XCTAssertTrue(coreGraphics.view.isHidden)
    }

    func testInitializationFailureDisplaysLatestSceneWithCoreGraphics() throws {
        let coreGraphics = AdaptiveRecordingRenderer()
        let renderer = AdaptiveCanvasRenderer(
            metalFactory: { _ in throw MetalCanvasError.deviceUnavailable },
            coreGraphicsFactory: { coreGraphics }
        )
        let container = renderer.makeRenderView(displayCompletion: { _, _ in })
        let first = try preparedScene(generationValue: 2)
        let latest = try preparedScene(generationValue: 3)

        renderer.update(first, in: container)
        renderer.update(latest, in: container)

        XCTAssertEqual(coreGraphics.scenes.map(\.previewGeneration), [
            first.previewGeneration,
            latest.previewGeneration,
        ])
        XCTAssertFalse(coreGraphics.view.isHidden)
    }

    func testPermanentRuntimeFailureSwitchesLatestSceneToCoreGraphics() throws {
        let metal = AdaptiveRecordingRenderer()
        let coreGraphics = AdaptiveRecordingRenderer()
        var reportFailure: ((MetalCanvasError, MetalFailurePermanence) -> Void)?
        let renderer = AdaptiveCanvasRenderer(
            metalFactory: { handler in
                reportFailure = handler
                metal.onUpdate = {
                    reportFailure?(.resourceBudgetExceeded, .permanent)
                    metal.onUpdate = nil
                }
                return metal
            },
            coreGraphicsFactory: { coreGraphics }
        )
        let container = renderer.makeRenderView(displayCompletion: { _, _ in })
        let latest = try preparedScene(generationValue: 4)

        renderer.update(latest, in: container)

        XCTAssertEqual(metal.scenes.count, 1)
        XCTAssertEqual(coreGraphics.scenes.count, 1)
        XCTAssertEqual(coreGraphics.scenes.first?.previewGeneration, latest.previewGeneration)
        XCTAssertTrue(metal.view.isHidden)
        XCTAssertFalse(coreGraphics.view.isHidden)
    }

    func testTemporaryDrawableLossDoesNotSwitchBackend() throws {
        let metal = AdaptiveRecordingRenderer()
        let coreGraphics = AdaptiveRecordingRenderer()
        var reportFailure: ((MetalCanvasError, MetalFailurePermanence) -> Void)?
        var diagnostics: [CanvasDiagnostic] = []
        let renderer = AdaptiveCanvasRenderer(
            metalFactory: { handler in
                reportFailure = handler
                return metal
            },
            coreGraphicsFactory: { coreGraphics },
            diagnosticHandler: { diagnostics.append($0) }
        )
        let container = renderer.makeRenderView(displayCompletion: { _, _ in })
        renderer.update(try preparedScene(generationValue: 5), in: container)

        reportFailure?(.commandBufferFailed, .temporary)

        XCTAssertEqual(metal.scenes.count, 1)
        XCTAssertTrue(coreGraphics.scenes.isEmpty)
        XCTAssertFalse(metal.view.isHidden)
        XCTAssertTrue(diagnostics.isEmpty)
    }

    func testFallbackPreservesLatestPreparedSceneAndDisplayGeneration() throws {
        let metal = AdaptiveRecordingRenderer()
        let coreGraphics = AdaptiveRecordingRenderer()
        var reportFailure: ((MetalCanvasError, MetalFailurePermanence) -> Void)?
        var displayed: [(RecognitionGeneration, TimeInterval)] = []
        let renderer = AdaptiveCanvasRenderer(
            metalFactory: { handler in
                reportFailure = handler
                return metal
            },
            coreGraphicsFactory: { coreGraphics }
        )
        let container = renderer.makeRenderView { displayed.append(($0, $1)) }
        let first = try preparedScene(generationValue: 6)
        let latest = try preparedScene(generationValue: 7)
        renderer.update(first, in: container)
        renderer.update(latest, in: container)

        reportFailure?(.presentationCallbackUnavailable, .permanent)
        metal.reportDisplay(try XCTUnwrap(first.previewGeneration), at: 6)
        coreGraphics.reportDisplay(try XCTUnwrap(latest.previewGeneration), at: 7)

        XCTAssertEqual(coreGraphics.scenes.count, 1)
        XCTAssertEqual(coreGraphics.scenes.first?.geometry.map(\.id), latest.geometry.map(\.id))
        XCTAssertEqual(coreGraphics.scenes.first?.previewGeneration, latest.previewGeneration)
        XCTAssertEqual(displayed.map(\.0), [try XCTUnwrap(latest.previewGeneration)])
        XCTAssertEqual(displayed.map(\.1), [7])
    }

    func testCacheResetReachesActiveAndDormantBackends() throws {
        let metal = AdaptiveRecordingRenderer()
        let coreGraphics = AdaptiveRecordingRenderer()
        var displayed: [RecognitionGeneration] = []
        let renderer = AdaptiveCanvasRenderer(
            metalFactory: { _ in metal },
            coreGraphicsFactory: { coreGraphics }
        )
        let firstContainer = renderer.makeRenderView { generation, _ in
            displayed.append(generation)
        }

        renderer.resetDerivedRenderCaches()
        renderer.dismantleRenderView(firstContainer)

        XCTAssertEqual(metal.cacheResetCount, 1)
        XCTAssertEqual(coreGraphics.cacheResetCount, 1)
        XCTAssertTrue(metal.dismantledViews.contains { $0 === metal.view })
        XCTAssertTrue(coreGraphics.dismantledViews.contains { $0 === coreGraphics.view })

        let secondContainer = renderer.makeRenderView { generation, _ in
            displayed.append(generation)
        }
        renderer.update(try preparedScene(generationValue: 8), in: secondContainer)
        coreGraphics.reportDisplay(
            RecognitionGeneration(words: [7]),
            completionIndex: 0
        )

        XCTAssertFalse(firstContainer === secondContainer)
        XCTAssertEqual(metal.makeViewCount, 2)
        XCTAssertEqual(coreGraphics.makeViewCount, 2)
        XCTAssertEqual(metal.scenes.count, 1)
        XCTAssertTrue(displayed.isEmpty)
    }

    func testFallbackDiagnosticContainsSanitizedReasonWithoutDocumentData() throws {
        let secretID = UUID()
        let secretText = "private-quote-payload"
        let coreGraphics = AdaptiveRecordingRenderer()
        let session = CanvasSession()
        var diagnostics: [CanvasDiagnostic] = []
        session.onDiagnostic = { diagnostics.append($0) }
        let renderer = AdaptiveCanvasRenderer(
            metalFactory: { _ in throw MetalCanvasError.functionUnavailable(secretText) },
            coreGraphicsFactory: { coreGraphics },
            diagnosticHandler: { [weak session] diagnostic in
                session?.onDiagnostic?(diagnostic)
            }
        )
        let container = renderer.makeRenderView(displayCompletion: { _, _ in })
        renderer.update(try preparedScene(generationValue: 9, elementID: secretID), in: container)

        XCTAssertEqual(diagnostics, [.rendererFallback(.initialization)])
        let renderedDiagnostic = String(reflecting: diagnostics)
        XCTAssertFalse(renderedDiagnostic.contains(secretID.uuidString))
        XCTAssertFalse(renderedDiagnostic.contains(secretText))
    }

    func testExplicitCustomRendererBypassesAdaptiveDefault() throws {
        let session = CanvasSession()
        let custom = AdaptiveRecordingRenderer()
        let configuredView = DrawCanvasView(
            session: session,
            recognizer: nil,
            renderer: custom
        )
        let configuredRenderer = Mirror(reflecting: configuredView).children.first {
            $0.label == "renderer"
        }?.value as? AdaptiveRecordingRenderer
        let coordinator = DrawCanvasCoordinator(
            session: session,
            recognizer: nil,
            renderer: custom,
            theme: .default
        )
        let host = coordinator.makeHostView()
        coordinator.update()

        XCTAssertTrue(configuredRenderer === custom)
        XCTAssertTrue(host.renderView === custom.view)
        XCTAssertEqual(custom.scenes.count, 1)
    }
}

@MainActor
private final class AdaptiveRecordingRenderer:
    CanvasTimestampedDisplayReportingRenderer,
    CanvasRenderCacheResetting,
    CanvasRenderDismantling
{
    private(set) var view = UIView()
    private(set) var scenes: [CanvasPreparedScene] = []
    private(set) var makeViewCount = 0
    private(set) var cacheResetCount = 0
    private(set) var dismantledViews: [UIView] = []
    var onUpdate: (() -> Void)?
    private var displayCompletions: [(RecognitionGeneration, TimeInterval) -> Void] = []

    func makeRenderView(
        displayCompletion: @escaping (RecognitionGeneration, TimeInterval) -> Void
    ) -> UIView {
        makeViewCount += 1
        if makeViewCount > 1 {
            view = UIView()
        }
        displayCompletions.append(displayCompletion)
        return view
    }

    func update(_ scene: CanvasPreparedScene, in renderView: UIView) {
        guard renderView === view else { return }
        scenes.append(scene)
        onUpdate?()
    }

    func reportDisplay(
        _ generation: RecognitionGeneration,
        at presentedTime: TimeInterval = 1,
        completionIndex: Int? = nil
    ) {
        let index = completionIndex ?? (displayCompletions.count - 1)
        guard displayCompletions.indices.contains(index) else { return }
        displayCompletions[index](generation, presentedTime)
    }

    func resetDerivedRenderCaches() {
        cacheResetCount += 1
    }

    func dismantleRenderView(_ renderView: UIView) {
        dismantledViews.append(renderView)
    }
}

@MainActor
private func preparedScene(
    generationValue: UInt64,
    elementID: UUID = UUID()
) throws -> CanvasPreparedScene {
    let element = CanvasElement(
        id: elementID,
        geometry: .line(.init(
            start: .init(x: Double(generationValue), y: 0),
            end: .init(x: Double(generationValue) + 20, y: 20)
        ))
    )
    let prepared = try CanvasScenePreparer().prepare(
        document: .init(elements: [element]),
        preview: nil,
        viewport: .identity(size: .init(width: 100, height: 80)),
        selectedElementID: nil,
        editingTextIDs: [],
        guides: [],
        gridSpacing: 20,
        theme: CanvasTheme.default.renderSnapshot
    ).scene
    return CanvasPreparedScene(
        geometry: prepared.geometry,
        gridLines: prepared.gridLines,
        selectionBounds: prepared.selectionBounds,
        guides: prepared.guides,
        viewport: prepared.viewport,
        theme: prepared.theme,
        previewGeneration: RecognitionGeneration(words: [generationValue])
    )
}

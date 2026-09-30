import CadCanvasCore
@testable import CadCanvasUI
import UIKit
import XCTest

@MainActor
final class PreparedPresentationDeliveryTests: XCTestCase {
    func testCoordinatorMarksOnlyActivePinchAsInteractive() {
        let session = CanvasSession()
        session.setViewport(try! .identity(size: .init(width: 500, height: 400)))
        let renderer = PresentationRecordingRenderer()
        let coordinator = CadCanvasCoordinator(
            session: session,
            recognizer: nil,
            renderer: renderer
        )
        let host = coordinator.makeHostView()

        coordinator.update()
        coordinator.receive(.pinchBegan(
            canvasAnchor: .init(x: 100, y: 100),
            screenCentroid: .init(x: 100, y: 100)
        ))
        coordinator.receive(.pinchChanged(
            scaleFromStart: 2,
            currentScreenCentroid: .init(x: 100, y: 100)
        ))
        coordinator.receive(.pinchEnded)

        XCTAssertEqual(renderer.phases, [
            .settled,
            .interactive,
            .interactive,
            .settled,
        ])
        withExtendedLifetime(host) {}
    }
}

@MainActor
private final class PresentationRecordingRenderer:
    CanvasRenderer,
    CanvasPreparedPresentationRendering
{
    private(set) var phases: [CanvasViewportRenderPhase] = []

    func makeRenderView() -> UIView {
        UIView()
    }

    func update(_: CanvasPreparedScene, in _: UIView) {}

    func update(_ presentation: CanvasPreparedPresentation, in _: UIView) {
        phases.append(presentation.viewportRenderPhase)
    }
}

@MainActor
extension CanvasPreparedInk {
    convenience init(points: [CanvasPoint]) {
        self.init(
            confirmedSamples: points.map { .init(point: $0, pressure: 1) },
            predictedSamples: [],
            pressureEnabled: false,
            isFinalized: false
        )
    }

    var points: [CanvasPoint] {
        let snapshot = snapshot()
        return (snapshot.confirmed + snapshot.predicted).map(\.point)
    }

    func append(_ points: [CanvasPoint]) {
        _ = appendConfirmed(
            confirmedSamples + points.map { .init(point: $0, pressure: 1) }
        )
    }
}

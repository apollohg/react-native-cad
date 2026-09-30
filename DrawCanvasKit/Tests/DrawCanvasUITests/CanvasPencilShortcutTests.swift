import XCTest
import UIKit
@testable import DrawCanvasUI
import DrawCanvasCore

@MainActor
final class CanvasPencilShortcutTests: XCTestCase {
    func testMapsEveryKnownPreferredAction() {
        XCTAssertNil(CanvasPencilShortcutCoordinator.action(for: .ignore))
        XCTAssertEqual(
            CanvasPencilShortcutCoordinator.action(for: .switchEraser),
            .switchEraser
        )
        XCTAssertEqual(
            CanvasPencilShortcutCoordinator.action(for: .switchPrevious),
            .switchPreviousTool
        )
        XCTAssertEqual(
            CanvasPencilShortcutCoordinator.action(for: .showColorPalette),
            .showColorPalette
        )
        XCTAssertEqual(
            CanvasPencilShortcutCoordinator.action(for: .showInkAttributes),
            .showInkAttributes
        )
        XCTAssertEqual(
            CanvasPencilShortcutCoordinator.action(for: .showContextualPalette),
            .showContextualPalette
        )
        XCTAssertNil(CanvasPencilShortcutCoordinator.action(for: .runSystemShortcut))
    }

    func testContinuousSqueezeCapturesPreferenceUpdatesAnchorAndDispatchesOnce() throws {
        var preferredAction = UIPencilPreferredAction.switchEraser
        var received: [CanvasPencilShortcutContext] = []
        let coordinator = makeCoordinator(
            preferredAction: { preferredAction },
            send: { received.append($0) }
        )

        coordinator.receive(phase: .began, hoverLocation: .init(x: 20, y: 30), timestamp: 1)
        preferredAction = .showColorPalette
        coordinator.receive(phase: .changed, hoverLocation: .init(x: 25, y: 35), timestamp: 1)
        coordinator.receive(phase: .ended, hoverLocation: .init(x: 30, y: 40), timestamp: 1)
        coordinator.receive(phase: .ended, hoverLocation: .init(x: 50, y: 60), timestamp: 1)

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].action, .switchEraser)
        XCTAssertEqual(received[0].screenAnchor, .init(x: 30, y: 40))
    }

    func testDiscreteEndedDispatchesAndInvalidHoverUsesFallback() throws {
        var received: [CanvasPencilShortcutContext] = []
        let coordinator = makeCoordinator(
            preferredAction: { .switchPrevious },
            fallbackAnchor: { .init(x: 100, y: 200) },
            send: { received.append($0) }
        )

        coordinator.receive(
            phase: .ended,
            hoverLocation: .init(x: CGFloat.infinity, y: 40)
        )

        XCTAssertEqual(
            received,
            [.init(action: .switchPreviousTool, screenAnchor: .init(x: 100, y: 200))]
        )
    }

    func testCancelledSqueezeDoesNotDispatch() {
        var received: [CanvasPencilShortcutContext] = []
        let coordinator = makeCoordinator(send: { received.append($0) })

        coordinator.receive(phase: .began, hoverLocation: .init(x: 20, y: 30), timestamp: 2)
        coordinator.receive(phase: .cancelled, hoverLocation: .init(x: 25, y: 35), timestamp: 2)
        coordinator.receive(phase: .ended, hoverLocation: .init(x: 30, y: 40), timestamp: 2)

        XCTAssertTrue(received.isEmpty)
    }

    func testDefersOneActionUntilPencilTransactionFinishes() {
        var isPencilActive = true
        var received: [CanvasPencilShortcutContext] = []
        let coordinator = makeCoordinator(
            isPencilTransactionActive: { isPencilActive },
            send: { received.append($0) }
        )

        coordinator.receive(phase: .ended, hoverLocation: .init(x: 20, y: 30))
        XCTAssertTrue(received.isEmpty)

        isPencilActive = false
        coordinator.pencilTransactionDidFinish()

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].action, .switchEraser)
    }

    func testCancellingPendingActionPreventsDeferredDispatch() {
        var isPencilActive = true
        var received: [CanvasPencilShortcutContext] = []
        let coordinator = makeCoordinator(
            isPencilTransactionActive: { isPencilActive },
            send: { received.append($0) }
        )

        coordinator.receive(phase: .ended, hoverLocation: nil)
        coordinator.cancelPendingAction()
        isPencilActive = false
        coordinator.pencilTransactionDidFinish()

        XCTAssertTrue(received.isEmpty)
    }

    func testIgnoreAndSystemShortcutDoNotDispatch() {
        var preferredAction = UIPencilPreferredAction.ignore
        var received: [CanvasPencilShortcutContext] = []
        let coordinator = makeCoordinator(
            preferredAction: { preferredAction },
            send: { received.append($0) }
        )

        coordinator.receive(phase: .ended, hoverLocation: nil)
        preferredAction = .runSystemShortcut
        coordinator.receive(phase: .ended, hoverLocation: nil)

        XCTAssertTrue(received.isEmpty)
    }

    func testUnknownPreferenceDiagnosesWithoutDispatch() {
        let unknown = unsafeBitCast(999, to: UIPencilPreferredAction.self)
        var diagnostics: [CanvasDiagnostic] = []
        var received: [CanvasPencilShortcutContext] = []
        let coordinator = makeCoordinator(
            preferredAction: { unknown },
            send: { received.append($0) },
            diagnose: { diagnostics.append($0) }
        )

        coordinator.receive(phase: .ended, hoverLocation: nil)

        XCTAssertTrue(received.isEmpty)
        XCTAssertEqual(diagnostics, [.unknownPencilPreferredAction(999)])
    }

    func testInstallReplacementAndUninstallOwnExactlyOneInteraction() {
        let firstHost = UIView()
        let secondHost = UIView()
        let coordinator = makeCoordinator()

        coordinator.install(on: firstHost)
        XCTAssertEqual(firstHost.interactions.compactMap { $0 as? UIPencilInteraction }.count, 1)

        coordinator.install(on: secondHost)
        XCTAssertTrue(firstHost.interactions.compactMap { $0 as? UIPencilInteraction }.isEmpty)
        XCTAssertEqual(secondHost.interactions.compactMap { $0 as? UIPencilInteraction }.count, 1)

        coordinator.uninstall()
        XCTAssertTrue(secondHost.interactions.compactMap { $0 as? UIPencilInteraction }.isEmpty)
    }

    private func makeCoordinator(
        preferredAction: @escaping () -> UIPencilPreferredAction = { .switchEraser },
        fallbackAnchor: @escaping () -> CanvasPoint = { .init(x: 0, y: 0) },
        isPencilTransactionActive: @escaping () -> Bool = { false },
        send: @escaping (CanvasPencilShortcutContext) -> Void = { _ in },
        diagnose: @escaping (CanvasDiagnostic) -> Void = { _ in }
    ) -> CanvasPencilShortcutCoordinator {
        CanvasPencilShortcutCoordinator(
            preferredAction: preferredAction,
            fallbackAnchor: fallbackAnchor,
            isPencilTransactionActive: isPencilTransactionActive,
            send: send,
            diagnose: diagnose
        )
    }
}

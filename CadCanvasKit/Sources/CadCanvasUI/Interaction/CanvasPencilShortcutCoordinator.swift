import UIKit
import CadCanvasCore

@MainActor
package final class CanvasPencilShortcutCoordinator: NSObject, UIPencilInteractionDelegate {
    private struct Capture {
        let action: CanvasPencilShortcutAction
        var anchor: CanvasPoint
    }

    private let preferredAction: () -> UIPencilPreferredAction
    private let fallbackAnchor: () -> CanvasPoint
    private let isPencilTransactionActive: () -> Bool
    private let send: (CanvasPencilShortcutContext) -> Void
    private let diagnose: (CanvasDiagnostic) -> Void
    private let interaction: UIPencilInteraction
    private weak var installedView: UIView?
    private var capture: Capture?
    private var deferredContext: CanvasPencilShortcutContext?
    private var hasContinuousSequence = false
    private var hasCapturedPreference = false
    private var lastTerminalTimestamp: TimeInterval?

    package init(
        preferredAction: @escaping () -> UIPencilPreferredAction,
        fallbackAnchor: @escaping () -> CanvasPoint,
        isPencilTransactionActive: @escaping () -> Bool,
        send: @escaping (CanvasPencilShortcutContext) -> Void,
        diagnose: @escaping (CanvasDiagnostic) -> Void
    ) {
        self.preferredAction = preferredAction
        self.fallbackAnchor = fallbackAnchor
        self.isPencilTransactionActive = isPencilTransactionActive
        self.send = send
        self.diagnose = diagnose
        interaction = UIPencilInteraction()
        super.init()
        interaction.delegate = self
    }

    package func install(on view: UIView) {
        guard installedView !== view else { return }
        uninstall()
        interaction.delegate = self
        view.addInteraction(interaction)
        installedView = view
    }

    package func uninstall() {
        if let installedView {
            installedView.removeInteraction(interaction)
        }
        installedView = nil
        interaction.delegate = nil
        cancelPendingAction()
    }

    package func receive(
        phase: UIPencilInteraction.Phase,
        hoverLocation: CGPoint?,
        timestamp: TimeInterval = .nan
    ) {
        switch phase {
        case .began:
            hasContinuousSequence = true
            hasCapturedPreference = true
            capture = makeCapture(hoverLocation: hoverLocation)
        case .changed:
            hasContinuousSequence = true
            if !hasCapturedPreference {
                hasCapturedPreference = true
                capture = makeCapture(hoverLocation: hoverLocation)
            } else if let anchor = finiteAnchor(hoverLocation) {
                capture?.anchor = anchor
            }
        case .ended:
            guard lastTerminalTimestamp != timestamp else { return }
            let wasContinuous = hasContinuousSequence
            var completed = wasContinuous
                ? capture
                : makeCapture(hoverLocation: hoverLocation)
            if let anchor = finiteAnchor(hoverLocation) {
                completed?.anchor = anchor
            }
            capture = nil
            hasContinuousSequence = false
            hasCapturedPreference = false
            lastTerminalTimestamp = timestamp
            guard let completed else { return }
            dispatch(.init(action: completed.action, screenAnchor: completed.anchor))
        case .cancelled:
            lastTerminalTimestamp = timestamp
            capture = nil
            hasContinuousSequence = false
            hasCapturedPreference = false
        @unknown default:
            capture = nil
            hasContinuousSequence = false
            hasCapturedPreference = false
        }
    }

    package func pencilTransactionDidFinish() {
        guard !isPencilTransactionActive(), let deferredContext else { return }
        self.deferredContext = nil
        send(deferredContext)
    }

    package func cancelPendingAction() {
        capture = nil
        deferredContext = nil
        hasContinuousSequence = false
        hasCapturedPreference = false
    }

    package static func action(
        for preferredAction: UIPencilPreferredAction
    ) -> CanvasPencilShortcutAction? {
        switch preferredAction {
        case .ignore, .runSystemShortcut:
            nil
        case .switchEraser:
            .switchEraser
        case .switchPrevious:
            .switchPreviousTool
        case .showColorPalette:
            .showColorPalette
        case .showInkAttributes:
            .showInkAttributes
        case .showContextualPalette:
            .showContextualPalette
        @unknown default:
            nil
        }
    }

    package func pencilInteraction(
        _ interaction: UIPencilInteraction,
        didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze
    ) {
        receive(
            phase: squeeze.phase,
            hoverLocation: squeeze.hoverPose?.location,
            timestamp: squeeze.timestamp
        )
    }

    private func makeCapture(hoverLocation: CGPoint?) -> Capture? {
        let preferred = preferredAction()
        guard let action = Self.action(for: preferred) else {
            if !Self.isKnownNoAction(preferred) {
                diagnose(.unknownPencilPreferredAction(preferred.rawValue))
            }
            return nil
        }
        return Capture(
            action: action,
            anchor: finiteAnchor(hoverLocation) ?? finiteFallbackAnchor()
        )
    }

    private func dispatch(_ context: CanvasPencilShortcutContext) {
        if isPencilTransactionActive() {
            deferredContext = context
        } else {
            send(context)
        }
    }

    private func finiteAnchor(_ point: CGPoint?) -> CanvasPoint? {
        guard let point, point.x.isFinite, point.y.isFinite else { return nil }
        return CanvasPoint(x: Double(point.x), y: Double(point.y))
    }

    private func finiteFallbackAnchor() -> CanvasPoint {
        let anchor = fallbackAnchor()
        guard anchor.x.isFinite, anchor.y.isFinite else {
            return CanvasPoint(x: 0, y: 0)
        }
        return anchor
    }

    private static func isKnownNoAction(_ action: UIPencilPreferredAction) -> Bool {
        switch action {
        case .ignore, .runSystemShortcut:
            true
        case .switchEraser, .switchPrevious, .showColorPalette,
             .showInkAttributes, .showContextualPalette:
            false
        @unknown default:
            false
        }
    }
}

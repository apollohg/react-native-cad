import UIKit
import SwiftUI
import DrawCanvasCore

@MainActor
package protocol CanvasPencilPalettePresenting: AnyObject {
    var presentedAction: CanvasPencilShortcutAction? { get }

    func toggle(
        _ action: CanvasPencilShortcutAction,
        anchor: CanvasPoint,
        hostView: UIView,
        actions: CanvasActions,
        styleTool: CanvasTool
    )

    func dismiss()
    func update(theme: CanvasTheme)
}

package extension CanvasPencilPalettePresenting {
    func update(theme: CanvasTheme) {}
}

@MainActor
package protocol CanvasPencilPalettePresentationDriving: AnyObject {
    func present(
        _ controller: UIViewController,
        from hostView: UIView,
        sourceRect: CGRect
    ) -> Bool

    func dismiss(_ controller: UIViewController)
}

@MainActor
private final class UIKitPencilPalettePresentationDriver:
    CanvasPencilPalettePresentationDriving {
    func present(
        _ controller: UIViewController,
        from hostView: UIView,
        sourceRect: CGRect
    ) -> Bool {
        guard hostView.window != nil,
              let host = hostView.nearestViewController,
              host.viewIfLoaded?.window != nil,
              host.presentedViewController == nil,
              !host.isBeingDismissed else { return false }
        controller.modalPresentationStyle = .popover
        if let popover = controller.popoverPresentationController {
            popover.sourceView = hostView
            popover.sourceRect = sourceRect
            popover.permittedArrowDirections = .any
        }
        host.present(controller, animated: true)
        return true
    }

    func dismiss(_ controller: UIViewController) {
        controller.dismiss(animated: false)
    }
}

@MainActor
package final class CanvasPencilPalettePresenter: NSObject,
    CanvasPencilPalettePresenting,
    UIColorPickerViewControllerDelegate,
    UIAdaptivePresentationControllerDelegate {
    package private(set) var presentedAction: CanvasPencilShortcutAction?
    package private(set) var presentedAnchor: CanvasPoint?

    private let presentationDriver: any CanvasPencilPalettePresentationDriving
    private let diagnose: (CanvasDiagnostic) -> Void
    private weak var actions: CanvasActions?
    private var presentedStyleTool: CanvasTool?
    private var presentedController: UIViewController?
    private var theme: CanvasTheme = .default

    package func update(theme: CanvasTheme) {
        guard self.theme != theme else { return }
        dismiss()
        self.theme = theme
    }

    package init(
        presentationDriver: (any CanvasPencilPalettePresentationDriving)? = nil,
        diagnose: @escaping (CanvasDiagnostic) -> Void = { _ in }
    ) {
        self.presentationDriver = presentationDriver
            ?? UIKitPencilPalettePresentationDriver()
        self.diagnose = diagnose
    }

    package func toggle(
        _ action: CanvasPencilShortcutAction,
        anchor: CanvasPoint,
        hostView: UIView,
        actions: CanvasActions,
        styleTool: CanvasTool
    ) {
        guard Self.isPaletteAction(action) else { return }
        if presentedAction == action {
            dismiss()
            return
        }
        dismiss()

        let anchor = Self.constrainedAnchor(anchor, in: hostView)
        let controller = makeController(
            for: action,
            actions: actions,
            styleTool: styleTool
        )
        let sourceRect = CGRect(
            x: anchor.x,
            y: anchor.y,
            width: 1,
            height: 1
        )
        guard presentationDriver.present(
            controller,
            from: hostView,
            sourceRect: sourceRect
        ) else {
            diagnose(.pencilPalettePresentationUnavailable)
            return
        }

        controller.presentationController?.delegate = self
        self.actions = actions
        presentedStyleTool = styleTool
        presentedAction = action
        presentedAnchor = CanvasPoint(x: Double(anchor.x), y: Double(anchor.y))
        presentedController = controller
    }

    package func dismiss() {
        if let presentedController {
            presentationDriver.dismiss(presentedController)
        }
        clearPresentation()
    }

    package func applySelectedColor(_ color: UIColor) {
        guard let actions, let color = CanvasColor(uiColor: color) else { return }
        if effectiveStyleTool(for: actions, fallback: presentedStyleTool) == .text {
            var style = actions.session.textStyle
            style.color = color
            try? actions.setTextStyle(style)
        } else {
            var style = actions.session.strokeStyle
            style.stroke = color
            try? actions.setStrokeStyle(style)
        }
    }

    package func colorPickerViewControllerDidSelectColor(
        _ viewController: UIColorPickerViewController
    ) {
        applySelectedColor(viewController.selectedColor)
    }

    package func colorPickerViewControllerDidFinish(
        _ viewController: UIColorPickerViewController
    ) {
        dismiss()
    }

    package func presentationControllerDidDismiss(
        _ presentationController: UIPresentationController
    ) {
        clearPresentation()
    }

    private func makeController(
        for action: CanvasPencilShortcutAction,
        actions: CanvasActions,
        styleTool: CanvasTool
    ) -> UIViewController {
        switch action {
        case .showColorPalette:
            let picker = UIColorPickerViewController()
            let color = effectiveStyleTool(for: actions, fallback: styleTool) == .text
                ? actions.session.textStyle.color
                : actions.session.strokeStyle.stroke
            picker.selectedColor = color.uiColor
            picker.supportsAlpha = true
            picker.delegate = self
            picker.view.tintColor = theme.controlTint?.uiColor
            return picker
        case .showInkAttributes:
            return hostingController(
                CanvasPencilInkPalette(actions: actions, styleTool: styleTool)
            )
        case .showContextualPalette:
            return hostingController(CanvasPencilContextualPalette(actions: actions))
        case .switchEraser, .switchPreviousTool:
            preconditionFailure("Tool shortcuts do not present palettes")
        }
    }

    private func hostingController<Content: View>(_ content: Content) -> UIViewController {
        let controller = UIHostingController(rootView: content.canvasTheme(theme).tint(theme.controlTint.map(Color.init(canvasColor:))))
        controller.preferredContentSize = CGSize(width: 340, height: 420)
        return controller
    }

    private func clearPresentation() {
        actions = nil
        presentedStyleTool = nil
        presentedAction = nil
        presentedAnchor = nil
        presentedController = nil
    }

    private static func isPaletteAction(_ action: CanvasPencilShortcutAction) -> Bool {
        switch action {
        case .showColorPalette, .showInkAttributes, .showContextualPalette:
            true
        case .switchEraser, .switchPreviousTool:
            false
        }
    }

    private func effectiveStyleTool(
        for actions: CanvasActions,
        fallback: CanvasTool?
    ) -> CanvasTool {
        switch actions.session.activeTool {
        case .line, .rectangle, .arch, .freehand, .text:
            return actions.session.activeTool
        case .select, .eraser:
            let recent = actions.session.mostRecentStyleTool
            return recent == .select || recent == .eraser
                ? (fallback ?? .freehand)
                : recent
        }
    }

    private static func constrainedAnchor(_ anchor: CanvasPoint, in view: UIView) -> CGPoint {
        let safeBounds = view.bounds.inset(by: view.safeAreaInsets)
        let bounds = safeBounds.isEmpty ? view.bounds : safeBounds
        let requested = anchor.x.isFinite && anchor.y.isFinite
            ? CGPoint(x: anchor.x, y: anchor.y)
            : CGPoint(x: bounds.midX, y: bounds.midY)
        let inset = bounds.insetBy(dx: 8, dy: 8)
        let clampingBounds = inset.isEmpty ? bounds : inset
        return CGPoint(
            x: min(max(requested.x, clampingBounds.minX), clampingBounds.maxX),
            y: min(max(requested.y, clampingBounds.minY), clampingBounds.maxY)
        )
    }
}

package extension CanvasColor {
    init?(uiColor: UIColor) {
        let resolved = uiColor.resolvedColor(with: .current)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return nil
        }
        let candidate = CanvasColor(
            red: Double(red),
            green: Double(green),
            blue: Double(blue),
            alpha: Double(alpha)
        )
        guard (try? candidate.validate()) != nil else { return nil }
        self = candidate
    }

    var uiColor: UIColor {
        UIColor(
            red: CGFloat(red),
            green: CGFloat(green),
            blue: CGFloat(blue),
            alpha: CGFloat(alpha)
        )
    }
}

private extension UIView {
    var nearestViewController: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let viewController = current as? UIViewController {
                return viewController
            }
            responder = current.next
        }
        return nil
    }
}

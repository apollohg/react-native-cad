import UIKit

@MainActor
final class CanvasPencilHoverCoordinator: NSObject {
    let recognizer: UIHoverGestureRecognizer

    private let send: (CGPoint?) -> Void
    private weak var installedView: UIView?

    init(send: @escaping (CGPoint?) -> Void) {
        self.send = send
        recognizer = UIHoverGestureRecognizer()
        super.init()
        recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        recognizer.addTarget(self, action: #selector(handleHover(_:)))
    }

    func install(on view: UIView) {
        guard installedView !== view else { return }
        uninstall()
        view.addGestureRecognizer(recognizer)
        installedView = view
    }

    func uninstall() {
        guard let view = installedView else { return }
        view.removeGestureRecognizer(recognizer)
        self.installedView = nil
        deliver(screenPoint: nil)
    }

    func deliver(screenPoint: CGPoint?) {
        guard let screenPoint,
              screenPoint.x.isFinite,
              screenPoint.y.isFinite else {
            send(nil)
            return
        }
        send(screenPoint)
    }

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed:
            guard let installedView else {
                deliver(screenPoint: nil)
                return
            }
            deliver(screenPoint: recognizer.location(in: installedView))
        case .ended, .cancelled, .failed:
            deliver(screenPoint: nil)
        case .possible:
            break
        @unknown default:
            deliver(screenPoint: nil)
        }
    }
}

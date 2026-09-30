import UIKit
import CadCanvasCore

enum CanvasGestureRole: Sendable {
    case tap
    case pan
    case pinch
    case manipulation
}

@MainActor
public final class CanvasGestureCoordinator: NSObject, UIGestureRecognizerDelegate, UIPointerInteractionDelegate {
    private let viewport: @MainActor () -> CanvasViewport
    private let elements: @MainActor () -> [CanvasElement]
    private let canManipulate: @MainActor (CanvasPoint) -> Bool
    private let send: @MainActor (CanvasInput) -> Void
    private let hitToleranceScreen: Double

    let tapRecognizer: UITapGestureRecognizer
    let panRecognizer: UIPanGestureRecognizer
    let pinchRecognizer: UIPinchGestureRecognizer
    let manipulationRecognizer: UIPanGestureRecognizer
    private(set) var pointerInteraction: UIPointerInteraction?

    var recognizers: [UIGestureRecognizer] {
        [tapRecognizer, panRecognizer, pinchRecognizer, manipulationRecognizer]
    }

    package init(
        viewport: @escaping @MainActor () -> CanvasViewport,
        elements: @escaping @MainActor () -> [CanvasElement] = { [] },
        canManipulate: @escaping @MainActor (CanvasPoint) -> Bool = { _ in false },
        hitToleranceScreen: Double = 8,
        send: @escaping @MainActor (CanvasInput) -> Void
    ) {
        self.viewport = viewport
        self.elements = elements
        self.canManipulate = canManipulate
        self.hitToleranceScreen = hitToleranceScreen
        self.send = send
        tapRecognizer = UITapGestureRecognizer()
        panRecognizer = UIPanGestureRecognizer()
        pinchRecognizer = UIPinchGestureRecognizer()
        manipulationRecognizer = UIPanGestureRecognizer()
        super.init()

        panRecognizer.maximumNumberOfTouches = 1
        manipulationRecognizer.maximumNumberOfTouches = 1

        for recognizer in recognizers {
            recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            recognizer.delegate = self
        }
        tapRecognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
        ]
        tapRecognizer.addTarget(self, action: #selector(handleTap(_:)))
        panRecognizer.addTarget(self, action: #selector(handlePan(_:)))
        pinchRecognizer.addTarget(self, action: #selector(handlePinch(_:)))
        manipulationRecognizer.addTarget(self, action: #selector(handleManipulation(_:)))
    }

    public func install(on view: UIView) {
        for recognizer in recognizers where recognizer.view !== view {
            recognizer.view?.removeGestureRecognizer(recognizer)
            view.addGestureRecognizer(recognizer)
        }
        if pointerInteraction?.view !== view {
            if let pointerInteraction {
                pointerInteraction.view?.removeInteraction(pointerInteraction)
            }
            let interaction = UIPointerInteraction(delegate: self)
            view.addInteraction(interaction)
            pointerInteraction = interaction
        }
    }

    public func uninstall() {
        for recognizer in recognizers {
            recognizer.view?.removeGestureRecognizer(recognizer)
        }
        if let pointerInteraction {
            pointerInteraction.view?.removeInteraction(pointerInteraction)
            self.pointerInteraction = nil
        }
    }

    func hitElementID(atScreenPoint screenPoint: CanvasPoint) -> UUID? {
        guard hitToleranceScreen.isFinite, hitToleranceScreen >= 0,
              let canvasPoint = canvasPoint(from: screenPoint) else {
            return nil
        }
        let currentViewport = viewport()
        let tolerance = hitToleranceScreen / currentViewport.zoom
        guard tolerance.isFinite, tolerance >= 0 else { return nil }
        return elements().reversed().first { element in
            element.geometry.hitTest(
                canvasPoint,
                tolerance: tolerance,
                textBounds: element.bounds
            )
        }?.id
    }

    func pointerRegion(atScreenPoint screenPoint: CanvasPoint) -> UIPointerRegion? {
        guard let id = hitElementID(atScreenPoint: screenPoint),
              let element = elements().first(where: { $0.id == id }),
              let rect = screenRegion(for: element) else {
            return nil
        }
        return UIPointerRegion(rect: rect, identifier: AnyHashable(id))
    }

    public func pointerInteraction(
        _ interaction: UIPointerInteraction,
        regionFor request: UIPointerRegionRequest,
        defaultRegion: UIPointerRegion
    ) -> UIPointerRegion? {
        pointerRegion(
            atScreenPoint: .init(x: Double(request.location.x), y: Double(request.location.y))
        )
    }

    public func pointerInteraction(
        _ interaction: UIPointerInteraction,
        styleFor region: UIPointerRegion
    ) -> UIPointerStyle? {
        UIPointerStyle(
            shape: .roundedRect(
                CGRect(x: -4, y: -4, width: 8, height: 8),
                radius: 4
            )
        )
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard let first = role(for: gestureRecognizer),
              let second = role(for: otherGestureRecognizer) else {
            return false
        }
        return allowsSimultaneousRecognition(first, second)
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let role = role(for: gestureRecognizer) else { return false }
        return shouldBegin(
            role: role,
            screenLocation: point(gestureRecognizer.location(in: gestureRecognizer.view))
        )
    }

    func allowsSimultaneousRecognition(
        _ first: CanvasGestureRole,
        _ second: CanvasGestureRole
    ) -> Bool {
        false
    }

    func shouldBegin(role: CanvasGestureRole, screenLocation: CanvasPoint) -> Bool {
        switch role {
        case .tap, .pinch:
            return true
        case .pan, .manipulation:
            guard let canvasPoint = canvasPoint(from: screenLocation) else { return false }
            let manipulationOwnsPoint = canManipulate(canvasPoint)
            return role == .manipulation ? manipulationOwnsPoint : !manipulationOwnsPoint
        }
    }

    func map(
        role: CanvasGestureRole,
        state: UIGestureRecognizer.State,
        screenLocation: CanvasPoint? = nil,
        cumulativeScreenDelta: CanvasPoint = .init(x: 0, y: 0),
        scaleFromStart: Double = 1,
        screenVelocity: CanvasPoint = .init(x: 0, y: 0)
    ) -> CanvasInput? {
        switch (role, state) {
        case (.tap, .ended):
            guard let point = canvasPoint(from: screenLocation) else { return nil }
            return .tap(point)

        case (.pan, .began):
            guard let point = canvasPoint(from: screenLocation) else { return nil }
            return .panBegan(point)
        case (.pan, .changed):
            return .panChanged(cumulativeScreenDelta: cumulativeScreenDelta)
        case (.pan, .ended):
            return .panEnded(screenVelocity: screenVelocity)
        case (.pan, .cancelled):
            return .panEnded(screenVelocity: .init(x: 0, y: 0))
        case (.pan, .failed):
            return nil

        case (.pinch, .began):
            guard let screenLocation, finite(screenLocation),
                  let point = canvasPoint(from: screenLocation) else { return nil }
            return .pinchBegan(canvasAnchor: point, screenCentroid: screenLocation)
        case (.pinch, .changed):
            guard let screenLocation, finite(screenLocation) else { return nil }
            return .pinchChanged(
                scaleFromStart: scaleFromStart,
                currentScreenCentroid: screenLocation
            )
        case (.pinch, .ended):
            return .pinchEnded
        case (.pinch, .cancelled):
            return .pinchCancelled
        case (.pinch, .failed):
            return nil

        case (.manipulation, .began):
            guard let point = canvasPoint(from: screenLocation) else { return nil }
            return .manipulationBegan(point: point)
        case (.manipulation, .changed):
            return .manipulationChanged(cumulativeScreenDelta: cumulativeScreenDelta)
        case (.manipulation, .ended):
            return .manipulationEnded
        case (.manipulation, .cancelled):
            return .manipulationCancelled
        case (.manipulation, .failed):
            return nil

        default:
            return nil
        }
    }
}

private extension CanvasGestureCoordinator {
    @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
        deliver(
            role: .tap,
            recognizer: recognizer,
            screenLocation: point(recognizer.location(in: recognizer.view))
        )
    }

    @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
        deliver(
            role: .pan,
            recognizer: recognizer,
            screenLocation: point(recognizer.location(in: recognizer.view)),
            cumulativeScreenDelta: point(recognizer.translation(in: recognizer.view)),
            screenVelocity: point(recognizer.velocity(in: recognizer.view))
        )
    }

    @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        deliver(
            role: .pinch,
            recognizer: recognizer,
            screenLocation: point(recognizer.location(in: recognizer.view)),
            scaleFromStart: Double(recognizer.scale)
        )
    }

    @objc func handleManipulation(_ recognizer: UIPanGestureRecognizer) {
        deliver(
            role: .manipulation,
            recognizer: recognizer,
            screenLocation: point(recognizer.location(in: recognizer.view)),
            cumulativeScreenDelta: point(recognizer.translation(in: recognizer.view)),
            screenVelocity: point(recognizer.velocity(in: recognizer.view))
        )
    }

    func deliver(
        role: CanvasGestureRole,
        recognizer: UIGestureRecognizer,
        screenLocation: CanvasPoint? = nil,
        cumulativeScreenDelta: CanvasPoint = .init(x: 0, y: 0),
        scaleFromStart: Double = 1,
        screenVelocity: CanvasPoint = .init(x: 0, y: 0)
    ) {
        guard let input = map(
            role: role,
            state: recognizer.state,
            screenLocation: screenLocation,
            cumulativeScreenDelta: cumulativeScreenDelta,
            scaleFromStart: scaleFromStart,
            screenVelocity: screenVelocity
        ) else {
            return
        }
        send(input)
    }

    func canvasPoint(from screenPoint: CanvasPoint?) -> CanvasPoint? {
        guard let screenPoint, finite(screenPoint) else { return nil }
        let currentViewport = viewport()
        guard currentViewport.zoom.isFinite, currentViewport.zoom > 0,
              finite(currentViewport.translation),
              currentViewport.viewportSize.width.isFinite,
              currentViewport.viewportSize.height.isFinite,
              currentViewport.viewportSize.width >= 0,
              currentViewport.viewportSize.height >= 0 else {
            return nil
        }
        let canvasPoint = currentViewport.canvasPoint(fromScreen: screenPoint)
        return finite(canvasPoint) ? canvasPoint : nil
    }

    func screenRegion(for element: CanvasElement) -> CGRect? {
        let bounds = element.bounds
        let currentViewport = viewport()
        guard bounds.isFinite, bounds.width >= 0, bounds.height >= 0,
              hitToleranceScreen.isFinite, hitToleranceScreen >= 0,
              currentViewport.zoom.isFinite, currentViewport.zoom > 0,
              finite(currentViewport.translation) else {
            return nil
        }
        let minimum = currentViewport.screenPoint(
            fromCanvas: .init(x: bounds.minX, y: bounds.minY)
        )
        let maximum = currentViewport.screenPoint(
            fromCanvas: .init(x: bounds.maxX, y: bounds.maxY)
        )
        guard finite(minimum), finite(maximum) else { return nil }
        let x = minimum.x - hitToleranceScreen
        let y = minimum.y - hitToleranceScreen
        let width = maximum.x - minimum.x + hitToleranceScreen * 2
        let height = maximum.y - minimum.y + hitToleranceScreen * 2
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              width >= 0, height >= 0 else {
            return nil
        }
        let rect = CGRect(x: x, y: y, width: width, height: height)
        return rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite ? rect : nil
    }

    func role(for recognizer: UIGestureRecognizer) -> CanvasGestureRole? {
        if recognizer === tapRecognizer { return .tap }
        if recognizer === panRecognizer { return .pan }
        if recognizer === pinchRecognizer { return .pinch }
        if recognizer === manipulationRecognizer { return .manipulation }
        return nil
    }

    func point(_ point: CGPoint) -> CanvasPoint {
        CanvasPoint(x: Double(point.x), y: Double(point.y))
    }
}

private func finite(_ point: CanvasPoint) -> Bool {
    point.x.isFinite && point.y.isFinite
}

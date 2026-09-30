import XCTest
import UIKit
@testable import DrawCanvasUI
import DrawCanvasCore

@MainActor
final class CanvasPencilPaletteTests: XCTestCase {
    func testSameActionTogglesOffAndDifferentActionReplacesPresentation() {
        let driver = RecordingPencilPalettePresentationDriver()
        let presenter = CanvasPencilPalettePresenter(presentationDriver: driver)
        let host = UIView(frame: .init(x: 0, y: 0, width: 400, height: 300))
        let actions = CanvasActions(session: CanvasSession())

        presenter.toggle(
            .showInkAttributes,
            anchor: .init(x: 40, y: 50),
            hostView: host,
            actions: actions,
            styleTool: .freehand
        )
        XCTAssertEqual(presenter.presentedAction, .showInkAttributes)
        XCTAssertEqual(driver.presentCount, 1)

        presenter.toggle(
            .showInkAttributes,
            anchor: .init(x: 60, y: 70),
            hostView: host,
            actions: actions,
            styleTool: .freehand
        )
        XCTAssertNil(presenter.presentedAction)
        XCTAssertEqual(driver.dismissCount, 1)

        presenter.toggle(
            .showInkAttributes,
            anchor: .init(x: 60, y: 70),
            hostView: host,
            actions: actions,
            styleTool: .freehand
        )
        presenter.toggle(
            .showContextualPalette,
            anchor: .init(x: 80, y: 90),
            hostView: host,
            actions: actions,
            styleTool: .freehand
        )

        XCTAssertEqual(presenter.presentedAction, .showContextualPalette)
        XCTAssertEqual(driver.dismissCount, 2)
        XCTAssertEqual(driver.presentCount, 3)
    }

    func testAnchorClampsToBoundsAndNonfiniteAnchorFallsBackToCenter() {
        let driver = RecordingPencilPalettePresentationDriver()
        let presenter = CanvasPencilPalettePresenter(presentationDriver: driver)
        let host = UIView(frame: .init(x: 0, y: 0, width: 400, height: 300))
        let actions = CanvasActions(session: CanvasSession())

        presenter.toggle(
            .showInkAttributes,
            anchor: .init(x: -100, y: 900),
            hostView: host,
            actions: actions,
            styleTool: .freehand
        )
        XCTAssertEqual(presenter.presentedAnchor, .init(x: 8, y: 292))

        presenter.dismiss()
        presenter.toggle(
            .showInkAttributes,
            anchor: .init(x: .nan, y: .infinity),
            hostView: host,
            actions: actions,
            styleTool: .freehand
        )
        XCTAssertEqual(presenter.presentedAnchor, .init(x: 200, y: 150))
    }

    func testColorPickerRoutesTextAndStrokeColorsThroughValidatedActions() throws {
        let driver = RecordingPencilPalettePresentationDriver()
        let presenter = CanvasPencilPalettePresenter(presentationDriver: driver)
        let host = UIView(frame: .init(x: 0, y: 0, width: 400, height: 300))
        let session = CanvasSession()
        let actions = CanvasActions(session: session)
        let chosen = UIColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.8)

        session.selectTool(.text)
        presenter.toggle(
            .showColorPalette,
            anchor: .init(x: 40, y: 50),
            hostView: host,
            actions: actions,
            styleTool: .text
        )
        presenter.applySelectedColor(chosen)

        XCTAssertEqual(session.textStyle.color.red, 0.2, accuracy: 0.001)
        XCTAssertEqual(session.textStyle.color.green, 0.4, accuracy: 0.001)
        XCTAssertEqual(session.textStyle.color.blue, 0.6, accuracy: 0.001)
        XCTAssertEqual(session.textStyle.color.alpha, 0.8, accuracy: 0.001)
        XCTAssertEqual(session.strokeStyle.stroke, .black)

        presenter.dismiss()
        session.selectTool(.line)
        presenter.toggle(
            .showColorPalette,
            anchor: .init(x: 40, y: 50),
            hostView: host,
            actions: actions,
            styleTool: .line
        )
        presenter.applySelectedColor(chosen)

        XCTAssertEqual(session.strokeStyle.stroke.red, 0.2, accuracy: 0.001)
        XCTAssertEqual(session.strokeStyle.stroke.green, 0.4, accuracy: 0.001)
        XCTAssertEqual(session.strokeStyle.stroke.blue, 0.6, accuracy: 0.001)
        XCTAssertEqual(session.strokeStyle.stroke.alpha, 0.8, accuracy: 0.001)
    }

    func testInkPaletteSelectsControlsForStyleTool() {
        XCTAssertEqual(CanvasPencilInkPalette.controlKind(for: .line), .stroke(allowsFill: false))
        XCTAssertEqual(CanvasPencilInkPalette.controlKind(for: .freehand), .stroke(allowsFill: false))
        XCTAssertEqual(CanvasPencilInkPalette.controlKind(for: .rectangle), .stroke(allowsFill: true))
        XCTAssertEqual(CanvasPencilInkPalette.controlKind(for: .arch), .stroke(allowsFill: true))
        XCTAssertEqual(CanvasPencilInkPalette.controlKind(for: .text), .text)
    }

    func testContextualPaletteIncludesEveryToolAndConditionalSelectionActions() throws {
        let emptyActions = CanvasActions(session: CanvasSession())
        XCTAssertEqual(emptyActions.session.configuration.availableTools, CanvasTool.allCases)
        XCTAssertFalse(CanvasPencilContextualPalette.availability(for: emptyActions).canDelete)
        XCTAssertFalse(CanvasPencilContextualPalette.availability(for: emptyActions).canDuplicate)

        let element = CanvasElement.rectangle(
            id: UUID(),
            rect: .init(x: 0, y: 0, width: 20, height: 20)
        )
        let session = try CanvasSession(document: CanvasDocument(elements: [element]))
        session.selectedElementID = element.id
        let selectedActions = CanvasActions(session: session)

        XCTAssertTrue(CanvasPencilContextualPalette.availability(for: selectedActions).canDelete)
        XCTAssertTrue(CanvasPencilContextualPalette.availability(for: selectedActions).canDuplicate)
    }
}

@MainActor
private final class RecordingPencilPalettePresentationDriver:
    CanvasPencilPalettePresentationDriving {
    private(set) var presentCount = 0
    private(set) var dismissCount = 0

    func present(
        _ controller: UIViewController,
        from hostView: UIView,
        sourceRect: CGRect
    ) -> Bool {
        presentCount += 1
        return true
    }

    func dismiss(_ controller: UIViewController) {
        dismissCount += 1
    }
}

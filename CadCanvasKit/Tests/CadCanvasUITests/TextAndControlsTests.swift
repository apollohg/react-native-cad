import UIKit
import SwiftUI
import XCTest
import Observation
import CadCanvasCore
@testable import CadCanvasUI

@MainActor
final class TextAndControlsTests: XCTestCase {
    func testRenderSnapshotCarriesEveryGridTierToken() {
        let theme = CanvasTheme.default
        let snapshot = theme.renderSnapshot

        XCTAssertEqual(snapshot.gridMajor, theme.gridMajor)
        XCTAssertEqual(snapshot.axis, theme.axis)
        XCTAssertEqual(snapshot.gridMajorLineWidth, theme.gridMajorLineWidth)
        XCTAssertEqual(snapshot.axisLineWidth, theme.axisLineWidth)
        XCTAssertEqual(snapshot.selectionHandleFill, theme.selectionHandleFill)
        XCTAssertEqual(snapshot.selectionDashPattern, theme.selectionDashPattern)
        XCTAssertEqual(snapshot.guideDashPattern, theme.guideDashPattern)
    }

    func testDarkThemeTunesItsOwnGridTiersRatherThanInheritingLightDefaults() {
        let dark = CanvasTheme.dark.renderSnapshot
        let light = CanvasTheme.default.renderSnapshot

        XCTAssertNotEqual(dark.gridMajor, light.gridMajor)
        XCTAssertNotEqual(dark.axis, light.axis)
        XCTAssertNotEqual(dark.selectionHandleFill, light.selectionHandleFill)

        // A major line must stay visible against its own background: on dark it
        // has to be lighter than the backdrop, on light darker.
        XCTAssertGreaterThan(dark.gridMajor.red, dark.background.red)
        XCTAssertLessThan(light.gridMajor.red, light.background.red)
    }

    func testDecimalParserAcceptsCommaAndPeriodLocales() throws {
        XCTAssertEqual(
            CanvasDecimalParser.parsePositiveFinite(
                "12,5",
                locale: Locale(identifier: "de_DE")
            ),
            12.5
        )
        XCTAssertEqual(
            CanvasDecimalParser.parsePositiveFinite(
                "12.5",
                locale: Locale(identifier: "en_AU")
            ),
            12.5
        )
        XCTAssertNil(
            CanvasDecimalParser.parsePositiveFinite(
                "-1",
                locale: Locale(identifier: "en_AU")
            )
        )
    }
    func testWideEmojiAndFallbackFontsUseMeasuredFrames() throws {
        let engine = CanvasTextLayoutEngine()
        let frame = try XCTUnwrap(engine.measure(
            text: "WWW 👨‍👩‍👧‍👦",
            font: .init(familyName: "Missing Font", pointSize: 72),
            origin: .init(x: 10, y: 20),
            width: 400
        ))

        XCTAssertGreaterThan(frame.height, 0)
        XCTAssertEqual(frame.width, 400)
        XCTAssertTrue(frame.maxX.isFinite)
        XCTAssertTrue(frame.maxY.isFinite)
    }

    func testReplacementWithSameTextIDDiscardsDirtyDraft() throws {
        let id = UUID()
        let original = textElement(id: id, anchor: .init(x: 10, y: 20), text: "original")
        let downloaded = textElement(id: id, anchor: .init(x: 30, y: 40), text: "downloaded")
        let session = try CanvasSession(document: CanvasDocument(elements: [original]))
        session.selectTool(.text)
        let coordinator = makeCoordinator(session: session)
        coordinator.install(on: UIView())
        let view = try XCTUnwrap(coordinator.overlayView(for: id))
        coordinator.textViewDidBeginEditing(view)
        view.text = "dirty"
        coordinator.textViewDidChange(view)

        try session.replaceDocument(CanvasDocument(elements: [downloaded]))
        coordinator.update()
        coordinator.textViewDidEndEditing(view)

        XCTAssertEqual(text(in: session.document.elements[0]).text, "downloaded")
        XCTAssertEqual(text(in: session.document.elements[0]).frame, text(in: downloaded).frame)
    }

    func testTextDragPreservesGrabOffsetWithCumulativeTranslation() throws {
        let element = textElement(anchor: .init(x: 10, y: 20), text: "Drag")
        let session = try CanvasSession(document: CanvasDocument(elements: [element]))
        let coordinator = makeCoordinator(session: session)
        let start = CanvasPoint(
            x: element.bounds.x + element.bounds.width / 2,
            y: element.bounds.y + element.bounds.height / 2
        )
        let end = CanvasPoint(x: start.x + 20, y: start.y + 30)

        XCTAssertTrue(coordinator.beginDrag(id: element.id, at: start))
        XCTAssertTrue(coordinator.updateDrag(id: element.id, to: end))
        XCTAssertEqual(text(in: session.presentationDocument.elements[0]).frame.x, 30)
        XCTAssertEqual(text(in: session.presentationDocument.elements[0]).frame.y, 50)
        XCTAssertEqual(text(in: session.document.elements[0]).frame.x, 10)
        XCTAssertTrue(coordinator.endDrag(id: element.id, at: end))

        XCTAssertEqual(text(in: session.document.elements[0]).frame.x, 30)
        XCTAssertEqual(text(in: session.document.elements[0]).frame.y, 50)
    }

    func testTextEditAndMovePreserveElementIDAndUndoRedo() throws {
        let original = textElement(anchor: .init(x: 10, y: 20), text: "Before")
        let session = try CanvasSession(document: CanvasDocument(elements: [original]))
        session.selectTool(.text)
        let coordinator = makeCoordinator(session: session)
        coordinator.install(on: UIView())

        let view = try XCTUnwrap(coordinator.overlayView(for: original.id))
        coordinator.textViewDidBeginEditing(view)
        view.text = "After"
        coordinator.textViewDidChange(view)
        coordinator.textViewDidEndEditing(view)

        XCTAssertEqual(session.document.elements[0].id, original.id)
        XCTAssertEqual(session.document.elements[0].contentRevision, 1)
        XCTAssertEqual(text(in: session.document.elements[0]).text, "After")

        XCTAssertTrue(coordinator.moveElement(id: original.id, toScreenPoint: CGPoint(x: 23, y: 37)))
        assertText(session.document.elements[0], id: original.id, text: "After", anchor: .init(x: 20, y: 40), revision: 2)

        try session.undo()
        assertText(session.document.elements[0], id: original.id, text: "After", anchor: .init(x: 10, y: 20), revision: 3)
        try session.undo()
        assertText(session.document.elements[0], id: original.id, text: "Before", anchor: .init(x: 10, y: 20), revision: 4)
        try session.redo()
        assertText(session.document.elements[0], id: original.id, text: "After", anchor: .init(x: 10, y: 20), revision: 5)
        try session.redo()
        assertText(session.document.elements[0], id: original.id, text: "After", anchor: .init(x: 20, y: 40), revision: 6)
    }

    func testTextHitTestingUsesCanvasBoundsAtZoomAndTranslation() throws {
        let element = textElement(anchor: .init(x: 10, y: 20), text: "abcd", pointSize: 10)
        let viewport = try CanvasViewport(
            zoom: 3,
            translation: .init(x: 40, y: -20),
            viewportSize: .init(width: 500, height: 400)
        )
        let session = try CanvasSession(document: CanvasDocument(elements: [element]), viewport: viewport)
        let coordinator = makeCoordinator(session: session)

        let insideCanvas = CanvasPoint(x: element.bounds.maxX - 1, y: element.bounds.maxY - 1)
        let insideScreen = viewport.screenPoint(fromCanvas: insideCanvas)
        XCTAssertEqual(
            coordinator.hitTest(screenPoint: CGPoint(x: insideScreen.x, y: insideScreen.y)),
            element.id
        )

        let missCanvas = CanvasPoint(x: element.bounds.maxX + 1, y: element.bounds.maxY + 1)
        let missScreen = viewport.screenPoint(fromCanvas: missCanvas)
        XCTAssertNil(coordinator.hitTest(screenPoint: CGPoint(x: missScreen.x, y: missScreen.y)))
    }

    func testTextSnapAppliesBothAxes() throws {
        let element = textElement(anchor: .init(x: 1, y: 2), text: "Snap")
        let session = try CanvasSession(document: CanvasDocument(elements: [element]))
        let coordinator = makeCoordinator(session: session)

        XCTAssertTrue(coordinator.moveElement(id: element.id, toScreenPoint: CGPoint(x: 14, y: 27)))

        assertText(session.document.elements[0], id: element.id, text: "Snap", anchor: .init(x: 10, y: 30), revision: 1)
    }

    func testOverlappingTextElementsRemainIndependent() throws {
        let bottom = textElement(anchor: .init(x: 10, y: 10), text: "Bottom")
        let top = textElement(anchor: .init(x: 10, y: 10), text: "Top")
        let session = try CanvasSession(document: CanvasDocument(elements: [bottom, top]))
        session.selectTool(.text)
        let coordinator = makeCoordinator(session: session)
        coordinator.install(on: UIView())

        XCTAssertEqual(coordinator.hitTest(screenPoint: CGPoint(x: 11, y: 11)), top.id)
        let topView = try XCTUnwrap(coordinator.overlayView(for: top.id))
        coordinator.textViewDidBeginEditing(topView)
        topView.text = "Edited top"
        coordinator.textViewDidChange(topView)
        coordinator.textViewDidEndEditing(topView)

        assertText(session.document.elements[0], id: bottom.id, text: "Bottom", anchor: .init(x: 10, y: 10), revision: 0)
        assertText(session.document.elements[1], id: top.id, text: "Edited top", anchor: .init(x: 10, y: 10), revision: 1)
    }

    func testScribbleIdentifiersFramesFocusAndCompletionRoundTrip() throws {
        let element = textElement(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000011")!,
            anchor: .init(x: 4, y: 8),
            text: "Scribble",
            pointSize: 10
        )
        let viewport = try CanvasViewport(
            zoom: 2,
            translation: .init(x: 30, y: 40),
            viewportSize: .init(width: 500, height: 400)
        )
        let session = try CanvasSession(document: CanvasDocument(elements: [element]), viewport: viewport)
        session.selectTool(.text)
        let coordinator = makeCoordinator(session: session)
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        coordinator.install(on: host)
        let interaction = try XCTUnwrap(coordinator.scribbleInteraction)
        let identifier = coordinator.identifier(for: element.id)

        XCTAssertEqual(coordinator.elementID(for: identifier), element.id)
        XCTAssertEqual(
            coordinator.indirectScribbleInteraction(interaction, frameForElement: identifier),
            CGRect(x: 38, y: 56, width: 96, height: 24)
        )

        var requested: [String] = []
        coordinator.indirectScribbleInteraction(
            interaction,
            requestElementsIn: CGRect(x: 35, y: 50, width: 20, height: 20)
        ) { requested = $0 }
        XCTAssertEqual(requested, [identifier])

        var focusedInput: (any UIResponder & UITextInput)?
        coordinator.indirectScribbleInteraction(
            interaction,
            focusElementIfNeeded: identifier,
            referencePoint: CGPoint(x: 40, y: 60)
        ) { focusedInput = $0 }
        XCTAssertTrue((focusedInput as? UITextView) === coordinator.overlayView(for: element.id))
        XCTAssertTrue(coordinator.indirectScribbleInteraction(interaction, isElementFocused: identifier))
    }

    func testOverlayDiffHandlesExternalInsertDeleteAndActiveEditRefresh() throws {
        let first = textElement(anchor: .init(x: 0, y: 0), text: "First")
        let second = textElement(anchor: .init(x: 50, y: 50), text: "Second")
        let session = try CanvasSession(document: CanvasDocument(elements: [first]))
        session.selectTool(.text)
        let coordinator = makeCoordinator(session: session)
        let host = UIView()
        coordinator.install(on: host)
        let firstView = try XCTUnwrap(coordinator.overlayView(for: first.id))

        coordinator.textViewDidBeginEditing(firstView)
        firstView.text = "Transient"
        coordinator.textViewDidChange(firstView)
        var externallyMoved = try first.moved(by: .init(x: 10, y: 20))
        externallyMoved.geometry = .text(.init(
            frame: text(in: externallyMoved).frame,
            text: "External",
            font: text(in: externallyMoved).font,
            color: text(in: externallyMoved).color
        ))
        try session.replaceDocument(CanvasDocument(elements: [externallyMoved, second]))
        coordinator.update()

        XCTAssertEqual(firstView.text, "External")
        XCTAssertEqual(firstView.frame.origin, CGPoint(x: 10, y: 20))
        let secondView = try XCTUnwrap(coordinator.overlayView(for: second.id))

        try session.perform(.remove(id: second.id))
        coordinator.update()
        XCTAssertNil(coordinator.overlayView(for: second.id))
        XCTAssertFalse(host.subviews.contains { $0 === secondView })
    }

    func testEmptyNewTextIsRemovedReversiblyWhileExistingEmptyTextRetainsIdentity() throws {
        let newID = UUID(uuidString: "10000000-0000-0000-0000-000000000012")!
        let session = CanvasSession()
        session.selectTool(.text)
        let coordinator = makeCoordinator(session: session, makeElementID: { newID })
        coordinator.install(on: UIView())

        XCTAssertEqual(coordinator.createText(atScreenPoint: CGPoint(x: 20, y: 30), focus: false), newID)
        let newView = try XCTUnwrap(coordinator.overlayView(for: newID))
        let interaction = try XCTUnwrap(coordinator.scribbleInteraction)
        let identifier = coordinator.identifier(for: newID)
        coordinator.indirectScribbleInteraction(interaction, willBeginWritingInElement: identifier)
        coordinator.indirectScribbleInteraction(interaction, didFinishWritingInElement: identifier)
        XCTAssertTrue(session.document.elements.isEmpty)
        XCTAssertEqual(session.presentationDocument.elements.map(\.id), [newID])
        coordinator.textViewDidEndEditing(newView)
        XCTAssertTrue(session.document.elements.isEmpty)
        XCTAssertFalse(session.canUndo)

        let existing = textElement(anchor: .init(x: 0, y: 0), text: "Existing")
        try session.perform(.insert(existing, at: 0))
        coordinator.update()
        let existingView = try XCTUnwrap(coordinator.overlayView(for: existing.id))
        coordinator.textViewDidBeginEditing(existingView)
        existingView.text = ""
        coordinator.textViewDidChange(existingView)
        coordinator.textViewDidEndEditing(existingView)

        XCTAssertEqual(session.document.elements.map(\.id), [existing.id])
        XCTAssertEqual(text(in: session.document.elements[0]).text, "")
        XCTAssertEqual(session.document.elements[0].contentRevision, 1)
    }

    func testNewNonemptyTextCommitsAsOneUndoableInsertion() throws {
        let id = UUID()
        let session = CanvasSession()
        session.selectTool(.text)
        let coordinator = makeCoordinator(session: session, makeElementID: { id })
        coordinator.install(on: UIView())
        XCTAssertEqual(coordinator.createText(atCanvasPoint: .init(x: 10, y: 20), focus: false), id)
        let view = try XCTUnwrap(coordinator.overlayView(for: id))

        coordinator.textViewDidBeginEditing(view)
        view.text = "Committed once"
        coordinator.textViewDidChange(view)

        XCTAssertTrue(session.document.elements.isEmpty)
        XCTAssertEqual(text(in: session.presentationDocument.elements[0]).text, "Committed once")

        coordinator.textViewDidEndEditing(view)
        XCTAssertEqual(session.document.elements.map(\.id), [id])
        XCTAssertEqual(text(in: session.document.elements[0]).text, "Committed once")
        try session.undo()
        XCTAssertTrue(session.document.elements.isEmpty)
        XCTAssertFalse(session.canUndo)
    }

    func testScribbleFinishKeepsEditingActiveForSubsequentKeyboardChangeAndSingleUndo() throws {
        let element = textElement(anchor: .init(x: 10, y: 20), text: "Before")
        let session = try CanvasSession(document: CanvasDocument(elements: [element]))
        session.selectTool(.text)
        let coordinator = makeCoordinator(session: session)
        coordinator.install(on: UIView())
        let view = try XCTUnwrap(coordinator.overlayView(for: element.id))
        let interaction = try XCTUnwrap(coordinator.scribbleInteraction)
        let identifier = coordinator.identifier(for: element.id)

        coordinator.indirectScribbleInteraction(interaction, willBeginWritingInElement: identifier)
        view.text = "Scribble text"
        coordinator.textViewDidChange(view)
        coordinator.indirectScribbleInteraction(interaction, didFinishWritingInElement: identifier)
        XCTAssertEqual(session.document.revision, 0)

        view.text = "Scribble text plus keyboard"
        coordinator.textViewDidChange(view)
        coordinator.textViewDidEndEditing(view)

        assertText(
            session.document.elements[0],
            id: element.id,
            text: "Scribble text plus keyboard",
            anchor: .init(x: 10, y: 20),
            revision: 1
        )
        XCTAssertEqual(session.document.revision, 1)
        try session.undo()
        assertText(
            session.document.elements[0],
            id: element.id,
            text: "Before",
            anchor: .init(x: 10, y: 20),
            revision: 2
        )
    }

    func testScribbleRequestCreatesEmptyTextBeforeCompletionAndSelectsIt() throws {
        let id = UUID(uuidString: "10000000-0000-0000-0000-000000000013")!
        let session = CanvasSession()
        session.selectTool(.text)
        let coordinator = makeCoordinator(session: session, makeElementID: { id })
        coordinator.install(on: UIView())
        let interaction = try XCTUnwrap(coordinator.scribbleInteraction)
        var draftWasReadyInCompletion = false
        var identifiers: [String] = []

        coordinator.indirectScribbleInteraction(
            interaction,
            requestElementsIn: CGRect(x: 40, y: 60, width: 20, height: 10)
        ) { result in
            identifiers = result
            draftWasReadyInCompletion = session.document.elements.isEmpty
                && session.presentationDocument.elements.map(\.id) == [id]
                && coordinator.overlayView(for: id) != nil
                && session.selectedElementID == id
        }

        XCTAssertEqual(identifiers, [id.uuidString])
        XCTAssertTrue(draftWasReadyInCompletion)
        XCTAssertEqual(text(in: session.presentationDocument.elements[0]).frame.x, 50)
        XCTAssertEqual(text(in: session.presentationDocument.elements[0]).frame.y, 70)
    }

    func testTextToolTapCreatesSelectsAndFocusesStableOverlay() throws {
        let session = CanvasSession()
        session.selectTool(.text)
        let coordinator = CadCanvasCoordinator(
            session: session,
            recognizer: nil,
            renderer: TextTestRenderer()
        )
        let host = coordinator.makeHostView()

        coordinator.receive(.tap(.init(x: 17, y: 29)))

        let id = try XCTUnwrap(session.presentationDocument.elements.first?.id)
        XCTAssertTrue(session.document.elements.isEmpty)
        XCTAssertEqual(session.presentationDocument.elements.map(\.id), [id])
        XCTAssertEqual(session.selectedElementID, id)
        XCTAssertNotNil(host.subviews.compactMap { $0 as? UITextView }.first)
        XCTAssertEqual(text(in: session.presentationDocument.elements[0]).frame.x, 17)
        XCTAssertEqual(text(in: session.presentationDocument.elements[0]).frame.y, 29)
    }

    func testOverlayTouchOwnershipFollowsActiveToolAndPreservesHostRouting() throws {
        let element = textElement(anchor: .init(x: 10, y: 10), text: "Route")
        let session = try CanvasSession(document: CanvasDocument(elements: [element]))
        session.selectTool(.text)
        let coordinator = makeCoordinator(session: session)
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        coordinator.install(on: host)
        let overlay = try XCTUnwrap(coordinator.overlayView(for: element.id))
        let interaction = try XCTUnwrap(coordinator.scribbleInteraction)
        let textPoint = CGPoint(x: 12, y: 12)

        for tool in [CanvasTool.select, .line, .rectangle, .arch, .freehand] {
            session.selectTool(tool)
            coordinator.update()

            XCTAssertFalse(overlay.isUserInteractionEnabled, "Tool \(tool) must route direct and Pencil touches to the host")
            XCTAssertTrue(host.hitTest(textPoint, with: nil) === host, "Tool \(tool)")
            var scribbleIDs = ["unexpected"]
            coordinator.indirectScribbleInteraction(
                interaction,
                requestElementsIn: overlay.frame
            ) { scribbleIDs = $0 }
            XCTAssertTrue(scribbleIDs.isEmpty, "Tool \(tool) must not claim Pencil Scribble input")
        }

        session.selectTool(.text)
        coordinator.update()
        XCTAssertTrue(overlay.isUserInteractionEnabled)
        let textHit = host.hitTest(textPoint, with: nil)
        XCTAssertTrue(textHit === overlay || textHit?.isDescendant(of: overlay) == true)
    }

    func testToolSwitchFinishesTextBeforeRendererUpdateAndRestoresHostOwnership() throws {
        let element = textElement(anchor: .init(x: 10, y: 10), text: "Before")
        let session = try CanvasSession(document: CanvasDocument(elements: [element]))
        session.selectTool(.text)
        let renderer = TextTestRenderer()
        let coordinator = CadCanvasCoordinator(session: session, recognizer: nil, renderer: renderer)
        let host = coordinator.makeHostView()
        host.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        coordinator.update()
        let overlay = try XCTUnwrap(host.subviews.compactMap { $0 as? UITextView }.first)
        let textCoordinator = try XCTUnwrap(overlay.delegate as? CanvasTextCoordinator)
        textCoordinator.textViewDidBeginEditing(overlay)
        overlay.text = "Committed on switch"
        textCoordinator.textViewDidChange(overlay)

        session.selectTool(.line)
        coordinator.update()

        XCTAssertEqual(text(in: session.document.elements[0]).text, "Committed on switch")
        XCTAssertEqual(
            renderer.presentations.last?.committed.generation.documentRevision,
            session.document.revision
        )
        XCTAssertFalse(overlay.isUserInteractionEnabled)
        XCTAssertTrue(host.hitTest(CGPoint(x: 12, y: 12), with: nil) === host)
    }

    func testEmptyEditingTargetIsUsableAndLiveTextGrowthDoesNotMutateDocument() throws {
        let id = UUID(uuidString: "10000000-0000-0000-0000-000000000016")!
        let session = CanvasSession()
        session.selectTool(.text)
        let coordinator = makeCoordinator(session: session, makeElementID: { id })
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 500, height: 500))
        coordinator.install(on: host)
        XCTAssertEqual(coordinator.createText(atScreenPoint: CGPoint(x: 20, y: 30), focus: false), id)
        let view = try XCTUnwrap(coordinator.overlayView(for: id))
        let emptyFrame = view.frame

        XCTAssertTrue(emptyFrame.width.isFinite && emptyFrame.height.isFinite)
        XCTAssertGreaterThanOrEqual(emptyFrame.width, 44)
        XCTAssertGreaterThanOrEqual(emptyFrame.height, 44)
        let interaction = try XCTUnwrap(coordinator.scribbleInteraction)
        XCTAssertEqual(
            coordinator.indirectScribbleInteraction(interaction, frameForElement: id.uuidString),
            emptyFrame
        )

        coordinator.textViewDidBeginEditing(view)
        view.text = "A long live editing line\nsecond line\nthird line"
        coordinator.textViewDidChange(view)

        XCTAssertEqual(view.frame.width, emptyFrame.width)
        XCTAssertGreaterThan(view.frame.height, emptyFrame.height)
        XCTAssertEqual(session.document.revision, 0)
        XCTAssertTrue(session.document.elements.isEmpty)
        XCTAssertEqual(text(in: session.presentationDocument.elements[0]).text, view.text)
        XCTAssertEqual(session.presentationDocument.elements[0].contentRevision, 0)
    }

    func testRehostFinishesDirtyExistingEditExactlyOnce() throws {
        let element = textElement(anchor: .init(x: 10, y: 10), text: "Before")
        let session = try CanvasSession(document: CanvasDocument(elements: [element]))
        session.selectTool(.text)
        let coordinator = makeCoordinator(session: session)
        let firstHost = UIView()
        let secondHost = UIView()
        coordinator.install(on: firstHost)
        let view = try XCTUnwrap(coordinator.overlayView(for: element.id))
        coordinator.textViewDidBeginEditing(view)
        view.text = "After rehost"
        coordinator.textViewDidChange(view)

        coordinator.install(on: secondHost)

        assertText(
            session.document.elements[0],
            id: element.id,
            text: "After rehost",
            anchor: .init(x: 10, y: 10),
            revision: 1
        )
        XCTAssertEqual(session.document.revision, 1)
        XCTAssertTrue(firstHost.interactions.isEmpty)
        XCTAssertTrue(firstHost.subviews.compactMap { $0 as? UITextView }.isEmpty)
        XCTAssertEqual(coordinator.overlayView(for: element.id)?.text, "After rehost")

        coordinator.dismantle()
        XCTAssertEqual(session.document.revision, 1)
    }

    func testRehostCleansUpEmptyNewTextBeforeDismantle() throws {
        let id = UUID(uuidString: "10000000-0000-0000-0000-000000000017")!
        let session = CanvasSession()
        session.selectTool(.text)
        let coordinator = makeCoordinator(session: session, makeElementID: { id })
        let firstHost = UIView()
        let secondHost = UIView()
        coordinator.install(on: firstHost)
        XCTAssertEqual(coordinator.createText(atScreenPoint: CGPoint(x: 10, y: 20), focus: false), id)

        coordinator.install(on: secondHost)

        XCTAssertTrue(session.document.elements.isEmpty)
        XCTAssertNil(coordinator.overlayView(for: id))
        XCTAssertTrue(firstHost.interactions.isEmpty)
        coordinator.dismantle()
        XCTAssertTrue(session.document.elements.isEmpty)
        XCTAssertTrue(secondHost.interactions.isEmpty)
    }

    func testRehostRestoresCanonicalTextWhenEditCannotAcquirePreview() throws {
        let element = textElement(anchor: .init(x: 10, y: 10), text: "Canonical")
        let session = try CanvasSession(
            document: CanvasDocument(revision: .max - 2, elements: [element])
        )
        session.selectTool(.text)
        let coordinator = makeCoordinator(session: session)
        let firstHost = UIView()
        let secondHost = UIView()
        coordinator.install(on: firstHost)
        let firstView = try XCTUnwrap(coordinator.overlayView(for: element.id))
        coordinator.textViewDidBeginEditing(firstView)
        firstView.text = "Uncommitted transient"
        coordinator.textViewDidChange(firstView)

        coordinator.install(on: secondHost)

        XCTAssertEqual(session.document.revision, .max - 2)
        XCTAssertEqual(text(in: session.document.elements[0]).text, "Canonical")
        XCTAssertEqual(coordinator.overlayView(for: element.id)?.text, "Canonical")
        XCTAssertFalse(firstHost.subviews.contains { $0 === firstView })
        XCTAssertTrue(coordinator.overlayView(for: element.id)?.superview === secondHost)
    }

    func testInvalidViewportDragAndRevisionExhaustionDoNotMutateDocument() throws {
        let element = textElement(anchor: .init(x: 5, y: 6), text: "Safe")
        let session = try CanvasSession(document: CanvasDocument(elements: [element]))
        let coordinator = makeCoordinator(session: session)
        let snapshot = session.document

        XCTAssertThrowsError(try CanvasViewport(
            zoom: 1,
            translation: .init(x: .nan, y: 0),
            viewportSize: .init(width: 100, height: 100)
        ))
        try session.setViewport(.identity(size: .init(width: 100, height: 100)))
        XCTAssertFalse(coordinator.moveElement(
            id: element.id,
            toScreenPoint: CGPoint(x: CGFloat.infinity, y: 30)
        ))
        XCTAssertEqual(session.document.revision, snapshot.revision)

        let exhaustedSession = try CanvasSession(
            document: CanvasDocument(revision: .max - 2, elements: [element])
        )
        let exhausted = makeCoordinator(session: exhaustedSession)
        XCTAssertFalse(exhausted.moveElement(id: element.id, toScreenPoint: CGPoint(x: 20, y: 30)))
        XCTAssertEqual(exhaustedSession.document.revision, .max - 2)
        XCTAssertEqual(exhaustedSession.document.elements[0].geometry, element.geometry)
    }

    func testEditingCoalescesChangesAndRejectsContentRevisionOverflow() throws {
        let element = textElement(anchor: .init(x: 0, y: 0), text: "A")
        let session = try CanvasSession(document: CanvasDocument(elements: [element]))
        session.selectTool(.text)
        let coordinator = makeCoordinator(session: session)
        coordinator.install(on: UIView())
        let view = try XCTUnwrap(coordinator.overlayView(for: element.id))

        coordinator.textViewDidBeginEditing(view)
        for value in ["AB", "ABC", "ABCD"] {
            view.text = value
            coordinator.textViewDidChange(view)
        }
        XCTAssertEqual(session.document.revision, 0)
        coordinator.textViewDidEndEditing(view)
        XCTAssertEqual(session.document.revision, 1)
        XCTAssertEqual(session.document.elements[0].contentRevision, 1)
        XCTAssertEqual(text(in: session.document.elements[0]).text, "ABCD")

        let boundary = textElement(
            contentRevision: .max - 1,
            anchor: .init(x: 0, y: 0),
            text: "Boundary"
        )
        let boundarySession = try CanvasSession(document: CanvasDocument(elements: [boundary]))
        boundarySession.selectTool(.text)
        let boundaryCoordinator = makeCoordinator(session: boundarySession)
        boundaryCoordinator.install(on: UIView())
        let boundaryView = try XCTUnwrap(boundaryCoordinator.overlayView(for: boundary.id))
        boundaryCoordinator.textViewDidBeginEditing(boundaryView)
        boundaryView.text = "Rejected"
        boundaryCoordinator.textViewDidChange(boundaryView)
        boundaryCoordinator.textViewDidEndEditing(boundaryView)
        XCTAssertEqual(text(in: boundarySession.document.elements[0]).text, "Boundary")
        XCTAssertEqual(boundarySession.document.elements[0].contentRevision, .max - 1)
    }

    func testDismantleFinishesEmptyCreationAndReleasesCoordinator() throws {
        let id = UUID(uuidString: "10000000-0000-0000-0000-000000000015")!
        let session = CanvasSession()
        session.selectTool(.text)
        let host = UIView()
        var coordinator: CanvasTextCoordinator? = makeCoordinator(
            session: session,
            makeElementID: { id }
        )
        weak let weakCoordinator = coordinator
        coordinator?.install(on: host)
        XCTAssertEqual(coordinator?.createText(atScreenPoint: CGPoint(x: 10, y: 20)), id)

        coordinator?.dismantle()
        coordinator = nil

        XCTAssertTrue(session.document.elements.isEmpty)
        XCTAssertNil(weakCoordinator)
        XCTAssertTrue(host.interactions.isEmpty)
        XCTAssertTrue(host.subviews.compactMap { $0 as? UITextView }.isEmpty)
    }

    func testCadCanvasCoordinatorInstallsOverlaysAboveRendererAndDismantlesCleanly() throws {
        let element = textElement(anchor: .init(x: 10, y: 10), text: "Hosted")
        let session = try CanvasSession(document: CanvasDocument(elements: [element]))
        let renderer = TextTestRenderer()
        let coordinator = CadCanvasCoordinator(session: session, recognizer: nil, renderer: renderer)
        let host = coordinator.makeHostView()
        coordinator.update()

        let overlay = host.subviews.compactMap { $0 as? UITextView }.first
        XCTAssertNotNil(overlay)
        XCTAssertTrue(host.subviews.first === renderer.renderView)
        XCTAssertTrue(host.subviews.last === overlay)
        XCTAssertEqual(host.interactions.filter { $0 is UIIndirectScribbleInteraction<CanvasTextCoordinator> }.count, 1)

        coordinator.update()
        XCTAssertEqual(host.interactions.filter { $0 is UIIndirectScribbleInteraction<CanvasTextCoordinator> }.count, 1)
        coordinator.dismantle()

        XCTAssertTrue(host.subviews.compactMap { $0 as? UITextView }.isEmpty)
        XCTAssertTrue(host.interactions.filter { $0 is UIIndirectScribbleInteraction<CanvasTextCoordinator> }.isEmpty)
        XCTAssertTrue(host.gestureRecognizers?.isEmpty ?? true)
    }

    func testToolSelectionUpdatesOnlyActiveTool() throws {
        let element = rectangleElement(rect: .init(x: 10, y: 20, width: 30, height: 40))
        let viewport = try CanvasViewport(
            zoom: 2,
            translation: .init(x: 5, y: 7),
            viewportSize: .init(width: 500, height: 400)
        )
        let session = try CanvasSession(document: CanvasDocument(elements: [element]), viewport: viewport)
        let hidden = DimensionKey(
            axis: .horizontal,
            role: .element,
            elementIDs: [element.id],
            startEdge: 10,
            endEdge: 40
        )
        session.selectedElementID = element.id
        session.hiddenDimensionKeys = [hidden]
        let actions = CanvasActions(session: session)
        let document = session.document

        actions.selectTool(.arch)

        XCTAssertEqual(session.activeTool, .arch)
        XCTAssertEqual(session.document.revision, document.revision)
        XCTAssertEqual(session.document.elements.map(\.geometry), document.elements.map(\.geometry))
        XCTAssertEqual(session.document.calibration, document.calibration)
        XCTAssertEqual(session.viewport, viewport)
        XCTAssertEqual(session.selectedElementID, element.id)
        XCTAssertEqual(session.hiddenDimensionKeys, [hidden])
        XCTAssertFalse(actions.canUndo)
        XCTAssertFalse(actions.canRedo)
    }

    func testValidatedSessionStylingPreservesLastValidStateAndAppliesToCreation() throws {
        let strokeStyle = CanvasStyle(
            stroke: .init(red: 0.2, green: 0.4, blue: 0.8),
            fill: .init(red: 0.9, green: 0.8, blue: 0.3, alpha: 0.5),
            lineWidth: 6
        )
        let textStyle = CanvasTextStyle(
            font: .init(familyName: "Avenir Next", pointSize: 23),
            color: .init(red: 0.7, green: 0.1, blue: 0.2)
        )
        let session = CanvasSession()
        let actions = CanvasActions(session: session)
        try actions.setStrokeStyle(strokeStyle)
        try actions.setTextStyle(textStyle)
        let coordinator = CadCanvasCoordinator(
            session: session,
            recognizer: nil,
            renderer: TextTestRenderer()
        )

        session.selectTool(.line)
        coordinator.receive(.pencilDown(.init(x: 0, y: 0)))
        coordinator.receive(.pencilUp(.init(x: 40, y: 30)))
        session.selectTool(.freehand)
        coordinator.receive(.pencilDown(.init(x: 50, y: 50)))
        coordinator.receive(.pencilMoved(.init(x: 60, y: 55)))
        coordinator.receive(.pencilUp(.init(x: 70, y: 60)))
        session.selectTool(.text)
        coordinator.receive(.tap(.init(x: 80, y: 90)))

        XCTAssertEqual(session.document.elements[0].style, strokeStyle)
        XCTAssertEqual(session.document.elements[1].style, strokeStyle)
        XCTAssertEqual(text(in: session.presentationDocument.elements[2]).font, textStyle.font)
        XCTAssertEqual(text(in: session.presentationDocument.elements[2]).color, textStyle.color)

        do {
        let validStroke = CanvasStyle(
            stroke: .init(red: 0.2, green: 0.4, blue: 0.8),
            fill: .init(red: 0.9, green: 0.8, blue: 0.3, alpha: 0.5),
            lineWidth: 6
        )
        let validText = CanvasTextStyle(
            font: .init(familyName: "Avenir Next", pointSize: 23),
            color: .init(red: 0.7, green: 0.1, blue: 0.2)
        )
        let validSnap = SnapConfiguration(screenThreshold: 0, gridSpacing: 25, snapToGrid: true)
        let session = CanvasSession()
        let actions = CanvasActions(session: session)
        try actions.setStrokeStyle(validStroke)
        try actions.setTextStyle(validText)
        try actions.setSnapConfiguration(validSnap)
        nonisolated(unsafe) var configurationChangeCount = 0

        withObservationTracking {
            _ = session.strokeStyle
            _ = session.textStyle
            _ = session.snapConfiguration
        } onChange: {
            configurationChangeCount += 1
        }

        let invalidStrokes: [(CanvasStyle, String, String)] = [
            (.init(stroke: .black, fill: nil, lineWidth: .nan), "style.lineWidth", "must be finite"),
            (.init(stroke: .black, fill: nil, lineWidth: .infinity), "style.lineWidth", "must be finite"),
            (.init(stroke: .black, fill: nil, lineWidth: -1), "style.lineWidth", "must be greater than zero"),
            (
                .init(stroke: .init(red: 1.1, green: 0, blue: 0), fill: nil, lineWidth: 1),
                "style.stroke.red",
                "must be between zero and one"
            ),
            (
                .init(stroke: .black, fill: .init(red: 0, green: .nan, blue: 0), lineWidth: 1),
                "style.fill.green",
                "must be finite"
            )
        ]
        for (candidate, field, reason) in invalidStrokes {
            assertCanvasValidationError(field: field, reason: reason) {
                try actions.setStrokeStyle(candidate)
            }
            XCTAssertEqual(session.strokeStyle, validStroke)
        }

        let invalidTexts: [(CanvasTextStyle, String, String)] = [
            (.init(font: .init(familyName: "Helvetica", pointSize: .nan), color: .black), "font.pointSize", "must be finite"),
            (.init(font: .init(familyName: "Helvetica", pointSize: .infinity), color: .black), "font.pointSize", "must be finite"),
            (.init(font: .init(familyName: "Helvetica", pointSize: -1), color: .black), "font.pointSize", "must be greater than zero"),
            (
                .init(
                    font: .init(familyName: "Helvetica", pointSize: 12),
                    color: .init(red: 0, green: 0, blue: -0.1)
                ),
                "color.blue",
                "must be between zero and one"
            ),
            (
                .init(
                    font: .init(familyName: "Helvetica", pointSize: 12),
                    color: .init(red: 0, green: 0, blue: 0, alpha: 1.1)
                ),
                "color.alpha",
                "must be between zero and one"
            )
        ]
        for (candidate, field, reason) in invalidTexts {
            assertCanvasValidationError(field: field, reason: reason) {
                try actions.setTextStyle(candidate)
            }
            XCTAssertEqual(session.textStyle, validText)
        }

        let invalidSnaps: [(SnapConfiguration, String, String)] = [
            (.init(screenThreshold: .nan, gridSpacing: 25, snapToGrid: true), "snapConfiguration.screenThreshold", "must be finite"),
            (.init(screenThreshold: .infinity, gridSpacing: 25, snapToGrid: true), "snapConfiguration.screenThreshold", "must be finite"),
            (.init(screenThreshold: -1, gridSpacing: 25, snapToGrid: true), "snapConfiguration.screenThreshold", "must not be negative"),
            (.init(screenThreshold: 0, gridSpacing: .nan, snapToGrid: true), "snapConfiguration.gridSpacing", "must be finite"),
            (.init(screenThreshold: 0, gridSpacing: .infinity, snapToGrid: true), "snapConfiguration.gridSpacing", "must be finite"),
            (.init(screenThreshold: 0, gridSpacing: 0, snapToGrid: true), "snapConfiguration.gridSpacing", "must be greater than zero"),
            (.init(screenThreshold: 0, gridSpacing: -1, snapToGrid: true), "snapConfiguration.gridSpacing", "must be greater than zero")
        ]
        for (candidate, field, reason) in invalidSnaps {
            assertCanvasValidationError(field: field, reason: reason) {
                try actions.setSnapConfiguration(candidate)
            }
            XCTAssertEqual(session.snapConfiguration, validSnap)
        }

        XCTAssertEqual(configurationChangeCount, 0)

        let finalStroke = CanvasStyle(stroke: .black, fill: nil, lineWidth: 7)
        try actions.setStrokeStyle(finalStroke)
        XCTAssertEqual(configurationChangeCount, 1)

        let coordinator = CadCanvasCoordinator(
            session: session,
            recognizer: nil,
            renderer: TextTestRenderer()
        )
        session.selectTool(.line)
        coordinator.receive(.pencilDown(.init(x: 13, y: 14)))
        coordinator.receive(.pencilUp(.init(x: 38, y: 39)))
        assertLine(
            session.document.elements[0],
            start: .init(x: 25, y: 25),
            end: .init(x: 50, y: 50)
        )
        XCTAssertEqual(session.document.elements[0].style, finalStroke)

        session.selectTool(.text)
        coordinator.receive(.tap(.init(x: 61, y: 64)))
        XCTAssertEqual(text(in: session.presentationDocument.elements[1]).frame.x, 50)
        XCTAssertEqual(text(in: session.presentationDocument.elements[1]).frame.y, 75)
        XCTAssertEqual(text(in: session.presentationDocument.elements[1]).font, validText.font)
        XCTAssertEqual(text(in: session.presentationDocument.elements[1]).color, validText.color)
        }
    }

    func testSessionSnapConfigurationAlignsDrawingTextAndRenderedGrid() throws {
        let configuration = SnapConfiguration(
            screenThreshold: 0,
            gridSpacing: 25,
            snapToGrid: true
        )
        let session = CanvasSession()
        try CanvasActions(session: session).setSnapConfiguration(configuration)
        let renderer = TextTestRenderer()
        let coordinator = CadCanvasCoordinator(
            session: session,
            recognizer: nil,
            renderer: renderer
        )
        let host = coordinator.makeHostView()

        session.selectTool(.line)
        coordinator.receive(.pencilDown(.init(x: 13, y: 14)))
        coordinator.receive(.pencilUp(.init(x: 38, y: 39)))
        assertLine(
            session.document.elements[0],
            start: .init(x: 25, y: 25),
            end: .init(x: 50, y: 50)
        )

        session.selectTool(.text)
        coordinator.receive(.tap(.init(x: 61, y: 64)))
        XCTAssertEqual(text(in: session.presentationDocument.elements[1]).frame.x, 50)
        XCTAssertEqual(text(in: session.presentationDocument.elements[1]).frame.y, 75)
        XCTAssertTrue(renderer.snapshots.last?.gridLines.contains { line in
            line.start.x == configuration.gridSpacing && line.end.x == configuration.gridSpacing
        } == true)
        XCTAssertTrue(host.renderView === renderer.renderView)
    }

    func testStylingAndGridControlsAreComposableAgainstCanvasActions() throws {
        let session = CanvasSession()
        let actions = CanvasActions(session: session)
        let strokeStyle = CanvasStyle(
            stroke: .init(red: 0.1, green: 0.2, blue: 0.3),
            fill: nil,
            lineWidth: 4
        )
        let textStyle = CanvasTextStyle(
            font: .init(familyName: "Helvetica Neue", pointSize: 19),
            color: .init(red: 0.5, green: 0.4, blue: 0.3)
        )
        let snap = SnapConfiguration(screenThreshold: 7, gridSpacing: 32, snapToGrid: true)

        try actions.setStrokeStyle(strokeStyle)
        try actions.setTextStyle(textStyle)
        try actions.setSnapConfiguration(snap)

        XCTAssertEqual(session.strokeStyle, strokeStyle)
        XCTAssertEqual(session.textStyle, textStyle)
        XCTAssertEqual(session.snapConfiguration, snap)
        _ = CanvasStrokeStyleControls(actions: actions)
        _ = CanvasTextStyleControls(actions: actions)
        _ = CanvasGridAndSnapControls(actions: actions)
    }

    func testUndoRedoEnablementAndClearFollowReversibleHistory() throws {
        let element = rectangleElement(rect: .init(x: 0, y: 0, width: 40, height: 30))
        let session = try CanvasSession(document: CanvasDocument(elements: [element]))
        let actions = CanvasActions(session: session)

        XCTAssertFalse(actions.canUndo)
        XCTAssertFalse(actions.canRedo)
        XCTAssertTrue(actions.clear())
        XCTAssertTrue(session.document.elements.isEmpty)
        XCTAssertTrue(actions.canUndo)
        XCTAssertFalse(actions.canRedo)

        XCTAssertTrue(actions.undo())
        XCTAssertEqual(session.document.elements.map(\.id), [element.id])
        XCTAssertFalse(actions.canUndo)
        XCTAssertTrue(actions.canRedo)

        XCTAssertTrue(actions.redo())
        XCTAssertTrue(session.document.elements.isEmpty)
        XCTAssertTrue(actions.canUndo)
        XCTAssertFalse(actions.canRedo)
    }

    func testHiddenDimensionKeySurvivesViewportAndLayoutRecomputation() throws {
        let element = rectangleElement(rect: .init(x: 20, y: 30, width: 80, height: 50))
        let session = try CanvasSession(document: CanvasDocument(elements: [element]))
        let actions = CanvasActions(session: session)
        let original = try XCTUnwrap(actions.dimensionLayout.all.first)
        actions.hideDimension(original)

        session.setViewport(try CanvasViewport(
            zoom: 3,
            translation: .init(x: 45, y: -17),
            viewportSize: .init(width: 1024, height: 768)
        ))
        let recomputed = actions.dimensionLayout

        XCTAssertTrue(recomputed.all.contains { $0.key == original.key })
        XCTAssertTrue(session.hiddenDimensionKeys.contains(original.key))
        XCTAssertFalse(actions.visibleDimensions.contains { $0.key == original.key })
    }

    func testOnlySingleElementDimensionsExposeEditAction() throws {
        let first = rectangleElement(rect: .init(x: 0, y: 0, width: 20, height: 30))
        let second = rectangleElement(rect: .init(x: 50, y: 60, width: 40, height: 20))
        let actions = CanvasActions(
            session: try CanvasSession(document: CanvasDocument(elements: [first, second]))
        )
        let dimensions = actions.dimensionLayout.all

        XCTAssertTrue(dimensions.contains { $0.key.role == .gap })
        XCTAssertTrue(dimensions.contains { $0.key.role == .overall })
        XCTAssertTrue(dimensions.contains { actions.canEditDimension($0) })
        for dimension in dimensions {
            XCTAssertEqual(
                actions.canEditDimension(dimension),
                dimension.isEditable
                    && dimension.key.role == .element
                    && dimension.key.elementIDs.count == 1
            )
        }
    }

    func testInvalidCalibrationAndDimensionTextLeaveDocumentUnchanged() throws {
        let line = lineElement(start: .init(x: 0, y: 0), end: .init(x: 100, y: 0))
        let rectangle = rectangleElement(rect: .init(x: 200, y: 100, width: 50, height: 40))
        let session = try CanvasSession(document: CanvasDocument(elements: [line, rectangle]))
        session.selectedElementID = line.id
        let actions = CanvasActions(session: session)
        let dimension = try XCTUnwrap(actions.dimensionLayout.all.first {
            $0.isEditable && $0.key.elementIDs == [rectangle.id]
        })

        for invalid in ["", "0", "-1", "nan", "inf"] {
            let before = session.document

            XCTAssertFalse(actions.calibrateSelectedLine(toMillimeters: invalid), invalid)
            XCTAssertFalse(actions.editDimension(dimension, toMillimeters: invalid), invalid)
            XCTAssertEqual(session.document.revision, before.revision, invalid)
            XCTAssertEqual(session.document.elements.map(\.geometry), before.elements.map(\.geometry), invalid)
            XCTAssertEqual(session.document.calibration, before.calibration, invalid)
            XCTAssertFalse(actions.canUndo, invalid)
            XCTAssertFalse(actions.canRedo, invalid)
        }
    }

    func testZoomToFitChangesViewportWithoutChangingActiveTool() throws {
        let element = rectangleElement(rect: .init(x: 100, y: 200, width: 100, height: 50))
        let session = try CanvasSession(
            document: CanvasDocument(
                elements: [element],
                calibration: .init(millimetersPerPoint: 2.5)
            ),
            viewport: try .identity(size: .init(width: 1000, height: 800))
        )
        session.selectTool(.freehand)
        session.selectedElementID = element.id
        let hidden = DimensionKey(
            axis: .horizontal,
            role: .element,
            elementIDs: [element.id],
            startEdge: 100,
            endEdge: 200
        )
        session.hiddenDimensionKeys = [hidden]
        let actions = CanvasActions(session: session)
        let before = session.document

        XCTAssertTrue(actions.zoomToFit())

        XCTAssertNotEqual(session.viewport, try .identity(size: .init(width: 1000, height: 800)))
        XCTAssertEqual(session.activeTool, .freehand)
        XCTAssertEqual(session.selectedElementID, element.id)
        XCTAssertEqual(session.document.revision, before.revision)
        XCTAssertEqual(session.document.calibration, before.calibration)
        XCTAssertEqual(session.document.elements.map(\.geometry), before.elements.map(\.geometry))
        XCTAssertEqual(session.hiddenDimensionKeys, [hidden])
        XCTAssertFalse(actions.canUndo)
        XCTAssertFalse(actions.canRedo)
    }

    func testZoomToFitHandlesEmptyDegenerateAndOverflowingBoundsSafely() throws {
        let empty = CanvasSession(
            viewport: try .identity(size: .init(width: 500, height: 400)))
        let emptyActions = CanvasActions(session: empty)
        let emptyViewport = empty.viewport
        XCTAssertFalse(emptyActions.zoomToFit())
        XCTAssertEqual(empty.viewport, emptyViewport)

        let vertical = lineElement(start: .init(x: 20, y: 10), end: .init(x: 20, y: 110))
        let degenerate = try CanvasSession(
            document: CanvasDocument(elements: [vertical]),
            viewport: try .identity(size: .init(width: 500, height: 400))
        )
        XCTAssertTrue(CanvasActions(session: degenerate).zoomToFit())
        XCTAssertTrue(degenerate.viewport.zoom.isFinite)
        XCTAssertTrue(degenerate.viewport.translation.x.isFinite)
        XCTAssertTrue(degenerate.viewport.translation.y.isFinite)

        let overflowing = rectangleElement(
            rect: .init(
                x: Double.greatestFiniteMagnitude,
                y: 0,
                width: Double.greatestFiniteMagnitude,
                height: 10
            )
        )
        XCTAssertThrowsError(try CanvasSession(
            document: CanvasDocument(elements: [overflowing]),
            viewport: try .identity(size: .init(width: 500, height: 400))
        ))

        let tiny = rectangleElement(
            rect: .init(x: 0, y: 0, width: .leastNonzeroMagnitude, height: 0)
        )
        let tinySession = try CanvasSession(
            document: CanvasDocument(elements: [tiny]),
            viewport: try .identity(size: .init(width: 500, height: 400))
        )
        XCTAssertTrue(CanvasActions(session: tinySession).zoomToFit())
        XCTAssertEqual(tinySession.viewport.zoom, CanvasViewport.zoomRange.upperBound)
    }

    func testDeleteAndDuplicateUseReversibleSessionCommands() throws {
        let original = rectangleElement(rect: .init(x: 0, y: 0, width: 20, height: 30))
        let duplicateID = try XCTUnwrap(
            UUID(uuidString: "10000000-0000-0000-0000-000000000018")
        )
        let session = try CanvasSession(document: CanvasDocument(elements: [original]))
        session.selectedElementID = original.id
        let actions = CanvasActions(session: session, makeElementID: { duplicateID })

        XCTAssertTrue(actions.duplicateSelection())
        XCTAssertEqual(session.document.elements.map(\.id), [original.id, duplicateID])
        XCTAssertEqual(session.selectedElementID, duplicateID)
        XCTAssertTrue(actions.undo())
        XCTAssertEqual(session.document.elements.map(\.id), [original.id])
        XCTAssertTrue(actions.redo())
        XCTAssertEqual(session.document.elements.map(\.id), [original.id, duplicateID])

        session.selectedElementID = original.id
        XCTAssertTrue(actions.deleteSelection())
        XCTAssertEqual(session.document.elements.map(\.id), [duplicateID])
        XCTAssertTrue(actions.undo())
        XCTAssertEqual(session.document.elements.map(\.id), [original.id, duplicateID])
    }

    func testCalibrationEligibilityRequiresSelectedFiniteNonzeroLine() throws {
        let line = lineElement(start: .init(x: 10, y: 10), end: .init(x: 30, y: 10))
        let point = lineElement(start: .init(x: 5, y: 5), end: .init(x: 5, y: 5))
        let rectangle = rectangleElement(rect: .init(x: 0, y: 0, width: 20, height: 20))
        let session = try CanvasSession(document: CanvasDocument(elements: [line, point, rectangle]))
        let actions = CanvasActions(session: session)

        XCTAssertFalse(actions.canCalibrateSelection)
        session.selectedElementID = rectangle.id
        XCTAssertFalse(actions.canCalibrateSelection)
        session.selectedElementID = point.id
        XCTAssertFalse(actions.canCalibrateSelection)
        session.selectedElementID = line.id
        XCTAssertTrue(actions.canCalibrateSelection)
        XCTAssertTrue(actions.calibrateSelectedLine(toMillimeters: "100"))
        XCTAssertEqual(session.document.calibration.millimetersPerPoint, 5)
        XCTAssertTrue(actions.canUndo)
        XCTAssertTrue(actions.undo())
        XCTAssertEqual(session.document.calibration.millimetersPerPoint, 1)
    }

    func testValidDimensionEditUsesResizeCommandAndUndo() throws {
        let element = rectangleElement(rect: .init(x: 10, y: 20, width: 30, height: 40))
        let session = try CanvasSession(document: CanvasDocument(elements: [element]))
        let actions = CanvasActions(session: session)
        let width = try XCTUnwrap(actions.dimensionLayout.horizontal.first(where: \.isEditable))

        XCTAssertTrue(actions.editDimension(width, toMillimeters: "75"))
        XCTAssertEqual(session.document.elements[0].bounds.minX, 10)
        XCTAssertEqual(session.document.elements[0].bounds.width, 75)
        XCTAssertTrue(actions.canUndo)

        XCTAssertTrue(actions.undo())
        XCTAssertEqual(session.document.elements[0].bounds, element.bounds)
    }

    func testDimensionEditRejectionAndRevisionExhaustionAreNoOps() throws {
        let element = rectangleElement(rect: .init(x: 0, y: 0, width: 20, height: 30))
        let session = try CanvasSession(
            document: CanvasDocument(revision: .max - 2, elements: [element])
        )
        let actions = CanvasActions(session: session)
        let dimension = try XCTUnwrap(actions.dimensionLayout.all.first(where: \.isEditable))
        let before = session.document

        XCTAssertFalse(actions.editDimension(dimension, toMillimeters: "100"))
        XCTAssertEqual(session.document.revision, before.revision)
        XCTAssertEqual(session.document.elements.map(\.geometry), before.elements.map(\.geometry))
        XCTAssertEqual(session.document.calibration, before.calibration)
        XCTAssertFalse(actions.canUndo)
        XCTAssertFalse(actions.canRedo)
    }

    func testShowAllDimensionsOnlyRestoresRequestedAxis() throws {
        let element = rectangleElement(rect: .init(x: 10, y: 20, width: 30, height: 40))
        let session = try CanvasSession(document: CanvasDocument(elements: [element]))
        let actions = CanvasActions(session: session)
        let horizontal = try XCTUnwrap(actions.dimensionLayout.horizontal.first)
        let vertical = try XCTUnwrap(actions.dimensionLayout.vertical.first)
        actions.hideDimension(horizontal)
        actions.hideDimension(vertical)

        actions.showAllDimensions(on: .horizontal)

        XCTAssertFalse(session.hiddenDimensionKeys.contains(horizontal.key))
        XCTAssertTrue(session.hiddenDimensionKeys.contains(vertical.key))
    }

    func testThemeSnapshotPropagatesToCustomRenderer() throws {
        let theme = CanvasTheme(
            background: .init(red: 0.1, green: 0.2, blue: 0.3),
            grid: .init(red: 0.2, green: 0.3, blue: 0.4),
            stroke: .init(red: 0.3, green: 0.4, blue: 0.5),
            selection: .init(red: 0.4, green: 0.5, blue: 0.6),
            guides: .init(red: 0.5, green: 0.6, blue: 0.7),
            dimensions: .init(red: 0.6, green: 0.7, blue: 0.8),
            controlSpacing: 9,
            gridLineWidth: 2,
            selectionLineWidth: 3,
            dimensionLineWidth: 4,
            handleSize: 12,
            gridMajor: .init(red: 0.7, green: 0.8, blue: 0.9),
            axis: .init(red: 0.8, green: 0.9, blue: 0.95),
            gridMajorLineWidth: 5,
            axisLineWidth: 6,
            selectionHandleFill: .init(red: 0.15, green: 0.25, blue: 0.35)
        )
        let renderer = TextTestRenderer()
        let session = CanvasSession()
        try CanvasActions(session: session).setSnapConfiguration(
            .init(screenThreshold: 8, gridSpacing: 23, snapToGrid: false)
        )
        let coordinator = CadCanvasCoordinator(
            session: session,
            recognizer: nil,
            renderer: renderer
        )
        let host = coordinator.makeHostView()

        coordinator.update(theme: theme)

        XCTAssertTrue(renderer.renderView.superview === host)
        XCTAssertFalse(Mirror(reflecting: theme).children.contains { $0.label == "gridSpacing" })
        XCTAssertEqual(renderer.snapshots.last?.theme, theme.renderSnapshot)
        XCTAssertTrue(renderer.snapshots.last?.gridLines.contains { line in
            line.start.x == session.snapConfiguration.gridSpacing
                && line.end.x == session.snapConfiguration.gridSpacing
        } == true)
    }

    func testDimensionLayoutCacheInvalidatesForViewportAndCalibration() throws {
        let element = rectangleElement(rect: .init(x: 10, y: 20, width: 30, height: 40))
        let session = try CanvasSession(document: CanvasDocument(elements: [element]))
        let actions = CanvasActions(session: session)
        let original = try XCTUnwrap(actions.dimensionLayout.horizontal.first)
        XCTAssertEqual(actions.dimensionLayout.horizontal.first, original)

        session.setViewport(try CanvasViewport(
            zoom: 2,
            translation: .init(x: 7, y: 11),
            viewportSize: .init(width: 1024, height: 768)
        ))
        let transformed = try XCTUnwrap(actions.dimensionLayout.horizontal.first)
        XCTAssertNotEqual(transformed.screenStart, original.screenStart)
        XCTAssertEqual(transformed.key, original.key)

        try session.perform(.setCalibration(.init(validatingMillimetersPerPoint: 3)))
        let calibrated = try XCTUnwrap(actions.dimensionLayout.horizontal.first)
        XCTAssertEqual(calibrated.millimeters, original.canvasLength * 3)
        XCTAssertEqual(calibrated.key, original.key)
    }

    func testDimensionLayoutCacheInvalidatesForSameRevisionPreviewGeometry() throws {
        let element = rectangleElement(rect: .init(x: 10, y: 20, width: 30, height: 40))
        let session = try CanvasSession(document: CanvasDocument(elements: [element]))
        let actions = CanvasActions(session: session)
        let original = try XCTUnwrap(actions.dimensionLayout.horizontal.first(where: \.isEditable))
        let revision = session.document.revision

        let token = try session.acquirePreview(.editing(elementID: element.id))
        let firstPreview = try element.replacingBounds(
            .init(x: 10, y: 20, width: 60, height: 40)
        )
        try session.updatePreview(.element(firstPreview), token: token)
        let firstLayout = try XCTUnwrap(actions.dimensionLayout.horizontal.first(where: \.isEditable))

        XCTAssertEqual(session.document.revision, revision)
        XCTAssertEqual(firstPreview.contentRevision, 1)
        XCTAssertEqual(firstLayout.canvasLength, 60)
        XCTAssertEqual(firstLayout.key.startEdge, 10)
        XCTAssertEqual(firstLayout.key.endEdge, 70)
        XCTAssertNotEqual(firstLayout.screenEnd, original.screenEnd)

        let secondPreview = try element.replacingBounds(
            .init(x: 10, y: 20, width: 90, height: 40)
        )
        try session.updatePreview(.element(secondPreview), token: token)
        let secondLayout = try XCTUnwrap(actions.dimensionLayout.horizontal.first(where: \.isEditable))

        XCTAssertEqual(session.document.revision, revision)
        XCTAssertEqual(secondPreview.contentRevision, firstPreview.contentRevision)
        XCTAssertEqual(secondLayout.canvasLength, 90)
        XCTAssertEqual(secondLayout.key.startEdge, 10)
        XCTAssertEqual(secondLayout.key.endEdge, 100)
        XCTAssertNotEqual(secondLayout.screenEnd, firstLayout.screenEnd)
    }

    func testStandardDynamicTypeUsesTwoControlColumns() {
        let sizes: [DynamicTypeSize] = [
            .xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge
        ]

        for size in sizes {
            XCTAssertEqual(CanvasControlLayoutPolicy.columnCount(for: size), 2, "\(size)")
        }
    }

    func testAccessibilityDynamicTypeUsesOneControlColumn() {
        let sizes: [DynamicTypeSize] = [
            .accessibility1, .accessibility2, .accessibility3,
            .accessibility4, .accessibility5
        ]

        for size in sizes {
            XCTAssertEqual(CanvasControlLayoutPolicy.columnCount(for: size), 1, "\(size)")
        }
    }

    func testContextualStyleSectionTracksEveryTool() {
        let expected: [CanvasTool: CanvasControlStyleSection] = [
            .select: .none,
            .line: .stroke(allowsFill: false),
            .rectangle: .stroke(allowsFill: true),
            .arch: .stroke(allowsFill: true),
            .freehand: .freehand,
            .text: .text,
            .eraser: .none
        ]

        for tool in CanvasTool.allCases {
            XCTAssertEqual(CanvasControlLayoutPolicy.styleSection(for: tool), expected[tool])
        }
    }

    func testEveryToolUsesAStableSystemSymbol() {
        let expected: [CanvasTool: String] = [
            .select: "cursorarrow",
            .line: "line.diagonal",
            .rectangle: "rectangle",
            .arch: "rainbow",
            .freehand: "pencil.tip",
            .text: "textformat",
            .eraser: "eraser.fill"
        ]

        for tool in CanvasTool.allCases {
            XCTAssertEqual(CanvasControlLayoutPolicy.symbolName(for: tool), expected[tool])
        }
    }

    func testInspectorSectionsAreContextualAndKeepClearLast() {
        XCTAssertEqual(
            CanvasControlLayoutPolicy.sections(for: .select),
            [.tools, .gridAndSnap, .edit, .clear]
        )
        XCTAssertEqual(
            CanvasControlLayoutPolicy.sections(for: .line),
            [.tools, .style(.stroke(allowsFill: false)), .gridAndSnap, .edit, .clear]
        )
        XCTAssertEqual(
            CanvasControlLayoutPolicy.sections(for: .rectangle),
            [.tools, .style(.stroke(allowsFill: true)), .gridAndSnap, .edit, .clear]
        )
        XCTAssertEqual(
            CanvasControlLayoutPolicy.sections(for: .text),
            [.tools, .style(.text), .gridAndSnap, .edit, .clear]
        )
    }

    func testRegularWidthPresentsInspectorByDefault() {
        XCTAssertTrue(CanvasInspectorPresentationPolicy.shouldPresent(for: .regular))
    }

    func testCompactAndUnknownWidthsKeepInspectorClosedByDefault() {
        XCTAssertFalse(CanvasInspectorPresentationPolicy.shouldPresent(for: .compact))
        XCTAssertFalse(CanvasInspectorPresentationPolicy.shouldPresent(for: nil))
    }

    func testSupplementaryContentMovesToInspectorWhenInlineSpaceIsInsufficient() {
        XCTAssertFalse(
            CanvasInspectorPresentationPolicy.shouldPlaceSupplementaryContentInInspector(
                for: 600,
                dynamicTypeSize: .large
            )
        )
        XCTAssertTrue(
            CanvasInspectorPresentationPolicy.shouldPlaceSupplementaryContentInInspector(
                for: 599,
                dynamicTypeSize: .large
            )
        )
        XCTAssertFalse(
            CanvasInspectorPresentationPolicy.shouldPlaceSupplementaryContentInInspector(
                for: 720,
                dynamicTypeSize: .xLarge
            )
        )
        XCTAssertTrue(
            CanvasInspectorPresentationPolicy.shouldPlaceSupplementaryContentInInspector(
                for: 719,
                dynamicTypeSize: .xLarge
            )
        )
        XCTAssertTrue(
            CanvasInspectorPresentationPolicy.shouldPlaceSupplementaryContentInInspector(
                for: 1_000,
                dynamicTypeSize: .accessibility1
            )
        )
    }
}

@MainActor
private func makeCoordinator(
    session: CanvasSession,
    makeElementID: @escaping () -> UUID = UUID.init
) -> CanvasTextCoordinator {
    CanvasTextCoordinator(
        session: session,
        snapConfiguration: .init(screenThreshold: 0, gridSpacing: 10, snapToGrid: true),
        makeElementID: makeElementID
    )
}

private func textElement(
    id: UUID = UUID(),
    contentRevision: UInt64 = 0,
    anchor: CanvasPoint,
    text: String,
    pointSize: Double = 12
) -> CanvasElement {
    CanvasElement(
        id: id,
        contentRevision: contentRevision,
        geometry: .text(.init(
            frame: .init(
                x: anchor.x,
                y: anchor.y,
                width: Double(text.split(separator: "\n", omittingEmptySubsequences: false).map(\.count).max() ?? 0) * pointSize * 0.6,
                height: Double(max(1, text.split(separator: "\n", omittingEmptySubsequences: false).count)) * pointSize * 1.2
            ),
            text: text,
            font: .init(familyName: "Helvetica", pointSize: pointSize),
            color: .black
        ))
    )
}

private func rectangleElement(id: UUID = UUID(), rect: CanvasRect) -> CanvasElement {
    .rectangle(id: id, rect: rect)
}

private func lineElement(
    id: UUID = UUID(),
    start: CanvasPoint,
    end: CanvasPoint
) -> CanvasElement {
    CanvasElement(id: id, geometry: .line(.init(start: start, end: end)))
}

private func text(in element: CanvasElement) -> CanvasText {
    guard case .text(let text) = element.geometry else {
        XCTFail("Expected text geometry")
        return .init(frame: .init(x: 0, y: 0, width: 0, height: 14.4), text: "", font: .init(familyName: "Helvetica", pointSize: 12), color: .black)
    }
    return text
}

private func assertText(
    _ element: CanvasElement,
    id: UUID,
    text expectedText: String,
    anchor: CanvasPoint,
    revision: UInt64,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(element.id, id, file: file, line: line)
    XCTAssertEqual(element.contentRevision, revision, file: file, line: line)
    let value = text(in: element)
    XCTAssertEqual(value.text, expectedText, file: file, line: line)
    XCTAssertEqual(value.frame.x, anchor.x, file: file, line: line)
    XCTAssertEqual(value.frame.y, anchor.y, file: file, line: line)
}

private func assertLine(
    _ element: CanvasElement,
    start: CanvasPoint,
    end: CanvasPoint,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case .line(let value) = element.geometry else {
        return XCTFail("Expected line geometry", file: file, line: line)
    }
    XCTAssertEqual(value.start, start, file: file, line: line)
    XCTAssertEqual(value.end, end, file: file, line: line)
}

private func assertCanvasValidationError(
    field: String,
    reason: String,
    file: StaticString = #filePath,
    line: UInt = #line,
    operation: () throws -> Void
) {
    XCTAssertThrowsError(try operation(), file: file, line: line) { error in
        XCTAssertEqual(error as? CanvasValidationError, .init(field: field, reason: reason), "Unexpected error type: \(String(reflecting: type(of: error))); error: \(error)", file: file, line: line)
    }
}

@MainActor
private final class TextTestRenderer: CanvasRenderer, CanvasPreparedPresentationRendering {
    let renderView = UIView()
    private(set) var snapshots: [CanvasPreparedScene] = []
    private(set) var presentations: [CanvasPreparedPresentation] = []

    func makeRenderView() -> UIView { renderView }

    func update(_ snapshot: CanvasPreparedScene, in renderView: UIView) {
        snapshots.append(snapshot)
    }

    func update(_ presentation: CanvasPreparedPresentation, in renderView: UIView) {
        presentations.append(presentation)
        snapshots.append(presentation.scene)
    }
}

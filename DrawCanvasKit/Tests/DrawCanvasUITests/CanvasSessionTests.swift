import XCTest
import Observation
import DrawCanvasCore
import DrawCanvasUI

final class CanvasSessionTests: XCTestCase {
    @MainActor
    func testSessionDefaultsExposeDocumentViewportAndToolState() throws {
        let document = CanvasDocument.empty()
        let viewport = try CanvasViewport(
            zoom: 2,
            translation: .init(x: 30, y: 40),
            viewportSize: .init(width: 500, height: 400)
        )

        let session = try CanvasSession(document: document, viewport: viewport)

        assertDocument(session.document, equals: document)
        XCTAssertEqual(session.viewport, viewport)
        XCTAssertNil(session.selectedElementID)
        XCTAssertTrue(session.hiddenDimensionKeys.isEmpty)
        XCTAssertEqual(session.activeTool, .select)
        XCTAssertEqual(
            CanvasTool.allCases,
            [.select, .line, .rectangle, .arch, .freehand, .text, .eraser]
        )
        XCTAssertFalse(session.canUndo)
        XCTAssertFalse(session.canRedo)

        let strokeStyle = CanvasStyle(stroke: .black, fill: nil, lineWidth: 3)
        let textStyle = CanvasTextStyle(
            font: .init(familyName: "Helvetica", pointSize: 18),
            color: .black
        )
        let snapConfiguration = SnapConfiguration(screenThreshold: 4, gridSpacing: 20, snapToGrid: true)
        try session.setStrokeStyle(strokeStyle)
        try session.setTextStyle(textStyle)
        try session.setSnapConfiguration(snapConfiguration)

        XCTAssertEqual(session.strokeStyle, strokeStyle)
        XCTAssertEqual(session.textStyle, textStyle)
        XCTAssertEqual(session.snapConfiguration, snapConfiguration)
        XCTAssertThrowsError(try session.setStrokeStyle(.init(stroke: .black, lineWidth: .nan))) { error in
            XCTAssertEqual(
                error as? CanvasValidationError,
                .init(field: "style.lineWidth", reason: "must be finite")
            )
        }
        XCTAssertThrowsError(try session.setTextStyle(.init(
            font: .init(familyName: "Helvetica", pointSize: 0),
            color: .black
        ))) { error in
            XCTAssertEqual(
                error as? CanvasValidationError,
                .init(field: "font.pointSize", reason: "must be greater than zero")
            )
        }
        XCTAssertThrowsError(try session.setSnapConfiguration(.init(
            screenThreshold: 4,
            gridSpacing: 0,
            snapToGrid: true
        ))) { error in
            XCTAssertEqual(
                error as? CanvasValidationError,
                .init(field: "snapConfiguration.gridSpacing", reason: "must be greater than zero")
            )
        }
        XCTAssertEqual(session.strokeStyle, strokeStyle)
        XCTAssertEqual(session.textStyle, textStyle)
        XCTAssertEqual(session.snapConfiguration, snapConfiguration)
    }

    @MainActor
    func testToolSelectionTracksPreviousEraserAndStyleTools() {
        let session = CanvasSession()

        session.selectTool(.line)
        session.selectTool(.rectangle)
        session.selectPreviousTool()
        XCTAssertEqual(session.activeTool, .line)

        session.toggleEraser()
        XCTAssertEqual(session.activeTool, .eraser)
        session.toggleEraser()
        XCTAssertEqual(session.activeTool, .line)
        XCTAssertEqual(session.mostRecentStyleTool, .line)
    }

    @MainActor
    func testPerformMutatesSingleDocumentAndNotifiesAfterSuccessfulCommit() throws {
        let session = CanvasSession()
        var notifications: [CanvasDocument] = []
        session.onDocumentChange = { notifications.append($0) }
        let element = rectangle(x: 0, y: 0, width: 100, height: 80)

        try session.perform(.insert(element, at: 0))

        XCTAssertEqual(session.document.elements.map(\.id), [element.id])
        XCTAssertEqual(session.document.revision, 1)
        XCTAssertEqual(notifications.map(\.revision), [1])
        XCTAssertEqual(notifications[0].elements.map(\.id), [element.id])
        XCTAssertTrue(session.canUndo)
        XCTAssertFalse(session.canRedo)
    }

    @MainActor
    func testFreehandCommitPublishesExactDraftHandoffUntilNextMutation() throws {
        let session = CanvasSession()
        let id = UUID()
        let token = try session.acquirePreview(.freehand(elementID: id))
        let samples = (0..<30_000).map { index in
            CanvasInkSample(
                point: .init(x: Double(index), y: Double(index % 17)),
                pressure: Double(index % 31) / 30
            )
        }
        try session.appendFreehandInkPreview(
            id: id,
            style: .default,
            confirmed: samples,
            predicted: [],
            pressureEnabled: true,
            widthMode: .canvasScaled,
            token: token
        )
        guard case .freehand(let draft) = session.preview?.payload else {
            return XCTFail("Expected freehand draft")
        }

        try session.commitPreview(token: token)

        let handoff = try XCTUnwrap(session.committedFreehandHandoff)
        XCTAssertEqual(handoff.documentRevision, session.document.revision)
        XCTAssertEqual(handoff.documentIndex, 0)
        XCTAssertEqual(handoff.elementID, id)
        XCTAssertTrue(handoff.draft === draft)

        try session.perform(.insert(rectangle(x: 0, y: 0, width: 10, height: 10), at: 1))
        XCTAssertNil(session.committedFreehandHandoff)
    }

    @MainActor
    func testRejectedPerformIsAtomicAndDoesNotNotify() throws {
        let original = rectangle(x: 0, y: 0, width: 10, height: 10)
        let initial = CanvasDocument(elements: [original])
        let session = try CanvasSession(document: initial)
        var notificationCount = 0
        session.onDocumentChange = { _ in notificationCount += 1 }

        XCTAssertThrowsError(try session.perform(.insert(original, at: 1)))

        assertDocument(session.document, equals: initial)
        XCTAssertEqual(notificationCount, 0)
        XCTAssertFalse(session.canUndo)
        XCTAssertFalse(session.canRedo)
    }

    @MainActor
    func testEncodingDuringPreviewUsesCommittedDocument() throws {
        let original = rectangle(x: 0, y: 0, width: 10, height: 10)
        let session = try CanvasSession(document: CanvasDocument(elements: [original]))
        let committedBytes = try CanvasDocumentCodec.encode(session.document)
        let token = try session.acquirePreview(.editing(elementID: original.id))

        try session.updatePreview(
            .element(try original.moved(by: .init(x: 20, y: 0))),
            token: token
        )

        XCTAssertEqual(try CanvasDocumentCodec.encode(session.document), committedBytes)
        XCTAssertNotNil(session.preview)
    }

    @MainActor
    func testEraserPreviewKeepsCommittedDocumentStableAndCommitsOnce() throws {
        let first = rectangle(x: 0, y: 0, width: 10, height: 10)
        let second = rectangle(x: 20, y: 0, width: 10, height: 10)
        let session = try CanvasSession(document: .init(elements: [first, second]))
        let committed = try CanvasDocumentCodec.encode(session.document)
        let token = try session.acquirePreview(.erasing)

        try session.updatePreview(.erasedElementIDs([first.id, second.id]), token: token)
        XCTAssertEqual(try CanvasDocumentCodec.encode(session.document), committed)
        try session.commitPreview(token: token)
        XCTAssertTrue(session.document.elements.isEmpty)
        try session.undo()
        XCTAssertEqual(session.document.elements.map(\.id), [first.id, second.id])
    }

    @MainActor
    func testEraserPreviewRejectsInvalidIDsAndCancellationRestoresPresentation() throws {
        let element = rectangle(x: 0, y: 0, width: 10, height: 10)
        let session = try CanvasSession(document: .init(elements: [element]))
        let token = try session.acquirePreview(.erasing)

        XCTAssertThrowsError(
            try session.updatePreview(
                .erasedElementIDs([element.id, element.id]),
                token: token
            )
        ) { error in
            XCTAssertEqual(error as? CanvasPreviewError, .invalidPayload)
        }
        XCTAssertThrowsError(
            try session.updatePreview(.erasedElementIDs([UUID()]), token: token)
        ) { error in
            XCTAssertEqual(error as? CanvasPreviewError, .invalidPayload)
        }

        try session.updatePreview(.erasedElementIDs([element.id]), token: token)
        try session.cancelPreview(token: token)
        XCTAssertEqual(session.document.elements.map(\.id), [element.id])
        XCTAssertFalse(session.canUndo)
    }

    @MainActor
    func testEmptyEraserPreviewCommitsNoHistoryEntry() throws {
        let element = rectangle(x: 0, y: 0, width: 10, height: 10)
        let session = try CanvasSession(document: .init(elements: [element]))
        let token = try session.acquirePreview(.erasing)

        try session.updatePreview(.erasedElementIDs([]), token: token)
        try session.commitPreview(token: token)

        XCTAssertEqual(session.document.elements.map(\.id), [element.id])
        XCTAssertFalse(session.canUndo)
    }

    @MainActor
    func testPreviewTokenCannotCommitAnotherOwnersPreview() throws {
        let original = rectangle(x: 0, y: 0, width: 10, height: 10)
        let session = try CanvasSession(document: CanvasDocument(elements: [original]))
        let token = try session.acquirePreview(.editing(elementID: original.id))
        let forged = CanvasPreviewToken()

        XCTAssertThrowsError(try session.commitPreview(token: forged)) { error in
            XCTAssertEqual(error as? CanvasPreviewError, .invalidOwner)
        }
        XCTAssertNotNil(session.preview)
        try session.cancelPreview(token: token)
        XCTAssertNil(session.preview)
    }

    @MainActor
    func testInsertionPreviewCommitsOnceWithoutMutatingCommittedDocumentEarly() throws {
        let element = rectangle(x: 10, y: 20, width: 30, height: 40)
        let session = CanvasSession()
        var notificationCount = 0
        session.onDocumentChange = { _ in notificationCount += 1 }
        let token = try session.acquirePreview(.inserting(elementID: element.id))

        try session.updatePreview(.element(element), token: token)

        XCTAssertTrue(session.document.elements.isEmpty)
        XCTAssertEqual(session.presentationDocument.elements.map(\.id), [element.id])
        XCTAssertEqual(notificationCount, 0)

        try session.commitPreview(token: token)

        XCTAssertEqual(session.document.elements.map(\.id), [element.id])
        XCTAssertEqual(notificationCount, 1)
        XCTAssertTrue(session.canUndo)
    }

    @MainActor
    func testStalePreviewTokenCannotCancelReplacementPreview() throws {
        let first = rectangle(x: 0, y: 0, width: 10, height: 10)
        let second = rectangle(x: 20, y: 0, width: 10, height: 10)
        let session = try CanvasSession(document: CanvasDocument(elements: [first]))
        let stale = try session.acquirePreview(.editing(elementID: first.id))
        try session.replaceDocument(CanvasDocument(elements: [second]))
        let current = try session.acquirePreview(.editing(elementID: second.id))

        XCTAssertThrowsError(try session.cancelPreview(token: stale)) { error in
            XCTAssertEqual(error as? CanvasPreviewError, .invalidOwner)
        }
        XCTAssertEqual(session.preview?.token, current)
    }

    @MainActor
    func testPerformUndoAndRedoEachNotifyWithCommittedRevision() throws {
        let session = CanvasSession()
        let element = rectangle(x: 0, y: 0, width: 10, height: 10)
        var revisions: [UInt64] = []
        session.onDocumentChange = { revisions.append($0.revision) }

        try session.perform(.insert(element, at: 0))
        try session.undo()
        try session.redo()

        XCTAssertEqual(revisions, [1, 2, 3])
        XCTAssertEqual(session.document.elements.map(\.id), [element.id])
        XCTAssertTrue(session.canUndo)
        XCTAssertFalse(session.canRedo)
    }

    @MainActor
    func testEmptyUndoAndRedoDoNotNotifyOrIncrementRevision() throws {
        let session = CanvasSession()
        var notificationCount = 0
        session.onDocumentChange = { _ in notificationCount += 1 }

        try session.undo()
        try session.redo()

        XCTAssertEqual(session.document.revision, 0)
        XCTAssertEqual(notificationCount, 0)
    }

    @MainActor
    func testNewPerformAfterUndoInvalidatesRedo() throws {
        let session = CanvasSession()
        let first = rectangle(x: 0, y: 0, width: 10, height: 10)
        let second = rectangle(x: 20, y: 0, width: 10, height: 10)

        try session.perform(.insert(first, at: 0))
        try session.undo()
        XCTAssertTrue(session.canRedo)

        try session.perform(.insert(second, at: 0))

        XCTAssertFalse(session.canRedo)
        XCTAssertTrue(session.canUndo)
        XCTAssertEqual(session.document.elements.map(\.id), [second.id])
    }

    @MainActor
    func testAcquirePreviewRejectsMissingElementWithoutChangingState() throws {
        let initial = CanvasDocument.empty()
        let session = try CanvasSession(document: initial)
        let missingID = UUID()

        XCTAssertThrowsError(try session.acquirePreview(.editing(elementID: missingID))) { error in
            XCTAssertEqual(error as? CanvasPreviewError, .elementNotFound(missingID))
        }

        assertDocument(session.document, equals: initial)
        XCTAssertFalse(session.canUndo)
    }

    @MainActor
    func testAcquirePreviewRejectsNestedOwnership() throws {
        let first = rectangle(x: 0, y: 0, width: 10, height: 10)
        let second = rectangle(x: 20, y: 0, width: 10, height: 10)
        let session = try CanvasSession(document: CanvasDocument(elements: [first, second]))
        let token = try session.acquirePreview(.editing(elementID: first.id))

        for elementID in [first.id, second.id] {
            XCTAssertThrowsError(try session.acquirePreview(.editing(elementID: elementID))) { error in
                XCTAssertEqual(error as? CanvasPreviewError, .previewAlreadyActive)
            }
        }

        try session.updatePreview(.element(try first.moved(by: .init(x: 15, y: 0))), token: token)
        XCTAssertEqual(session.presentationDocument.elements[0].bounds.x, 15, accuracy: 0.000_001)
        try session.cancelPreview(token: token)
        XCTAssertEqual(session.document.elements[0].bounds.x, 0, accuracy: 0.000_001)
    }

    @MainActor
    func testPreviewUpdatesRenderStateWithoutRevisionOrNotification() throws {
        let original = rectangle(x: 0, y: 0, width: 100, height: 80)
        let session = try CanvasSession(document: CanvasDocument(revision: 7, elements: [original]))
        var notificationCount = 0
        session.onDocumentChange = { _ in notificationCount += 1 }
        let token = try session.acquirePreview(.editing(elementID: original.id))

        try session.updatePreview(.element(try original.moved(by: .init(x: 50, y: 25))), token: token)

        XCTAssertEqual(session.presentationDocument.elements[0].bounds.x, 50, accuracy: 0.000_001)
        XCTAssertEqual(session.presentationDocument.elements[0].bounds.y, 25, accuracy: 0.000_001)
        XCTAssertEqual(session.document.elements[0].bounds.x, 0, accuracy: 0.000_001)
        XCTAssertEqual(session.document.revision, 7)
        XCTAssertEqual(notificationCount, 0)
        XCTAssertFalse(session.canUndo)
    }

    @MainActor
    func testPreviewRejectsElementWithMismatchedIdentity() throws {
        let original = rectangle(x: 0, y: 0, width: 100, height: 80)
        let other = rectangle(x: 200, y: 200, width: 20, height: 20)
        let initial = CanvasDocument(elements: [original, other])
        let session = try CanvasSession(document: initial)
        let token = try session.acquirePreview(.editing(elementID: original.id))

        XCTAssertThrowsError(try session.updatePreview(
            .element(try other.moved(by: .init(x: 50, y: 25))),
            token: token
        ))

        assertDocument(session.document, equals: initial)
        try session.cancelPreview(token: token)
        XCTAssertFalse(session.canUndo)
    }

    @MainActor
    func testUpdateAfterCancellationIsRejected() throws {
        let original = rectangle(x: 0, y: 0, width: 100, height: 80)
        let initial = CanvasDocument(elements: [original])
        let session = try CanvasSession(document: initial)
        let token = try session.acquirePreview(.editing(elementID: original.id))
        try session.cancelPreview(token: token)

        XCTAssertThrowsError(try session.updatePreview(
            .element(try original.moved(by: .init(x: 50, y: 25))),
            token: token
        ))

        assertDocument(session.document, equals: initial)
        XCTAssertFalse(session.canUndo)
    }

    @MainActor
    func testCancelledPreviewRestoresExactDocumentWithoutRevisionNotificationOrUndo() throws {
        let original = rectangle(x: 0, y: 0, width: 100, height: 80)
        let sibling = rectangle(x: 200, y: 40, width: 20, height: 30)
        let initial = CanvasDocument(
            id: UUID(),
            revision: 9,
            elements: [original, sibling],
            calibration: .init(millimetersPerPoint: 2.5)
        )
        let session = try CanvasSession(document: initial)
        var notificationCount = 0
        session.onDocumentChange = { _ in notificationCount += 1 }
        let token = try session.acquirePreview(.editing(elementID: original.id))
        try session.updatePreview(.element(try original.moved(by: .init(x: 50, y: 25))), token: token)

        try session.cancelPreview(token: token)

        assertDocument(session.document, equals: initial)
        XCTAssertEqual(notificationCount, 0)
        XCTAssertFalse(session.canUndo)
        XCTAssertFalse(session.canRedo)
    }

    @MainActor
    func testCommittedPreviewNotifiesOnceAndCreatesExactlyOneUndoStep() throws {
        let original = rectangle(x: 0, y: 0, width: 100, height: 80)
        let initial = CanvasDocument(revision: 4, elements: [original])
        let session = try CanvasSession(document: initial)
        var revisions: [UInt64] = []
        session.onDocumentChange = { revisions.append($0.revision) }
        let token = try session.acquirePreview(.editing(elementID: original.id))
        for offset in 1 ... 10 {
            try session.updatePreview(
                .element(try original.moved(by: .init(x: Double(offset * 10), y: 0))),
                token: token
            )
        }

        try session.commitPreview(token: token)

        XCTAssertEqual(session.document.elements[0].bounds.x, 100, accuracy: 0.000_001)
        XCTAssertEqual(session.document.revision, 5)
        XCTAssertEqual(revisions, [5])
        XCTAssertTrue(session.canUndo)

        try session.undo()

        XCTAssertEqual(session.document.elements[0].geometry, original.geometry)
        XCTAssertEqual(session.document.elements[0].contentRevision, original.contentRevision + 2)
        XCTAssertEqual(session.document.revision, 6)
        XCTAssertFalse(session.canUndo)
        XCTAssertTrue(session.canRedo)
        XCTAssertEqual(revisions, [5, 6])
    }

    @MainActor
    func testCancelledPreviewDoesNotInvalidateExistingRedo() throws {
        let first = rectangle(x: 0, y: 0, width: 10, height: 10)
        let second = rectangle(x: 20, y: 0, width: 10, height: 10)
        let session = try CanvasSession(document: CanvasDocument(elements: [first]))
        try session.perform(.insert(second, at: 1))
        try session.undo()
        XCTAssertTrue(session.canRedo)

        let token = try session.acquirePreview(.editing(elementID: first.id))
        try session.updatePreview(.element(try first.moved(by: .init(x: 15, y: 0))), token: token)
        try session.cancelPreview(token: token)

        XCTAssertTrue(session.canRedo)
        try session.redo()
        XCTAssertEqual(session.document.elements.map(\.id), [first.id, second.id])
    }

    @MainActor
    func testCommittedPreviewInvalidatesExistingRedo() throws {
        let first = rectangle(x: 0, y: 0, width: 10, height: 10)
        let second = rectangle(x: 20, y: 0, width: 10, height: 10)
        let session = try CanvasSession(document: CanvasDocument(elements: [first]))
        try session.perform(.insert(second, at: 1))
        try session.undo()
        XCTAssertTrue(session.canRedo)
        let token = try session.acquirePreview(.editing(elementID: first.id))
        try session.updatePreview(.element(try first.moved(by: .init(x: 15, y: 0))), token: token)

        try session.commitPreview(token: token)

        XCTAssertFalse(session.canRedo)
        XCTAssertTrue(session.canUndo)
    }

    @MainActor
    func testCommitAndCancelWithoutOwnedPreviewThrow() throws {
        let initial = CanvasDocument.empty()
        let session = try CanvasSession(document: initial)
        let token = CanvasPreviewToken()

        XCTAssertThrowsError(try session.commitPreview(token: token)) { error in
            XCTAssertEqual(error as? CanvasPreviewError, .invalidOwner)
        }
        XCTAssertThrowsError(try session.cancelPreview(token: token)) { error in
            XCTAssertEqual(error as? CanvasPreviewError, .invalidOwner)
        }

        assertDocument(session.document, equals: initial)
        XCTAssertFalse(session.canUndo)
    }

    @MainActor
    func testReplaceDocumentValidatesBeforeAnyMutation() throws {
        let original = rectangle(x: 0, y: 0, width: 10, height: 10)
        let inserted = rectangle(x: 20, y: 0, width: 10, height: 10)
        let session = try CanvasSession(document: CanvasDocument(elements: [original]))
        try session.perform(.insert(inserted, at: 1))
        try session.undo()
        session.selectedElementID = original.id
        let hiddenKey = dimensionKey(for: original.id)
        session.hiddenDimensionKeys = [hiddenKey]
        var notificationCount = 0
        session.onDocumentChange = { _ in notificationCount += 1 }
        let beforeReplacement = session.document
        let invalid = CanvasDocument(elements: [original, original])

        XCTAssertThrowsError(try session.replaceDocument(invalid))

        assertDocument(session.document, equals: beforeReplacement)
        XCTAssertEqual(session.selectedElementID, original.id)
        XCTAssertEqual(session.hiddenDimensionKeys, [hiddenKey])
        XCTAssertFalse(session.canUndo)
        XCTAssertTrue(session.canRedo)
        XCTAssertEqual(notificationCount, 0)
    }

    @MainActor
    func testReplaceDocumentResetsTransientAndHistoryStateAndNotifiesOnce() throws {
        let original = rectangle(x: 0, y: 0, width: 10, height: 10)
        let inserted = rectangle(x: 20, y: 0, width: 10, height: 10)
        let replacement = rectangle(x: 100, y: 100, width: 50, height: 60)
        let session = try CanvasSession(document: CanvasDocument(elements: [original]))
        try session.perform(.insert(inserted, at: 1))
        session.selectedElementID = original.id
        session.hiddenDimensionKeys = [dimensionKey(for: original.id)]
        let token = try session.acquirePreview(.editing(elementID: original.id))
        try session.updatePreview(.element(try original.moved(by: .init(x: 10, y: 0))), token: token)
        var notifications: [CanvasDocument] = []
        session.onDocumentChange = { notifications.append($0) }
        let replacementDocument = CanvasDocument(
            id: UUID(),
            revision: 12,
            elements: [replacement],
            calibration: .init(millimetersPerPoint: 0.5)
        )

        try session.replaceDocument(replacementDocument)

        assertDocument(session.document, equals: replacementDocument)
        XCTAssertNil(session.selectedElementID)
        XCTAssertTrue(session.hiddenDimensionKeys.isEmpty)
        XCTAssertFalse(session.canUndo)
        XCTAssertFalse(session.canRedo)
        XCTAssertEqual(notifications.count, 1)
        assertDocument(notifications[0], equals: replacementDocument)

        XCTAssertThrowsError(try session.updatePreview(
            .element(try original.moved(by: .init(x: 50, y: 0))),
            token: token
        ))
        assertDocument(session.document, equals: replacementDocument)
    }

    @MainActor
    func testPerformRejectsRevisionThatCannotReserveImmediateUndo() throws {
        let initial = CanvasDocument(revision: .max - 2)
        let session = try CanvasSession(document: initial)
        let element = rectangle(x: 0, y: 0, width: 10, height: 10)
        var notificationCount = 0
        session.onDocumentChange = { _ in notificationCount += 1 }

        XCTAssertThrowsError(try session.perform(.insert(element, at: 0))) { error in
            XCTAssertEqual(error as? CanvasSessionError, .revisionExhausted)
        }

        assertDocument(session.document, equals: initial)
        XCTAssertEqual(notificationCount, 0)
        XCTAssertFalse(session.canUndo)
        XCTAssertFalse(session.canRedo)
    }

    @MainActor
    func testPerformAtLastReversibleRevisionAllowsUndoThenHidesTerminalRedo() throws {
        let initial = CanvasDocument(revision: .max - 3)
        let session = try CanvasSession(document: initial)
        let element = rectangle(x: 0, y: 0, width: 10, height: 10)
        var revisions: [UInt64] = []
        session.onDocumentChange = { revisions.append($0.revision) }

        try session.perform(.insert(element, at: 0))

        XCTAssertEqual(session.document.revision, .max - 2)
        XCTAssertTrue(session.canUndo)
        XCTAssertFalse(session.canRedo)

        try session.undo()

        XCTAssertEqual(session.document.revision, .max - 1)
        XCTAssertTrue(session.document.elements.isEmpty)
        XCTAssertNoThrow(try session.document.validate())
        XCTAssertFalse(session.canUndo)
        XCTAssertFalse(session.canRedo)
        XCTAssertEqual(revisions, [.max - 2, .max - 1])

        try session.redo()
        XCTAssertEqual(session.document.revision, .max - 1)
        XCTAssertNoThrow(try session.document.validate())
        XCTAssertEqual(revisions, [.max - 2, .max - 1])
    }

    @MainActor
    func testPreviewCommitAtLastReversibleRevisionAllowsOneUndoThenHidesCounterpart() throws {
        let original = rectangle(x: 0, y: 0, width: 10, height: 10)
        let session = try CanvasSession(
            document: CanvasDocument(revision: .max - 3, elements: [original])
        )
        let token = try session.acquirePreview(.editing(elementID: original.id))
        try session.updatePreview(.element(try original.moved(by: .init(x: 20, y: 0))), token: token)

        try session.commitPreview(token: token)

        XCTAssertEqual(session.document.revision, .max - 2)
        XCTAssertEqual(session.document.elements[0].bounds.x, 20, accuracy: 0.000_001)
        XCTAssertTrue(session.canUndo)

        try session.undo()

        XCTAssertEqual(session.document.revision, .max - 1)
        XCTAssertEqual(session.document.elements[0].geometry, original.geometry)
        XCTAssertNoThrow(try session.document.validate())
        XCTAssertFalse(session.canUndo)
        XCTAssertFalse(session.canRedo)
    }

    @MainActor
    func testExhaustedPreviewAcquisitionIsAtomic() throws {
        let original = rectangle(x: 0, y: 0, width: 10, height: 10)
        let session = try CanvasSession(
            document: CanvasDocument(revision: .max - 3, elements: [original])
        )
        try session.perform(.setCalibration(.init(millimetersPerPoint: 2)))
        let snapshot = session.document
        XCTAssertEqual(snapshot.revision, .max - 2)
        XCTAssertTrue(session.canUndo)
        var notifications: [CanvasDocument] = []
        session.onDocumentChange = { notifications.append($0) }
        XCTAssertThrowsError(try session.acquirePreview(.editing(elementID: original.id))) { error in
            XCTAssertEqual(error as? CanvasSessionError, .revisionExhausted)
        }

        XCTAssertEqual(session.document.revision, .max - 2)
        XCTAssertEqual(session.document.elements[0].bounds.x, 0, accuracy: 0.000_001)
        XCTAssertTrue(notifications.isEmpty)
        XCTAssertTrue(session.canUndo)
        XCTAssertFalse(session.canRedo)
        assertDocument(session.document, equals: snapshot)
    }

    @MainActor
    func testInvalidInitialDocumentThrowsWithoutReplacingCallerData() throws {
        let duplicate = rectangle(x: 0, y: 0, width: 10, height: 10)
        let invalid = CanvasDocument(revision: 4, elements: [duplicate, duplicate])

        XCTAssertThrowsError(try CanvasSession(document: invalid)) { error in
            XCTAssertEqual(
                error as? CanvasValidationError,
                CanvasValidationError(field: "elements[1].id", reason: "must be unique")
            )
        }
        XCTAssertEqual(invalid.revision, 4)
        XCTAssertEqual(invalid.elements.count, 2)
        XCTAssertEqual(invalid.elements.map(\.geometry), [duplicate.geometry, duplicate.geometry])
    }

    @MainActor
    func testPerformReconcilesSelectionForRemoveClearAndReplaceAll() throws {
        let first = rectangle(x: 0, y: 0, width: 10, height: 10)
        let second = rectangle(x: 20, y: 0, width: 10, height: 10)
        let replacement = rectangle(x: 40, y: 0, width: 10, height: 10)
        let session = try CanvasSession(document: CanvasDocument(elements: [first, second]))

        session.selectedElementID = first.id
        try session.perform(.remove(id: first.id))
        XCTAssertNil(session.selectedElementID)

        session.selectedElementID = second.id
        try session.perform(.clear)
        XCTAssertNil(session.selectedElementID)

        try session.undo()
        session.selectedElementID = second.id
        try session.perform(.replaceAll([replacement]))
        XCTAssertNil(session.selectedElementID)
    }

    @MainActor
    func testUndoAndRedoReconcileSelectionAgainstCommittedDocument() throws {
        let element = rectangle(x: 0, y: 0, width: 10, height: 10)
        let session = CanvasSession()
        try session.perform(.insert(element, at: 0))
        session.selectedElementID = element.id

        try session.undo()

        XCTAssertNil(session.selectedElementID)
        session.selectedElementID = element.id

        try session.redo()

        XCTAssertEqual(session.selectedElementID, element.id)
        try session.undo()
        XCTAssertNil(session.selectedElementID)
    }

    @MainActor
    func testPreviewCommitPreservesSelectionWhenSelectedElementStillExists() throws {
        let original = rectangle(x: 0, y: 0, width: 10, height: 10)
        let session = try CanvasSession(document: CanvasDocument(elements: [original]))
        session.selectedElementID = original.id
        let token = try session.acquirePreview(.editing(elementID: original.id))
        try session.updatePreview(.element(try original.moved(by: .init(x: 20, y: 0))), token: token)

        try session.commitPreview(token: token)

        XCTAssertEqual(session.selectedElementID, original.id)
    }

    @MainActor
    func testPerformAndUndoAreRejectedWhilePreviewIsActiveWithoutStateLoss() throws {
        let original = rectangle(x: 0, y: 0, width: 10, height: 10)
        let sibling = rectangle(x: 20, y: 0, width: 10, height: 10)
        let session = try CanvasSession(document: CanvasDocument(elements: [original]))
        try session.perform(.insert(sibling, at: 1))
        var notificationCount = 0
        session.onDocumentChange = { _ in notificationCount += 1 }
        let token = try session.acquirePreview(.editing(elementID: original.id))
        try session.updatePreview(.element(try original.moved(by: .init(x: 15, y: 0))), token: token)
        let previewDocument = session.presentationDocument

        XCTAssertThrowsError(try session.perform(.clear)) { error in
            XCTAssertEqual(error as? CanvasPreviewError, .previewAlreadyActive)
        }
        XCTAssertThrowsError(try session.undo()) { error in
            XCTAssertEqual(error as? CanvasPreviewError, .previewAlreadyActive)
        }

        assertDocument(session.presentationDocument, equals: previewDocument)
        XCTAssertEqual(notificationCount, 0)
        XCTAssertFalse(session.canUndo)
        XCTAssertFalse(session.canRedo)

        try session.cancelPreview(token: token)
        XCTAssertTrue(session.canUndo)
    }

    @MainActor
    func testRedoIsRejectedWhilePreviewIsActiveWithoutInvalidatingRedo() throws {
        let original = rectangle(x: 0, y: 0, width: 10, height: 10)
        let sibling = rectangle(x: 20, y: 0, width: 10, height: 10)
        let session = try CanvasSession(document: CanvasDocument(elements: [original]))
        try session.perform(.insert(sibling, at: 1))
        try session.undo()
        let token = try session.acquirePreview(.editing(elementID: original.id))
        try session.updatePreview(.element(try original.moved(by: .init(x: 15, y: 0))), token: token)
        let previewDocument = session.presentationDocument

        XCTAssertThrowsError(try session.redo()) { error in
            XCTAssertEqual(error as? CanvasPreviewError, .previewAlreadyActive)
        }

        assertDocument(session.presentationDocument, equals: previewDocument)
        XCTAssertFalse(session.canUndo)
        XCTAssertFalse(session.canRedo)
        try session.cancelPreview(token: token)
        XCTAssertTrue(session.canRedo)
    }

    @MainActor
    func testUnchangedPreviewCommitIsNoOpAndPreservesRedo() throws {
        let original = rectangle(x: 0, y: 0, width: 10, height: 10)
        let sibling = rectangle(x: 20, y: 0, width: 10, height: 10)
        let session = try CanvasSession(document: CanvasDocument(elements: [original]))
        try session.perform(.insert(sibling, at: 1))
        try session.undo()
        let snapshot = session.document
        var notificationCount = 0
        session.onDocumentChange = { _ in notificationCount += 1 }
        let token = try session.acquirePreview(.editing(elementID: original.id))
        try session.updatePreview(.element(original), token: token)

        try session.commitPreview(token: token)

        assertDocument(session.document, equals: snapshot)
        XCTAssertEqual(notificationCount, 0)
        XCTAssertFalse(session.canUndo)
        XCTAssertTrue(session.canRedo)
    }

    @MainActor
    func testInvalidMatchingPreviewUpdateIsRejectedAndKeepsLastValidRenderState() throws {
        let original = rectangle(x: 0, y: 0, width: 10, height: 10)
        let session = try CanvasSession(document: CanvasDocument(elements: [original]))
        let token = try session.acquirePreview(.editing(elementID: original.id))
        let validPreview = try original.moved(by: .init(x: 15, y: 0))
        try session.updatePreview(.element(validPreview), token: token)
        var invalidPreview = validPreview
        invalidPreview.geometry = .rectangle(
            .init(rect: .init(x: .nan, y: 0, width: 10, height: 10))
        )

        XCTAssertThrowsError(try session.updatePreview(.element(invalidPreview), token: token))

        XCTAssertEqual(session.presentationDocument.elements[0].geometry, validPreview.geometry)
        XCTAssertEqual(session.presentationDocument.elements[0].contentRevision, validPreview.contentRevision)
        XCTAssertEqual(session.document.revision, 0)
        XCTAssertFalse(session.canUndo)
        try session.cancelPreview(token: token)
        XCTAssertEqual(session.document.elements[0].geometry, original.geometry)
    }

    @MainActor
    func testDocumentChangeCallbackSupportsBoundedReentrantPerform() throws {
        let first = rectangle(x: 0, y: 0, width: 10, height: 10)
        let second = rectangle(x: 20, y: 0, width: 10, height: 10)
        let session = CanvasSession()
        var didReenter = false
        var revisions: [UInt64] = []
        session.onDocumentChange = { document in
            revisions.append(document.revision)
            guard !didReenter else {
                return
            }
            didReenter = true
            do {
                try session.perform(.insert(second, at: document.elements.endIndex))
            } catch {
                XCTFail("Unexpected reentrant perform error: \(error)")
            }
        }

        try session.perform(.insert(first, at: 0))

        XCTAssertEqual(session.document.elements.map(\.id), [first.id, second.id])
        XCTAssertEqual(session.document.revision, 2)
        XCTAssertEqual(revisions, [1, 2])
        XCTAssertTrue(session.canUndo)
    }

    @MainActor
    func testObservationTracksCanUndoAndCanRedoChanges() throws {
        let element = rectangle(x: 0, y: 0, width: 10, height: 10)
        let session = CanvasSession()
        nonisolated(unsafe) var historyChangeCount = 0

        withObservationTracking {
            _ = session.canUndo
            _ = session.canRedo
        } onChange: {
            historyChangeCount += 1
        }

        try session.perform(.insert(element, at: 0))
        XCTAssertEqual(historyChangeCount, 1)

        withObservationTracking {
            _ = session.canUndo
            _ = session.canRedo
        } onChange: {
            historyChangeCount += 1
        }

        try session.undo()
        XCTAssertEqual(historyChangeCount, 2)
    }

    private func rectangle(
        id: UUID = UUID(),
        x: Double,
        y: Double,
        width: Double,
        height: Double
    ) -> CanvasElement {
        .rectangle(id: id, rect: .init(x: x, y: y, width: width, height: height))
    }

    private func dimensionKey(for elementID: UUID) -> DimensionKey {
        DimensionKey(
            axis: .horizontal,
            role: .element,
            elementIDs: [elementID],
            startEdge: 0,
            endEdge: 10
        )
    }

    private func assertDocument(
        _ actual: CanvasDocument,
        equals expected: CanvasDocument,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.schemaVersion, expected.schemaVersion, file: file, line: line)
        XCTAssertEqual(actual.id, expected.id, file: file, line: line)
        XCTAssertEqual(actual.revision, expected.revision, file: file, line: line)
        XCTAssertEqual(actual.calibration, expected.calibration, file: file, line: line)
        XCTAssertEqual(actual.elements.map(\.id), expected.elements.map(\.id), file: file, line: line)
        XCTAssertEqual(
            actual.elements.map(\.contentRevision),
            expected.elements.map(\.contentRevision),
            file: file,
            line: line
        )
        XCTAssertEqual(actual.elements.map(\.geometry), expected.elements.map(\.geometry), file: file, line: line)
        XCTAssertEqual(actual.elements.map(\.style), expected.elements.map(\.style), file: file, line: line)
    }
}

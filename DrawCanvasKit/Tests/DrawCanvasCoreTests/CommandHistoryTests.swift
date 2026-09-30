import XCTest
@testable import DrawCanvasCore

final class CommandHistoryTests: XCTestCase {
    func testGeometryCommandAdvancesContentRevisionItself() throws {
        let original = styledRectangle(
            x: 0,
            y: 0,
            width: 10,
            height: 10,
            contentRevision: 7,
            lineWidth: 1
        )
        var document = CanvasDocument(elements: [original])
        var history = CanvasHistory()

        try history.perform(
            .setGeometry(
                id: original.id,
                .rectangle(.init(rect: .init(x: 1, y: 2, width: 30, height: 40)))
            ),
            on: &document
        )

        XCTAssertEqual(document.elements[0].contentRevision, 8)
    }

    func testHistoryRejectsWrongDocumentAndDivergedRevisionAtomically() throws {
        var first = CanvasDocument(elements: [rectangle(x: 0, y: 0, width: 10, height: 10)])
        var second = CanvasDocument(elements: [rectangle(x: 20, y: 0, width: 10, height: 10)])
        var history = CanvasHistory()
        try history.perform(.clear, on: &first)

        let secondSnapshot = second
        XCTAssertThrowsError(try history.undo(on: &second))
        assertSameDocument(second, as: secondSnapshot)

        var diverged = first
        diverged.revision += 1
        let divergedSnapshot = diverged
        XCTAssertThrowsError(try history.undo(on: &diverged))
        assertSameDocument(diverged, as: divergedSnapshot)
    }

    func testInsertUndoRedoPreservesCompleteState() throws {
        let element = styledRectangle(
            x: 10,
            y: 20,
            width: 30,
            height: 40,
            contentRevision: 7,
            lineWidth: 3
        )
        let initial = CanvasDocument(revision: 4, calibration: .init(millimetersPerPoint: 1.25))
        var document = initial
        var history = CanvasHistory()
        var normalizedElement = element
        normalizedElement.contentRevision = 0

        try history.perform(.insert(element, at: 0), on: &document)
        assertSameDocument(document, as: expectedDocument(from: initial, revision: 5, elements: [normalizedElement]))
        try history.undo(on: &document)
        assertSameDocument(document, as: expectedDocument(from: initial, revision: 6, elements: []))
        try history.redo(on: &document)
        assertSameDocument(document, as: expectedDocument(from: initial, revision: 7, elements: [normalizedElement]))
    }

    func testSetGeometryUndoRedoRestoresContentWithForwardRevisions() throws {
        let original = styledRectangle(
            x: 0,
            y: 0,
            width: 100,
            height: 80,
            contentRevision: 3,
            lineWidth: 2
        )
        let initial = CanvasDocument(
            revision: 8,
            elements: [original],
            calibration: .init(millimetersPerPoint: 0.75)
        )
        var document = initial
        var history = CanvasHistory()
        let replacementGeometry = CanvasGeometry.rectangle(
            .init(rect: .init(x: 20, y: 30, width: 120, height: 90))
        )
        var afterSet = original
        afterSet.geometry = replacementGeometry
        afterSet.contentRevision = 4
        var afterUndo = original
        afterUndo.contentRevision = 5
        var afterRedo = afterSet
        afterRedo.contentRevision = 6

        try history.perform(.setGeometry(id: original.id, replacementGeometry), on: &document)
        assertSameDocument(document, as: expectedDocument(from: initial, revision: 9, elements: [afterSet]))
        try history.undo(on: &document)
        assertSameDocument(document, as: expectedDocument(from: initial, revision: 10, elements: [afterUndo]))
        try history.redo(on: &document)
        assertSameDocument(document, as: expectedDocument(from: initial, revision: 11, elements: [afterRedo]))
    }

    func testClearIsOneReversibleCommand() throws {
        let elements: [CanvasElement] = (0 ..< 3).map { index in
            let x = Double(index) * 20
            let contentRevision = UInt64(index + 1)
            let lineWidth = Double(index + 2)
            return styledRectangle(
                x: x,
                y: 0,
                width: 10,
                height: 10,
                contentRevision: contentRevision,
                lineWidth: lineWidth
            )
        }
        let initial = CanvasDocument(
            revision: 12,
            elements: elements,
            calibration: .init(millimetersPerPoint: 2.5)
        )
        var document = initial
        var history = CanvasHistory()

        try history.perform(.clear, on: &document)
        assertSameDocument(document, as: expectedDocument(from: initial, revision: 13, elements: []))
        try history.undo(on: &document)
        assertSameDocument(document, as: expectedDocument(from: initial, revision: 14, elements: elements))
        try history.redo(on: &document)
        assertSameDocument(document, as: expectedDocument(from: initial, revision: 15, elements: []))
    }

    func testRemoveManyIsOneReversibleCommandAndRestoresZOrder() throws {
        let first = rectangle(x: 0, y: 0, width: 10, height: 10)
        let second = rectangle(x: 20, y: 0, width: 10, height: 10)
        let third = rectangle(x: 40, y: 0, width: 10, height: 10)
        var document = CanvasDocument(elements: [first, second, third])
        var history = CanvasHistory()

        try history.perform(.removeMany(ids: [third.id, first.id]), on: &document)
        XCTAssertEqual(document.elements.map(\.id), [second.id])
        try history.undo(on: &document)
        XCTAssertEqual(document.elements.map(\.id), [first.id, second.id, third.id])
        try history.redo(on: &document)
        XCTAssertEqual(document.elements.map(\.id), [second.id])
    }

    func testRemoveManyRejectsDuplicateAndMissingIDsAtomically() throws {
        let first = rectangle(x: 0, y: 0, width: 10, height: 10)
        var document = CanvasDocument(revision: 4, elements: [first])
        var history = CanvasHistory()
        let snapshot = document

        XCTAssertThrowsError(
            try history.perform(.removeMany(ids: [first.id, first.id]), on: &document)
        ) { error in
            XCTAssertEqual(error as? CanvasCommandError, .duplicateRemovalID(first.id))
        }
        assertSameDocument(document, as: snapshot)

        let missing = UUID()
        XCTAssertThrowsError(
            try history.perform(.removeMany(ids: [missing]), on: &document)
        ) { error in
            XCTAssertEqual(error as? CanvasCommandError, .elementNotFound(missing))
        }
        assertSameDocument(document, as: snapshot)
    }

    func testRejectedCommandDoesNotChangeDocumentOrHistory() {
        var document = CanvasDocument.empty()
        var history = CanvasHistory()

        XCTAssertThrowsError(try history.perform(.remove(id: UUID()), on: &document))
        XCTAssertEqual(document.revision, 0)
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.canRedo)
    }

    func testInvalidGeometryAndDuplicateReplaceAllAreAtomic() {
        let original = rectangle(x: 0, y: 0, width: 10, height: 10)
        var document = CanvasDocument(elements: [original])
        var history = CanvasHistory()
        var invalid = original
        invalid.geometry = .rectangle(.init(rect: .init(x: 0, y: 0, width: .nan, height: 10)))

        XCTAssertThrowsError(try history.perform(.setGeometry(id: original.id, invalid.geometry), on: &document))
        XCTAssertThrowsError(try history.perform(.replaceAll([original, original]), on: &document))
        XCTAssertEqual(document.elements.count, 1)
        XCTAssertEqual(document.elements[0].geometry, original.geometry)
        XCTAssertEqual(document.revision, 0)
        XCTAssertFalse(history.canUndo)
    }

    func testRemoveAndReplaceAllUndoRestoreOriginalOrderAndValues() throws {
        let first = styledRectangle(
            x: 0, y: 0, width: 10, height: 10, contentRevision: 2, lineWidth: 2
        )
        let second = styledRectangle(
            x: 20, y: 0, width: 10, height: 10, contentRevision: 4, lineWidth: 4
        )
        let replacement = styledRectangle(
            x: 40, y: 0, width: 10, height: 10, contentRevision: 6, lineWidth: 6
        )
        let initial = CanvasDocument(
            revision: 16,
            elements: [first, second],
            calibration: .init(millimetersPerPoint: 3.25)
        )
        var document = initial
        var history = CanvasHistory()
        var normalizedReplacement = replacement
        normalizedReplacement.contentRevision = 0

        try history.perform(.remove(id: first.id), on: &document)
        assertSameDocument(document, as: expectedDocument(from: initial, revision: 17, elements: [second]))
        try history.undo(on: &document)
        assertSameDocument(document, as: expectedDocument(from: initial, revision: 18, elements: [first, second]))
        try history.redo(on: &document)
        assertSameDocument(document, as: expectedDocument(from: initial, revision: 19, elements: [second]))
        try history.undo(on: &document)
        assertSameDocument(document, as: expectedDocument(from: initial, revision: 20, elements: [first, second]))

        try history.perform(.replaceAll([replacement]), on: &document)
        assertSameDocument(document, as: expectedDocument(from: initial, revision: 21, elements: [normalizedReplacement]))
        try history.undo(on: &document)
        assertSameDocument(document, as: expectedDocument(from: initial, revision: 22, elements: [first, second]))
        try history.redo(on: &document)
        assertSameDocument(document, as: expectedDocument(from: initial, revision: 23, elements: [normalizedReplacement]))
    }

    func testSetCalibrationUndoRedoRestoresExactValue() throws {
        var document = CanvasDocument(calibration: .init(millimetersPerPoint: 1.25))
        var history = CanvasHistory()

        try history.perform(.setCalibration(.init(millimetersPerPoint: 2.5)), on: &document)
        XCTAssertEqual(document.calibration, .init(millimetersPerPoint: 2.5))
        try history.undo(on: &document)
        XCTAssertEqual(document.calibration, .init(millimetersPerPoint: 1.25))
        try history.redo(on: &document)
        XCTAssertEqual(document.calibration, .init(millimetersPerPoint: 2.5))
    }

    func testEverySuccessfulApplicationIncludingUndoAndRedoIncrementsRevision() throws {
        var document = CanvasDocument.empty()
        var history = CanvasHistory()
        let element = rectangle(x: 0, y: 0, width: 10, height: 10)

        try history.perform(.insert(element, at: 0), on: &document)
        XCTAssertEqual(document.revision, 1)
        try history.undo(on: &document)
        XCTAssertEqual(document.revision, 2)
        try history.redo(on: &document)
        XCTAssertEqual(document.revision, 3)
    }

    func testSequentialCommandsCanBeFullyUndoneAndRedone() throws {
        let first = rectangle(x: 0, y: 0, width: 10, height: 10)
        let second = rectangle(x: 20, y: 0, width: 10, height: 10)
        var document = CanvasDocument.empty()
        var history = CanvasHistory()

        try history.perform(.insert(first, at: 0), on: &document)
        try history.perform(.insert(second, at: 1), on: &document)
        try history.undo(on: &document)
        try history.undo(on: &document)
        XCTAssertTrue(document.elements.isEmpty)

        try history.redo(on: &document)
        try history.redo(on: &document)
        XCTAssertEqual(document.elements.map(\.id), [first.id, second.id])
    }

    func testCommandErrorsAreTypedAndLeaveDocumentUnchanged() {
        let existing = rectangle(x: 0, y: 0, width: 10, height: 10)
        let other = rectangle(x: 20, y: 0, width: 10, height: 10)

        assertRejected(
            .insert(existing, at: 0),
            from: CanvasDocument(elements: [existing]),
            equals: .duplicateElement(existing.id)
        )
        assertRejected(
            .insert(other, at: 2),
            from: CanvasDocument(elements: [existing]),
            equals: .invalidIndex(2)
        )
        assertRejected(
            .remove(id: other.id),
            from: CanvasDocument(elements: [existing]),
            equals: .elementNotFound(other.id)
        )
        assertRejected(
            .setText(
                id: existing.id,
                .init(
                    frame: .init(x: 0, y: 0, width: 10, height: 10),
                    text: "Invalid target",
                    font: .init(familyName: "Helvetica", pointSize: 12),
                    color: .black
                )
            ),
            from: CanvasDocument(elements: [existing]),
            equals: .notTextElement(existing.id)
        )
    }

    func testRevisionBoundaryAdvancesLastValidRevision() throws {
        let original = styledRectangle(
            x: 0,
            y: 0,
            width: 10,
            height: 10,
            contentRevision: 7,
            lineWidth: 3
        )
        var document = CanvasDocument(revision: .max - 2, elements: [original])

        let inverse = try CanvasCommandEngine.apply(.clear, to: &document)

        XCTAssertEqual(document.revision, .max - 1)
        XCTAssertTrue(document.elements.isEmpty)
        if case .replaceAll(let restored) = inverse {
            assertSameElements(restored, as: [original])
        } else {
            XCTFail("Expected replaceAll inverse")
        }
    }

    func testRevisionOverflowIsTypedAndAtomicForEngineAndHistory() {
        let original = rectangle(x: 0, y: 0, width: 10, height: 10)
        let overflowing = CanvasDocument(revision: .max - 1, elements: [original])
        var directDocument = overflowing

        XCTAssertThrowsError(try CanvasCommandEngine.apply(.clear, to: &directDocument)) { error in
            XCTAssertEqual(error as? CanvasCommandError, .revisionOverflow)
        }
        assertSameDocument(directDocument, as: overflowing)

        var historyDocument = overflowing
        var history = CanvasHistory()
        XCTAssertThrowsError(try history.perform(.clear, on: &historyDocument)) { error in
            XCTAssertEqual(error as? CanvasCommandError, .revisionOverflow)
        }
        assertSameDocument(historyDocument, as: overflowing)
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.canRedo)
    }

    func testFailedPerformPreservesExistingRedoStackUntilSuccessfulPerform() throws {
        let first = rectangle(x: 0, y: 0, width: 10, height: 10)
        let second = rectangle(x: 20, y: 0, width: 10, height: 10)
        var document = CanvasDocument.empty()
        var history = CanvasHistory()

        try history.perform(.insert(first, at: 0), on: &document)
        try history.undo(on: &document)
        XCTAssertTrue(history.canRedo)

        XCTAssertThrowsError(try history.perform(.remove(id: UUID()), on: &document))
        XCTAssertTrue(history.canRedo)

        try history.perform(.insert(second, at: 0), on: &document)
        XCTAssertFalse(history.canRedo)
        XCTAssertTrue(history.canUndo)
    }

    func testFailedUndoPreservesBothDocumentAndUndoEntry() throws {
        let element = rectangle(x: 0, y: 0, width: 10, height: 10)
        var document = CanvasDocument.empty()
        var history = CanvasHistory()
        try history.perform(.insert(element, at: 0), on: &document)
        let documentAfterPerform = document
        document.elements.removeAll()
        document.revision += 1
        let externallyChanged = document

        XCTAssertThrowsError(try history.undo(on: &document)) { error in
            XCTAssertEqual(error as? CanvasHistoryError, .divergedDocument)
        }
        assertSameDocument(document, as: externallyChanged)
        XCTAssertTrue(history.canUndo)
        XCTAssertFalse(history.canRedo)

        document = documentAfterPerform
        try history.undo(on: &document)
        XCTAssertFalse(history.canUndo)
        XCTAssertTrue(history.canRedo)
    }

    func testFailedRedoPreservesBothDocumentAndRedoEntry() throws {
        let element = rectangle(x: 0, y: 0, width: 10, height: 10)
        var document = CanvasDocument.empty()
        var history = CanvasHistory()
        try history.perform(.insert(element, at: 0), on: &document)
        try history.undo(on: &document)
        let documentAfterUndo = document
        document.elements.append(element)
        document.revision += 1
        let externallyChanged = document

        XCTAssertThrowsError(try history.redo(on: &document)) { error in
            XCTAssertEqual(error as? CanvasHistoryError, .divergedDocument)
        }
        assertSameDocument(document, as: externallyChanged)
        XCTAssertFalse(history.canUndo)
        XCTAssertTrue(history.canRedo)

        document = documentAfterUndo
        try history.redo(on: &document)
        XCTAssertTrue(history.canUndo)
        XCTAssertFalse(history.canRedo)
    }

    func testRemoveAllClearsBothStacksAndEmptyUndoRedoAreNoOps() throws {
        let element = rectangle(x: 0, y: 0, width: 10, height: 10)
        var document = CanvasDocument.empty()
        var history = CanvasHistory()
        try history.perform(.insert(element, at: 0), on: &document)
        try history.undo(on: &document)

        history.removeAll()
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.canRedo)
        let revision = document.revision
        try history.undo(on: &document)
        try history.redo(on: &document)
        XCTAssertEqual(document.revision, revision)
    }

    func testPrevalidatedFreehandInsertionRemainsUndoable() throws {
        let samples = (0..<30_000).map { index in
            CanvasInkSample(
                point: .init(x: Double(index), y: Double(index % 19)),
                pressure: Double(index % 31) / 30
            )
        }
        let element = CanvasElement(
            id: UUID(),
            geometry: .freehand(.init(samples: samples, pressureEnabled: true)),
            style: .default
        )
        var document = CanvasDocument.empty()
        var history = CanvasHistory()

        try history.performPrevalidatedFreehandInsertion(
            element,
            at: 0,
            on: &document
        )

        XCTAssertEqual(document.elements.first?.geometry, element.geometry)
        XCTAssertTrue(history.canUndo)
        try history.undo(on: &document)
        XCTAssertTrue(document.elements.isEmpty)
    }

    private func assertRejected(
        _ command: CanvasCommand,
        from original: CanvasDocument,
        equals expectedError: CanvasCommandError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var document = original
        XCTAssertThrowsError(try CanvasCommandEngine.apply(command, to: &document), file: file, line: line) { error in
            XCTAssertEqual(error as? CanvasCommandError, expectedError, file: file, line: line)
        }
        assertSameDocument(document, as: original, file: file, line: line)
    }

    private func assertSameDocument(
        _ actual: CanvasDocument,
        as expected: CanvasDocument,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.schemaVersion, expected.schemaVersion, file: file, line: line)
        XCTAssertEqual(actual.id, expected.id, file: file, line: line)
        XCTAssertEqual(actual.revision, expected.revision, file: file, line: line)
        XCTAssertEqual(actual.calibration, expected.calibration, file: file, line: line)
        XCTAssertEqual(actual.elements.map(\.id), expected.elements.map(\.id), file: file, line: line)
        XCTAssertEqual(actual.elements.map(\.contentRevision), expected.elements.map(\.contentRevision), file: file, line: line)
        XCTAssertEqual(actual.elements.map(\.geometry), expected.elements.map(\.geometry), file: file, line: line)
        XCTAssertEqual(actual.elements.map(\.style), expected.elements.map(\.style), file: file, line: line)
    }

    private func assertSameElements(
        _ actual: [CanvasElement],
        as expected: [CanvasElement],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.map(\.id), expected.map(\.id), file: file, line: line)
        XCTAssertEqual(actual.map(\.contentRevision), expected.map(\.contentRevision), file: file, line: line)
        XCTAssertEqual(actual.map(\.geometry), expected.map(\.geometry), file: file, line: line)
        XCTAssertEqual(actual.map(\.style), expected.map(\.style), file: file, line: line)
    }

    private func expectedDocument(
        from initial: CanvasDocument,
        revision: UInt64,
        elements: [CanvasElement]
    ) -> CanvasDocument {
        var expected = initial
        expected.revision = revision
        expected.elements = elements
        return expected
    }

    private func styledRectangle(
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        contentRevision: UInt64,
        lineWidth: Double
    ) -> CanvasElement {
        CanvasElement(
            id: UUID(),
            contentRevision: contentRevision,
            geometry: .rectangle(.init(rect: .init(x: x, y: y, width: width, height: height))),
            style: .init(
                stroke: .init(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.8),
                fill: .init(red: 0.7, green: 0.6, blue: 0.5, alpha: 0.4),
                lineWidth: lineWidth
            )
        )
    }

    private func rectangle(x: Double, y: Double, width: Double, height: Double) -> CanvasElement {
        CanvasElement.rectangle(id: UUID(), rect: .init(x: x, y: y, width: width, height: height))
    }
}

import Foundation

package enum CanvasHistoryError: Error, Equatable, Sendable {
    case divergedDocument
}

package struct CanvasHistoryEntry: Sendable {
    let documentID: UUID
    var expectedRevision: UInt64
    let operation: CanvasHistoryOperation
}

package struct CanvasHistory: Sendable {
    private var undoStack: [CanvasHistoryEntry] = []
    private var redoStack: [CanvasHistoryEntry] = []

    package init() {}

    package var canUndo: Bool { !undoStack.isEmpty }
    package var canRedo: Bool { !redoStack.isEmpty }

    package mutating func perform(
        _ command: CanvasCommand,
        on document: inout CanvasDocument
    ) throws {
        var candidate = document
        let inverse = try CanvasCommandEngine.apply(command, to: &candidate)
        undoStack.append(.init(
            documentID: candidate.id,
            expectedRevision: candidate.revision,
            operation: inverse
        ))
        redoStack.removeAll()
        document = candidate
    }

    package mutating func performPrevalidatedFreehandInsertion(
        _ element: CanvasElement,
        at index: Int,
        on document: inout CanvasDocument
    ) throws {
        var candidate = document
        let inverse = try CanvasCommandEngine.applyPrevalidatedFreehandInsertion(
            element,
            at: index,
            to: &candidate
        )
        undoStack.append(.init(
            documentID: candidate.id,
            expectedRevision: candidate.revision,
            operation: inverse
        ))
        redoStack.removeAll()
        document = candidate
    }

    package mutating func undo(on document: inout CanvasDocument) throws {
        guard let entry = undoStack.last else { return }
        try requireMatch(entry, document: document)

        var candidate = document
        let inverse = try CanvasCommandEngine.applyHistoryOperation(entry.operation, to: &candidate)
        undoStack.removeLast()
        if !undoStack.isEmpty {
            undoStack[undoStack.endIndex - 1].expectedRevision = candidate.revision
        }
        redoStack.append(.init(
            documentID: candidate.id,
            expectedRevision: candidate.revision,
            operation: inverse
        ))
        document = candidate
    }

    package mutating func redo(on document: inout CanvasDocument) throws {
        guard let entry = redoStack.last else { return }
        try requireMatch(entry, document: document)

        var candidate = document
        let inverse = try CanvasCommandEngine.applyHistoryOperation(entry.operation, to: &candidate)
        redoStack.removeLast()
        if !redoStack.isEmpty {
            redoStack[redoStack.endIndex - 1].expectedRevision = candidate.revision
        }
        undoStack.append(.init(
            documentID: candidate.id,
            expectedRevision: candidate.revision,
            operation: inverse
        ))
        document = candidate
    }

    package mutating func removeAll() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    private func requireMatch(
        _ entry: CanvasHistoryEntry,
        document: CanvasDocument
    ) throws {
        guard entry.documentID == document.id,
              entry.expectedRevision == document.revision else {
            throw CanvasHistoryError.divergedDocument
        }
    }
}

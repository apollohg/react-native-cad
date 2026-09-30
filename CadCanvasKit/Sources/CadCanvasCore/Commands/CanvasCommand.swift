import Foundation

public enum CanvasCommand: Sendable {
    case insert(CanvasElement, at: Int)
    case remove(id: UUID)
    case removeMany(ids: [UUID])
    case setGeometry(id: UUID, CanvasGeometry)
    case setStyle(id: UUID, CanvasStyle)
    case setText(id: UUID, CanvasText)
    case replaceAll([CanvasElement])
    case setCalibration(CanvasCalibration)
    case clear
}

public enum CanvasCommandError: Error, Equatable, Sendable {
    case elementNotFound(UUID)
    case duplicateElement(UUID)
    case duplicateRemovalID(UUID)
    case emptyRemoval
    case invalidIndex(Int)
    case notTextElement(UUID)
    case revisionOverflow
}

package enum CanvasHistoryOperation: Sendable {
    case insert(CanvasElement, at: Int)
    case remove(id: UUID)
    case removeMany(ids: [UUID])
    case restoreMany([CanvasIndexedElement])
    case setGeometry(id: UUID, CanvasGeometry)
    case setStyle(id: UUID, CanvasStyle)
    case setText(id: UUID, CanvasText)
    case replaceAll([CanvasElement])
    case setCalibration(CanvasCalibration)
}

package struct CanvasIndexedElement: Sendable {
    package let index: Int
    package let element: CanvasElement
}

package enum CanvasCommandEngine {
    @discardableResult
    package static func applyPrevalidatedFreehandInsertion(
        _ sourceElement: CanvasElement,
        at index: Int,
        to document: inout CanvasDocument
    ) throws -> CanvasHistoryOperation {
        guard let nextRevision = document.revision.nextValidCanvasRevision else {
            throw CanvasCommandError.revisionOverflow
        }
        guard case .freehand = sourceElement.geometry else {
            throw CanvasValidationError(
                field: "elements[\(index)].geometry",
                reason: "must be prevalidated freehand geometry"
            )
        }
        var element = sourceElement
        element.contentRevision = 0
        guard !document.elements.contains(where: { $0.id == element.id }) else {
            throw CanvasCommandError.duplicateElement(element.id)
        }
        guard document.elements.indices.contains(index) || index == document.elements.endIndex else {
            throw CanvasCommandError.invalidIndex(index)
        }
        var candidate = document
        candidate.elements.insert(element, at: index)
        candidate.revision = nextRevision
        try candidate.validateEnvelope()
        document = candidate
        return .remove(id: element.id)
    }

    @discardableResult
    package static func apply(
        _ command: CanvasCommand,
        to document: inout CanvasDocument
    ) throws -> CanvasHistoryOperation {
        let operation: CanvasHistoryOperation
        switch command {
        case .insert(var element, let index):
            element.contentRevision = 0
            operation = .insert(element, at: index)
        case .remove(let id):
            operation = .remove(id: id)
        case .removeMany(let ids):
            operation = .removeMany(ids: ids)
        case .setGeometry(let id, let geometry):
            operation = .setGeometry(id: id, geometry)
        case .setStyle(let id, let style):
            operation = .setStyle(id: id, style)
        case .setText(let id, let text):
            operation = .setText(id: id, text)
        case .replaceAll(let elements):
            operation = .replaceAll(elements.map { element in
                var normalized = element
                normalized.contentRevision = 0
                return normalized
            })
        case .setCalibration(let calibration):
            operation = .setCalibration(calibration)
        case .clear:
            operation = .replaceAll([])
        }
        return try applyHistoryOperation(operation, to: &document)
    }

    @discardableResult
    package static func applyHistoryOperation(
        _ operation: CanvasHistoryOperation,
        to document: inout CanvasDocument
    ) throws -> CanvasHistoryOperation {
        guard let nextRevision = document.revision.nextValidCanvasRevision else {
            throw CanvasCommandError.revisionOverflow
        }
        var candidate = document
        let inverse: CanvasHistoryOperation

        switch operation {
        case .insert(let element, let index):
            guard !candidate.elements.contains(where: { $0.id == element.id }) else {
                throw CanvasCommandError.duplicateElement(element.id)
            }
            guard candidate.elements.indices.contains(index) || index == candidate.elements.endIndex else {
                throw CanvasCommandError.invalidIndex(index)
            }
            candidate.elements.insert(element, at: index)
            inverse = .remove(id: element.id)

        case .remove(let id):
            guard let index = candidate.elements.firstIndex(where: { $0.id == id }) else {
                throw CanvasCommandError.elementNotFound(id)
            }
            inverse = .insert(candidate.elements.remove(at: index), at: index)

        case .removeMany(let ids):
            guard !ids.isEmpty else {
                throw CanvasCommandError.emptyRemoval
            }
            var seen: Set<UUID> = []
            var records: [CanvasIndexedElement] = []
            records.reserveCapacity(ids.count)
            for id in ids {
                guard seen.insert(id).inserted else {
                    throw CanvasCommandError.duplicateRemovalID(id)
                }
                guard let index = candidate.elements.firstIndex(where: { $0.id == id }) else {
                    throw CanvasCommandError.elementNotFound(id)
                }
                records.append(.init(index: index, element: candidate.elements[index]))
            }
            records.sort { $0.index < $1.index }
            for record in records.reversed() {
                candidate.elements.remove(at: record.index)
            }
            inverse = .restoreMany(records)

        case .restoreMany(let records):
            guard !records.isEmpty else {
                throw CanvasCommandError.emptyRemoval
            }
            var seen: Set<UUID> = []
            var lastIndex = -1
            for record in records {
                guard seen.insert(record.element.id).inserted else {
                    throw CanvasCommandError.duplicateRemovalID(record.element.id)
                }
                guard !candidate.elements.contains(where: { $0.id == record.element.id }) else {
                    throw CanvasCommandError.duplicateElement(record.element.id)
                }
                guard record.index > lastIndex,
                      record.index >= 0,
                      record.index <= candidate.elements.endIndex else {
                    throw CanvasCommandError.invalidIndex(record.index)
                }
                candidate.elements.insert(record.element, at: record.index)
                lastIndex = record.index
            }
            inverse = .removeMany(ids: records.map(\.element.id))

        case .setGeometry(let id, let geometry):
            let index = try elementIndex(id: id, in: candidate)
            let original = candidate.elements[index]
            candidate.elements[index].geometry = geometry
            candidate.elements[index].contentRevision = try nextContentRevision(for: original)
            inverse = .setGeometry(id: id, original.geometry)

        case .setStyle(let id, let style):
            let index = try elementIndex(id: id, in: candidate)
            let original = candidate.elements[index]
            candidate.elements[index].style = style
            candidate.elements[index].contentRevision = try nextContentRevision(for: original)
            inverse = .setStyle(id: id, original.style)

        case .setText(let id, let text):
            let index = try elementIndex(id: id, in: candidate)
            let original = candidate.elements[index]
            guard case .text(let originalText) = original.geometry else {
                throw CanvasCommandError.notTextElement(id)
            }
            candidate.elements[index].geometry = .text(text)
            candidate.elements[index].contentRevision = try nextContentRevision(for: original)
            inverse = .setText(id: id, originalText)

        case .replaceAll(let elements):
            inverse = .replaceAll(candidate.elements)
            candidate.elements = elements

        case .setCalibration(let calibration):
            inverse = .setCalibration(candidate.calibration)
            candidate.calibration = calibration
        }

        candidate.revision = nextRevision
        if case .insert(_, let index) = operation {
            try candidate.validateInsertion(at: index)
        } else {
            try candidate.validate()
        }
        document = candidate
        return inverse
    }

    private static func elementIndex(id: UUID, in document: CanvasDocument) throws -> Int {
        guard let index = document.elements.firstIndex(where: { $0.id == id }) else {
            throw CanvasCommandError.elementNotFound(id)
        }
        return index
    }

    private static func nextContentRevision(for element: CanvasElement) throws -> UInt64 {
        guard let revision = element.contentRevision.nextValidCanvasRevision else {
            throw CanvasCommandError.revisionOverflow
        }
        return revision
    }
}

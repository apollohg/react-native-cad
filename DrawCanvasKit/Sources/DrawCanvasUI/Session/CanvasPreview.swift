import Foundation
import DrawCanvasCore

public enum CanvasSessionError: Error, Equatable, Sendable {
    case revisionExhausted
    case featureDisabled
}

package struct CanvasPreviewToken: Hashable, Sendable {
    private let rawValue: UUID

    package init() {
        rawValue = UUID()
    }
}

package enum CanvasPreviewKind: Sendable {
    case editing(elementID: UUID)
    case inserting(elementID: UUID)
    case freehand(elementID: UUID)
    case text(elementID: UUID?)
    case erasing
}

package enum CanvasPreviewPayload {
    case element(CanvasElement)
    case freehand(CanvasFreehandDraft)
    case erasedElementIDs([UUID])
}

package struct CanvasInteractionPreview {
    package let token: CanvasPreviewToken
    package let kind: CanvasPreviewKind
    package let originalElement: CanvasElement?
    package var payload: CanvasPreviewPayload?
    package var predictedInkSamples: [CanvasInkSample]
    package var revision: CanvasGeneration
}

package struct CanvasTextEditState: Sendable {
    package let token: CanvasPreviewToken
    package let replacementGeneration: CanvasGeneration
    package let original: CanvasText?
    package var draft: CanvasText
}

package enum CanvasPreviewError: Error, Equatable, Sendable {
    case previewAlreadyActive
    case invalidOwner
    case elementNotFound(UUID)
    case duplicateElement(UUID)
    case invalidPayload
}

extension CanvasPreviewPayload {
    @MainActor
    var materializedElement: CanvasElement? {
        switch self {
        case .element(let element):
            return element
        case .freehand(let draft):
            return try? draft.materializeElement()
        case .erasedElementIDs:
            return nil
        }
    }
}

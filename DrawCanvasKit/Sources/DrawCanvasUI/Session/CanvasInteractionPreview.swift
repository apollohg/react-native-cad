import Foundation
import DrawCanvasCore

@MainActor
enum CanvasRenderPreviewContent {
    case element(CanvasElement)
    case freehand(CanvasFreehandDraft)

    var id: UUID {
        switch self {
        case .element(let element):
            element.id
        case .freehand(let draft):
            draft.id
        }
    }
}

@MainActor
struct CanvasRenderPreview {
    let replacingElementID: UUID?
    let originalElement: CanvasElement?
    private(set) var content: CanvasRenderPreviewContent?
    private(set) var predictedInkSamples: [CanvasInkSample]
    private(set) var guides: [SnapGuide]
    let hiddenElementIDs: Set<UUID>
    private(set) var generation: RecognitionGeneration

    init?(_ preview: CanvasInteractionPreview?) {
        guard let preview else { return nil }
        generation = preview.revision
        predictedInkSamples = preview.predictedInkSamples
        guides = []
        originalElement = preview.originalElement

        switch preview.payload {
        case .element(let element):
            content = .element(element)
            hiddenElementIDs = []
            replacingElementID = preview.originalElement?.id
        case .freehand(let draft):
            content = .freehand(draft)
            hiddenElementIDs = []
            replacingElementID = nil
        case .erasedElementIDs(let ids):
            content = nil
            hiddenElementIDs = Set(ids)
            replacingElementID = nil
        case nil:
            return nil
        }
    }

    init(replacing element: CanvasElement, generation: RecognitionGeneration) {
        replacingElementID = element.id
        originalElement = element
        content = .element(element)
        predictedInkSamples = []
        guides = []
        hiddenElementIDs = []
        self.generation = generation
    }

    init(
        inserting element: CanvasElement,
        guides: [SnapGuide] = [],
        generation: RecognitionGeneration
    ) {
        replacingElementID = nil
        originalElement = nil
        content = .element(element)
        predictedInkSamples = []
        self.guides = guides
        hiddenElementIDs = []
        self.generation = generation
    }

    init(
        freehand draft: CanvasFreehandDraft,
        predictedInkSamples: [CanvasInkSample],
        generation: RecognitionGeneration
    ) {
        replacingElementID = nil
        originalElement = nil
        content = .freehand(draft)
        self.predictedInkSamples = predictedInkSamples
        guides = []
        hiddenElementIDs = []
        self.generation = generation
    }

    var element: CanvasElement? {
        guard case .element(let element) = content else { return nil }
        return element
    }

    var freehandDraft: CanvasFreehandDraft? {
        guard case .freehand(let draft) = content else { return nil }
        return draft
    }

    var hasChanges: Bool {
        guard let originalElement, let element else { return true }
        return originalElement.contentRevision != element.contentRevision
            || originalElement.geometry != element.geometry
            || originalElement.style != element.style
    }

    mutating func update(
        element: CanvasElement,
        guides: [SnapGuide]? = nil,
        generation: RecognitionGeneration
    ) -> Bool {
        guard element.id == content?.id else { return false }
        content = .element(element)
        if let guides { self.guides = guides }
        self.generation = generation
        return true
    }

    mutating func update(
        freehand draft: CanvasFreehandDraft,
        predictedInkSamples: [CanvasInkSample],
        generation: RecognitionGeneration
    ) -> Bool {
        guard draft.id == content?.id else { return false }
        content = .freehand(draft)
        self.predictedInkSamples = predictedInkSamples
        self.generation = generation
        return true
    }

    mutating func update(guides: [SnapGuide], generation: RecognitionGeneration) {
        self.guides = guides
        self.generation = generation
    }
}

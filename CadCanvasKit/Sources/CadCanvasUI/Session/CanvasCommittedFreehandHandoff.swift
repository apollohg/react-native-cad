import Foundation

@MainActor
package struct CanvasCommittedFreehandHandoff {
    package let documentRevision: UInt64
    package let documentIndex: Int
    package let elementID: UUID
    package let contentRevision: UInt64
    package let draft: CanvasFreehandDraft

    init(
        documentRevision: UInt64,
        documentIndex: Int,
        elementID: UUID,
        contentRevision: UInt64,
        draft: CanvasFreehandDraft
    ) {
        self.documentRevision = documentRevision
        self.documentIndex = documentIndex
        self.elementID = elementID
        self.contentRevision = contentRevision
        self.draft = draft
    }
}

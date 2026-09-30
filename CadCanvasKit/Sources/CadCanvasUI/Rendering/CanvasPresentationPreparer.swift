import Foundation
import CadCanvasCore

package struct CanvasPresentationInput {
    package let document: CanvasDocument
    package let replacementGeneration: CanvasGeneration
    package let presentationRevision: CanvasGeneration
    package let preview: CanvasInteractionPreview?
    package let transientPreview: CanvasElement?
    package let transientPreviewRevision: CanvasGeneration
    package let viewport: CanvasViewport
    package let selectedElementID: UUID?
    package let guides: [SnapGuide]
    package let gridSpacing: Double
    package let theme: CanvasThemeSnapshot
    package let eraserTargetID: UUID?
    package let viewportRenderPhase: CanvasViewportRenderPhase
    package let committedFreehandHandoff: CanvasCommittedFreehandHandoff?

    package init(
        document: CanvasDocument,
        replacementGeneration: CanvasGeneration,
        presentationRevision: CanvasGeneration,
        preview: CanvasInteractionPreview?,
        transientPreview: CanvasElement?,
        transientPreviewRevision: CanvasGeneration,
        viewport: CanvasViewport,
        selectedElementID: UUID?,
        guides: [SnapGuide],
        gridSpacing: Double,
        theme: CanvasThemeSnapshot,
        eraserTargetID: UUID?,
        viewportRenderPhase: CanvasViewportRenderPhase,
        committedFreehandHandoff: CanvasCommittedFreehandHandoff? = nil
    ) {
        self.document = document
        self.replacementGeneration = replacementGeneration
        self.presentationRevision = presentationRevision
        self.preview = preview
        self.transientPreview = transientPreview
        self.transientPreviewRevision = transientPreviewRevision
        self.viewport = viewport
        self.selectedElementID = selectedElementID
        self.guides = guides
        self.gridSpacing = gridSpacing
        self.theme = theme
        self.eraserTargetID = eraserTargetID
        self.viewportRenderPhase = viewportRenderPhase
        self.committedFreehandHandoff = committedFreehandHandoff
    }
}

@MainActor
package final class CanvasPresentationPreparer {
    private let scenePreparer = CanvasScenePreparer()

    func prepare(_ input: CanvasPresentationInput) throws -> CanvasPreparedPresentation {
        var theme = input.theme
        if input.eraserTargetID != nil {
            theme.selection = theme.eraserTarget
            theme.selectionLineWidth = theme.eraserTargetLineWidth
            theme.selectionDashPattern = []
            theme.showsSelectionHandles = false
        }
        let preview = CanvasRenderPreview(input.preview)
            ?? input.transientPreview.map {
                CanvasRenderPreview(
                    inserting: $0,
                    generation: input.transientPreviewRevision
                )
            }
        return try scenePreparer.prepare(
            document: input.document,
            preview: preview,
            viewport: input.viewport,
            selectedElementID: input.eraserTargetID ?? input.selectedElementID,
            editingTextIDs: [],
            guides: input.guides,
            gridSpacing: input.gridSpacing,
            theme: theme,
            documentReplacementGeneration: input.replacementGeneration,
            viewportRenderPhase: input.viewportRenderPhase,
            committedFreehandHandoff: input.committedFreehandHandoff
        )
    }
}

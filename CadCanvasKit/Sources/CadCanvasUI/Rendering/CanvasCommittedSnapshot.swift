import CadCanvasCore
import Foundation

struct CanvasCommittedPreparationKey: Equatable {
    let generation: CanvasCommittedGeneration
    let viewport: CanvasViewport
    let theme: CanvasThemeSnapshot
    let selectedElementID: UUID?
    let editingTextIDs: Set<UUID>
}

struct CanvasPreparedGeometryLayers {
    let committed: [CanvasPreparedGeometry]
    let dynamic: [CanvasPreparedGeometry]
    private let ordered: [CanvasPreparedGeometry]?

    init(geometry: [CanvasPreparedGeometry]) {
        committed = []
        dynamic = geometry
        ordered = geometry
    }

    init(
        committed: [CanvasPreparedGeometry],
        dynamic: [CanvasPreparedGeometry],
        ordered: [CanvasPreparedGeometry]? = nil
    ) {
        self.committed = committed
        self.dynamic = dynamic
        self.ordered = ordered
    }

    var materialized: [CanvasPreparedGeometry] {
        if let ordered { return ordered }
        if dynamic.isEmpty { return committed }
        return committed + dynamic
    }
}

final class CanvasCommittedPreparedSnapshot {
    let key: CanvasCommittedPreparationKey
    let visibleGeometry: [CanvasPreparedGeometry]
    let textDescriptors: [CanvasTextDescriptor]
    let committed: CanvasCommittedPresentation
    let selectionBounds: CanvasRect?
    let elementIDs: Set<UUID>

    init(
        key: CanvasCommittedPreparationKey,
        visibleGeometry: [CanvasPreparedGeometry],
        textDescriptors: [CanvasTextDescriptor],
        committed: CanvasCommittedPresentation,
        selectionBounds: CanvasRect?,
        elementIDs: Set<UUID>
    ) {
        self.key = key
        self.visibleGeometry = visibleGeometry
        self.textDescriptors = textDescriptors
        self.committed = committed
        self.selectionBounds = selectionBounds
        self.elementIDs = elementIDs
    }
}

extension CanvasRenderPreview {
    var canReuseCommittedSnapshot: Bool {
        freehandDraft != nil
            && replacingElementID == nil
            && hiddenElementIDs.isEmpty
            && element == nil
    }
}

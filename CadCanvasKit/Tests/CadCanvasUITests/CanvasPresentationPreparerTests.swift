import XCTest
import CadCanvasCore
@testable import CadCanvasUI

@MainActor
final class CanvasPresentationPreparerTests: XCTestCase {
    func testTransientPreviewComposesWithoutMutatingCommittedDocument() throws {
        let committed = line(id: UUID(), start: .init(x: 10, y: 10), end: .init(x: 30, y: 30))
        let transient = CanvasElement.rectangle(
            id: UUID(),
            rect: .init(x: 40, y: 50, width: 20, height: 30)
        )
        let document = CanvasDocument(revision: 4, elements: [committed])
        var transientRevision = CanvasGeneration.zero
        transientRevision.advance()

        let presentation = try CanvasPresentationPreparer().prepare(input(
            document: document,
            transientPreview: transient,
            transientPreviewRevision: transientRevision
        ))

        XCTAssertEqual(presentation.scene.geometry.map(\.id), [committed.id, transient.id])
        XCTAssertEqual(presentation.scene.previewGeneration, transientRevision)
        XCTAssertEqual(document.elements.map(\.id), [committed.id])
        XCTAssertEqual(presentation.committed.generation.documentRevision, 4)
        XCTAssertEqual(presentation.committed.items.map(\.geometry.id), [committed.id])
    }

    func testOwnedEraserPreviewHidesTargetsAndKeepsCommittedMetadata() throws {
        let first = line(id: UUID(), start: .init(x: 0, y: 0), end: .init(x: 40, y: 40))
        let second = line(id: UUID(), start: .init(x: 60, y: 0), end: .init(x: 100, y: 40))
        let document = CanvasDocument(elements: [first, second])
        let session = try CanvasSession(document: document)
        let token = try session.acquirePreview(.erasing)
        try session.updatePreview(.erasedElementIDs([first.id]), token: token)

        let presentation = try CanvasPresentationPreparer().prepare(input(
            document: session.document,
            presentationRevision: session.presentationRevision,
            preview: session.preview
        ))

        XCTAssertEqual(presentation.scene.geometry.map(\.id), [second.id])
        XCTAssertEqual(presentation.committed.items.map(\.geometry.id), [first.id, second.id])
        XCTAssertEqual(presentation.scene.previewGeneration, session.preview?.revision)
    }

    func testTextRemainsUIKitDescriptorAndRendererSceneStaysTextFree() throws {
        let text = CanvasElement(
            id: UUID(),
            contentRevision: 3,
            geometry: .text(.init(
                frame: .init(x: 20, y: 30, width: 120, height: 44),
                text: "Quote note",
                font: .init(familyName: "Helvetica", pointSize: 18),
                color: .black
            ))
        )

        let presentation = try CanvasPresentationPreparer().prepare(input(
            document: CanvasDocument(elements: [text])
        ))

        XCTAssertTrue(presentation.scene.geometry.isEmpty)
        let descriptor = try XCTUnwrap(presentation.textDescriptors.first)
        XCTAssertEqual(descriptor.id, text.id)
        XCTAssertEqual(descriptor.contentRevision, 3)
        XCTAssertEqual(descriptor.frame, text.bounds)
        XCTAssertEqual(descriptor.text, "Quote note")
    }

    func testGridSpacingAndReplacementGenerationReachRendererFoundation() throws {
        var replacementGeneration = CanvasGeneration.zero
        replacementGeneration.advance()
        let presentation = try CanvasPresentationPreparer().prepare(input(
            document: CanvasDocument(revision: 7, elements: []),
            replacementGeneration: replacementGeneration,
            gridSpacing: 25
        ))

        XCTAssertEqual(presentation.committed.generation, CanvasCommittedGeneration(
            documentRevision: 7,
            replacementGeneration: replacementGeneration
        ))
        XCTAssertTrue(presentation.scene.gridLines.contains { line in
            line.start.x == 25 && line.end.x == 25
        })
        XCTAssertTrue(presentation.scene.gridLines.contains { line in
            line.start.y == 25 && line.end.y == 25
        })
    }

    private func input(
        document: CanvasDocument,
        replacementGeneration: CanvasGeneration = .zero,
        presentationRevision: CanvasGeneration = .zero,
        preview: CanvasInteractionPreview? = nil,
        transientPreview: CanvasElement? = nil,
        transientPreviewRevision: CanvasGeneration = .zero,
        gridSpacing: Double = 20
    ) throws -> CanvasPresentationInput {
        CanvasPresentationInput(
            document: document,
            replacementGeneration: replacementGeneration,
            presentationRevision: presentationRevision,
            preview: preview,
            transientPreview: transientPreview,
            transientPreviewRevision: transientPreviewRevision,
            viewport: try .identity(size: .init(width: 200, height: 160)),
            selectedElementID: nil,
            guides: [],
            gridSpacing: gridSpacing,
            theme: CanvasTheme.default.renderSnapshot,
            eraserTargetID: nil,
            viewportRenderPhase: .settled
        )
    }

    private func line(id: UUID, start: CanvasPoint, end: CanvasPoint) -> CanvasElement {
        CanvasElement(id: id, geometry: .line(.init(start: start, end: end)))
    }
}

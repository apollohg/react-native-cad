import UIKit
import XCTest
import CadCanvasCore
@testable import CadCanvasUI

@MainActor
final class CanvasScenePreparerTests: XCTestCase {
    func testPreparedInkRetainsPersistedWidthMode() throws {
        let element = CanvasElement(
            id: UUID(),
            geometry: .freehand(.init(
                samples: [
                    .init(point: .init(x: 10, y: 10), pressure: 0.3),
                    .init(point: .init(x: 30, y: 30), pressure: 1),
                ],
                pressureEnabled: true,
                widthMode: .screenConstant
            )),
            style: .default
        )
        let presentation = try prepare(
            .init(elements: [element]),
            with: CanvasScenePreparer()
        )
        guard case .ink(let ink) = try XCTUnwrap(presentation.scene.geometry.first).path else {
            return XCTFail("Expected prepared ink")
        }

        XCTAssertEqual(ink.widthMode, .screenConstant)
        XCTAssertEqual(ink.snapshot().widthMode, .screenConstant)
    }

    func testWarmFreehandInsertionReusesCommittedSnapshotWithoutDocumentVisits() throws {
        let elements = (0 ..< 100).map { index in
            freehand(
                id: UUID(),
                points: [
                    .init(x: 8, y: Double(index + 8)),
                    .init(x: 112, y: Double(index + 8)),
                ]
            )
        }
        let document = CanvasDocument(elements: elements)
        let preparer = CanvasScenePreparer()
        let committed = try prepare(document, with: preparer)
        let visitsBeforeLiveFrames = preparer.statistics.committedElementVisitCount
        let draft = CanvasFreehandDraft(
            id: UUID(),
            style: .init(stroke: .black, lineWidth: 2)
        )
        draft.append([
            .init(point: .init(x: 8, y: 120), pressure: 0.4),
            .init(point: .init(x: 16, y: 122), pressure: 0.6),
        ])
        var generation = RecognitionGeneration.zero
        generation.advance()
        var preview = CanvasRenderPreview(
            freehand: draft,
            predictedInkSamples: [],
            generation: generation
        )

        let firstLive = try prepare(document, preview: preview, with: preparer)
        generation.advance()
        draft.append([.init(point: .init(x: 24, y: 118), pressure: 0.8)])
        XCTAssertTrue(preview.update(
            freehand: draft,
            predictedInkSamples: [],
            generation: generation
        ))
        let secondLive = try prepare(document, preview: preview, with: preparer)

        XCTAssertEqual(
            preparer.statistics.committedElementVisitCount,
            visitsBeforeLiveFrames
        )
        XCTAssertTrue(committed.committedSnapshot === firstLive.committedSnapshot)
        XCTAssertTrue(firstLive.committedSnapshot === secondLive.committedSnapshot)
        XCTAssertEqual(secondLive.committed.items.count, 100)
        XCTAssertEqual(secondLive.scene.committedGeometry.count, 100)
        XCTAssertEqual(secondLive.scene.dynamicGeometry.map(\.id), [draft.id])
        XCTAssertEqual(secondLive.scene.geometry.count, 101)
    }

    func testCommittedSnapshotInvalidatesForEveryPreparationKeyInput() throws {
        let element = line()
        let text = textElement()
        let document = CanvasDocument(revision: 3, elements: [element, text])
        let preparer = CanvasScenePreparer()
        let viewport = try CanvasViewport.identity(size: .init(width: 500, height: 400))
        let theme = CanvasTheme.default.renderSnapshot
        let baseline = try preparer.prepare(
            document: document,
            preview: nil,
            viewport: viewport,
            selectedElementID: nil,
            editingTextIDs: [],
            guides: [],
            gridSpacing: 20,
            theme: theme
        )
        let baselineSnapshot = try XCTUnwrap(baseline.committedSnapshot)
        var visitsBeforeChange = preparer.statistics.committedElementVisitCount

        var replacementGeneration = RecognitionGeneration.zero
        replacementGeneration.advance()
        let replacementChanged = try preparer.prepare(
            document: document,
            preview: nil,
            viewport: viewport,
            selectedElementID: nil,
            editingTextIDs: [],
            guides: [],
            gridSpacing: 20,
            theme: theme,
            documentReplacementGeneration: replacementGeneration
        )
        XCTAssertFalse(replacementChanged.committedSnapshot === baselineSnapshot)
        XCTAssertGreaterThan(
            preparer.statistics.committedElementVisitCount,
            visitsBeforeChange
        )
        visitsBeforeChange = preparer.statistics.committedElementVisitCount

        let panned = try viewport.panned(byScreen: .init(x: 20, y: 10))
        let viewportChanged = try preparer.prepare(
            document: document,
            preview: nil,
            viewport: panned,
            selectedElementID: nil,
            editingTextIDs: [],
            guides: [],
            gridSpacing: 20,
            theme: theme,
            documentReplacementGeneration: replacementGeneration
        )
        XCTAssertFalse(
            viewportChanged.committedSnapshot === replacementChanged.committedSnapshot
        )
        XCTAssertGreaterThan(
            preparer.statistics.committedElementVisitCount,
            visitsBeforeChange
        )
        visitsBeforeChange = preparer.statistics.committedElementVisitCount

        var changedTheme = theme
        changedTheme.background = .black
        let themeChanged = try preparer.prepare(
            document: document,
            preview: nil,
            viewport: panned,
            selectedElementID: nil,
            editingTextIDs: [],
            guides: [],
            gridSpacing: 20,
            theme: changedTheme,
            documentReplacementGeneration: replacementGeneration
        )
        XCTAssertFalse(themeChanged.committedSnapshot === viewportChanged.committedSnapshot)
        XCTAssertGreaterThan(
            preparer.statistics.committedElementVisitCount,
            visitsBeforeChange
        )
        visitsBeforeChange = preparer.statistics.committedElementVisitCount

        let selectionChanged = try preparer.prepare(
            document: document,
            preview: nil,
            viewport: panned,
            selectedElementID: element.id,
            editingTextIDs: [],
            guides: [],
            gridSpacing: 20,
            theme: changedTheme,
            documentReplacementGeneration: replacementGeneration
        )
        XCTAssertFalse(selectionChanged.committedSnapshot === themeChanged.committedSnapshot)
        XCTAssertGreaterThan(
            preparer.statistics.committedElementVisitCount,
            visitsBeforeChange
        )
        visitsBeforeChange = preparer.statistics.committedElementVisitCount

        let editingChanged = try preparer.prepare(
            document: document,
            preview: nil,
            viewport: panned,
            selectedElementID: element.id,
            editingTextIDs: [text.id],
            guides: [],
            gridSpacing: 20,
            theme: changedTheme,
            documentReplacementGeneration: replacementGeneration
        )
        XCTAssertFalse(editingChanged.committedSnapshot === selectionChanged.committedSnapshot)
        XCTAssertGreaterThan(
            preparer.statistics.committedElementVisitCount,
            visitsBeforeChange
        )
        visitsBeforeChange = preparer.statistics.committedElementVisitCount

        let documentChanged = try preparer.prepare(
            document: .init(revision: 4, elements: [element, text]),
            preview: nil,
            viewport: panned,
            selectedElementID: element.id,
            editingTextIDs: [text.id],
            guides: [],
            gridSpacing: 20,
            theme: changedTheme,
            documentReplacementGeneration: replacementGeneration
        )
        XCTAssertFalse(documentChanged.committedSnapshot === editingChanged.committedSnapshot)
        XCTAssertGreaterThan(
            preparer.statistics.committedElementVisitCount,
            visitsBeforeChange
        )
    }

    func testFreehandDraftIDCollisionUsesGeneralPathAndDoesNotDuplicateGeometry() throws {
        let id = UUID()
        let committed = freehand(
            id: id,
            points: [.init(x: 10, y: 10), .init(x: 30, y: 30)]
        )
        let document = CanvasDocument(elements: [committed])
        let preparer = CanvasScenePreparer()
        _ = try prepare(document, with: preparer)
        let visitsBeforeCollision = preparer.statistics.committedElementVisitCount
        let draft = CanvasFreehandDraft(id: id, style: committed.style)
        draft.append([
            .init(point: .init(x: 40, y: 40), pressure: 1),
            .init(point: .init(x: 60, y: 60), pressure: 1),
        ])
        let preview = CanvasRenderPreview(
            freehand: draft,
            predictedInkSamples: [],
            generation: .zero
        )

        let presentation = try prepare(document, preview: preview, with: preparer)

        XCTAssertEqual(presentation.scene.geometry.map(\.id), [id])
        XCTAssertGreaterThan(
            preparer.statistics.committedElementVisitCount,
            visitsBeforeCollision
        )
    }

    func testCommittedPresentationKeepsOffscreenGeometryInDocumentOrder() throws {
        let first = line()
        let text = textElement()
        let offscreen = CanvasElement(
            id: UUID(),
            geometry: .line(.init(
                start: .init(x: 2_000, y: 2_000),
                end: .init(x: 2_040, y: 2_040)
            ))
        )
        let document = CanvasDocument(revision: 7, elements: [first, text, offscreen])
        var replacementGeneration = RecognitionGeneration.zero
        replacementGeneration.advance()
        let preparer = CanvasScenePreparer()

        let firstPresentation = try preparer.prepare(
            document: document,
            preview: nil,
            viewport: .identity(size: .init(width: 500, height: 400)),
            selectedElementID: nil,
            editingTextIDs: [],
            guides: [],
            gridSpacing: 20,
            theme: CanvasTheme.default.renderSnapshot,
            documentReplacementGeneration: replacementGeneration,
            viewportRenderPhase: .settled
        )
        var previewGeneration = RecognitionGeneration.zero
        previewGeneration.advance()
        let preview = CanvasRenderPreview(
            inserting: line(),
            generation: previewGeneration
        )
        let previewPresentation = try preparer.prepare(
            document: document,
            preview: preview,
            viewport: .identity(size: .init(width: 500, height: 400)),
            selectedElementID: nil,
            editingTextIDs: [],
            guides: [],
            gridSpacing: 20,
            theme: CanvasTheme.default.renderSnapshot,
            documentReplacementGeneration: replacementGeneration,
            viewportRenderPhase: .settled
        )

        XCTAssertEqual(firstPresentation.scene.geometry.map(\.id), [first.id])
        XCTAssertEqual(firstPresentation.committed.items.map(\.documentIndex), [0, 2])
        XCTAssertEqual(firstPresentation.committed.items.map(\.geometry.id), [first.id, offscreen.id])
        XCTAssertEqual(
            firstPresentation.committed.generation,
            CanvasCommittedGeneration(
                documentRevision: 7,
                replacementGeneration: replacementGeneration
            )
        )
        XCTAssertEqual(
            previewPresentation.committed.generation,
            firstPresentation.committed.generation
        )
        XCTAssertEqual(
            previewPresentation.committed.items.map(\.geometry.resourceIdentity),
            firstPresentation.committed.items.map(\.geometry.resourceIdentity)
        )
    }

    func testCommittedPresentationDescribesReplacementAtOriginalIndex() throws {
        let first = line()
        let original = line()
        let third = line()
        let document = CanvasDocument(elements: [first, original, third])
        var generation = RecognitionGeneration.zero
        generation.advance()
        var preview = CanvasRenderPreview(replacing: original, generation: generation)
        var replacement = original
        replacement.geometry = .line(.init(
            start: .init(x: 100, y: 120),
            end: .init(x: 220, y: 180)
        ))
        XCTAssertTrue(preview.update(element: replacement, generation: generation))

        let presentation = try prepare(document, preview: preview, with: CanvasScenePreparer())
        let metadata = try XCTUnwrap(presentation.committed.replacement)

        XCTAssertEqual(metadata.documentIndex, 1)
        XCTAssertEqual(metadata.originalGeometry.id, original.id)
        XCTAssertEqual(
            metadata.originalPaintedBounds,
            CanvasRect(x: -0.5, y: -0.5, width: 41, height: 41)
        )
        XCTAssertEqual(metadata.replacementGeometry.id, replacement.id)
        XCTAssertEqual(
            metadata.replacementPaintedBounds,
            CanvasRect(x: 99.5, y: 119.5, width: 121, height: 61)
        )
        XCTAssertEqual(presentation.committed.items.map(\.geometry.id), [
            first.id, original.id, third.id,
        ])
    }

    func testReplacementGenerationAndViewportPhaseArePartOfInternalPresentation() throws {
        let document = CanvasDocument(revision: 4, elements: [line()])
        let preparer = CanvasScenePreparer()
        let settled = try prepare(document, with: preparer)
        var replacementGeneration = RecognitionGeneration.zero
        replacementGeneration.advance()
        let interactive = try preparer.prepare(
            document: document,
            preview: nil,
            viewport: .identity(size: .init(width: 500, height: 400)),
            selectedElementID: nil,
            editingTextIDs: [],
            guides: [],
            gridSpacing: 20,
            theme: CanvasTheme.default.renderSnapshot,
            documentReplacementGeneration: replacementGeneration,
            viewportRenderPhase: .interactive
        )

        XCTAssertNotEqual(settled.committed.generation, interactive.committed.generation)
        XCTAssertEqual(interactive.viewportRenderPhase, .interactive)
    }

    func testPreparedSceneExcludesTextAndReusesGeometryAcrossViewportChanges() throws {
        let line = line(contentRevision: 3)
        let text = textElement()
        let document = CanvasDocument(elements: [line, text])
        let preparer = CanvasScenePreparer()

        let first = try prepare(document, with: preparer)
        var panned = try! CanvasViewport.identity(size: .init(width: 500, height: 400))
        panned = try! panned.panned(byScreen: .init(x: 30, y: 20))
        let second = try prepare(document, with: preparer, viewport: panned)

        XCTAssertEqual(first.scene.geometry.map(\.id), [line.id])
        XCTAssertEqual(first.textDescriptors.map(\.id), [text.id])
        XCTAssertEqual(second.scene.geometry.map(\.id), [line.id])
        XCTAssertEqual(preparer.statistics.geometryBuildCount, 1)
    }

    func testContentRevisionRebuildsOnlyTheChangedNode() throws {
        let first = line()
        let second = line()
        let preparer = CanvasScenePreparer()
        _ = try prepare(.init(elements: [first, second]), with: preparer)
        var changed = first
        changed.contentRevision = 1
        changed.geometry = .line(.init(start: .init(x: 0, y: 0), end: .init(x: 50, y: 50)))
        _ = try prepare(.init(elements: [changed, second]), with: preparer)
        XCTAssertEqual(preparer.statistics.geometryBuildCount, 3)
    }

    func testDocumentRevisionChangeRebuildsRecycledCommittedRenderKey() throws {
        let original = line()
        var document = CanvasDocument(elements: [original])
        let preparer = CanvasScenePreparer()
        let renderer = CoreGraphicsCanvasRenderer()
        let originalPresentation = try prepare(document, with: preparer)
        let originalResourceIdentity = try XCTUnwrap(
            originalPresentation.scene.geometry.first?.resourceIdentity
        )
        _ = renderer.renderCommands(
            scene: originalPresentation.scene,
            bounds: CGRect(x: 0, y: 0, width: 500, height: 400),
            displayScale: 2
        )
        XCTAssertEqual(renderer.pathBuildCount, 1)

        try CanvasCommandEngine.apply(.replaceAll([]), to: &document)
        var reinserted = original
        reinserted.geometry = .line(.init(
            start: .init(x: 100, y: 120),
            end: .init(x: 180, y: 160)
        ))
        reinserted.style.lineWidth = 9
        try CanvasCommandEngine.apply(.replaceAll([reinserted]), to: &document)

        let rebuilt = try prepare(document, with: preparer)
        let rebuiltCommands = renderer.renderCommands(
            scene: rebuilt.scene,
            bounds: CGRect(x: 0, y: 0, width: 500, height: 400),
            displayScale: 2
        )
        let rebuiltPath = rebuiltCommands.compactMap { command -> CGPath? in
            guard case .element(_, let path, _, _, _) = command else { return nil }
            return path
        }.first

        XCTAssertEqual(document.revision, 2)
        XCTAssertEqual(document.elements[0].contentRevision, original.contentRevision)
        XCTAssertEqual(preparer.statistics.geometryBuildCount, 2)
        XCTAssertEqual(rebuilt.scene.geometry.first?.bounds, reinserted.bounds)
        XCTAssertEqual(rebuilt.scene.geometry.first?.style, reinserted.style)
        XCTAssertNotEqual(rebuilt.scene.geometry.first?.resourceIdentity, originalResourceIdentity)
        XCTAssertEqual(renderer.pathBuildCount, 2)
        XCTAssertEqual(
            rebuiltPath?.boundingBoxOfPath,
            CGRect(x: 100, y: 120, width: 80, height: 40)
        )

        var panned = try! CanvasViewport.identity(size: .init(width: 500, height: 400))
        panned = try! panned.panned(byScreen: .init(x: 20, y: 10))
        let viewportOnly = try prepare(document, with: preparer, viewport: panned)
        XCTAssertEqual(
            viewportOnly.scene.geometry.first?.resourceIdentity,
            rebuilt.scene.geometry.first?.resourceIdentity
        )
        _ = renderer.renderCommands(
            scene: viewportOnly.scene,
            bounds: CGRect(x: 0, y: 0, width: 500, height: 400),
            displayScale: 2
        )
        XCTAssertEqual(preparer.statistics.geometryBuildCount, 2)
        XCTAssertEqual(renderer.pathBuildCount, 2)
    }

    func testFailedPreparationDoesNotCommitRenderContentSnapshot() throws {
        let original = line()
        let preparer = CanvasScenePreparer()
        let successful = try prepare(.init(elements: [original]), with: preparer)
        let successfulStatistics = preparer.statistics
        var changed = original
        changed.geometry = .line(.init(
            start: .init(x: 100, y: 120),
            end: .init(x: 180, y: 160)
        ))
        let maximum = Double.greatestFiniteMagnitude
        let invalid = CanvasElement(
            id: UUID(),
            geometry: .line(.init(
                start: .init(x: -maximum, y: 20),
                end: .init(x: maximum, y: 20)
            ))
        )
        let failedDocument = CanvasDocument(revision: 1, elements: [changed, invalid])

        XCTAssertThrowsError(try prepare(failedDocument, with: preparer)) { error in
            XCTAssertEqual(error as? CanvasScenePreparationError, .invalidGeometryBounds)
        }
        XCTAssertEqual(preparer.statistics, successfulStatistics)
        XCTAssertEqual(
            preparer.lastPresentation?.scene.geometry.map(\.id),
            successful.scene.geometry.map(\.id)
        )

        let recovered = try prepare(.init(revision: 1, elements: [changed]), with: preparer)
        XCTAssertEqual(preparer.statistics.geometryBuildCount, 2)
        XCTAssertEqual(recovered.scene.geometry.first?.bounds, changed.bounds)
    }

    func testDuplicateFreehandIDsFailBeforeStagedInkMutation() throws {
        let id = UUID()
        let basePoints = [
            CanvasPoint(x: 10, y: 10),
            CanvasPoint(x: 20, y: 20),
        ]
        let base = freehand(id: id, points: basePoints)
        let preparer = CanvasScenePreparer()
        var generation = RecognitionGeneration.zero
        generation.advance()
        let successful = try prepare(
            .init(elements: [base]),
            preview: CanvasRenderPreview(replacing: base, generation: generation),
            with: preparer
        )
        let publishedInk = try preparedInk(in: successful)
        let publishedSnapshot = publishedInk.snapshot()
        let publishedGeneration = publishedInk.generation
        let publishedStatistics = preparer.statistics
        let publishedResourceIdentity = try XCTUnwrap(
            successful.scene.geometry.first?.resourceIdentity
        )

        var first = freehand(
            id: id,
            points: basePoints + [.init(x: 30, y: 12)]
        )
        first.contentRevision = 1
        var second = freehand(
            id: id,
            points: basePoints + [.init(x: 31, y: 38)]
        )
        second.contentRevision = 2
        let malformed = CanvasDocument(revision: 1, elements: [first, second])

        XCTAssertThrowsError(try prepare(malformed, with: preparer)) { error in
            XCTAssertEqual(
                error as? CanvasValidationError,
                CanvasValidationError(
                    field: "elements[1].id",
                    reason: "must be unique"
                )
            )
        }
        XCTAssertEqual(publishedInk.snapshot().confirmed, publishedSnapshot.confirmed)
        XCTAssertEqual(publishedInk.snapshot().predicted, publishedSnapshot.predicted)
        XCTAssertEqual(
            publishedInk.snapshot().finalizedConfirmedSampleCount,
            publishedSnapshot.finalizedConfirmedSampleCount
        )
        XCTAssertEqual(publishedInk.generation, publishedGeneration)
        XCTAssertEqual(preparer.statistics, publishedStatistics)
        let retainedPresentation = try XCTUnwrap(preparer.lastPresentation)
        XCTAssertEqual(
            retainedPresentation.scene.geometry.first?.resourceIdentity,
            publishedResourceIdentity
        )
        XCTAssertTrue(try preparedInk(in: retainedPresentation) === publishedInk)
    }

    func testReplacementAndInsertionPreviewsComposeWithoutMutationOrDuplication() throws {
        let committed = line()
        let document = CanvasDocument(elements: [committed])
        let preparer = CanvasScenePreparer()
        var generation = RecognitionGeneration.zero
        generation.advance()

        var replacementElement = committed
        replacementElement.contentRevision = 1
        replacementElement.geometry = .line(
            .init(start: .init(x: 5, y: 5), end: .init(x: 45, y: 45))
        )
        var replacement = CanvasRenderPreview(
            replacing: committed,
            generation: generation
        )
        XCTAssertTrue(replacement.update(element: replacementElement, generation: generation))

        let replaced = try preparer.prepare(
            document: document,
            preview: replacement,
            viewport: .identity(size: .init(width: 500, height: 400)),
            selectedElementID: committed.id,
            editingTextIDs: [],
            guides: [],
            gridSpacing: 20,
            theme: CanvasTheme.default.renderSnapshot
        )

        XCTAssertEqual(replaced.scene.geometry.map(\.id), [committed.id])
        XCTAssertEqual(replaced.scene.geometry.first?.renderKey, .preview(id: committed.id, generation: generation))
        XCTAssertEqual(replaced.scene.geometry.first?.bounds, replacementElement.bounds)
        XCTAssertEqual(replaced.scene.previewGeneration, generation)
        XCTAssertEqual(document.elements[0].geometry, committed.geometry)

        generation.advance()
        let inserted = line(id: UUID(), contentRevision: 7)
        let insertion = CanvasRenderPreview(
            inserting: inserted,
            generation: generation
        )
        let appended = try preparer.prepare(
            document: document,
            preview: insertion,
            viewport: .identity(size: .init(width: 500, height: 400)),
            selectedElementID: inserted.id,
            editingTextIDs: [],
            guides: [],
            gridSpacing: 20,
            theme: CanvasTheme.default.renderSnapshot
        )

        XCTAssertEqual(appended.scene.geometry.map(\.id), [committed.id, inserted.id])
        XCTAssertEqual(Set(appended.scene.geometry.map(\.id)).count, 2)
        XCTAssertEqual(appended.scene.geometry.last?.renderKey, .preview(id: inserted.id, generation: generation))
        XCTAssertEqual(appended.scene.previewGeneration, generation)
        XCTAssertEqual(document.elements.map(\.id), [committed.id])
    }

    func testSuccessfulPreparationEvictsStaleCommittedGeometry() throws {
        let first = line()
        let second = line()
        let preparer = CanvasScenePreparer()

        _ = try prepare(.init(elements: [first, second]), with: preparer)
        XCTAssertEqual(preparer.statistics.geometryBuildCount, 2)
        XCTAssertEqual(preparer.statistics.cachedGeometryCount, 2)

        _ = try prepare(.init(elements: [first]), with: preparer)
        XCTAssertEqual(preparer.statistics.geometryBuildCount, 2)
        XCTAssertEqual(preparer.statistics.cachedGeometryCount, 1)

        _ = try prepare(.init(elements: [first, second]), with: preparer)
        XCTAssertEqual(preparer.statistics.geometryBuildCount, 3)
        XCTAssertEqual(preparer.statistics.cachedGeometryCount, 2)
    }

    func testFailedPreparationPreservesCacheStatisticsAndLastPresentation() throws {
        let first = line()
        let second = line()
        let preparer = CanvasScenePreparer()
        let successful = try prepare(.init(elements: [first]), with: preparer)
        let successfulStatistics = preparer.statistics

        XCTAssertThrowsError(
            try preparer.prepare(
                document: .init(elements: [second]),
                preview: nil,
                viewport: .identity(size: .init(width: 500, height: 400)),
                selectedElementID: nil,
                editingTextIDs: [],
                guides: [],
                gridSpacing: .nan,
                theme: CanvasTheme.default.renderSnapshot
            )
        ) { error in
            XCTAssertEqual(error as? CanvasScenePreparationError, .invalidGrid)
        }

        XCTAssertEqual(preparer.statistics, successfulStatistics)
        XCTAssertEqual(preparer.lastPresentation?.scene.geometry.map(\.id), successful.scene.geometry.map(\.id))
        _ = try prepare(.init(elements: [first]), with: preparer)
        XCTAssertEqual(preparer.statistics.geometryBuildCount, 1)
    }

    func testTextDescriptorsCarryUIKitPresentationStateAndPreviewMetadata() throws {
        let committedText = textElement()
        let document = CanvasDocument(elements: [committedText])
        let preparer = CanvasScenePreparer()
        var generation = RecognitionGeneration.zero
        generation.advance()
        var previewText = committedText
        previewText.contentRevision = 1
        previewText.geometry = .text(.init(
            frame: .init(x: 20, y: 30, width: 120, height: 50),
            text: "Preview text",
            font: .init(familyName: "Helvetica", pointSize: 18),
            color: .black
        ))
        var preview = CanvasRenderPreview(
            replacing: committedText,
            generation: generation
        )
        XCTAssertTrue(preview.update(element: previewText, generation: generation))

        let presentation = try preparer.prepare(
            document: document,
            preview: preview,
            viewport: .identity(size: .init(width: 500, height: 400)),
            selectedElementID: committedText.id,
            editingTextIDs: [committedText.id],
            guides: [],
            gridSpacing: 20,
            theme: CanvasTheme.default.renderSnapshot
        )

        XCTAssertTrue(presentation.scene.geometry.isEmpty)
        let descriptor = try XCTUnwrap(presentation.textDescriptors.first)
        XCTAssertEqual(descriptor.id, committedText.id)
        XCTAssertEqual(descriptor.frame, CanvasRect(x: 20, y: 30, width: 120, height: 50))
        XCTAssertEqual(descriptor.text, "Preview text")
        XCTAssertTrue(descriptor.isSelected)
        XCTAssertTrue(descriptor.isEditing)
        XCTAssertEqual(descriptor.previewGeneration, generation)
    }

    func testFreehandGeometryUsesReusablePreparedInk() throws {
        let points = [CanvasPoint(x: 1, y: 2), CanvasPoint(x: 3, y: 4), CanvasPoint(x: 5, y: 6)]
        let freehand = CanvasElement(
            id: UUID(),
            geometry: .freehand(inkStroke(points))
        )
        let document = CanvasDocument(elements: [freehand])
        let preparer = CanvasScenePreparer()

        let first = try prepare(document, with: preparer)
        var panned = try! CanvasViewport.identity(size: .init(width: 500, height: 400))
        panned = try! panned.panned(byScreen: .init(x: 10, y: 10))
        let second = try prepare(document, with: preparer, viewport: panned)

        guard case .ink(let firstInk) = try XCTUnwrap(first.scene.geometry.first).path,
              case .ink(let secondInk) = try XCTUnwrap(second.scene.geometry.first).path else {
            return XCTFail("Expected prepared ink geometry")
        }
        XCTAssertEqual(firstInk.confirmedSamples.map(\.point), points)
        XCTAssertEqual(firstInk.predictedSamples, [])
        XCTAssertEqual(firstInk.finalizedConfirmedSampleCount, points.count)
        XCTAssertTrue(firstInk === secondInk)
        XCTAssertEqual(preparer.statistics.geometryBuildCount, 1)
    }

    func testGrowingPreviewReusesPreparedInkAndBackendAppendsOnlyTail() throws {
        let id = UUID()
        let preparer = CanvasScenePreparer()
        let renderer = CoreGraphicsCanvasRenderer()
        var generation = RecognitionGeneration.zero
        generation.advance()
        let initialPoints = [
            CanvasPoint(x: 10, y: 10),
            CanvasPoint(x: 20, y: 20),
        ]
        var preview = CanvasRenderPreview(
            inserting: freehand(id: id, points: initialPoints),
            generation: generation
        )

        let first = try prepare(preview: preview, with: preparer)
        guard case .ink(let firstInk) = try XCTUnwrap(first.scene.geometry.first).path else {
            return XCTFail("Expected prepared ink preview geometry")
        }
        let initialInkGeneration = firstInk.generation
        _ = renderer.renderCommands(
            scene: first.scene,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayScale: 2
        )

        generation.advance()
        let grownPoints = initialPoints + [CanvasPoint(x: 30, y: 10)]
        XCTAssertTrue(preview.update(
            element: freehand(id: id, points: grownPoints),
            generation: generation
        ))
        let second = try prepare(preview: preview, with: preparer)
        guard case .ink(let secondInk) = try XCTUnwrap(second.scene.geometry.first).path else {
            return XCTFail("Expected prepared ink preview geometry")
        }
        _ = renderer.renderCommands(
            scene: second.scene,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayScale: 2
        )
        var expectedInkGeneration = initialInkGeneration
        expectedInkGeneration.advance()

        XCTAssertTrue(firstInk === secondInk)
        XCTAssertEqual(firstInk.confirmedSamples.map(\.point), grownPoints)
        XCTAssertEqual(secondInk.generation, expectedInkGeneration)
        XCTAssertEqual(renderer.pathBuildCount, 1)
        XCTAssertEqual(renderer.cachedPathCount, 1)
        XCTAssertEqual(renderer.cachedPointCount(for: secondInk), grownPoints.count)
    }

    func testChangedAndTruncatedPreviewsDoNotMutateRetainedInk() throws {
        let id = UUID()
        let preparer = CanvasScenePreparer()
        let renderer = CoreGraphicsCanvasRenderer()
        var generation = RecognitionGeneration.zero
        generation.advance()
        let initialPoints = [
            CanvasPoint(x: 10, y: 10),
            CanvasPoint(x: 20, y: 20),
        ]
        var preview = CanvasRenderPreview(
            inserting: freehand(id: id, points: initialPoints),
            generation: generation
        )
        let first = try prepare(preview: preview, with: preparer)
        let firstInk = try preparedInk(in: first)
        _ = renderer.renderCommands(
            scene: first.scene,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayScale: 2
        )

        generation.advance()
        let changedPoints = [initialPoints[0], CanvasPoint(x: 40, y: 40)]
        XCTAssertTrue(preview.update(
            element: freehand(id: id, points: changedPoints),
            generation: generation
        ))
        let changed = try prepare(preview: preview, with: preparer)
        let changedInk = try preparedInk(in: changed)
        _ = renderer.renderCommands(
            scene: changed.scene,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayScale: 2
        )

        generation.advance()
        let truncatedPoints = [changedPoints[0]]
        XCTAssertTrue(preview.update(
            element: freehand(id: id, points: truncatedPoints),
            generation: generation
        ))
        let truncated = try prepare(preview: preview, with: preparer)
        let truncatedInk = try preparedInk(in: truncated)
        _ = renderer.renderCommands(
            scene: truncated.scene,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayScale: 2
        )

        XCTAssertFalse(firstInk === changedInk)
        XCTAssertFalse(changedInk === truncatedInk)
        XCTAssertEqual(firstInk.confirmedSamples.map(\.point), initialPoints)
        XCTAssertEqual(changedInk.confirmedSamples.map(\.point), changedPoints)
        XCTAssertEqual(truncatedInk.confirmedSamples.map(\.point), truncatedPoints)
        XCTAssertEqual(renderer.pathBuildCount, 3)

        _ = try prepare(.empty(), with: preparer)
        generation.advance()
        let restarted = try prepare(
            preview: CanvasRenderPreview(
                inserting: freehand(id: id, points: truncatedPoints),
                generation: generation
            ),
            with: preparer
        )
        let restartedInk = try preparedInk(in: restarted)
        XCTAssertFalse(restartedInk === truncatedInk)
    }

    func testFailedPreparationDoesNotAppendToPublishedPreviewInk() throws {
        let previewID = UUID()
        let invalidID = UUID()
        let initialPoints = [
            CanvasPoint(x: 10, y: 10),
            CanvasPoint(x: 20, y: 20),
        ]
        let previewTarget = freehand(id: previewID, points: initialPoints)
        let validCompanion = line(id: invalidID)
        let validDocument = CanvasDocument(elements: [previewTarget, validCompanion])
        let preparer = CanvasScenePreparer()
        var generation = RecognitionGeneration.zero
        generation.advance()
        var preview = CanvasRenderPreview(
            replacing: previewTarget,
            generation: generation
        )
        let successful = try prepare(validDocument, preview: preview, with: preparer)
        let publishedInk = try preparedInk(in: successful)
        let publishedGeneration = publishedInk.generation

        generation.advance()
        let grownPoints = initialPoints + [CanvasPoint(x: 30, y: 10)]
        XCTAssertTrue(preview.update(
            element: freehand(id: previewID, points: grownPoints),
            generation: generation
        ))
        let maximum = Double.greatestFiniteMagnitude
        let invalidCompanion = CanvasElement(
            id: invalidID,
            contentRevision: 1,
            geometry: .freehand(inkStroke([
                .init(x: -maximum, y: 20),
                .init(x: 0, y: 20),
                .init(x: maximum, y: 20),
            ]))
        )

        XCTAssertThrowsError(
            try prepare(
                CanvasDocument(elements: [previewTarget, invalidCompanion]),
                preview: preview,
                with: preparer
            )
        ) { error in
            XCTAssertEqual(error as? CanvasScenePreparationError, .invalidGeometryBounds)
        }
        XCTAssertEqual(publishedInk.confirmedSamples.map(\.point), initialPoints)
        XCTAssertEqual(publishedInk.generation, publishedGeneration)

        let recovered = try prepare(validDocument, preview: preview, with: preparer)
        let recoveredInk = try preparedInk(in: recovered)
        XCTAssertTrue(recoveredInk === publishedInk)
        XCTAssertEqual(recoveredInk.confirmedSamples.map(\.point), grownPoints)
    }

    func testDraftPreparedInkKeepsIdentityAcrossTenBatchesAndReplacesPredictions() throws {
        let draft = CanvasFreehandDraft(id: UUID(), style: .default)
        let preparer = CanvasScenePreparer()
        var generation = RecognitionGeneration.zero
        var preview: CanvasRenderPreview?
        var retainedInk: CanvasPreparedInk?
        var confirmed: [CanvasInkSample] = []
        var evaluatedSpanCount = 0

        for index in 0..<12 {
            let point: CanvasPoint = switch index {
            case 4:
                .init(x: 20, y: 14)
            case 8:
                .init(x: 5, y: 35)
            default:
                .init(x: Double(index * 10), y: Double((index * 7) % 19))
            }
            let sample = CanvasInkSample(
                point: point,
                pressure: Double(index + 1) / 12
            )
            let predictions = [CanvasInkSample(
                point: .init(x: 10_000 + Double(index), y: -10_000 - Double(index)),
                pressure: 0.5
            )]
            confirmed.append(sample)
            draft.append([sample])
            generation.advance()
            if preview == nil {
                preview = CanvasRenderPreview(
                    freehand: draft,
                    predictedInkSamples: predictions,
                    generation: generation
                )
            } else {
                XCTAssertTrue(preview?.update(
                    freehand: draft,
                    predictedInkSamples: predictions,
                    generation: generation
                ) == true)
            }

            let presentation = try prepare(
                preview: try XCTUnwrap(preview),
                with: preparer
            )
            let ink = try preparedInk(in: presentation)
            if let retainedInk {
                XCTAssertTrue(ink === retainedInk)
            } else {
                retainedInk = ink
            }
            XCTAssertTrue(ink === draft.preparedInk)
            XCTAssertEqual(ink.confirmedSamples, confirmed)
            XCTAssertEqual(ink.predictedSamples, predictions)
            XCTAssertEqual(ink.finalizedConfirmedSampleCount, max(0, confirmed.count - 4))
            XCTAssertEqual(
                try XCTUnwrap(presentation.scene.geometry.first).bounds,
                try CanvasInkCurve.bounds(stroke: .init(
                    samples: confirmed,
                    pressureEnabled: true
                ))
            )
            XCTAssertLessThanOrEqual(
                ink.incrementalBoundsEvaluatedSpanCount - evaluatedSpanCount,
                5
            )
            evaluatedSpanCount = ink.incrementalBoundsEvaluatedSpanCount
        }

        let ink = try XCTUnwrap(retainedInk)
        let confirmedBeforeReplacement = ink.confirmedSamples
        let finalizedBeforeReplacement = ink.finalizedConfirmedSampleCount
        let generationBeforeReplacement = ink.generation
        let replacement = [
            CanvasInkSample(point: .init(x: 91, y: 42), pressure: 0.25),
            CanvasInkSample(point: .init(x: 96, y: 38), pressure: 0.75),
        ]
        generation.advance()
        XCTAssertTrue(preview?.update(
            freehand: draft,
            predictedInkSamples: replacement,
            generation: generation
        ) == true)
        let replacementPresentation = try prepare(
            preview: try XCTUnwrap(preview),
            with: preparer
        )
        let replacedInk = try preparedInk(in: replacementPresentation)

        XCTAssertTrue(replacedInk === ink)
        XCTAssertEqual(replacedInk.confirmedSamples, confirmedBeforeReplacement)
        XCTAssertEqual(replacedInk.predictedSamples, replacement)
        XCTAssertEqual(replacedInk.finalizedConfirmedSampleCount, finalizedBeforeReplacement)
        XCTAssertNotEqual(replacedInk.generation, generationBeforeReplacement)
    }

    func testInvalidIncrementalDraftPredictionDoesNotMutatePublishedInk() throws {
        let draft = CanvasFreehandDraft(id: UUID(), style: .default)
        draft.append([
            .init(point: .init(x: 0, y: 0), pressure: 0.2),
            .init(point: .init(x: 10, y: 20), pressure: 0.4),
            .init(point: .init(x: 20, y: 5), pressure: 0.6),
            .init(point: .init(x: 30, y: 15), pressure: 0.8),
        ])
        let preparer = CanvasScenePreparer()
        var generation = RecognitionGeneration.zero
        generation.advance()
        var preview = CanvasRenderPreview(
            freehand: draft,
            predictedInkSamples: [],
            generation: generation
        )
        let published = try preparedInk(in: prepare(preview: preview, with: preparer))
        let publishedGeneration = published.generation
        let publishedConfirmed = published.confirmedSamples
        let publishedPredicted = published.predictedSamples
        let publishedFinalizedCount = published.finalizedConfirmedSampleCount
        let publishedEvaluationCount = published.incrementalBoundsEvaluatedSpanCount

        generation.advance()
        let maximum = Double.greatestFiniteMagnitude
        XCTAssertTrue(preview.update(
            freehand: draft,
            predictedInkSamples: [
                .init(point: .init(x: -maximum, y: 0), pressure: 0.5),
                .init(point: .init(x: maximum, y: 0), pressure: 0.5),
            ],
            generation: generation
        ))
        XCTAssertThrowsError(try prepare(preview: preview, with: preparer)) { error in
            XCTAssertEqual(error as? CanvasScenePreparationError, .invalidGeometryBounds)
        }
        XCTAssertEqual(published.generation, publishedGeneration)
        XCTAssertEqual(published.confirmedSamples, publishedConfirmed)
        XCTAssertEqual(published.predictedSamples, publishedPredicted)
        XCTAssertEqual(published.finalizedConfirmedSampleCount, publishedFinalizedCount)
        XCTAssertEqual(
            published.incrementalBoundsEvaluatedSpanCount,
            publishedEvaluationCount
        )

        generation.advance()
        let recoveredPrediction = [CanvasInkSample(
            point: .init(x: 36, y: 12),
            pressure: 0.7
        )]
        XCTAssertTrue(preview.update(
            freehand: draft,
            predictedInkSamples: recoveredPrediction,
            generation: generation
        ))
        let recovered = try preparedInk(in: prepare(preview: preview, with: preparer))
        XCTAssertTrue(recovered === published)
        XCTAssertEqual(recovered.confirmedSamples, publishedConfirmed)
        XCTAssertEqual(recovered.predictedSamples, recoveredPrediction)
    }

    func testAppendingConfirmedSamplePreservesFinalizedFlattenedPrefixExactly() throws {
        let id = UUID()
        var initialSamples: [CanvasInkSample] = []
        for index in 0..<8 {
            let point = CanvasPoint(
                x: Double(index * 11),
                y: Double((index * index * 3) % 29)
            )
            initialSamples.append(CanvasInkSample(
                point: point,
                pressure: Double(index + 2) / 10
            ))
        }
        let preparer = CanvasScenePreparer()
        var generation = RecognitionGeneration.zero
        generation.advance()
        var preview = CanvasRenderPreview(
            inserting: CanvasElement(
                id: id,
                geometry: .freehand(.init(samples: initialSamples, pressureEnabled: true))
            ),
            generation: generation
        )
        let first = try prepare(preview: preview, with: preparer)
        let ink = try preparedInk(in: first)
        let firstSnapshot = ink.snapshot()
        let firstVertices = try CanvasInkCurve.flatten(
            stroke: .init(samples: firstSnapshot.confirmed, pressureEnabled: firstSnapshot.pressureEnabled),
            maximumError: 0.25
        )

        let appended = CanvasInkSample(point: .init(x: 91, y: 17), pressure: 0.35)
        generation.advance()
        XCTAssertTrue(preview.update(
            element: CanvasElement(
                id: id,
                geometry: .freehand(.init(
                    samples: initialSamples + [appended],
                    pressureEnabled: true
                ))
            ),
            generation: generation
        ))
        let second = try prepare(preview: preview, with: preparer)
        let grownInk = try preparedInk(in: second)
        let secondSnapshot = grownInk.snapshot()
        let secondVertices = try CanvasInkCurve.flatten(
            stroke: .init(samples: secondSnapshot.confirmed, pressureEnabled: secondSnapshot.pressureEnabled),
            maximumError: 0.25
        )
        let stableBoundaryPoint = initialSamples[
            firstSnapshot.finalizedConfirmedSampleCount - 1
        ].point
        let firstBoundaryCandidate: Int? = firstVertices.firstIndex {
            $0.point == stableBoundaryPoint
        }
        let secondBoundaryCandidate: Int? = secondVertices.firstIndex {
            $0.point == stableBoundaryPoint
        }
        let firstBoundary = try XCTUnwrap(firstBoundaryCandidate)
        let secondBoundary = try XCTUnwrap(secondBoundaryCandidate)

        XCTAssertTrue(grownInk === ink)
        XCTAssertEqual(firstSnapshot.finalizedConfirmedSampleCount, initialSamples.count - 4)
        XCTAssertEqual(secondSnapshot.finalizedConfirmedSampleCount, initialSamples.count - 3)
        XCTAssertEqual(
            Array(firstVertices.prefix(through: firstBoundary)),
            Array(secondVertices.prefix(through: secondBoundary))
        )
        XCTAssertNotEqual(
            Array(firstVertices.suffix(from: firstBoundary)),
            Array(secondVertices.suffix(from: secondBoundary))
        )
    }

    func testPredictionsDoNotAffectPreparedBoundsAndFinalPreviewMatchesCommit() throws {
        let draft = CanvasFreehandDraft(id: UUID(), style: .default, pressureEnabled: false)
        let confirmed = [
            CanvasInkSample(point: .init(x: 10, y: 10), pressure: 0.2),
            CanvasInkSample(point: .init(x: 30, y: 40), pressure: 0.8),
            CanvasInkSample(point: .init(x: 60, y: 12), pressure: 0.4),
            CanvasInkSample(point: .init(x: 90, y: 35), pressure: 0.6),
        ]
        draft.append(confirmed)
        var generation = RecognitionGeneration.zero
        generation.advance()
        var preview = CanvasRenderPreview(
            freehand: draft,
            predictedInkSamples: [
                .init(point: .init(x: 10_000, y: 20_000), pressure: 1),
            ],
            generation: generation
        )
        let preparer = CanvasScenePreparer()
        let renderer = CoreGraphicsCanvasRenderer()
        let predictedPresentation = try prepare(preview: preview, with: preparer)
        let predictedGeometry = try XCTUnwrap(predictedPresentation.scene.geometry.first)
        let predictedInk = try preparedInk(in: predictedPresentation)
        XCTAssertEqual(
            predictedGeometry.bounds,
            try CanvasInkCurve.bounds(stroke: .init(
                samples: confirmed,
                pressureEnabled: false
            ))
        )
        _ = renderer.renderCommands(
            scene: predictedPresentation.scene,
            bounds: CGRect(x: 0, y: 0, width: 500, height: 400),
            displayScale: 2
        )
        XCTAssertEqual(renderer.inkOutlineBuildCount, 1)

        generation.advance()
        XCTAssertTrue(preview.update(
            freehand: draft,
            predictedInkSamples: [],
            generation: generation
        ))
        let finalPreview = try prepare(preview: preview, with: preparer)
        let finalPreviewInk = try preparedInk(in: finalPreview)
        let finalPreviewSnapshot = finalPreviewInk.snapshot()
        let finalVertices = try CanvasInkCurve.flatten(
            stroke: .init(
                samples: finalPreviewSnapshot.confirmed + finalPreviewSnapshot.predicted,
                pressureEnabled: finalPreviewSnapshot.pressureEnabled
            ),
            maximumError: 0.25
        )
        XCTAssertTrue(finalPreviewInk === predictedInk)
        XCTAssertEqual(finalPreviewSnapshot.predicted, [])
        _ = renderer.renderCommands(
            scene: finalPreview.scene,
            bounds: CGRect(x: 0, y: 0, width: 500, height: 400),
            displayScale: 2
        )
        XCTAssertEqual(renderer.inkOutlineBuildCount, 2)
        let finalPreviewBitmap = try XCTUnwrap(renderer.makeBitmap(
            scene: finalPreview.scene,
            bounds: CGRect(x: 0, y: 0, width: 500, height: 400),
            displayScale: 2
        ))

        let committed = try draft.materializeElement()
        let committedPresentation = try prepare(
            .init(elements: [committed]),
            with: preparer
        )
        let committedInk = try preparedInk(in: committedPresentation)
        let committedSnapshot = committedInk.snapshot()
        let committedVertices = try CanvasInkCurve.flatten(
            stroke: .init(
                samples: committedSnapshot.confirmed + committedSnapshot.predicted,
                pressureEnabled: committedSnapshot.pressureEnabled
            ),
            maximumError: 0.25
        )

        XCTAssertTrue(committedInk === finalPreviewInk)
        XCTAssertEqual(committedSnapshot.confirmed, confirmed)
        XCTAssertEqual(committedSnapshot.predicted, [])
        XCTAssertEqual(committedSnapshot.finalizedConfirmedSampleCount, confirmed.count)
        XCTAssertEqual(committedVertices, finalVertices)
        XCTAssertNotEqual(
            committedPresentation.scene.geometry.first?.resourceIdentity,
            finalPreview.scene.geometry.first?.resourceIdentity
        )
        _ = renderer.renderCommands(
            scene: committedPresentation.scene,
            bounds: CGRect(x: 0, y: 0, width: 500, height: 400),
            displayScale: 2
        )
        XCTAssertEqual(
            renderer.inkOutlineBuildCount,
            2,
            "Exact final preview and commit should rekey the same prepared outline"
        )
        XCTAssertEqual(renderer.cachedPathCount, 1)
        let committedBitmap = try XCTUnwrap(renderer.makeBitmap(
            scene: committedPresentation.scene,
            bounds: CGRect(x: 0, y: 0, width: 500, height: 400),
            displayScale: 2
        ))
        XCTAssertEqual(committedBitmap.width, finalPreviewBitmap.width)
        XCTAssertEqual(committedBitmap.height, finalPreviewBitmap.height)
        XCTAssertEqual(committedBitmap.dataProvider?.data, finalPreviewBitmap.dataProvider?.data)
    }

    func testLongFreehandCommitPromotesPreparedInkByFinalizingOnlyTheTail() throws {
        let draft = CanvasFreehandDraft(id: UUID(), style: .default)
        let samples = (0..<30_000).map { index in
            CanvasInkSample(
                point: .init(
                    x: Double(index) * 0.25,
                    y: sin(Double(index) * 0.03) * 40
                ),
                pressure: Double(index % 31) / 30
            )
        }
        draft.append(samples)
        var generation = RecognitionGeneration.zero
        generation.advance()
        let preview = CanvasRenderPreview(
            freehand: draft,
            predictedInkSamples: [],
            generation: generation
        )
        let preparer = CanvasScenePreparer()

        let live = try prepare(preview: preview, with: preparer)
        let liveInk = try preparedInk(in: live)
        let evaluatedBeforeCommit = liveInk.incrementalBoundsEvaluatedSpanCount
        let element = try draft.materializeElement()
        let document = CanvasDocument(revision: 1, elements: [element])
        let handoff = CanvasCommittedFreehandHandoff(
            documentRevision: document.revision,
            documentIndex: 0,
            elementID: element.id,
            contentRevision: element.contentRevision,
            draft: draft
        )

        let committed = try preparer.prepare(
            document: document,
            preview: nil,
            viewport: try .identity(size: .init(width: 500, height: 400)),
            selectedElementID: nil,
            editingTextIDs: [],
            guides: [],
            gridSpacing: 20,
            theme: CanvasTheme.default.renderSnapshot,
            committedFreehandHandoff: handoff
        )
        let committedInk = try preparedInk(in: committed)

        XCTAssertTrue(committedInk === liveInk)
        XCTAssertEqual(committedInk.confirmedSamples, samples)
        XCTAssertEqual(committedInk.finalizedConfirmedSampleCount, samples.count)
        XCTAssertLessThanOrEqual(
            committedInk.incrementalBoundsEvaluatedSpanCount - evaluatedBeforeCommit,
            8
        )
        XCTAssertEqual(preparer.statistics.incrementalFreehandCommitCount, 1)
        XCTAssertLessThanOrEqual(
            preparer.statistics.incrementalFreehandCommitEvaluatedSpanCount,
            8
        )
    }

    func testOutputLimitFailureLeavesPublishedPreparedInkAndPresentationUnchanged() throws {
        let draft = CanvasFreehandDraft(id: UUID(), style: .default)
        draft.append([
            .init(point: .init(x: 0, y: 0), pressure: 1),
            .init(point: .init(x: 1, y: 1), pressure: 1),
            .init(point: .init(x: 2, y: 0), pressure: 1),
        ])
        var generation = RecognitionGeneration.zero
        generation.advance()
        var preview = CanvasRenderPreview(
            freehand: draft,
            predictedInkSamples: [],
            generation: generation
        )
        let preparer = CanvasScenePreparer()
        let valid = try prepare(preview: preview, with: preparer)
        let publishedInk = try preparedInk(in: valid)
        let publishedSnapshot = publishedInk.snapshot()
        let publishedGeneration = publishedInk.generation
        let publishedStatistics = preparer.statistics
        let publishedBounds = try XCTUnwrap(valid.scene.geometry.first).bounds
        let publishedCommittedSnapshot = try XCTUnwrap(valid.committedSnapshot)

        let excessiveSuffix = (0..<1_000_000).map { index in
            CanvasInkSample(
                point: .init(x: Double(index + 3), y: Double(index % 7)),
                pressure: 1
            )
        }
        draft.append(excessiveSuffix)
        generation.advance()
        XCTAssertTrue(preview.update(
            freehand: draft,
            predictedInkSamples: [],
            generation: generation
        ))

        XCTAssertThrowsError(try prepare(preview: preview, with: preparer)) { error in
            XCTAssertEqual(error as? CanvasInkCurveError, .outputLimitExceeded)
        }
        let retainedPresentation = try XCTUnwrap(preparer.lastPresentation)
        let retainedInk = try preparedInk(in: retainedPresentation)
        let retainedSnapshot = retainedInk.snapshot()

        XCTAssertTrue(retainedInk === publishedInk)
        XCTAssertEqual(retainedSnapshot.confirmed, publishedSnapshot.confirmed)
        XCTAssertEqual(retainedSnapshot.predicted, publishedSnapshot.predicted)
        XCTAssertEqual(
            retainedSnapshot.finalizedConfirmedSampleCount,
            publishedSnapshot.finalizedConfirmedSampleCount
        )
        XCTAssertEqual(retainedInk.generation, publishedGeneration)
        XCTAssertEqual(preparer.statistics, publishedStatistics)
        XCTAssertEqual(try XCTUnwrap(retainedPresentation.scene.geometry.first).bounds, publishedBounds)
        XCTAssertTrue(retainedPresentation.committedSnapshot === publishedCommittedSnapshot)
    }

    func testInkPreparedBoundsUseExactCurveExtrema() throws {
        let quadratic = CanvasElement(
            id: UUID(),
            geometry: .freehand(inkStroke([
                .init(x: 0, y: 0),
                .init(x: 100, y: 100),
                .init(x: 200, y: 0),
            ]))
        )
        let cubic = CanvasElement(
            id: UUID(),
            geometry: .freehand(inkStroke([
                .init(x: 0, y: 0),
                .init(x: 0, y: 100),
                .init(x: 100, y: 100),
                .init(x: 100, y: 0),
            ]))
        )

        let presentation = try CanvasScenePreparer().prepare(
            document: .init(elements: [quadratic, cubic]),
            preview: nil,
            viewport: .identity(size: .init(width: 500, height: 400)),
            selectedElementID: quadratic.id,
            editingTextIDs: [],
            guides: [],
            gridSpacing: 20,
            theme: CanvasTheme.default.renderSnapshot
        )
        let preparedQuadratic = try XCTUnwrap(
            presentation.scene.geometry.first(where: { $0.id == quadratic.id })
        )
        let preparedCubic = try XCTUnwrap(
            presentation.scene.geometry.first(where: { $0.id == cubic.id })
        )

        guard case .freehand(let quadraticStroke) = quadratic.geometry,
              case .freehand(let cubicStroke) = cubic.geometry else {
            return XCTFail("Expected ink strokes")
        }
        let quadraticBounds = try CanvasInkCurve.bounds(stroke: quadraticStroke)
        let cubicBounds = try CanvasInkCurve.bounds(stroke: cubicStroke)
        XCTAssertEqual(preparedQuadratic.bounds, quadraticBounds)
        XCTAssertEqual(preparedCubic.bounds, cubicBounds)
        XCTAssertEqual(
            presentation.scene.selectionBounds,
            try CanvasInkCurve.paintedBounds(
                centerlineBounds: quadraticBounds,
                lineWidth: quadratic.style.lineWidth,
                viewportZoom: 1,
                widthMode: .canvasScaled
            )
        )
    }

    func testExtremeFiniteQuadraticExtremumRemainsVisibleAndSelected() throws {
        let maximum = Double.greatestFiniteMagnitude
        let element = CanvasElement(
            id: UUID(),
            geometry: .freehand(inkStroke([
                .init(x: maximum / 2, y: 20),
                .init(x: -maximum / 2, y: 20),
                .init(x: maximum / 2, y: 20),
            ]))
        )

        let presentation = try prepareSelected(element)
        let prepared = try XCTUnwrap(presentation.scene.geometry.first)

        XCTAssertEqual(prepared.id, element.id)
        XCTAssertLessThanOrEqual(prepared.bounds.minX, 0)
        XCTAssertGreaterThanOrEqual(prepared.bounds.maxX.nextUp, maximum / 2)
        XCTAssertTrue(prepared.bounds.isFinite)
        XCTAssertEqual(
            presentation.scene.selectionBounds,
            try CanvasInkCurve.paintedBounds(
                centerlineBounds: prepared.bounds,
                lineWidth: element.style.lineWidth,
                viewportZoom: 1,
                widthMode: .canvasScaled
            )
        )
    }

    func testExtremeFiniteCubicExtremumRemainsVisibleAndSelected() throws {
        let maximum = Double.greatestFiniteMagnitude
        let element = CanvasElement(
            id: UUID(),
            geometry: .freehand(inkStroke([
                .init(x: maximum / 2, y: 40),
                .init(x: -maximum / 2, y: 40),
                .init(x: -maximum / 2, y: 40),
                .init(x: maximum / 2, y: 40),
            ]))
        )

        let presentation = try prepareSelected(element)
        let prepared = try XCTUnwrap(presentation.scene.geometry.first)

        XCTAssertEqual(prepared.id, element.id)
        XCTAssertLessThanOrEqual(prepared.bounds.minX, -maximum / 4)
        XCTAssertGreaterThanOrEqual(prepared.bounds.maxX, maximum / 2)
        XCTAssertTrue(prepared.bounds.isFinite)
        XCTAssertEqual(
            presentation.scene.selectionBounds,
            try CanvasInkCurve.paintedBounds(
                centerlineBounds: prepared.bounds,
                lineWidth: element.style.lineWidth,
                viewportZoom: 1,
                widthMode: .canvasScaled
            )
        )
    }

    func testQuadraticRootRoundingToEndpointFallsBackToConservativeBounds() throws {
        let element = CanvasElement(
            id: UUID(),
            geometry: .freehand(inkStroke([
                .init(x: 1.394275021058702e145, y: 20),
                .init(x: -8.530262230902952e80, y: 20),
                .init(x: -1.3044488852561162e-288, y: 20),
            ]))
        )

        let presentation = try prepareSelected(element)
        let prepared = try XCTUnwrap(presentation.scene.geometry.first)

        XCTAssertLessThanOrEqual(prepared.bounds.minX, -5.218868058951322e16)
        XCTAssertEqual(
            presentation.scene.selectionBounds,
            try CanvasInkCurve.paintedBounds(
                centerlineBounds: prepared.bounds,
                lineWidth: element.style.lineWidth,
                viewportZoom: 1,
                widthMode: .canvasScaled
            )
        )
    }

    func testQuadraticExtremumErrorBoundConservativelyContainsTrueMinimum() throws {
        let element = CanvasElement(
            id: UUID(),
            geometry: .freehand(inkStroke([
                .init(x: 1.5715811957142, y: 20),
                .init(x: -0.709455370859612, y: 20),
                .init(x: 0.9777212900279828, y: 20),
            ]))
        )

        let presentation = try prepareSelected(element)
        let prepared = try XCTUnwrap(presentation.scene.geometry.first)

        XCTAssertLessThanOrEqual(prepared.bounds.minX, 0.2603795238787749)
        XCTAssertEqual(
            presentation.scene.selectionBounds,
            try CanvasInkCurve.paintedBounds(
                centerlineBounds: prepared.bounds,
                lineWidth: element.style.lineWidth,
                viewportZoom: 1,
                widthMode: .canvasScaled
            )
        )
    }

    func testIllConditionedCubicExtremumIsConservativelyContained() throws {
        let element = CanvasElement(
            id: UUID(),
            geometry: .freehand(inkStroke([
                .init(x: 1.5715811957142, y: 20),
                .init(x: 0.05089015133165867, y: 20),
                .init(x: -0.14706315056374708, y: 20),
                .init(x: 0.9777212900279828, y: 20),
            ]))
        )

        let presentation = try prepareSelected(element)
        let prepared = try XCTUnwrap(presentation.scene.geometry.first)

        XCTAssertLessThanOrEqual(prepared.bounds.minX, 0.26037952387877486)
        XCTAssertEqual(
            presentation.scene.selectionBounds,
            try CanvasInkCurve.paintedBounds(
                centerlineBounds: prepared.bounds,
                lineWidth: element.style.lineWidth,
                viewportZoom: 1,
                widthMode: .canvasScaled
            )
        )
    }

    func testUnrepresentableFiniteInkBoundsFailAtomically() throws {
        let preparer = CanvasScenePreparer()
        let committed = line()
        let successful = try prepare(.init(elements: [committed]), with: preparer)
        let successfulStatistics = preparer.statistics
        let maximum = Double.greatestFiniteMagnitude
        let unrepresentable = CanvasElement(
            id: UUID(),
            geometry: .freehand(inkStroke([
                .init(x: -maximum, y: 20),
                .init(x: 0, y: 20),
                .init(x: maximum, y: 20),
            ]))
        )

        XCTAssertThrowsError(
            try prepare(.init(elements: [unrepresentable]), with: preparer)
        ) { error in
            XCTAssertEqual(error as? CanvasScenePreparationError, .invalidGeometryBounds)
        }

        XCTAssertEqual(preparer.statistics, successfulStatistics)
        XCTAssertEqual(
            preparer.lastPresentation?.scene.geometry.map(\.id),
            successful.scene.geometry.map(\.id)
        )
    }

    func testFiniteNonFreehandElementsWithUnrepresentableBoundsFailAtomically() throws {
        let preparer = CanvasScenePreparer()
        let committed = line()
        let successful = try prepare(.init(elements: [committed]), with: preparer)
        let successfulStatistics = preparer.statistics
        let maximum = Double.greatestFiniteMagnitude
        let elements = [
            CanvasElement(
                id: UUID(),
                geometry: .line(.init(
                    start: .init(x: -maximum, y: 20),
                    end: .init(x: maximum, y: 20)
                ))
            ),
            CanvasElement.rectangle(
                id: UUID(),
                rect: .init(x: maximum, y: 20, width: maximum, height: 40)
            ),
            CanvasElement(
                id: UUID(),
                geometry: .text(.init(
                    frame: .init(x: maximum, y: 20, width: maximum, height: 40),
                    text: "Finite but unrepresentable",
                    font: .init(familyName: "Helvetica", pointSize: 16),
                    color: .black
                ))
            ),
        ]

        for element in elements {
            let document = CanvasDocument(elements: [element])
            if (try? document.validate()) != nil {
                XCTAssertThrowsError(try prepare(document, with: preparer)) { error in
                    XCTAssertEqual(error as? CanvasScenePreparationError, .invalidGeometryBounds)
                }
            }
            XCTAssertEqual(preparer.statistics, successfulStatistics)
            XCTAssertEqual(
                preparer.lastPresentation?.scene.geometry.map(\.id),
                successful.scene.geometry.map(\.id)
            )
        }
    }

    func testInkBoundsEncloseFiniteSamples() throws {
        let maximum = Double.greatestFiniteMagnitude
        let element = CanvasElement(
            id: UUID(),
            geometry: .freehand(inkStroke([
                .init(x: -maximum / 4, y: 20),
                .init(x: 0, y: 20),
                .init(x: maximum / 2, y: 20),
            ]))
        )

        let presentation = try prepareSelected(element)
        let prepared = try XCTUnwrap(presentation.scene.geometry.first)

        XCTAssertLessThanOrEqual(prepared.bounds.minX, -maximum / 4)
        XCTAssertGreaterThanOrEqual(prepared.bounds.maxX.nextUp, maximum / 2)
        XCTAssertTrue(prepared.bounds.isFinite)
    }

    func testExtremeFiniteInkSamplesRemainRepresentable() throws {
        let maximum = Double.greatestFiniteMagnitude
        let element = CanvasElement(
            id: UUID(),
            geometry: .freehand(inkStroke([
                .init(x: maximum / 2, y: 20),
                .init(x: maximum / 9, y: 20),
                .init(x: maximum / 2, y: 20),
            ]))
        )
        let viewport = try! CanvasViewport(
            zoom: 1,
            translation: .init(x: -(maximum / 9), y: 0),
            viewportSize: .init(width: maximum / 100, height: 100)
        )

        let presentation = try CanvasScenePreparer().prepare(
            document: .init(elements: [element]),
            preview: nil,
            viewport: viewport,
            selectedElementID: element.id,
            editingTextIDs: [],
            guides: [],
            gridSpacing: 20,
            theme: CanvasTheme.default.renderSnapshot
        )
        let prepared = try XCTUnwrap(presentation.scene.geometry.first)

        XCTAssertLessThanOrEqual(prepared.bounds.minX, (maximum / 9).nextUp)
        XCTAssertGreaterThanOrEqual(prepared.bounds.maxX, maximum / 2)
        XCTAssertTrue(prepared.bounds.isFinite)
        XCTAssertEqual(
            presentation.scene.selectionBounds,
            try CanvasInkCurve.paintedBounds(
                centerlineBounds: prepared.bounds,
                lineWidth: element.style.lineWidth,
                viewportZoom: viewport.zoom,
                widthMode: .canvasScaled
            )
        )
    }

    func testAdjacentExtremeFiniteInkSamplesRemainRepresentable() throws {
        let maximum = Double.greatestFiniteMagnitude
        let element = CanvasElement(
            id: UUID(),
            geometry: .freehand(inkStroke([
                .init(x: maximum / 2, y: 20),
                .init(x: (maximum / 9).nextUp, y: 20),
                .init(x: maximum / 2, y: 20),
            ]))
        )
        let viewport = try! CanvasViewport(
            zoom: 1,
            translation: .init(x: -(maximum / 9), y: 0),
            viewportSize: .init(width: maximum / 100, height: 100)
        )

        let presentation = try CanvasScenePreparer().prepare(
            document: .init(elements: [element]),
            preview: nil,
            viewport: viewport,
            selectedElementID: element.id,
            editingTextIDs: [],
            guides: [],
            gridSpacing: 20,
            theme: CanvasTheme.default.renderSnapshot
        )
        let prepared = try XCTUnwrap(presentation.scene.geometry.first)

        XCTAssertLessThanOrEqual(prepared.bounds.minX, (maximum / 9).nextUp)
        XCTAssertGreaterThanOrEqual(prepared.bounds.maxX, maximum / 2)
        XCTAssertTrue(prepared.bounds.isFinite)
        XCTAssertEqual(
            presentation.scene.selectionBounds,
            try CanvasInkCurve.paintedBounds(
                centerlineBounds: prepared.bounds,
                lineWidth: element.style.lineWidth,
                viewportZoom: viewport.zoom,
                widthMode: .canvasScaled
            )
        )
    }

    func testViewportChangesReuseCachedBoundsPreparationWork() throws {
        let freehand = CanvasElement(
            id: UUID(),
            geometry: .freehand(inkStroke([
                .init(x: 0, y: 0),
                .init(x: 30, y: 80),
                .init(x: 70, y: 80),
                .init(x: 100, y: 0),
            ]))
        )
        let document = CanvasDocument(elements: [freehand])
        let preparer = CanvasScenePreparer()

        _ = try prepare(document, with: preparer)
        XCTAssertEqual(preparer.statistics.boundsBuildCount, 1)

        var panned = try! CanvasViewport.identity(size: .init(width: 500, height: 400))
        panned = try! panned.panned(byScreen: .init(x: 20, y: 10))
        _ = try prepare(document, with: preparer, viewport: panned)

        XCTAssertEqual(preparer.statistics.boundsBuildCount, 1)
    }

    func testPreparedGridMatchesExactModelSpaceGridPlan() throws {
        let preparer = CanvasScenePreparer()
        let viewport = try! CanvasViewport(
            zoom: 2,
            translation: .init(x: 15, y: -25),
            viewportSize: .init(width: 120, height: 80)
        )
        let presentation = try prepare(.empty(), with: preparer, viewport: viewport)
        let visibleRect = viewport.visibleCanvasRect
        let plan = try CanvasGridPlanner.plan(
            visibleRect: visibleRect,
            baseSpacing: 20,
            maximumLineCount: 10_000
        )
        let expected = plan.verticalCoordinates.map { coordinate in
            (CanvasPoint(x: coordinate, y: visibleRect.minY), CanvasPoint(x: coordinate, y: visibleRect.maxY))
        } + plan.horizontalCoordinates.map { coordinate in
            (CanvasPoint(x: visibleRect.minX, y: coordinate), CanvasPoint(x: visibleRect.maxX, y: coordinate))
        }

        XCTAssertEqual(presentation.scene.gridLines.count, expected.count)
        for (line, expectedLine) in zip(presentation.scene.gridLines, expected) {
            XCTAssertEqual(line.start, expectedLine.0)
            XCTAssertEqual(line.end, expectedLine.1)
        }
    }

    func testCullingIncludesPaintAndSelectionHandleExtents() throws {
        let paintedEdge = CanvasElement(
            id: UUID(),
            geometry: .line(.init(start: .init(x: 102, y: 10), end: .init(x: 102, y: 20))),
            style: .init(stroke: .black, lineWidth: 6)
        )
        let outside = CanvasElement(
            id: UUID(),
            geometry: .line(.init(start: .init(x: 104, y: 10), end: .init(x: 104, y: 20))),
            style: .init(stroke: .black, lineWidth: 6)
        )
        let selectedByHandle = CanvasElement(
            id: UUID(),
            geometry: .line(.init(start: .init(x: 106, y: 10), end: .init(x: 106, y: 20)))
        )
        var theme = CanvasTheme.default.renderSnapshot
        theme.handleSize = 14
        let preparer = CanvasScenePreparer()

        let presentation = try preparer.prepare(
            document: .init(elements: [paintedEdge, outside, selectedByHandle]),
            preview: nil,
            viewport: try .identity(size: .init(width: 100, height: 100)),
            selectedElementID: selectedByHandle.id,
            editingTextIDs: [],
            guides: [],
            gridSpacing: 20,
            theme: theme
        )

        XCTAssertEqual(presentation.scene.geometry.map(\.id), [paintedEdge.id, selectedByHandle.id])
        XCTAssertEqual(presentation.scene.selectionBounds, selectedByHandle.bounds)
    }

    func testCullingConvertsPaintAndHandleExtentsAtNonUnitZoom() throws {
        let paintedEdge = CanvasElement(
            id: UUID(),
            geometry: .line(.init(start: .init(x: 101.5, y: 10), end: .init(x: 101.5, y: 20))),
            style: .init(stroke: .black, lineWidth: 8)
        )
        let outside = CanvasElement(
            id: UUID(),
            geometry: .line(.init(start: .init(x: 102.5, y: 10), end: .init(x: 102.5, y: 20))),
            style: .init(stroke: .black, lineWidth: 8)
        )
        let selectedByHandle = CanvasElement(
            id: UUID(),
            geometry: .line(.init(start: .init(x: 103, y: 10), end: .init(x: 103, y: 20)))
        )
        var theme = CanvasTheme.default.renderSnapshot
        theme.handleSize = 14

        let presentation = try CanvasScenePreparer().prepare(
            document: .init(elements: [paintedEdge, outside, selectedByHandle]),
            preview: nil,
            viewport: .init(
                zoom: 2,
                translation: .init(x: 0, y: 0),
                viewportSize: .init(width: 200, height: 200)
            ),
            selectedElementID: selectedByHandle.id,
            editingTextIDs: [],
            guides: [],
            gridSpacing: 20,
            theme: theme
        )

        XCTAssertEqual(presentation.scene.geometry.map(\.id), [paintedEdge.id, selectedByHandle.id])
        XCTAssertEqual(presentation.scene.selectionBounds, selectedByHandle.bounds)
    }

    func testSelectedFreehandChromeEnclosesPressureExpandedInkAtCurrentZoom() throws {
        let element = CanvasElement(
            id: UUID(),
            geometry: .freehand(inkStroke([
                .init(x: 20, y: 50),
                .init(x: 80, y: 50),
            ])),
            style: .init(stroke: .black, lineWidth: 20)
        )
        let viewport = try! CanvasViewport(
            zoom: 2,
            translation: .init(x: 0, y: 0),
            viewportSize: .init(width: 200, height: 200)
        )

        let presentation = try CanvasScenePreparer().prepare(
            document: .init(elements: [element]),
            preview: nil,
            viewport: viewport,
            selectedElementID: element.id,
            editingTextIDs: [],
            guides: [],
            gridSpacing: 20,
            theme: CanvasTheme.default.renderSnapshot
        )

        XCTAssertEqual(
            presentation.scene.selectionBounds,
            CanvasRect(x: 2.5, y: 32.5, width: 95, height: 35)
        )
        XCTAssertEqual(presentation.scene.geometry.first?.bounds, element.bounds)
    }

    func testSelectedLiveFreehandDraftChromeEnclosesPressureExpandedInk() throws {
        let draft = CanvasFreehandDraft(
            id: UUID(),
            style: .init(stroke: .black, lineWidth: 20),
            pressureEnabled: true
        )
        draft.append([
            .init(point: .init(x: 20, y: 50), pressure: 1),
            .init(point: .init(x: 80, y: 50), pressure: 1),
        ])
        var generation = RecognitionGeneration.zero
        generation.advance()
        let preview = CanvasRenderPreview(
            freehand: draft,
            predictedInkSamples: [],
            generation: generation
        )

        let presentation = try CanvasScenePreparer().prepare(
            document: .empty(),
            preview: preview,
            viewport: .identity(size: .init(width: 100, height: 100)),
            selectedElementID: draft.id,
            editingTextIDs: [],
            guides: [],
            gridSpacing: 20,
            theme: CanvasTheme.default.renderSnapshot
        )

        XCTAssertEqual(
            presentation.scene.selectionBounds,
            CanvasRect(x: 2.5, y: 32.5, width: 95, height: 35)
        )
        XCTAssertEqual(
            presentation.scene.geometry.first?.bounds,
            CanvasRect(x: 20, y: 50, width: 60, height: 0)
        )
    }

    func testPressureInkSelectionAndCommittedBoundsUseOnePointSevenFiveWidth() throws {
        let stroke = CanvasInkStroke(
            samples: [
                .init(point: .init(x: 20, y: 50), pressure: 1),
                .init(point: .init(x: 80, y: 50), pressure: 1),
            ],
            pressureEnabled: true
        )
        let element = CanvasElement(
            id: UUID(),
            geometry: .freehand(stroke),
            style: .init(stroke: .black, lineWidth: 4)
        )
        let presentation = try prepareSelected(element)
        let expected = try CanvasInkCurve.paintedBounds(
            centerlineBounds: CanvasInkCurve.bounds(stroke: stroke),
            lineWidth: 4,
            viewportZoom: 1,
            pressureEnabled: true,
            widthMode: .canvasScaled
        )

        XCTAssertEqual(presentation.scene.selectionBounds, expected)
        XCTAssertEqual(try XCTUnwrap(presentation.committed.items.first).paintedBounds, expected)
    }

    func testPressureDisabledInkKeepsNominalPreparedBounds() throws {
        let stroke = CanvasInkStroke(
            samples: [
                .init(point: .init(x: 20, y: 50), pressure: 1),
                .init(point: .init(x: 80, y: 50), pressure: 1),
            ],
            pressureEnabled: false
        )
        let element = CanvasElement(
            id: UUID(),
            geometry: .freehand(stroke),
            style: .init(stroke: .black, lineWidth: 4)
        )
        let presentation = try prepareSelected(element)
        let expected = try CanvasInkCurve.paintedBounds(
            centerlineBounds: CanvasInkCurve.bounds(stroke: stroke),
            lineWidth: 4,
            viewportZoom: 1,
            pressureEnabled: false,
            widthMode: .canvasScaled
        )

        XCTAssertEqual(presentation.scene.selectionBounds, expected)
        XCTAssertEqual(try XCTUnwrap(presentation.committed.items.first).paintedBounds, expected)
    }

    func testPressureExtentKeepsEdgeStrokeVisibleWithoutBroadeningUniformInk() throws {
        func element(pressureEnabled: Bool) -> CanvasElement {
            CanvasElement(
                id: UUID(),
                geometry: .freehand(.init(
                    samples: [
                        .init(point: .init(x: 20, y: -0.8), pressure: 1),
                        .init(point: .init(x: 80, y: -0.8), pressure: 1),
                    ],
                    pressureEnabled: pressureEnabled
                )),
                style: .init(stroke: .black, lineWidth: 1)
            )
        }
        let pressure = element(pressureEnabled: true)
        let uniform = element(pressureEnabled: false)
        let presentation = try CanvasScenePreparer().prepare(
            document: .init(elements: [pressure, uniform]),
            preview: nil,
            viewport: .identity(size: .init(width: 100, height: 100)),
            selectedElementID: nil,
            editingTextIDs: [],
            guides: [],
            gridSpacing: 20,
            theme: CanvasTheme.default.renderSnapshot
        )

        XCTAssertTrue(presentation.scene.geometry.contains { $0.id == pressure.id })
        XCTAssertFalse(presentation.scene.geometry.contains { $0.id == uniform.id })
    }

    func testCoordinatorPreparesSceneAndFallsBackAtomicallyWithTypedDiagnostic() throws {
        let element = line()
        let session = try CanvasSession(
            document: .init(elements: [element]),
            viewport: .identity(size: .init(width: 100, height: 100))
        )
        let renderer = PreparedSceneRecordingRenderer()
        let preparer = CanvasPresentationPreparer()
        var failPreparation = false
        let coordinator = CadCanvasCoordinator(
            session: session,
            recognizer: nil,
            renderer: renderer,
            preparePresentation: { input in
                if failPreparation {
                    throw CanvasScenePreparationError.invalidViewport
                }
                return try preparer.prepare(input)
            }
        )
        let host = coordinator.makeHostView()
        _ = host
        var diagnostics: [CanvasDiagnostic] = []
        session.onDiagnostic = { diagnostics.append($0) }

        coordinator.update()
        let successful = try XCTUnwrap(renderer.scenes.last)
        failPreparation = true
        coordinator.update()

        XCTAssertEqual(renderer.scenes.count, 1)
        XCTAssertEqual(renderer.scenes.last?.geometry.map(\.renderKey), successful.geometry.map(\.renderKey))
        XCTAssertEqual(renderer.scenes.last?.viewport.zoom, successful.viewport.zoom)
        XCTAssertEqual(diagnostics, [.scenePreparationFailed(.invalidViewport)])
    }

    func testCoordinatorClearsPreparationOnDocumentReplacementWithReusedRenderKey() throws {
        let id = UUID()
        let original = CanvasElement(
            id: id,
            contentRevision: 0,
            geometry: .line(.init(start: .init(x: 0, y: 0), end: .init(x: 40, y: 40)))
        )
        let replacement = CanvasElement(
            id: id,
            contentRevision: 0,
            geometry: .line(.init(start: .init(x: 60, y: 60), end: .init(x: 90, y: 90)))
        )
        let session = try CanvasSession(
            document: .init(elements: [original]),
            viewport: .identity(size: .init(width: 100, height: 100))
        )
        let renderer = PreparedSceneRecordingRenderer()
        let coordinator = CadCanvasCoordinator(session: session, recognizer: nil, renderer: renderer)
        let host = coordinator.makeHostView()
        _ = host
        coordinator.update()

        try session.replaceDocument(.init(elements: [replacement]))
        coordinator.update()

        let path = try immutablePath(in: XCTUnwrap(renderer.scenes.last))
        XCTAssertEqual(path, replacement.geometry.renderPath)
    }

    func testCoordinatorClearsBackendCacheOnReplacementAndDismantle() throws {
        let session = try CanvasSession(
            document: .init(elements: [line()]),
            viewport: .identity(size: .init(width: 100, height: 100))
        )
        let renderer = CoreGraphicsCanvasRenderer()
        let coordinator = CadCanvasCoordinator(session: session, recognizer: nil, renderer: renderer)
        let host = coordinator.makeHostView()
        coordinator.update()
        let renderView = try XCTUnwrap(host.renderView as? CanvasRenderView)
        let firstScene = try XCTUnwrap(renderView.latestScene)
        _ = renderer.renderCommands(
            scene: firstScene,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayScale: 2
        )
        XCTAssertEqual(renderer.cachedPathCount, 1)

        try session.replaceDocument(.empty())
        coordinator.update()
        XCTAssertEqual(renderer.cachedPathCount, 0)

        try session.perform(.insert(line(), at: 0))
        coordinator.update()
        let secondScene = try XCTUnwrap(renderView.latestScene)
        _ = renderer.renderCommands(
            scene: secondScene,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayScale: 2
        )
        XCTAssertEqual(renderer.cachedPathCount, 1)

        coordinator.dismantle()

        XCTAssertEqual(renderer.cachedPathCount, 0)
        XCTAssertTrue(coordinator.isDismantled)
    }

    func testCoordinatorKeepsUIKitTextDocumentDrivenAndRendererTextFree() throws {
        let text = textElement()
        let session = try CanvasSession(
            document: .init(elements: [text]),
            viewport: .identity(size: .init(width: 100, height: 100))
        )
        let renderer = PreparedSceneRecordingRenderer()
        let coordinator = CadCanvasCoordinator(session: session, recognizer: nil, renderer: renderer)
        let host = coordinator.makeHostView()

        coordinator.update()

        XCTAssertTrue(try XCTUnwrap(renderer.scenes.last).geometry.isEmpty)
        XCTAssertTrue(containsTextView(in: host))
    }

    func testTypedPreparationFailuresDistinguishViewportVisibleRectAndGrid() throws {
        let preparer = CanvasScenePreparer()
        let document = CanvasDocument.empty()
        XCTAssertThrowsError(try CanvasViewport(
            zoom: 1,
            translation: .init(x: .nan, y: 0),
            viewportSize: .init(width: 100, height: 100)
        ))
        let extremeViewport = try CanvasViewport(
            zoom: 1,
            translation: .init(x: -.greatestFiniteMagnitude, y: 0),
            viewportSize: .init(width: .greatestFiniteMagnitude, height: 100)
        )
        XCTAssertThrowsError(try preparer.prepare(
            document: document,
            preview: nil,
            viewport: extremeViewport,
            selectedElementID: nil,
            editingTextIDs: [],
            guides: [],
            gridSpacing: 10,
            theme: CanvasTheme.default.renderSnapshot
        )) { error in
            XCTAssertEqual(error as? CanvasScenePreparationError, .invalidVisibleRect)
        }
        XCTAssertThrowsError(try preparer.prepare(
            document: document,
            preview: nil,
            viewport: try .identity(size: .init(width: 100, height: 100)),
            selectedElementID: nil,
            editingTextIDs: [],
            guides: [],
            gridSpacing: .leastNonzeroMagnitude,
            theme: CanvasTheme.default.renderSnapshot
        )) { error in
            XCTAssertEqual(error as? CanvasScenePreparationError, .invalidGrid)
        }

        let diagnostic = CanvasDiagnostic.scenePreparationFailed(.invalidGrid)
        XCTAssertEqual(diagnostic, .scenePreparationFailed(.invalidGrid))
        let session = CanvasSession()
        var received: CanvasDiagnostic?
        session.onDiagnostic = { received = $0 }
        session.onDiagnostic?(diagnostic)
        XCTAssertEqual(received, diagnostic)
    }
}

@MainActor
private final class PreparedSceneRecordingRenderer: CanvasRenderer {
    let view = UIView()
    private(set) var scenes: [CanvasPreparedScene] = []

    func makeRenderView() -> UIView { view }

    func update(_ scene: CanvasPreparedScene, in renderView: UIView) {
        guard renderView === view else { return }
        scenes.append(scene)
    }
}

@MainActor
private func immutablePath(in scene: CanvasPreparedScene) throws -> CanvasPath {
    guard case .immutable(let path) = try XCTUnwrap(scene.geometry.first).path else {
        XCTFail("Expected immutable prepared geometry")
        return CanvasPath(commands: [])
    }
    return path
}

@MainActor
private func preparedInk(
    in presentation: CanvasPreparedPresentation
) throws -> CanvasPreparedInk {
    guard case .ink(let preparedInk) = try XCTUnwrap(presentation.scene.geometry.first).path else {
        XCTFail("Expected prepared ink geometry")
        return CanvasPreparedInk(confirmedSamples: [], pressureEnabled: true)
    }
    return preparedInk
}

@MainActor
private func containsTextView(in view: UIView) -> Bool {
    if view is UITextView { return true }
    return view.subviews.contains(where: containsTextView)
}

@MainActor
private func prepareSelected(_ element: CanvasElement) throws -> CanvasPreparedPresentation {
    try CanvasScenePreparer().prepare(
        document: .init(elements: [element]),
        preview: nil,
        viewport: .identity(size: .init(width: 100, height: 100)),
        selectedElementID: element.id,
        editingTextIDs: [],
        guides: [],
        gridSpacing: 20,
        theme: CanvasTheme.default.renderSnapshot
    )
}

private func line(id: UUID = UUID(), contentRevision: UInt64 = 0) -> CanvasElement {
    CanvasElement(
        id: id,
        contentRevision: contentRevision,
        geometry: .line(.init(start: .init(x: 0, y: 0), end: .init(x: 40, y: 40)))
    )
}

private func freehand(id: UUID, points: [CanvasPoint]) -> CanvasElement {
    CanvasElement(
        id: id,
        geometry: .freehand(inkStroke(points))
    )
}

private func inkStroke(_ points: [CanvasPoint]) -> CanvasInkStroke {
    CanvasInkStroke(
        samples: points.map { CanvasInkSample(point: $0, pressure: 1) },
        pressureEnabled: true
    )
}

private func textElement() -> CanvasElement {
    CanvasElement(
        id: UUID(),
        geometry: .text(.init(
            frame: .init(x: 10, y: 10, width: 80, height: 40),
            text: "Prepared text",
            font: .init(familyName: "Helvetica", pointSize: 16),
            color: .black
        ))
    )
}

@MainActor
private func prepare(
    _ document: CanvasDocument,
    with preparer: CanvasScenePreparer,
    viewport: CanvasViewport = try! .identity(size: .init(width: 500, height: 400))
) throws -> CanvasPreparedPresentation {
    try preparer.prepare(
        document: document,
        preview: nil,
        viewport: viewport,
        selectedElementID: nil,
        editingTextIDs: [],
        guides: [],
        gridSpacing: 20,
        theme: CanvasTheme.default.renderSnapshot
    )
}

@MainActor
private func prepare(
    _ document: CanvasDocument = .empty(),
    preview: CanvasRenderPreview,
    with preparer: CanvasScenePreparer,
    viewport: CanvasViewport = try! .identity(size: .init(width: 500, height: 400))
) throws -> CanvasPreparedPresentation {
    try preparer.prepare(
        document: document,
        preview: preview,
        viewport: viewport,
        selectedElementID: nil,
        editingTextIDs: [],
        guides: [],
        gridSpacing: 20,
        theme: CanvasTheme.default.renderSnapshot
    )
}

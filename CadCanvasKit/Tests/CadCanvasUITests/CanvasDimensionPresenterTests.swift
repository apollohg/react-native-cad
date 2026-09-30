import Observation
import SwiftUI
import XCTest
import CadCanvasCore
@testable import CadCanvasUI

@MainActor
final class CanvasDimensionPresenterTests: XCTestCase {
    func testOverlappingShapeDimensionCanBeHiddenEditedAndUndoneIndependently() throws {
        let first = CanvasElement.rectangle(id: UUID(), rect: .init(x: 0, y: 20, width: 100, height: 80))
        let second = CanvasElement.rectangle(id: UUID(), rect: .init(x: 50, y: 20, width: 120, height: 80))
        let session = try CanvasSession(document: CanvasDocument(elements: [first, second]))
        let actions = CanvasActions(session: session)
        let width = try XCTUnwrap(actions.dimensionLayout.horizontal.first { $0.key.elementIDs == [first.id] })
        XCTAssertTrue(actions.canEditDimension(width))
        actions.hideDimension(width)
        XCTAssertFalse(actions.visibleDimensions.contains { $0.key == width.key })
        actions.showAllDimensions(on: .horizontal)
        XCTAssertTrue(actions.visibleDimensions.contains { $0.key == width.key })

        XCTAssertTrue(actions.editDimension(width, toMillimeters: "75", locale: Locale(identifier: "en_AU")))
        XCTAssertEqual(session.document.elements[0].bounds.width, 75)
        XCTAssertEqual(session.document.elements[1].bounds, second.bounds)
        XCTAssertTrue(actions.undo())
        XCTAssertEqual(session.document.elements[0].bounds, first.bounds)
    }

    func testShortGapKeepsItsTicksAndSharesTheDetailedChain() throws {
        let size = CanvasSize(width: 800, height: 600)
        let document = CanvasDocument(elements: [
            .rectangle(id: UUID(), rect: .init(x: 80, y: 60, width: 180, height: 220)),
            .rectangle(id: UUID(), rect: .init(x: 260, y: 60, width: 120, height: 220)),
            .rectangle(id: UUID(), rect: .init(x: 420, y: 120, width: 200, height: 240)),
        ])
        let result = CanvasDimensionPresenter().present(
            document: document, replacementGeneration: .zero, previewRevision: .zero,
            viewport: try .identity(size: size), hiddenKeys: [], availableSize: size
        )
        let detail = result.filter { $0.id.axis == .horizontal && ($0.id.role == .element || $0.id.role == .gap) }
        XCTAssertEqual(detail.count, 4)
        XCTAssertEqual(Set(detail.map { $0.clippedStart.y }).count, 1,
                       "Adjacent spans belong on a continuous chain when their labels fit side by side")
        let gap = try XCTUnwrap(detail.first { $0.id.role == .gap })
        let frame = try XCTUnwrap(gap.labelFrame)
        XCTAssertLessThan(frame.maxY, gap.clippedStart.y,
                          "A label wider than its gap must sit clear of the ticks")
    }

    func testLabelNearViewportEdgeNeverExtendsDimensionBeyondItsEndpoints() throws {
        let size = CanvasSize(width: 300, height: 200)
        let result = CanvasDimensionPresenter().project(
            .init(horizontal: [span(start: 0, end: 5)], vertical: []),
            viewport: try .identity(size: size), hiddenKeys: [], availableSize: size
        )
        let dimension = try XCTUnwrap(result.first)
        for line in dimension.dimensionLines {
            XCTAssertGreaterThanOrEqual(line.start.x, dimension.clippedStart.x)
            XCTAssertLessThanOrEqual(line.end.x, dimension.clippedEnd.x)
        }
    }

    func testOverallRemainsVisibleWhenThereAreMoreOverlapsThanAvailableRows() throws {
        let size = CanvasSize(width: 300, height: 100)
        let document = CanvasDocument(elements: (0..<20).map { index in
            .rectangle(id: UUID(), rect: .init(x: Double(index), y: 0, width: 100, height: 20))
        })
        let result = CanvasDimensionPresenter().present(
            document: document, replacementGeneration: .zero, previewRevision: .zero,
            viewport: try .identity(size: size), hiddenKeys: [], availableSize: size
        )
        XCTAssertNotNil(result.first { $0.id.axis == .horizontal && $0.id.role == .overall }?.labelPosition)
    }

    func testLabelsStayDisjointAndInsideViewportForLongLocalizedMeasurements() throws {
        let size = CanvasSize(width: 600, height: 400)
        let document = CanvasDocument(elements: [
            .rectangle(id: UUID(), rect: .init(x: 0, y: 0, width: 70, height: 90)),
            .rectangle(id: UUID(), rect: .init(x: 90, y: 95, width: 30, height: 15)),
            .rectangle(id: UUID(), rect: .init(x: 130, y: 140, width: 60, height: 40)),
        ], calibration: .init(millimetersPerPoint: 12345.67))
        let result = CanvasDimensionPresenter().present(
            document: document, replacementGeneration: .zero, previewRevision: .zero,
            viewport: try .identity(size: size), hiddenKeys: [], availableSize: size,
            labelFontSize: 24, locale: Locale(identifier: "de_DE")
        )
        let frames = result.compactMap(\.labelFrame)
        XCTAssertGreaterThan(frames.count, 2)
        for (index, frame) in frames.enumerated() {
            XCTAssertGreaterThanOrEqual(frame.minX, 0)
            XCTAssertGreaterThanOrEqual(frame.minY, 0)
            XCTAssertLessThanOrEqual(frame.maxX, size.width)
            XCTAssertLessThanOrEqual(frame.maxY, size.height)
            let rect = CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
            for other in frames.dropFirst(index + 1) {
                XCTAssertFalse(rect.intersects(CGRect(x: other.x, y: other.y, width: other.width, height: other.height)))
            }
        }
        XCTAssertTrue(result.contains { $0.labelText.contains(",") })
    }

    func testExtensionsStartAtGeometryAndClippedEndpointsDoNotInventTicks() throws {
        let size = CanvasSize(width: 300, height: 200)
        let document = CanvasDocument(elements: [
            .rectangle(id: UUID(), rect: .init(x: -20, y: 30, width: 120, height: 40)),
        ])
        let result = CanvasDimensionPresenter().present(
            document: document, replacementGeneration: .zero, previewRevision: .zero,
            viewport: try .identity(size: size), hiddenKeys: [], availableSize: size
        )
        let horizontal = try XCTUnwrap(result.first { $0.id.axis == .horizontal })
        XCTAssertFalse(horizontal.showsStartTick)
        XCTAssertTrue(horizontal.showsEndTick)
        XCTAssertEqual(horizontal.extensionLines.count, 1)
        let line = try XCTUnwrap(horizontal.extensionLines.first)
        XCTAssertEqual(line.start.x, 100)
        XCTAssertGreaterThan(line.start.y, 70)
        XCTAssertLessThan(line.start.y, horizontal.clippedStart.y)
        XCTAssertEqual(horizontal.dimension.canvasLength, 120, "Clipping must never change the measurement")
    }

    func testDimensionOverlayVisualEvidence() throws {
        let size = CanvasSize(width: 800, height: 600)
        let document = CanvasDocument(elements: [
            .rectangle(id: UUID(), rect: .init(x: 80, y: 60, width: 180, height: 220)),
            .rectangle(id: UUID(), rect: .init(x: 260, y: 60, width: 120, height: 220)),
            .rectangle(id: UUID(), rect: .init(x: 420, y: 120, width: 200, height: 240)),
        ])
        let session = try CanvasSession(document: document, viewport: .identity(size: size))
        let actions = CanvasActions(session: session)
        for (name, theme, typeSize) in [
            ("light", CanvasTheme.default, DynamicTypeSize.large),
            ("dark", CanvasTheme.dark, DynamicTypeSize.large),
            ("large-text", CanvasTheme.default, DynamicTypeSize.accessibility1),
        ] {
            let content = ZStack {
                Color(canvasColor: theme.background)
                Path { path in
                    for element in document.elements {
                        let bounds = element.bounds
                        path.addRect(CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height))
                    }
                }.stroke(Color(canvasColor: theme.stroke))
                DimensionOverlay(actions: actions)
            }
            .frame(width: size.width, height: size.height)
            .canvasTheme(theme)
            .environment(\.dynamicTypeSize, typeSize)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            let attachment = XCTAttachment(image: image)
            attachment.name = "dimension-chains-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testCollidingDimensionsMoveTheirLinesWithTheirLabels() throws {
        let size = CanvasSize(width: 300, height: 200)
        let result = CanvasDimensionPresenter().project(
            .init(horizontal: [span(start: 20, end: 180), span(start: 40, end: 200)], vertical: []),
            viewport: try .identity(size: size), hiddenKeys: [], availableSize: size
        )

        XCTAssertEqual(result.count, 2)
        XCTAssertNotEqual(result[0].clippedStart.y, result[1].clippedStart.y,
                          "Moving only labels leaves both measurements on the same line")
        for dimension in result {
            XCTAssertEqual(dimension.labelPosition?.y, dimension.clippedStart.y)
            XCTAssertEqual(dimension.clippedStart.y, dimension.clippedEnd.y)
        }
    }

    func testOverallLineIsOutsideTheDetailChain() throws {
        let size = CanvasSize(width: 600, height: 400)
        let document = CanvasDocument(elements: [
            .rectangle(id: UUID(), rect: .init(x: 40, y: 40, width: 100, height: 80)),
            .rectangle(id: UUID(), rect: .init(x: 240, y: 180, width: 160, height: 100)),
        ])
        let result = CanvasDimensionPresenter().present(
            document: document, replacementGeneration: .zero, previewRevision: .zero,
            viewport: try .identity(size: size), hiddenKeys: [], availableSize: size
        )
        for axis in [DimensionAxis.horizontal, .vertical] {
            let dimensions = result.filter { $0.id.axis == axis }
            let overall = try XCTUnwrap(dimensions.first { $0.id.role == .overall })
            for detail in dimensions where detail.id.role != .overall {
                if axis == .horizontal {
                    XCTAssertGreaterThan(overall.clippedStart.y, detail.clippedStart.y)
                } else {
                    XCTAssertGreaterThan(overall.clippedStart.x, detail.clippedStart.x)
                }
            }
        }
    }

    func testFreehandPreviewBatchDoesNotInvalidateDimensionOverlayDependencies() throws {
        let size = CanvasSize(width: 200, height: 150)
        let session = try CanvasSession(
            document: CanvasDocument(elements: [
                .rectangle(id: UUID(), rect: .init(x: 0, y: 0, width: 50, height: 40)),
                .rectangle(id: UUID(), rect: .init(x: 80, y: 20, width: 30, height: 30)),
            ]),
            viewport: .identity(size: size)
        )
        let actions = CanvasActions(session: session)
        let elementID = UUID()
        let token = try session.acquirePreview(.freehand(elementID: elementID))
        let recorder = DimensionInvalidationRecorder()
        withObservationTracking {
            _ = actions.presentedDimensions(availableSize: size)
        } onChange: {
            recorder.record()
        }

        try session.appendFreehandInkPreview(
            id: elementID,
            style: .default,
            confirmed: [.init(point: .init(x: 10, y: 10), pressure: 0.5)],
            predicted: [],
            pressureEnabled: true,
            token: token
        )

        XCTAssertEqual(recorder.count, 0)
    }

    func testElementPreviewInvalidatesDimensionOverlayDependencies() throws {
        let size = CanvasSize(width: 200, height: 150)
        let elementID = UUID()
        let session = try CanvasSession(
            document: CanvasDocument(elements: [
                .rectangle(
                    id: elementID,
                    rect: .init(x: 0, y: 0, width: 50, height: 40)
                ),
            ]),
            viewport: .identity(size: size)
        )
        let actions = CanvasActions(session: session)
        let token = try session.acquirePreview(.editing(elementID: elementID))
        let recorder = DimensionInvalidationRecorder()
        withObservationTracking {
            _ = actions.presentedDimensions(availableSize: size)
        } onChange: {
            recorder.record()
        }

        try session.updatePreview(
            .element(.rectangle(
                id: elementID,
                rect: .init(x: 0, y: 0, width: 75, height: 40)
            )),
            token: token
        )

        XCTAssertEqual(recorder.count, 1)
    }

    func testUnchangedElementPreviewCommitRestoresCommittedDimensionDocument() throws {
        let elementID = UUID()
        let original = CanvasElement.rectangle(
            id: elementID,
            rect: .init(x: 0, y: 0, width: 50, height: 40)
        )
        let session = try CanvasSession(document: CanvasDocument(elements: [original]))
        let token = try session.acquirePreview(.editing(elementID: elementID))
        try session.updatePreview(.element(original), token: token)
        try session.commitPreview(token: token)

        try session.perform(.setGeometry(
            id: elementID,
            .rectangle(.init(rect: .init(x: 0, y: 0, width: 75, height: 40)))
        ))

        XCTAssertEqual(session.presentationDocument.elements[0].bounds.width, 75)
    }

    func testTerminatorIsASlashCenteredOnTheDimensionEnd() {
        let point = CanvasPoint(x: 40, y: 25)

        let slash = CanvasDimensionTerminator.slash(at: point, axis: .horizontal)

        // A drafting slash crosses the endpoint diagonally rather than squarely,
        // so it stays legible where two dimension lines meet.
        XCTAssertNotEqual(slash.start.x, slash.end.x)
        XCTAssertNotEqual(slash.start.y, slash.end.y)
        XCTAssertEqual((slash.start.x + slash.end.x) / 2, point.x, accuracy: 0.000_1)
        XCTAssertEqual((slash.start.y + slash.end.y) / 2, point.y, accuracy: 0.000_1)
    }

    func testTerminatorLeansOppositeWaysOnEachAxis() {
        let point = CanvasPoint(x: 0, y: 0)

        let horizontal = CanvasDimensionTerminator.slash(at: point, axis: .horizontal)
        let vertical = CanvasDimensionTerminator.slash(at: point, axis: .vertical)

        let horizontalSlope = (horizontal.end.y - horizontal.start.y)
            / (horizontal.end.x - horizontal.start.x)
        let verticalSlope = (vertical.end.y - vertical.start.y)
            / (vertical.end.x - vertical.start.x)
        XCTAssertLessThan(horizontalSlope * verticalSlope, 0)
    }

    func testViewportChangeProjectsWithoutRecomputingStructure() throws {
        let document = CanvasDocument(elements: [
            .rectangle(id: UUID(), rect: .init(x: 0, y: 0, width: 50, height: 40)),
            .rectangle(id: UUID(), rect: .init(x: 80, y: 20, width: 30, height: 30)),
        ])
        let presenter = CanvasDimensionPresenter()
        let size = CanvasSize(width: 200, height: 150)
        _ = presenter.present(
            document: document,
            replacementGeneration: .zero,
            previewRevision: .zero,
            viewport: try .identity(size: size),
            hiddenKeys: [],
            availableSize: size
        )
        let baseline = presenter.metrics.structureBuildCount
        let panned = try CanvasViewport(
            zoom: 1,
            translation: .init(x: 30, y: 20),
            viewportSize: size
        )

        _ = presenter.present(
            document: document,
            replacementGeneration: .zero,
            previewRevision: .zero,
            viewport: panned,
            hiddenKeys: [],
            availableSize: size
        )

        XCTAssertEqual(presenter.metrics.structureBuildCount, baseline)
    }

    func testAppendingLongFreehandDoesNotReprocessCommittedFreehandHistory() throws {
        let size = CanvasSize(width: 1_024, height: 768)
        let committed = (0..<24).map { index in
            longFreehandElement(index: index, sampleCount: 20)
        }
        let session = try CanvasSession(
            document: CanvasDocument(elements: committed),
            viewport: .identity(size: size)
        )
        let presenter = CanvasDimensionPresenter()
        _ = presenter.present(
            document: session.document,
            replacementGeneration: session.documentReplacementGeneration,
            previewRevision: session.dimensionPresentationRevision,
            viewport: session.viewport,
            hiddenKeys: [],
            availableSize: size
        )
        let boundsBuildsBeforeInsertion = presenter.metrics.elementBoundsBuildCount
        try session.perform(.insert(
            longFreehandElement(index: committed.count, sampleCount: 20),
            at: committed.count
        ))

        _ = presenter.present(
            document: session.document,
            replacementGeneration: session.documentReplacementGeneration,
            previewRevision: session.dimensionPresentationRevision,
            viewport: session.viewport,
            hiddenKeys: [],
            availableSize: size
        )

        XCTAssertEqual(
            presenter.metrics.elementBoundsBuildCount - boundsBuildsBeforeInsertion,
            1
        )
    }

    func testCommittedFreehandHandoffSeedsBoundsWithoutReflatteningStroke() throws {
        let id = UUID()
        let draft = CanvasFreehandDraft(id: id, style: .default)
        let samples = (0..<50).map { index in
            CanvasInkSample(
                point: .init(x: Double(index), y: sin(Double(index) * 0.2) * 20),
                pressure: 0.5
            )
        }
        draft.append(samples)
        let candidate = try draft.preparedInk.makeIncrementalCandidate(
            appendingConfirmed: samples,
            predicted: [],
            isFinalized: true
        )
        XCTAssertTrue(draft.preparedInk.apply(candidate))
        let element = try draft.materializeElement()
        guard case .freehand(let stroke) = element.geometry else {
            return XCTFail("Expected freehand geometry")
        }
        XCTAssertEqual(
            draft.preparedInk.confirmedBounds,
            try CanvasInkCurve.bounds(stroke: stroke)
        )
        let document = CanvasDocument(elements: [element])
        let handoff = CanvasCommittedFreehandHandoff(
            documentRevision: document.revision,
            documentIndex: 0,
            elementID: id,
            contentRevision: element.contentRevision,
            draft: draft
        )
        let presenter = CanvasDimensionPresenter()

        let structure = presenter.structure(
            document: document,
            replacementGeneration: .zero,
            previewRevision: .zero,
            committedFreehandHandoff: handoff
        )

        XCTAssertFalse(structure.all.isEmpty)
        XCTAssertEqual(presenter.metrics.elementBoundsBuildCount, 0)
    }

    func testCanvasActionsForwardsCommittedFreehandBoundsToDimensionPresenter() throws {
        let session = CanvasSession()
        let id = UUID()
        let token = try session.acquirePreview(.freehand(elementID: id))
        let samples = (0..<50).map { index in
            CanvasInkSample(
                point: .init(x: Double(index), y: sin(Double(index) * 0.2) * 20),
                pressure: 0.5
            )
        }
        try session.appendFreehandInkPreview(
            id: id,
            style: .default,
            confirmed: samples,
            predicted: [],
            pressureEnabled: true,
            widthMode: .canvasScaled,
            token: token
        )
        try session.commitPreview(token: token)
        let handoff = try XCTUnwrap(session.committedFreehandHandoff)
        let candidate = try handoff.draft.preparedInk.makeIncrementalCandidate(
            appendingConfirmed: handoff.draft.samples,
            predicted: [],
            isFinalized: true
        )
        XCTAssertTrue(handoff.draft.preparedInk.apply(candidate))
        let actions = CanvasActions(session: session)

        _ = actions.presentedDimensions(
            availableSize: session.viewport.viewportSize
        )

        XCTAssertEqual(actions.dimensionPresentationMetrics.elementBoundsBuildCount, 0)
    }

    func testCanvasActionsBuildsCommittedBoundsFromUnrenderedFinalSamples() throws {
        let session = CanvasSession()
        let id = UUID()
        let token = try session.acquirePreview(.freehand(elementID: id))
        let samples = (0..<50).map { index in
            CanvasInkSample(
                point: .init(x: Double(index), y: sin(Double(index) * 0.2) * 20),
                pressure: 0.5
            )
        }
        try session.appendFreehandInkPreview(
            id: id,
            style: .default,
            confirmed: samples,
            predicted: [],
            pressureEnabled: true,
            widthMode: .canvasScaled,
            token: token
        )
        try session.commitPreview(token: token)
        let actions = CanvasActions(session: session)

        _ = actions.presentedDimensions(
            availableSize: session.viewport.viewportSize
        )

        XCTAssertEqual(actions.dimensionPresentationMetrics.elementBoundsBuildCount, 0)
    }

    func testWhollyOffscreenSpansAreCulledAndCollidingLabelsUseDifferentLanes() throws {
        let spans = [
            span(start: -100, end: -50),
            span(start: 0, end: 60),
            span(start: 10, end: 70),
        ]
        let presenter = CanvasDimensionPresenter()

        let result = presenter.project(
            .init(horizontal: spans, vertical: []),
            viewport: try .identity(size: .init(width: 100, height: 100)),
            hiddenKeys: [],
            availableSize: .init(width: 100, height: 100)
        )

        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.allSatisfy {
            $0.clippedStart.x >= 0 && $0.clippedEnd.x <= 100
        })
        let labels = result.compactMap(\.labelPosition)
        XCTAssertEqual(Set(labels).count, result.count)
        XCTAssertNotEqual(labels[0].y, labels[1].y)
    }

    func testInsufficientLaneSpaceCullsWholeDimensionsInsteadOfPilingThemAtEdge() {
        let spans = (0 ..< 8).map { offset in
            span(start: Double(offset), end: Double(offset + 60))
        }
        let result = CanvasDimensionPresenter().project(
            .init(horizontal: spans, vertical: []),
            viewport: try! .identity(size: .init(width: 100, height: 30)),
            hiddenKeys: [],
            availableSize: .init(width: 100, height: 30)
        )

        let labels = result.compactMap(\.labelPosition)
        XCTAssertLessThan(result.count, spans.count)
        XCTAssertEqual(Set(labels).count, labels.count)
        XCTAssertTrue(labels.allSatisfy { $0.y >= 0 })
        XCTAssertLessThan(labels.count, spans.count)
    }
}

private final class DimensionInvalidationRecorder: @unchecked Sendable {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

private extension CanvasDimensionPresenterTests {
    func longFreehandElement(index: Int, sampleCount: Int) -> CanvasElement {
        let samples = (0..<sampleCount).map { sample in
            CanvasInkSample(
                point: .init(
                    x: Double(sample % 960),
                    y: Double((sample * 17 + index * 31) % 700)
                ),
                pressure: 0.5
            )
        }
        return CanvasElement(
            id: UUID(),
            geometry: .freehand(.init(samples: samples, pressureEnabled: true))
        )
    }

    func span(start: Double, end: Double) -> CanvasDimensionSpan {
        CanvasDimensionSpan(
            key: .init(
                axis: .horizontal,
                role: .element,
                elementIDs: [UUID()],
                startEdge: start,
                endEdge: end
            ),
            canvasStart: .init(x: start, y: 0),
            canvasEnd: .init(x: end, y: 0),
            millimeters: end - start,
            isEditable: true
        )
    }
}

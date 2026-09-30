import CoreGraphics
import SwiftUI
import UIKit
import XCTest
import DrawCanvasCore
@testable import DrawCanvasUI

@MainActor
final class FreehandPipelineTests: XCTestCase {
    func testPencilPressureNormalizesClampsAndFallsBackToFullPressure() {
        XCTAssertEqual(
            CanvasPencilTouchSample(
                identity: NSObject(),
                location: CGPoint(x: 10, y: 20),
                force: 2,
                maximumPossibleForce: 4
            ).normalizedPressure,
            0.5
        )
        XCTAssertEqual(
            CanvasPencilTouchSample(
                identity: NSObject(),
                location: .zero,
                force: -2,
                maximumPossibleForce: 4
            ).normalizedPressure,
            0
        )
        XCTAssertEqual(
            CanvasPencilTouchSample(
                identity: NSObject(),
                location: .zero,
                force: 8,
                maximumPossibleForce: 4
            ).normalizedPressure,
            1
        )

        let unavailableOrInvalid: [(CGFloat, CGFloat)] = [
            (0, 0),
            (2, .nan),
            (2, .infinity),
            (.nan, 4),
            (.infinity, 4),
        ]
        for (force, maximumPossibleForce) in unavailableOrInvalid {
            XCTAssertEqual(
                CanvasPencilTouchSample(
                    identity: NSObject(),
                    location: .zero,
                    force: force,
                    maximumPossibleForce: maximumPossibleForce
                ).normalizedPressure,
                1
            )
        }
        XCTAssertEqual(
            CanvasPencilTouchSample(identity: NSObject(), location: .zero).normalizedPressure,
            1
        )
    }

    func testBeganBatchPreservesEveryConfirmedInkSampleInOrder() throws {
        let session = CanvasSession()
        session.selectTool(.freehand)
        let coordinator = DrawCanvasCoordinator(
            session: session,
            recognizer: nil,
            renderer: PipelineRecordingRenderer()
        )
        _ = coordinator.makeHostView()
        let samples = [
            CanvasInkSample(point: .init(x: 2, y: 3), pressure: 0.2),
            CanvasInkSample(point: .init(x: 5, y: 7), pressure: 0.6),
            CanvasInkSample(point: .init(x: 11, y: 13), pressure: 0.9),
        ]

        coordinator.receive(.pencilSamples(
            phase: .began,
            confirmed: samples,
            predicted: []
        ))

        let draft = try XCTUnwrap(CanvasRenderPreview(session.preview)?.freehandDraft)
        XCTAssertEqual(draft.samples, samples)
        coordinator.dismantle()
    }

    func testNativePressureSwitchWiringChangesOnlyFutureCoordinatorStrokes() throws {
        let session = CanvasSession()
        session.selectTool(.freehand)
        let actions = CanvasActions(session: session)
        let switchCoordinator = CanvasPressureSwitchCoordinator(isOn: Binding(
            get: { session.inkConfiguration.pressureEnabled },
            set: { actions.setInkConfiguration(.init(pressureEnabled: $0)) }
        ))
        let pressureSwitch = CanvasPressureSwitchWiring.makeControl(
            coordinator: switchCoordinator
        )
        pressureSwitch.update(isOn: session.inkConfiguration.pressureEnabled)
        let drawCoordinator = DrawCanvasCoordinator(
            session: session,
            recognizer: nil,
            renderer: PipelineRecordingRenderer()
        )
        _ = drawCoordinator.makeHostView()
        let firstSamples = [
            CanvasInkSample(point: .init(x: 0, y: 0), pressure: 0.25),
            CanvasInkSample(point: .init(x: 10, y: 8), pressure: 0.75),
        ]
        let secondSamples = [
            CanvasInkSample(point: .init(x: 20, y: 4), pressure: 0.1),
            CanvasInkSample(point: .init(x: 32, y: 14), pressure: 0.9),
        ]

        drawCoordinator.receive(.pencilSamples(
            phase: .began,
            confirmed: [firstSamples[0]],
            predicted: []
        ))
        pressureSwitch.setOn(false, animated: false)
        pressureSwitch.relayValueChanged()
        XCTAssertFalse(session.inkConfiguration.pressureEnabled)
        drawCoordinator.receive(.pencilSamples(
            phase: .ended,
            confirmed: [firstSamples[1]],
            predicted: []
        ))
        drawCoordinator.receive(.pencilSamples(
            phase: .began,
            confirmed: [secondSamples[0]],
            predicted: []
        ))
        drawCoordinator.receive(.pencilSamples(
            phase: .ended,
            confirmed: [secondSamples[1]],
            predicted: []
        ))

        var strokes: [CanvasInkStroke] = []
        for element in session.document.elements {
            guard case .freehand(let stroke) = element.geometry else {
                return XCTFail("Expected only Freehand strokes")
            }
            strokes.append(stroke)
        }
        XCTAssertEqual(strokes.map(\.samples), [firstSamples, secondSamples])
        XCTAssertEqual(strokes.map(\.pressureEnabled), [true, false])
        drawCoordinator.dismantle()
    }

    func testWidthModeToggleAffectsOnlyNewFreehandStrokes() throws {
        let session = CanvasSession()
        session.selectTool(.freehand)
        let actions = CanvasActions(session: session)
        let coordinator = DrawCanvasCoordinator(
            session: session,
            recognizer: nil,
            renderer: PipelineRecordingRenderer()
        )
        _ = coordinator.makeHostView()
        let first = [
            CanvasInkSample(point: .init(x: 10, y: 10), pressure: 0.3),
            CanvasInkSample(point: .init(x: 30, y: 30), pressure: 1),
        ]
        let second = [
            CanvasInkSample(point: .init(x: 40, y: 10), pressure: 0.3),
            CanvasInkSample(point: .init(x: 60, y: 30), pressure: 1),
        ]

        coordinator.receive(.pencilSamples(
            phase: .began,
            confirmed: [first[0]],
            predicted: []
        ))
        actions.setInkConfiguration(.init(
            pressureEnabled: session.inkConfiguration.pressureEnabled,
            widthMode: .screenConstant
        ))
        coordinator.receive(.pencilSamples(
            phase: .ended,
            confirmed: [first[1]],
            predicted: []
        ))
        coordinator.receive(.pencilSamples(
            phase: .began,
            confirmed: [second[0]],
            predicted: []
        ))
        coordinator.receive(.pencilSamples(
            phase: .ended,
            confirmed: [second[1]],
            predicted: []
        ))

        let strokes = session.document.elements.compactMap { element -> CanvasInkStroke? in
            guard case .freehand(let stroke) = element.geometry else { return nil }
            return stroke
        }
        XCTAssertEqual(strokes.map(\.widthMode), [.canvasScaled, .screenConstant])
        coordinator.dismantle()
    }

    func testPressureSwitchChangesWidthsWithoutDiscardingPersistedPressure() throws {
        let samples = [
            CanvasInkSample(point: .init(x: 0, y: 0), pressure: 0),
            CanvasInkSample(point: .init(x: 20, y: 0), pressure: 0.5),
            CanvasInkSample(point: .init(x: 40, y: 0), pressure: 1),
        ]
        let pressureOff = try CanvasInkCurve.flatten(
            stroke: .init(samples: samples, pressureEnabled: false),
            maximumError: 0.1
        )
        let pressureOn = try CanvasInkCurve.flatten(
            stroke: .init(samples: samples, pressureEnabled: true),
            maximumError: 0.1
        )

        XCTAssertEqual(Set(pressureOff.map(\.widthFactor)), [1])
        XCTAssertGreaterThan(Set(pressureOn.map(\.widthFactor)).count, 1)
        XCTAssertEqual(samples.map(\.pressure), [0, 0.5, 1])
    }

    func testHostKeepsConfirmedIdentityOrderAndSeparatesReplacementPredictions() {
        let host = CanvasHostView(renderView: UIView())
        let firstIdentity = NSObject()
        let primaryIdentity = NSObject()
        var deliveredConfirmed: [CanvasPencilTouchSample] = []
        var deliveredPredicted: [CanvasPencilTouchSample] = []
        host.sendPencil = { _, confirmed, predicted in
            deliveredConfirmed = confirmed
            deliveredPredicted = predicted
        }

        host.deliverPencilSamples(
            coalesced: [
                .init(
                    identity: firstIdentity,
                    location: .init(x: 10, y: 20),
                    force: 1,
                    maximumPossibleForce: 4
                ),
                .init(
                    identity: primaryIdentity,
                    location: .init(x: 30, y: 40),
                    force: 2,
                    maximumPossibleForce: 4
                ),
            ],
            primary: .init(
                identity: primaryIdentity,
                location: .init(x: 30, y: 40),
                force: 2,
                maximumPossibleForce: 4
            ),
            predicted: [
                .init(
                    identity: NSObject(),
                    location: .init(x: 50, y: 60),
                    force: 3,
                    maximumPossibleForce: 4
                ),
            ],
            phase: .moved
        )

        XCTAssertEqual(deliveredConfirmed.map(\.location), [
            .init(x: 10, y: 20),
            .init(x: 30, y: 40),
        ])
        XCTAssertEqual(deliveredConfirmed.map(\.normalizedPressure), [0.25, 0.5])
        XCTAssertEqual(deliveredPredicted.map(\.location), [.init(x: 50, y: 60)])
        XCTAssertEqual(deliveredPredicted.map(\.normalizedPressure), [0.75])
    }

    func testPredictionsReplaceWithoutEnteringDraftOrAcceptedRetainedDiagnosticsThenRemove() throws {
        let session = CanvasSession()
        session.selectTool(.freehand)
        let baselineEncoding = try CanvasDocumentCodec.encode(session.document)
        let baselineRevision = session.document.revision
        let baselineElements = session.document.elements
        func assertDocumentAndUndoNeutral(
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws {
            XCTAssertEqual(
                try CanvasDocumentCodec.encode(session.document),
                baselineEncoding,
                file: file,
                line: line
            )
            XCTAssertEqual(session.document.revision, baselineRevision, file: file, line: line)
            XCTAssertEqual(session.document.elements, baselineElements, file: file, line: line)
            XCTAssertFalse(session.canUndo, file: file, line: line)
        }
        let renderer = PipelineRecordingRenderer()
        let coordinator = DrawCanvasCoordinator(
            session: session,
            recognizer: nil,
            renderer: renderer
        )
        let host = coordinator.makeHostView()
        _ = host

        coordinator.receive(.pencilSamples(
            phase: .began,
            confirmed: [.init(point: .init(x: 0, y: 0), pressure: 0.2)],
            predicted: [.init(point: .init(x: 1, y: 1), pressure: 0.3)]
        ))
        try assertDocumentAndUndoNeutral()
        let draft = try XCTUnwrap(CanvasRenderPreview(session.preview)?.freehandDraft)
        let beganGeneration = try XCTUnwrap(CanvasRenderPreview(session.preview)?.generation)
        XCTAssertEqual(draft.samples, [.init(point: .init(x: 0, y: 0), pressure: 0.2)])
        XCTAssertEqual(draft.statistics.appendedPointCount, 1)
        XCTAssertEqual(CanvasRenderPreview(session.preview)?.predictedInkSamples, [
            .init(point: .init(x: 1, y: 1), pressure: 0.3),
        ])
        let beganInk = try preparedInk(in: XCTUnwrap(renderer.scenes.last))
        XCTAssertTrue(beganInk === draft.preparedInk)
        XCTAssertEqual(beganInk.confirmedSamples, draft.samples)
        XCTAssertEqual(beganInk.predictedSamples, [
            .init(point: .init(x: 1, y: 1), pressure: 0.3),
        ])
        let beganFinalizedCount = beganInk.finalizedConfirmedSampleCount

        coordinator.receive(.pencilSamples(
            phase: .moved,
            confirmed: [.init(point: .init(x: 2, y: 2), pressure: 0.4)],
            predicted: [
                .init(point: .init(x: 3, y: 3), pressure: 0.5),
                .init(point: .init(x: 4, y: 4), pressure: 0.6),
            ]
        ))
        try assertDocumentAndUndoNeutral()
        XCTAssertEqual(draft.samples, [
            .init(point: .init(x: 0, y: 0), pressure: 0.2),
            .init(point: .init(x: 2, y: 2), pressure: 0.4),
        ])
        XCTAssertEqual(draft.statistics.appendedPointCount, 2)
        XCTAssertNotEqual(CanvasRenderPreview(session.preview)?.generation, beganGeneration)
        XCTAssertEqual(CanvasRenderPreview(session.preview)?.generation, RecognitionGeneration(words: [2]))
        XCTAssertEqual(CanvasRenderPreview(session.preview)?.predictedInkSamples, [
            .init(point: .init(x: 3, y: 3), pressure: 0.5),
            .init(point: .init(x: 4, y: 4), pressure: 0.6),
        ])
        let movedInk = try preparedInk(in: XCTUnwrap(renderer.scenes.last))
        XCTAssertTrue(movedInk === beganInk)
        XCTAssertEqual(movedInk.confirmedSamples, draft.samples)
        XCTAssertEqual(movedInk.predictedSamples, [
            .init(point: .init(x: 3, y: 3), pressure: 0.5),
            .init(point: .init(x: 4, y: 4), pressure: 0.6),
        ])
        XCTAssertGreaterThanOrEqual(movedInk.finalizedConfirmedSampleCount, beganFinalizedCount)

        coordinator.receive(.pencilSamples(
            phase: .moved,
            confirmed: [.init(point: .init(x: 4.5, y: 4.5), pressure: 0.65)],
            predicted: [.init(point: .init(x: 6, y: 6), pressure: 0.8)]
        ))
        try assertDocumentAndUndoNeutral()
        XCTAssertEqual(CanvasRenderPreview(session.preview)?.predictedInkSamples, [
            .init(point: .init(x: 6, y: 6), pressure: 0.8),
        ])

        coordinator.receive(.pencilSamples(
            phase: .ended,
            confirmed: [.init(point: .init(x: 5, y: 5), pressure: 0.7)],
            predicted: [.init(point: .init(x: 99, y: 99), pressure: 0.9)]
        ))
        XCTAssertNil(CanvasRenderPreview(session.preview))
        XCTAssertEqual(session.document.revision, baselineRevision + 1)
        XCTAssertEqual(session.document.elements.count, 1)
        XCTAssertTrue(session.canUndo)
        guard case .freehand(let committed) = try XCTUnwrap(session.document.elements.first).geometry else {
            return XCTFail("Expected freehand geometry")
        }
        XCTAssertEqual(committed.samples, draft.samples)
        XCTAssertFalse(committed.samples.contains { $0.point == .init(x: 99, y: 99) })
        let committedInk = try preparedInk(in: XCTUnwrap(renderer.scenes.last))
        XCTAssertEqual(committedInk.confirmedSamples, committed.samples)
        XCTAssertEqual(committedInk.predictedSamples, [])
        XCTAssertEqual(committedInk.finalizedConfirmedSampleCount, committed.samples.count)

        try session.undo()
        XCTAssertTrue(session.document.elements.isEmpty)
        XCTAssertFalse(session.canUndo, "The committed stroke must create exactly one undo step")
        try session.redo()
        guard case .freehand(let redone) = try XCTUnwrap(session.document.elements.first).geometry else {
            return XCTFail("Expected redone freehand geometry")
        }
        XCTAssertEqual(redone.samples, committed.samples)
        XCTAssertNil(CanvasRenderPreview(session.preview))

        try session.replaceDocument(.empty())
        coordinator.receive(.pencilSamples(
            phase: .began,
            confirmed: [.init(point: .init(x: 10, y: 10), pressure: 0.2)],
            predicted: [.init(point: .init(x: 11, y: 11), pressure: 0.3)]
        ))
        XCTAssertFalse(try XCTUnwrap(CanvasRenderPreview(session.preview)?.predictedInkSamples).isEmpty)
        coordinator.receive(.pencilCancelled)
        XCTAssertNil(CanvasRenderPreview(session.preview))
        XCTAssertTrue(session.document.elements.isEmpty)
        XCTAssertTrue(try XCTUnwrap(renderer.scenes.last).geometry.isEmpty)
    }

     func testDraftPreservesEveryFiniteSampleInOrderAndMaterializesOnlyOnce() throws {
        let id = UUID()
        let draft = CanvasFreehandDraft(id: id, style: .default)

        draft.append([
            .init(x: 0, y: 0),
            .init(x: 1, y: 1),
            .init(x: .nan, y: 2),
            .init(x: 3, y: 3),
            .init(x: 4, y: .infinity),
        ])
        draft.append([.init(x: 4, y: 4)])

        let expected = [
            CanvasPoint(x: 0, y: 0),
            CanvasPoint(x: 1, y: 1),
            CanvasPoint(x: 3, y: 3),
            CanvasPoint(x: 4, y: 4),
        ]
        XCTAssertEqual(draft.points, expected)
        XCTAssertEqual(draft.preparedInk.confirmedSamples, [])
        XCTAssertEqual(draft.bounds, .init(x: 0, y: 0, width: 4, height: 4))
        XCTAssertEqual(draft.statistics.appendCallCount, 2)
        XCTAssertEqual(draft.statistics.appendedPointCount, 4)
        XCTAssertEqual(draft.statistics.fullPathMaterializationCount, 0)

        let first = try draft.materializeElement()
        let second = try draft.materializeElement()

        XCTAssertEqual(first.id, id)
        XCTAssertEqual(first.geometry, .freehand(.init(
            samples: expected.map { .init(point: $0, pressure: 1) },
            pressureEnabled: true
        )))
        XCTAssertEqual(second.geometry, first.geometry)
        XCTAssertEqual(draft.statistics.fullPathMaterializationCount, 1)
    }

     func testHostDeliversOneOrderedBatchAndDoesNotDuplicatePrimarySample() throws {
        let host = CanvasHostView(renderView: UIView())
        var deliveries: [(CanvasPencilBatchPhase, [CGPoint])] = []
        host.sendPencil = { phase, confirmed, _ in
            deliveries.append((phase, confirmed.map(\.location)))
        }
        let primary = CGPoint(x: 30, y: 4)
        let primaryTouch = NSObject()

        host.deliverPencilSamples(
            coalesced: [
                CanvasPencilTouchSample(identity: NSObject(), location: CGPoint(x: 10, y: 2)),
                CanvasPencilTouchSample(identity: NSObject(), location: CGPoint(x: 20, y: 3)),
                CanvasPencilTouchSample(identity: primaryTouch, location: primary),
            ],
            primary: CanvasPencilTouchSample(identity: primaryTouch, location: primary),
            phase: .moved
        )

        XCTAssertEqual(deliveries.count, 1)
        XCTAssertEqual(deliveries[0].0, .moved)
        XCTAssertEqual(deliveries[0].1, [
            CGPoint(x: 10, y: 2),
            CGPoint(x: 20, y: 3),
            primary,
        ])
    }

    func testHostPreservesDistinctPrimarySampleWhenItsCoordinateMatchesCoalescedTail() {
        let host = CanvasHostView(renderView: UIView())
        var delivered: [CGPoint] = []
        host.sendPencil = { _, confirmed, _ in delivered = confirmed.map(\.location) }
        let repeatedLocation = CGPoint(x: 30, y: 4)

        host.deliverPencilSamples(
            coalesced: [
                CanvasPencilTouchSample(identity: NSObject(), location: CGPoint(x: 20, y: 3)),
                CanvasPencilTouchSample(identity: NSObject(), location: repeatedLocation),
            ],
            primary: CanvasPencilTouchSample(
                identity: NSObject(),
                location: repeatedLocation
            ),
            phase: .ended
        )

        XCTAssertEqual(delivered, [
            CGPoint(x: 20, y: 3),
            repeatedLocation,
            repeatedLocation,
        ])
    }

    func testCoordinatorCapturesViewportOnceAndPublishesOnePreviewGenerationPerBatch() throws {
        let session = CanvasSession(viewport: try .init(
            zoom: 2,
            translation: .init(x: 10, y: 20),
            viewportSize: .init(width: 500, height: 400)
        ))
        session.selectTool(.freehand)
        let coordinator = DrawCanvasCoordinator(
            session: session,
            recognizer: nil,
            renderer: PipelineRecordingRenderer()
        )
        let host = coordinator.makeHostView()

        host.deliverPencilSamples(
            coalesced: [],
            primary: CanvasPencilTouchSample(
                identity: NSObject(),
                location: CGPoint(x: 12, y: 24)
            ),
            phase: .began
        )
        let draft = try XCTUnwrap(CanvasRenderPreview(session.preview)?.freehandDraft)
        let firstGeneration = try XCTUnwrap(CanvasRenderPreview(session.preview)?.generation)
        XCTAssertEqual(firstGeneration, RecognitionGeneration(words: [1]))
        let primaryTouch = NSObject()
        host.deliverPencilSamples(
            coalesced: [
                CanvasPencilTouchSample(
                    identity: NSObject(),
                    location: CGPoint(x: 14, y: 26)
                ),
                CanvasPencilTouchSample(
                    identity: primaryTouch,
                    location: CGPoint(x: 16, y: 28)
                ),
            ],
            primary: CanvasPencilTouchSample(
                identity: primaryTouch,
                location: CGPoint(x: 16, y: 28)
            ),
            phase: .moved
        )

        XCTAssertEqual(draft.points, [
            .init(x: 1, y: 2),
            .init(x: 2, y: 3),
            .init(x: 3, y: 4),
        ])
        XCTAssertEqual(draft.statistics.appendCallCount, 2)
        XCTAssertEqual(CanvasRenderPreview(session.preview)?.generation, RecognitionGeneration(words: [2]))
    }

    func testCancellationDropsDraftWithoutMaterializingOrMutatingDocument() throws {
        let session = CanvasSession()
        session.selectTool(.freehand)
        let coordinator = DrawCanvasCoordinator(
            session: session,
            recognizer: nil,
            renderer: PipelineRecordingRenderer()
        )
        let host = coordinator.makeHostView()
        _ = host
        coordinator.receive(.pencilSamples(
            phase: .began,
            points: [.init(x: 0, y: 0), .init(x: 1, y: 1)]
        ))
        let draft = try XCTUnwrap(CanvasRenderPreview(session.preview)?.freehandDraft)
        coordinator.receive(.pencilSamples(
            phase: .moved,
            points: [.init(x: 2, y: 2), .init(x: 3, y: 3)]
        ))

        coordinator.receive(.pencilCancelled)

        XCTAssertNil(CanvasRenderPreview(session.preview))
        XCTAssertTrue(session.document.elements.isEmpty)
        XCTAssertEqual(draft.statistics.fullPathMaterializationCount, 0)
    }

    func testCoordinatorCancelsPendingLatencyOnPencilCancellation() throws {
        let session = CanvasSession()
        session.selectTool(.freehand)
        let signposts = CanvasPerformanceSignposts()
        let coordinator = DrawCanvasCoordinator(
            session: session,
            recognizer: nil,
            renderer: PipelineRecordingRenderer(),
            performanceSignposts: signposts
        )
        let host = coordinator.makeHostView()

        host.deliverPencilSamples(
            coalesced: [],
            primary: .init(identity: NSObject(), location: .init(x: 1, y: 1)),
            phase: .began
        )
        XCTAssertEqual(signposts.statistics.activeIntervalCount, 1)

        coordinator.receive(.pencilCancelled)

        XCTAssertEqual(signposts.statistics.activeIntervalCount, 0)
        XCTAssertEqual(signposts.statistics.cancelledIntervalCount, 1)
    }

    func testPencilLatencyBeginsAfterGenerationAdvanceAndBeforeRendererUpdate() {
        var events: [String] = []
        let signposts = CanvasPerformanceSignposts(clock: {
            events.append("begin")
            return 1
        })
        let renderer = PipelineRecordingRenderer(onUpdate: {
            events.append("update")
        })
        let session = CanvasSession()
        session.selectTool(.freehand)
        let coordinator = DrawCanvasCoordinator(
            session: session,
            recognizer: nil,
            renderer: renderer,
            performanceSignposts: signposts
        )
        let host = coordinator.makeHostView()
        events.removeAll()

        host.deliverPencilSamples(
            coalesced: [],
            primary: .init(identity: NSObject(), location: .init(x: 1, y: 1)),
            phase: .moved
        )
        XCTAssertEqual(events, ["update"], "No interval may begin without a new preview generation")

        events.removeAll()
        host.deliverPencilSamples(
            coalesced: [],
            primary: .init(identity: NSObject(), location: .init(x: 2, y: 2)),
            phase: .began
        )

        XCTAssertEqual(events, ["begin", "update"])
    }

    func testCustomRendererCompletesCumulativePencilLatencyThroughPublicContract() throws {
        let signposts = CanvasPerformanceSignposts()
        let renderer = PipelineRecordingRenderer()
        let session = CanvasSession()
        session.selectTool(.freehand)
        let coordinator = DrawCanvasCoordinator(
            session: session,
            recognizer: nil,
            renderer: renderer,
            performanceSignposts: signposts
        )
        let host = coordinator.makeHostView()

        host.deliverPencilSamples(
            coalesced: [],
            primary: .init(identity: NSObject(), location: .init(x: 1, y: 1)),
            phase: .began
        )
        let first = try XCTUnwrap(renderer.scenes.last?.previewGeneration)
        host.deliverPencilSamples(
            coalesced: [],
            primary: .init(identity: NSObject(), location: .init(x: 2, y: 2)),
            phase: .moved
        )
        let second = try XCTUnwrap(renderer.scenes.last?.previewGeneration)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(signposts.statistics.activeIntervalCount, 2)
        renderer.completeDisplay(generation: second)
        XCTAssertEqual(signposts.statistics.activeIntervalCount, 0)
        XCTAssertEqual(signposts.statistics.completedIntervalCount, 2)
        XCTAssertEqual(signposts.statistics.cancelledIntervalCount, 0)
    }

    func testNonReportingRendererDoesNotStartPencilLatencyIntervals() {
        let signposts = CanvasPerformanceSignposts()
        let renderer = NonReportingRenderer()
        let session = CanvasSession()
        session.selectTool(.freehand)
        let coordinator = DrawCanvasCoordinator(
            session: session,
            recognizer: nil,
            renderer: renderer,
            performanceSignposts: signposts
        )
        let host = coordinator.makeHostView()

        withExtendedLifetime(host) {
            coordinator.receive(.pencilSamples(
                phase: .began,
                points: [.init(x: 1, y: 1), .init(x: 2, y: 2)]
            ))
        }

        XCTAssertNotNil(CanvasRenderPreview(session.preview)?.generation)
        XCTAssertEqual(signposts.statistics.activeIntervalCount, 0)
        XCTAssertEqual(signposts.statistics.completedIntervalCount, 0)
        XCTAssertEqual(signposts.statistics.cancelledIntervalCount, 0)
    }

    func testPreparationFailureCancelsPendingLatency() {
        var statuses: [CanvasPerformanceSignposts.IntervalEndStatus] = []
        let signposts = CanvasPerformanceSignposts(onIntervalEnd: { _, status in
            statuses.append(status)
        })
        let session = CanvasSession()
        session.selectTool(.freehand)
        let coordinator = DrawCanvasCoordinator(
            session: session,
            recognizer: nil,
            renderer: PipelineRecordingRenderer(),
            performanceSignposts: signposts,
            preparePresentation: { _ in throw CanvasScenePreparationError.invalidGeometryBounds }
        )
        let host = coordinator.makeHostView()

        withExtendedLifetime(host) {
            coordinator.receive(.pencilSamples(
                phase: .began,
                points: [.init(x: 1, y: 1), .init(x: 2, y: 2)]
            ))
        }

        XCTAssertNotNil(CanvasRenderPreview(session.preview)?.generation)
        XCTAssertEqual(signposts.statistics.activeIntervalCount, 0)
        XCTAssertEqual(signposts.statistics.cancelledIntervalCount, 1)
        XCTAssertEqual(statuses, [.cancelled])
    }

    func testCoordinatorCancelsPendingLatencyWhenPreciseStrokeCommits() {
        let session = CanvasSession()
        session.selectTool(.line)
        let signposts = CanvasPerformanceSignposts()
        let coordinator = DrawCanvasCoordinator(
            session: session,
            recognizer: nil,
            renderer: PipelineRecordingRenderer(),
            performanceSignposts: signposts
        )
        let host = coordinator.makeHostView()

        host.deliverPencilSamples(
            coalesced: [],
            primary: .init(identity: NSObject(), location: .init(x: 1, y: 1)),
            phase: .began
        )
        XCTAssertEqual(signposts.statistics.activeIntervalCount, 1)

        host.deliverPencilSamples(
            coalesced: [],
            primary: .init(identity: NSObject(), location: .init(x: 20, y: 20)),
            phase: .ended
        )

        XCTAssertEqual(session.document.elements.count, 1)
        XCTAssertEqual(signposts.statistics.activeIntervalCount, 0)
        XCTAssertEqual(signposts.statistics.cancelledIntervalCount, 1)
    }

    func testCoordinatorCancelsPendingLatencyOnDocumentReplacementAndDismantle() throws {
        let session = CanvasSession()
        session.selectTool(.freehand)
        let signposts = CanvasPerformanceSignposts()
        let coordinator = DrawCanvasCoordinator(
            session: session,
            recognizer: nil,
            renderer: PipelineRecordingRenderer(),
            performanceSignposts: signposts
        )
        let host = coordinator.makeHostView()

        host.deliverPencilSamples(
            coalesced: [],
            primary: .init(identity: NSObject(), location: .init(x: 1, y: 1)),
            phase: .began
        )
        XCTAssertEqual(signposts.statistics.activeIntervalCount, 1)

        try session.replaceDocument(.empty())
        coordinator.update()

        XCTAssertEqual(signposts.statistics.activeIntervalCount, 0)
        XCTAssertEqual(signposts.statistics.cancelledIntervalCount, 1)

        host.deliverPencilSamples(
            coalesced: [],
            primary: .init(identity: NSObject(), location: .init(x: 2, y: 2)),
            phase: .began
        )
        XCTAssertEqual(signposts.statistics.activeIntervalCount, 1)

        coordinator.dismantle()

        XCTAssertEqual(signposts.statistics.activeIntervalCount, 0)
        XCTAssertEqual(signposts.statistics.cancelledIntervalCount, 2)
    }

    func testBackendAppendsOnlyNewTailAndCommitUsesInkCacheKey() throws {
        let session = CanvasSession()
        let preparer = CanvasScenePreparer()
        let renderer = CoreGraphicsCanvasRenderer()
        let id = UUID()
        let token = try session.acquirePreview(.freehand(elementID: id))
        try session.appendFreehandPreview(
            id: id,
            style: .default,
            points: [.init(x: 10, y: 10), .init(x: 20, y: 20)],
            token: token
        )
        let draft = try XCTUnwrap(CanvasRenderPreview(session.preview)?.freehandDraft)

        let first = try prepare(session: session, preparer: preparer)
        render(first, with: renderer)
        XCTAssertEqual(renderer.pathPointAppendCount, 2)
        XCTAssertEqual(renderer.pathPointValidationCount, 2)
        XCTAssertEqual(renderer.pathBuildCount, 1)

        try session.appendFreehandPreview(
            id: id,
            style: .default,
            points: [.init(x: 30, y: 15), .init(x: 40, y: 25), .init(x: 50, y: 35)],
            token: token
        )
        let second = try prepare(session: session, preparer: preparer)
        render(second, with: renderer)
        XCTAssertEqual(renderer.pathPointAppendCount, 5)
        XCTAssertEqual(renderer.pathPointValidationCount, 5)
        XCTAssertEqual(renderer.pathBuildCount, 1)

        try session.commitPreview(token: token)
        let committedPresentation = try prepare(session: session, preparer: preparer)
        render(committedPresentation, with: renderer)
        let committedInk = try preparedInk(in: committedPresentation.scene)
        XCTAssertTrue(committedInk === draft.preparedInk)
        XCTAssertEqual(renderer.cachedPointCount(for: committedInk), draft.samples.count)
        XCTAssertEqual(renderer.cachedPathCount, 1)
    }
}

private extension FreehandPipelineTests {
    func preparedInk(in scene: CanvasPreparedScene) throws -> CanvasPreparedInk {
        guard case .ink(let preparedInk) = try XCTUnwrap(scene.geometry.first).path else {
            XCTFail("Expected prepared ink geometry")
            return CanvasPreparedInk(confirmedSamples: [], pressureEnabled: true)
        }
        return preparedInk
    }

    func prepare(
        session: CanvasSession,
        preparer: CanvasScenePreparer = CanvasScenePreparer()
    ) throws -> CanvasPreparedPresentation {
        try preparer.prepare(
            document: session.document,
            preview: CanvasRenderPreview(session.preview),
            viewport: session.viewport,
            selectedElementID: nil,
            editingTextIDs: [],
            guides: [],
            gridSpacing: session.snapConfiguration.gridSpacing,
            theme: CanvasTheme.default.renderSnapshot
        )
    }

    func render(_ presentation: CanvasPreparedPresentation, with renderer: CoreGraphicsCanvasRenderer) {
        _ = renderer.renderCommands(
            scene: presentation.scene,
            bounds: CGRect(x: 0, y: 0, width: 500, height: 400),
            displayScale: 2
        )
    }
}


extension CanvasInput {
    static func pencilSamples(
        phase: CanvasPencilBatchPhase,
        points: [CanvasPoint]
    ) -> CanvasInput {
        .pencilSamples(
            phase: phase,
            confirmed: points.map { CanvasInkSample(point: $0, pressure: 1) },
            predicted: []
        )
    }
}

extension CanvasFreehandDraft {
    func append(_ points: [CanvasPoint]) {
        append(points.map { CanvasInkSample(point: $0, pressure: 1) })
    }
}

@MainActor
private final class PipelineRecordingRenderer: CanvasTimestampedDisplayReportingRenderer {
    let view = UIView()
    private let onUpdate: () -> Void
    private var displayCompletion: ((RecognitionGeneration, TimeInterval) -> Void)?
    private(set) var scenes: [CanvasPreparedScene] = []

    init(onUpdate: @escaping () -> Void = {}) {
        self.onUpdate = onUpdate
    }

    func makeRenderView(
        displayCompletion: @escaping (RecognitionGeneration, TimeInterval) -> Void
    ) -> UIView {
        self.displayCompletion = displayCompletion
        return view
    }

    func update(_ scene: CanvasPreparedScene, in renderView: UIView) {
        XCTAssertTrue(renderView === view)
        scenes.append(scene)
        onUpdate()
    }

    func completeDisplay(generation: RecognitionGeneration) {
        displayCompletion?(generation, ProcessInfo.processInfo.systemUptime)
    }
}

@MainActor
private final class NonReportingRenderer: CanvasRenderer {
    let view = UIView()
    private(set) var scenes: [CanvasPreparedScene] = []

    func makeRenderView() -> UIView { view }

    func update(_ scene: CanvasPreparedScene, in renderView: UIView) {
        XCTAssertTrue(renderView === view)
        scenes.append(scene)
    }
}

@MainActor
private final class LegacyDisplayReportingRenderer: CanvasDisplayReportingRenderer {
    let view = UIView()

    func makeRenderView(
        displayCompletion _: @escaping (RecognitionGeneration) -> Void
    ) -> UIView {
        view
    }

    func update(_: CanvasPreparedScene, in renderView: UIView) {
        XCTAssertTrue(renderView === view)
    }
}

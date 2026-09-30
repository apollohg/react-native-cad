import XCTest
import UIKit
@testable import CadCanvasUI
import CadCanvasCore

@MainActor
final class InteractionReducerTests: XCTestCase {
    func testTextWidthResizePreservesOppositeEdgeAndRemeasuresHeight() throws {
        let element = textElement(
            frame: .init(x: 10, y: 20, width: 200, height: 24),
            text: "A long line of text that wraps when narrowed"
        )
        let context = makeContext(elements: [element], selectedElementID: element.id)

        var rightReducer = CanvasInteractionReducer()
        _ = beginManipulation(
            &rightReducer,
            at: .init(x: element.bounds.maxX, y: element.bounds.minY),
            in: context
        )
        let wider = try XCTUnwrap(rightReducer.reduce(
            .manipulationChanged(cumulativeScreenDelta: .init(x: 100, y: 80)),
            in: context
        ).updatedElement)
        XCTAssertEqual(wider.bounds.minX, element.bounds.minX)
        XCTAssertEqual(wider.bounds.width, 300)
        XCTAssertEqual(wider.bounds.minY, element.bounds.minY)

        var leftReducer = CanvasInteractionReducer()
        _ = beginManipulation(
            &leftReducer,
            at: .init(x: element.bounds.minX, y: element.bounds.minY),
            in: context
        )
        let narrower = try XCTUnwrap(leftReducer.reduce(
            .manipulationChanged(cumulativeScreenDelta: .init(x: 100, y: -80)),
            in: context
        ).updatedElement)
        XCTAssertEqual(narrower.bounds.maxX, element.bounds.maxX)
        XCTAssertEqual(narrower.bounds.width, 100)
        XCTAssertEqual(narrower.bounds.minY, element.bounds.minY)
        XCTAssertGreaterThan(narrower.bounds.height, wider.bounds.height)
    }

    func testManipulationWaitsForPreviewOwnership() throws {
        let element = rectangle(x: 0, y: 0, width: 100, height: 80)
        let context = makeContext(elements: [element], selectedElementID: element.id)
        var reducer = CanvasInteractionReducer()

        let effects = reducer.reduce(
            .manipulationBegan(point: .init(x: 50, y: 40)),
            in: context
        )

        XCTAssertBeginPreview(effects, id: element.id)
        guard case .awaitingManipulation = reducer.state else {
            return XCTFail("Expected pending preview ownership")
        }
        XCTAssertTrue(reducer.reduce(
            .manipulationChanged(cumulativeScreenDelta: .init(x: 10, y: 10)),
            in: context
        ).isEmpty)

        _ = reducer.reduce(.previewRejected, in: context)
        XCTAssertIdle(reducer.state)
    }

    func testResizeUsesCumulativeDeltaAcrossTenChangedEvents() throws {
        let element = rectangle(x: 0, y: 0, width: 100, height: 80)
        let context = makeContext(elements: [element], selectedElementID: element.id)
        var reducer = CanvasInteractionReducer()

        XCTAssertBeginPreview(
            beginManipulation(&reducer, at: .init(x: 100, y: 80), in: context),
            id: element.id
        )

        var updates: [CanvasElement] = []
        for event in 1...10 {
            let effects = reducer.reduce(
                .manipulationChanged(
                    cumulativeScreenDelta: .init(x: Double(event * 10), y: 0)
                ),
                in: context
            )
            updates.append(contentsOf: effects.compactMap(\.updatedElement))
        }

        let final = try XCTUnwrap(updates.last)
        XCTAssertEqual(final.bounds, CanvasRect(x: 0, y: 0, width: 200, height: 80))
        let endEffects = reducer.reduce(.manipulationEnded, in: context)
        XCTAssertEqual(endEffects.filter(\.isCommitPreview).count, 1)
        XCTAssertTrue(endEffects.containsEmptyGuides)
        XCTAssertIdle(reducer.state)
    }

    func testResizeClampKeepsOppositeEdgeFixedAfterCrossing() throws {
        let element = rectangle(x: 20, y: 30, width: 100, height: 80)
        let context = makeContext(elements: [element], selectedElementID: element.id)
        var reducer = CanvasInteractionReducer()
        _ = beginManipulation(&reducer, at: .init(x: 20, y: 70), in: context)

        let effects = reducer.reduce(
            .manipulationChanged(cumulativeScreenDelta: .init(x: 200, y: 999)),
            in: context
        )
        let resized = try XCTUnwrap(effects.compactMap(\.updatedElement).last)

        XCTAssertEqual(resized.bounds, CanvasRect(x: 110, y: 30, width: 10, height: 80))
        XCTAssertEqual(resized.bounds.maxX, element.bounds.maxX)
    }

    func testMoveUsesStartSnapshotForCumulativeDeltaAndEmitsSnapGuides() throws {
        let selected = rectangle(x: 0, y: 0, width: 10, height: 10)
        let target = rectangle(x: 100, y: 50, width: 20, height: 20)
        let context = makeContext(elements: [selected, target], selectedElementID: selected.id)
        var reducer = CanvasInteractionReducer()
        _ = beginManipulation(&reducer, at: .init(x: 5, y: 5), in: context)

        let first = reducer.reduce(
            .manipulationChanged(cumulativeScreenDelta: .init(x: 91, y: 0)),
            in: context
        )
        let second = reducer.reduce(
            .manipulationChanged(cumulativeScreenDelta: .init(x: 94, y: 0)),
            in: context
        )

        XCTAssertEqual(try XCTUnwrap(first.compactMap(\.updatedElement).last).bounds.x, 91)
        XCTAssertEqual(try XCTUnwrap(second.compactMap(\.updatedElement).last).bounds.x, 100)
        XCTAssertTrue(second.containsGuides([.vertical(canvasX: 100)]))
        let end = reducer.reduce(.manipulationEnded, in: context)
        XCTAssertTrue(end.containsEmptyGuides)
    }

    func testLineEndpointsEmitValidCumulativeUpdates() throws {
        let horizontal = CanvasElement(
            id: UUID(),
            contentRevision: 7,
            geometry: .line(
                .init(start: .init(x: 0, y: 20), end: .init(x: 100, y: 20))
            )
        )
        let horizontalContext = makeContext(
            elements: [horizontal],
            selectedElementID: horizontal.id
        )
        var horizontalReducer = CanvasInteractionReducer()

        _ = beginManipulation(&horizontalReducer, at: .init(x: 0, y: 20), in: horizontalContext)
        XCTAssertManipulationHandle(horizontalReducer.state, expected: .lineEndpoint(.first))
        _ = horizontalReducer.reduce(
            .manipulationChanged(cumulativeScreenDelta: .init(x: 2, y: 3)),
            in: horizontalContext
        )
        let horizontalEffects = horizontalReducer.reduce(
            .manipulationChanged(cumulativeScreenDelta: .init(x: 10, y: 5)),
            in: horizontalContext
        )
        let updatedHorizontal = try XCTUnwrap(horizontalEffects.compactMap(\.updatedElement).last)
        guard case .line(let horizontalLine) = updatedHorizontal.geometry else {
            return XCTFail("Expected line geometry")
        }
        XCTAssertEqual(horizontalLine.start, .init(x: 10, y: 25))
        XCTAssertEqual(horizontalLine.end, .init(x: 100, y: 20))
        XCTAssertEqual(updatedHorizontal.id, horizontal.id)
        XCTAssertEqual(updatedHorizontal.contentRevision, 8)

        let vertical = CanvasElement(
            id: UUID(),
            contentRevision: 11,
            geometry: .line(
                .init(start: .init(x: 20, y: 0), end: .init(x: 20, y: 100))
            )
        )
        let verticalContext = makeContext(elements: [vertical], selectedElementID: vertical.id)
        var verticalReducer = CanvasInteractionReducer()
        _ = beginManipulation(&verticalReducer, at: .init(x: 20, y: 100), in: verticalContext)
        XCTAssertManipulationHandle(verticalReducer.state, expected: .lineEndpoint(.second))
        let verticalEffects = verticalReducer.reduce(
            .manipulationChanged(cumulativeScreenDelta: .init(x: -5, y: 10)),
            in: verticalContext
        )
        let updatedVertical = try XCTUnwrap(verticalEffects.compactMap(\.updatedElement).last)
        guard case .line(let verticalLine) = updatedVertical.geometry else {
            return XCTFail("Expected line geometry")
        }
        XCTAssertEqual(verticalLine.start, .init(x: 20, y: 0))
        XCTAssertEqual(verticalLine.end, .init(x: 15, y: 110))
        XCTAssertEqual(updatedVertical.id, vertical.id)
        XCTAssertEqual(updatedVertical.contentRevision, 12)
    }

    func testLineEndpointUsesHandleToleranceOutsideGeometryHitTolerance() throws {
        let line = CanvasElement(
            id: UUID(),
            geometry: .line(
                .init(start: .init(x: 0, y: 20), end: .init(x: 100, y: 20))
            )
        )
        let context = makeContext(elements: [line], selectedElementID: line.id)
        var reducer = CanvasInteractionReducer()

        _ = beginManipulation(&reducer, at: .init(x: -10, y: 20), in: context)
        XCTAssertManipulationHandle(reducer.state, expected: .lineEndpoint(.first))
        let effects = reducer.reduce(
            .manipulationChanged(cumulativeScreenDelta: .init(x: -5, y: 4)),
            in: context
        )
        let updated = try XCTUnwrap(effects.compactMap(\.updatedElement).last)
        guard case .line(let updatedLine) = updated.geometry else {
            return XCTFail("Expected line geometry")
        }
        XCTAssertEqual(updatedLine.start, .init(x: -5, y: 24))
        XCTAssertEqual(updatedLine.end, .init(x: 100, y: 20))
    }

    func testLineMidpointsAndZeroLengthLineMove() throws {
        let horizontal = CanvasElement(
            id: UUID(),
            geometry: .line(
                .init(start: .init(x: 0, y: 20), end: .init(x: 100, y: 20))
            )
        )
        let horizontalContext = makeContext(elements: [horizontal], selectedElementID: horizontal.id)
        var midpointReducer = CanvasInteractionReducer()
        _ = beginManipulation(&midpointReducer, at: .init(x: 50, y: 20), in: horizontalContext)
        XCTAssertManipulationHandle(midpointReducer.state, expected: .move)
        let midpointEffects = midpointReducer.reduce(
            .manipulationChanged(cumulativeScreenDelta: .init(x: 10, y: 5)),
            in: horizontalContext
        )
        let movedHorizontal = try XCTUnwrap(midpointEffects.compactMap(\.updatedElement).last)
        guard case .line(let movedHorizontalLine) = movedHorizontal.geometry else {
            return XCTFail("Expected line geometry")
        }
        XCTAssertEqual(movedHorizontalLine.start, .init(x: 10, y: 25))
        XCTAssertEqual(movedHorizontalLine.end, .init(x: 110, y: 25))

        let vertical = CanvasElement(
            id: UUID(),
            geometry: .line(
                .init(start: .init(x: 20, y: 0), end: .init(x: 20, y: 100))
            )
        )
        let verticalContext = makeContext(elements: [vertical], selectedElementID: vertical.id)
        var verticalReducer = CanvasInteractionReducer()
        _ = beginManipulation(&verticalReducer, at: .init(x: 20, y: 50), in: verticalContext)
        XCTAssertManipulationHandle(verticalReducer.state, expected: .move)
        XCTAssertFalse(
            verticalReducer.reduce(
                .manipulationChanged(cumulativeScreenDelta: .init(x: 5, y: 10)),
                in: verticalContext
            ).compactMap(\.updatedElement).isEmpty
        )

        let pointLine = CanvasElement(
            id: UUID(),
            geometry: .line(
                .init(start: .init(x: 10, y: 10), end: .init(x: 10, y: 10))
            )
        )
        let pointContext = makeContext(elements: [pointLine], selectedElementID: pointLine.id)
        var pointReducer = CanvasInteractionReducer()
        _ = beginManipulation(&pointReducer, at: .init(x: 10, y: 10), in: pointContext)
        XCTAssertManipulationHandle(pointReducer.state, expected: .move)
        let pointEffects = pointReducer.reduce(
            .manipulationChanged(cumulativeScreenDelta: .init(x: 5, y: 7)),
            in: pointContext
        )
        let movedPoint = try XCTUnwrap(pointEffects.compactMap(\.updatedElement).last)
        guard case .line(let movedPointLine) = movedPoint.geometry else {
            return XCTFail("Expected line geometry")
        }
        XCTAssertEqual(movedPointLine.start, .init(x: 15, y: 17))
        XCTAssertEqual(movedPointLine.end, .init(x: 15, y: 17))
    }

    func testTextCornerHitUsesMeasuredWidthResize() throws {
        let text = CanvasElement(
            id: UUID(),
            contentRevision: 3,
            geometry: .text(
                .init(
                    frame: .init(x: 10, y: 20, width: 24, height: 12),
                    text: "OAQS",
                    font: .init(familyName: "Portable", pointSize: 10),
                    color: .black
                )
            )
        )
        let context = makeContext(elements: [text], selectedElementID: text.id)
        var reducer = CanvasInteractionReducer()

        _ = beginManipulation(
            &reducer,
            at: .init(x: text.bounds.minX, y: text.bounds.minY),
            in: context
        )
        XCTAssertManipulationHandle(reducer.state, expected: .resize(.topLeft))
        let effects = reducer.reduce(
            .manipulationChanged(cumulativeScreenDelta: .init(x: 5, y: -3)),
            in: context
        )
        let moved = try XCTUnwrap(effects.compactMap(\.updatedElement).last)
        guard case .text(let movedText) = moved.geometry else {
            return XCTFail("Expected text geometry")
        }
        XCTAssertEqual(movedText.frame.x, 15)
        XCTAssertEqual(movedText.frame.y, 20)
        XCTAssertEqual(movedText.frame.width, 19)
        XCTAssertEqual(moved.id, text.id)
        XCTAssertEqual(moved.contentRevision, 3)
    }

    func testDegenerateFreehandAndObliqueArchHitsMoveInsteadOfEnteringInertResize() throws {
        let freehand = CanvasElement(
            id: UUID(),
            geometry: .freehand(
                inkStroke([.init(x: 0, y: 0), .init(x: 100, y: 0)])
            )
        )
        let freehandContext = makeContext(elements: [freehand], selectedElementID: freehand.id)
        var freehandReducer = CanvasInteractionReducer()
        _ = beginManipulation(&freehandReducer, at: .init(x: 0, y: 0), in: freehandContext)
        XCTAssertManipulationHandle(freehandReducer.state, expected: .move)
        XCTAssertFalse(
            freehandReducer.reduce(
                .manipulationChanged(cumulativeScreenDelta: .init(x: 10, y: 5)),
                in: freehandContext
            ).compactMap(\.updatedElement).isEmpty
        )

        let arch = CanvasElement(
            id: UUID(),
            geometry: .arch(
                .init(start: .init(x: 0, y: 0), end: .init(x: 100, y: 50), sagitta: 25)
            )
        )
        let archContext = makeContext(elements: [arch], selectedElementID: arch.id)
        var archReducer = CanvasInteractionReducer()
        _ = beginManipulation(&archReducer, at: .init(x: 0, y: 0), in: archContext)
        XCTAssertManipulationHandle(archReducer.state, expected: .move)
        let archEffects = archReducer.reduce(
            .manipulationChanged(cumulativeScreenDelta: .init(x: 10, y: 5)),
            in: archContext
        )
        let movedArch = try XCTUnwrap(archEffects.compactMap(\.updatedElement).last)
        guard case .arch(let movedArchGeometry) = movedArch.geometry else {
            return XCTFail("Expected arch geometry")
        }
        XCTAssertEqual(movedArchGeometry.start, .init(x: 10, y: 5))
        XCTAssertEqual(movedArchGeometry.end, .init(x: 110, y: 55))
        XCTAssertEqual(movedArchGeometry.sagitta, 25)
    }

    func testAxisAlignedArchUsesExecutableBoundsResize() throws {
        let arch = CanvasElement(
            id: UUID(),
            geometry: .arch(
                .init(start: .init(x: 0, y: 0), end: .init(x: 100, y: 0), sagitta: 25)
            )
        )
        let context = makeContext(elements: [arch], selectedElementID: arch.id)
        var reducer = CanvasInteractionReducer()
        let bottomRight = CanvasPoint(x: arch.bounds.maxX, y: arch.bounds.maxY)

        _ = beginManipulation(&reducer, at: bottomRight, in: context)
        XCTAssertManipulationHandle(reducer.state, expected: .resize(.bottomRight))
        let effects = reducer.reduce(
            .manipulationChanged(cumulativeScreenDelta: .init(x: 100, y: 75)),
            in: context
        )
        let resized = try XCTUnwrap(effects.compactMap(\.updatedElement).last)

        XCTAssertEqual(resized.id, arch.id)
        XCTAssertEqual(resized.contentRevision, arch.contentRevision + 1)
        XCTAssertEqual(resized.bounds.x, 0, accuracy: 0.000_001)
        XCTAssertEqual(resized.bounds.y, 0, accuracy: 0.000_001)
        XCTAssertEqual(resized.bounds.width, 200, accuracy: 0.000_001)
        XCTAssertEqual(resized.bounds.height, 100, accuracy: 0.000_001)
    }

    func testMinorArchResizeClampsAtSemicircleBoundaryInsteadOfBecomingInert() throws {
        let arch = CanvasElement(
            id: UUID(),
            geometry: .arch(
                .init(start: .init(x: 0, y: 0), end: .init(x: 100, y: 0), sagitta: 25)
            )
        )
        let context = makeContext(elements: [arch], selectedElementID: arch.id)
        var reducer = CanvasInteractionReducer()
        let bottomRight = CanvasPoint(x: arch.bounds.maxX, y: arch.bounds.maxY)

        _ = beginManipulation(&reducer, at: bottomRight, in: context)
        let effects = reducer.reduce(
            .manipulationChanged(cumulativeScreenDelta: .init(x: -80, y: 0)),
            in: context
        )
        let resized = try XCTUnwrap(effects.compactMap(\.updatedElement).last)

        XCTAssertEqual(resized.bounds.width, 20, accuracy: 0.000_001)
        XCTAssertEqual(resized.bounds.height, 10, accuracy: 0.000_001)
        XCTAssertEqual(resized.contentRevision, arch.contentRevision + 1)
    }

    func testArchResizeClampPreservesChordSideAcrossOrientations() throws {
        let cases: [(CanvasArch, CanvasPoint, CanvasPoint, CanvasRect)] = [
            (
                .init(start: .init(x: 0, y: 0), end: .init(x: 100, y: 0), sagitta: 25),
                .init(x: -40, y: 0),
                .init(x: -80, y: 0),
                .init(x: 0, y: 0, width: 20, height: 10)
            ),
            (
                .init(start: .init(x: 100, y: 0), end: .init(x: 0, y: 0), sagitta: 25),
                .init(x: -40, y: 0),
                .init(x: -80, y: 0),
                .init(x: 0, y: -25, width: 20, height: 10)
            ),
            (
                .init(start: .init(x: 0, y: 0), end: .init(x: 0, y: 100), sagitta: 25),
                .init(x: 0, y: -40),
                .init(x: 0, y: -80),
                .init(x: -25, y: 0, width: 10, height: 20)
            ),
            (
                .init(start: .init(x: 0, y: 100), end: .init(x: 0, y: 0), sagitta: 25),
                .init(x: 0, y: -40),
                .init(x: 0, y: -80),
                .init(x: 0, y: 0, width: 10, height: 20)
            ),
            (
                .init(start: .init(x: 0, y: 0), end: .init(x: 100, y: 0), sagitta: -25),
                .init(x: -40, y: 0),
                .init(x: -80, y: 0),
                .init(x: 0, y: -25, width: 20, height: 10)
            ),
            (
                .init(start: .init(x: 0, y: 0), end: .init(x: 0, y: 100), sagitta: -25),
                .init(x: 0, y: -40),
                .init(x: 0, y: -80),
                .init(x: 0, y: 0, width: 10, height: 20)
            ),
        ]

        for (geometry, firstDelta, finalDelta, expectedBounds) in cases {
            let arch = CanvasElement(id: UUID(), contentRevision: 9, geometry: .arch(geometry))
            let context = makeContext(elements: [arch], selectedElementID: arch.id)
            var reducer = CanvasInteractionReducer()
            let bottomRight = CanvasPoint(x: arch.bounds.maxX, y: arch.bounds.maxY)

            _ = beginManipulation(&reducer, at: bottomRight, in: context)
            XCTAssertManipulationHandle(reducer.state, expected: .resize(.bottomRight))
            _ = reducer.reduce(.manipulationChanged(cumulativeScreenDelta: firstDelta), in: context)
            let effects = reducer.reduce(
                .manipulationChanged(cumulativeScreenDelta: finalDelta),
                in: context
            )
            let resized = try XCTUnwrap(effects.compactMap(\.updatedElement).last)

            XCTAssertEqual(resized.id, arch.id)
            XCTAssertEqual(resized.contentRevision, 10)
            XCTAssertTrue(resized.bounds.isFinite)
            XCTAssertEqual(resized.bounds.x, expectedBounds.x, accuracy: 0.000_001)
            XCTAssertEqual(resized.bounds.y, expectedBounds.y, accuracy: 0.000_001)
            XCTAssertEqual(resized.bounds.width, expectedBounds.width, accuracy: 0.000_001)
            XCTAssertEqual(resized.bounds.height, expectedBounds.height, accuracy: 0.000_001)
            try CanvasDocument(elements: [resized]).validate()
        }
    }

    func testArchResizeClampKeepsOppositeEdgeFixedForEveryAxisHandle() throws {
        let horizontalChordAtMin = CanvasArch(
            start: .init(x: 0, y: 0),
            end: .init(x: 100, y: 0),
            sagitta: 25
        )
        let horizontalChordAtMax = CanvasArch(
            start: .init(x: 100, y: 0),
            end: .init(x: 0, y: 0),
            sagitta: 25
        )
        let verticalChordAtMax = CanvasArch(
            start: .init(x: 0, y: 0),
            end: .init(x: 0, y: 100),
            sagitta: 25
        )
        let verticalChordAtMin = CanvasArch(
            start: .init(x: 0, y: 100),
            end: .init(x: 0, y: 0),
            sagitta: 25
        )
        let cases: [(CanvasArch, ResizeHandle, CanvasPoint)] = [
            (horizontalChordAtMin, .top, .init(x: 0, y: -75)),
            (horizontalChordAtMax, .top, .init(x: 0, y: -75)),
            (horizontalChordAtMin, .bottom, .init(x: 0, y: 75)),
            (horizontalChordAtMax, .bottom, .init(x: 0, y: 75)),
            (verticalChordAtMax, .left, .init(x: -75, y: 0)),
            (verticalChordAtMin, .left, .init(x: -75, y: 0)),
            (verticalChordAtMax, .right, .init(x: 75, y: 0)),
            (verticalChordAtMin, .right, .init(x: 75, y: 0)),
        ]

        for (geometry, handle, delta) in cases {
            let arch = CanvasElement(id: UUID(), geometry: .arch(geometry))
            let originalBounds = arch.bounds
            let context = makeContext(elements: [arch], selectedElementID: arch.id)
            var reducer = CanvasInteractionReducer()
            let point: CanvasPoint
            switch handle {
            case .top:
                point = .init(x: (originalBounds.minX + originalBounds.maxX) / 2, y: originalBounds.minY)
            case .bottom:
                point = .init(x: (originalBounds.minX + originalBounds.maxX) / 2, y: originalBounds.maxY)
            case .left:
                point = .init(x: originalBounds.minX, y: (originalBounds.minY + originalBounds.maxY) / 2)
            case .right:
                point = .init(x: originalBounds.maxX, y: (originalBounds.minY + originalBounds.maxY) / 2)
            default:
                return XCTFail("Expected an axis handle")
            }

            _ = beginManipulation(&reducer, at: point, in: context)
            XCTAssertManipulationHandle(reducer.state, expected: .resize(handle))
            let effects = reducer.reduce(
                .manipulationChanged(cumulativeScreenDelta: delta),
                in: context
            )
            let resized = try XCTUnwrap(effects.compactMap(\.updatedElement).last)

            switch handle {
            case .top:
                XCTAssertEqual(resized.bounds.maxY, originalBounds.maxY, accuracy: 0.000_001)
            case .bottom:
                XCTAssertEqual(resized.bounds.minY, originalBounds.minY, accuracy: 0.000_001)
            case .left:
                XCTAssertEqual(resized.bounds.maxX, originalBounds.maxX, accuracy: 0.000_001)
            case .right:
                XCTAssertEqual(resized.bounds.minX, originalBounds.minX, accuracy: 0.000_001)
            default:
                break
            }
            XCTAssertEqual(resized.id, arch.id)
            XCTAssertEqual(resized.contentRevision, arch.contentRevision + 1)
            XCTAssertTrue(resized.bounds.isFinite)
            try CanvasDocument(elements: [resized]).validate()
        }
    }

    func testArchResizeWithoutNormalPositiveMinimumUsesExecutableMove() throws {
        let arch = CanvasElement(
            id: UUID(),
            geometry: .arch(
                .init(start: .init(x: 0, y: 0), end: .init(x: 100, y: 0), sagitta: 25)
            )
        )
        for minimumSize in [0, -10, Double.leastNonzeroMagnitude] {
            let context = makeContext(
                elements: [arch],
                selectedElementID: arch.id,
                minimumElementSize: minimumSize
            )
            var reducer = CanvasInteractionReducer()

            _ = beginManipulation(&reducer, at: .init(x: 0, y: 0), in: context)
            XCTAssertManipulationHandle(reducer.state, expected: .move)
            XCTAssertFalse(
                reducer.reduce(
                    .manipulationChanged(cumulativeScreenDelta: .init(x: 10, y: 5)),
                    in: context
                ).compactMap(\.updatedElement).isEmpty
            )
        }
    }

    func testAxisAlignedSemicirclesUseExecutableMoveAtBoundsHandles() throws {
        let arches = [
            CanvasElement(
                id: UUID(),
                geometry: .arch(
                    .init(start: .init(x: 0, y: 0), end: .init(x: 100, y: 0), sagitta: 50)
                )
            ),
            CanvasElement(
                id: UUID(),
                geometry: .arch(
                    .init(start: .init(x: 0, y: 0), end: .init(x: 0, y: 100), sagitta: 50)
                )
            ),
        ]

        for arch in arches {
            guard case .arch(let geometry) = arch.geometry else {
                return XCTFail("Expected arch geometry")
            }
            let context = makeContext(elements: [arch], selectedElementID: arch.id)
            var reducer = CanvasInteractionReducer()

            _ = beginManipulation(&reducer, at: geometry.end, in: context)
            XCTAssertManipulationHandle(reducer.state, expected: .move)
            let effects = reducer.reduce(
                .manipulationChanged(cumulativeScreenDelta: .init(x: 50, y: 25)),
                in: context
            )
            XCTAssertFalse(effects.compactMap(\.updatedElement).isEmpty)
        }
    }

    func testAxisAlignedMajorArchesUseExecutableMoveAtBoundsHandles() throws {
        let arches = [
            CanvasElement(
                id: UUID(),
                geometry: .arch(
                    .init(start: .init(x: 0, y: 0), end: .init(x: 100, y: 0), sagitta: 100)
                )
            ),
            CanvasElement(
                id: UUID(),
                geometry: .arch(
                    .init(start: .init(x: 0, y: 0), end: .init(x: 0, y: 100), sagitta: 100)
                )
            ),
        ]

        for arch in arches {
            guard case .arch(let geometry) = arch.geometry else {
                return XCTFail("Expected arch geometry")
            }
            let parameters = try ArchGeometry.parameters(for: geometry)
            let point: CanvasPoint
            if geometry.start.y == geometry.end.y {
                point = .init(x: arch.bounds.minX, y: parameters.center.y)
            } else {
                point = .init(x: parameters.center.x, y: arch.bounds.minY)
            }
            let context = makeContext(elements: [arch], selectedElementID: arch.id)
            var reducer = CanvasInteractionReducer()

            _ = beginManipulation(&reducer, at: point, in: context)
            XCTAssertManipulationHandle(reducer.state, expected: .move)
            XCTAssertFalse(
                reducer.reduce(
                    .manipulationChanged(cumulativeScreenDelta: .init(x: 10, y: 5)),
                    in: context
                ).compactMap(\.updatedElement).isEmpty
            )
        }
    }

    func testSubnormalFreehandExtentUsesExecutableMove() throws {
        let freehand = CanvasElement(
            id: UUID(),
            geometry: .freehand(
                inkStroke([
                    .init(x: 0, y: 0),
                    .init(x: .leastNonzeroMagnitude, y: 100),
                ])
            )
        )
        let context = makeContext(
            elements: [freehand],
            selectedElementID: freehand.id,
            minimumElementSize: 0
        )
        var reducer = CanvasInteractionReducer()

        _ = beginManipulation(&reducer, at: .init(x: 0, y: 0), in: context)
        XCTAssertManipulationHandle(reducer.state, expected: .move)
        XCTAssertFalse(
            reducer.reduce(
                .manipulationChanged(cumulativeScreenDelta: .init(x: 10, y: 5)),
                in: context
            ).compactMap(\.updatedElement).isEmpty
        )
    }

    func testManipulationRejectsElementsAtMaximumContentRevision() throws {
        let element = CanvasElement(
            id: UUID(),
            contentRevision: .max,
            geometry: .rectangle(.init(rect: .init(x: 0, y: 0, width: 100, height: 80)))
        )
        let context = makeContext(elements: [element], selectedElementID: element.id)
        var resizeReducer = CanvasInteractionReducer()
        var moveReducer = CanvasInteractionReducer()

        XCTAssertTrue(
            resizeReducer.reduce(
                .manipulationBegan(point: .init(x: 100, y: 80)),
                in: context
            ).isEmpty
        )
        XCTAssertTrue(
            moveReducer.reduce(
                .manipulationBegan(point: .init(x: 50, y: 40)),
                in: context
            ).isEmpty
        )
        XCTAssertIdle(resizeReducer.state)
        XCTAssertIdle(moveReducer.state)
    }

    func testManipulationRejectsHighestDocumentValidRevisionForEveryUpdatePath() throws {
        let rectangle = CanvasElement(
            id: UUID(),
            contentRevision: .max - 1,
            geometry: .rectangle(.init(rect: .init(x: 0, y: 0, width: 100, height: 80)))
        )
        let line = CanvasElement(
            id: UUID(),
            contentRevision: .max - 1,
            geometry: .line(.init(start: .init(x: 0, y: 0), end: .init(x: 100, y: 0)))
        )
        let cases: [(CanvasElement, CanvasPoint)] = [
            (rectangle, .init(x: 50, y: 40)),
            (rectangle, .init(x: 100, y: 80)),
            (line, .init(x: 0, y: 0)),
        ]

        for (element, point) in cases {
            let context = makeContext(elements: [element], selectedElementID: element.id)
            var reducer = CanvasInteractionReducer()
            XCTAssertTrue(reducer.reduce(.manipulationBegan(point: point), in: context).isEmpty)
            XCTAssertIdle(reducer.state)
        }
    }

    func testPanProjectionIsRelativeToCurrentTranslationAndCumulative() throws {
        let viewport = try CanvasViewport(
            zoom: 2,
            translation: .init(x: 30, y: -10),
            viewportSize: .init(width: 500, height: 400)
        )
        let context = makeContext(viewport: viewport)
        var reducer = CanvasInteractionReducer()
        _ = reducer.reduce(.panBegan(.init(x: 25, y: 50)), in: context)

        _ = reducer.reduce(
            .panChanged(cumulativeScreenDelta: .init(x: 10, y: 5)),
            in: context
        )
        let effects = reducer.reduce(
            .panChanged(cumulativeScreenDelta: .init(x: 100, y: 25)),
            in: context
        )

        XCTAssertEqual(try XCTUnwrap(effects.compactMap(\.viewport).last).translation, .init(x: 130, y: 15))
        _ = reducer.reduce(.panEnded(screenVelocity: .init(x: 500, y: -200)), in: context)
        XCTAssertIdle(reducer.state)
    }

    func testPinchPreservesCanvasAnchorAndUsesScaleFromStart() throws {
        let viewport = try CanvasViewport(
            zoom: 2,
            translation: .init(x: 30, y: -10),
            viewportSize: .init(width: 500, height: 400)
        )
        let anchor = CanvasPoint(x: 80, y: 40)
        let screenAnchor = viewport.screenPoint(fromCanvas: anchor)
        let context = makeContext(viewport: viewport)
        var reducer = CanvasInteractionReducer()
        _ = reducer.reduce(
            .pinchBegan(canvasAnchor: anchor, screenCentroid: screenAnchor),
            in: context
        )

        _ = reducer.reduce(
            .pinchChanged(scaleFromStart: 1.5, currentScreenCentroid: screenAnchor),
            in: context
        )
        let effects = reducer.reduce(
            .pinchChanged(scaleFromStart: 2, currentScreenCentroid: screenAnchor),
            in: context
        )
        let final = try XCTUnwrap(effects.compactMap(\.viewport).last)

        XCTAssertEqual(final.zoom, 4)
        XCTAssertEqual(final.screenPoint(fromCanvas: anchor).x, screenAnchor.x, accuracy: 0.000_001)
        XCTAssertEqual(final.screenPoint(fromCanvas: anchor).y, screenAnchor.y, accuracy: 0.000_001)
    }

    func testPinchTracksMovingCentroid() throws {
        let context = makeContext(viewport: try .identity(size: .init(width: 200, height: 200)))
        let anchor = CanvasPoint(x: 50, y: 50)
        var reducer = CanvasInteractionReducer()
        _ = reducer.reduce(
            .pinchBegan(canvasAnchor: anchor, screenCentroid: .init(x: 50, y: 50)),
            in: context
        )

        let effects = reducer.reduce(
            .pinchChanged(scaleFromStart: 2, currentScreenCentroid: .init(x: 80, y: 70)),
            in: context
        )
        let viewport = try XCTUnwrap(effects.compactMap(\.viewport).last)

        XCTAssertEqual(viewport.screenPoint(fromCanvas: anchor), .init(x: 80, y: 70))
    }

    func testPinchCancellationRestoresStartViewport() throws {
        let start = try CanvasViewport(
            zoom: 2,
            translation: .init(x: 30, y: 40),
            viewportSize: .init(width: 200, height: 200)
        )
        let context = makeContext(viewport: start)
        var reducer = CanvasInteractionReducer()
        _ = reducer.reduce(
            .pinchBegan(canvasAnchor: .init(x: 50, y: 50), screenCentroid: .init(x: 130, y: 140)),
            in: context
        )
        XCTAssertFalse(reducer.reduce(
            .pinchChanged(scaleFromStart: 2, currentScreenCentroid: .init(x: 160, y: 170)),
            in: context
        ).isEmpty)

        let effects = reducer.reduce(.pinchCancelled, in: context)

        XCTAssertEqual(effects.compactMap(\.viewport), [start])
        XCTAssertIdle(reducer.state)
    }

    func testPinchRejectsZeroNegativeAndNonfiniteScalesWithoutLeavingState() throws {
        let context = makeContext()
        var reducer = CanvasInteractionReducer()
        _ = reducer.reduce(
            .pinchBegan(canvasAnchor: .init(x: 20, y: 20), screenCentroid: .init(x: 20, y: 20)),
            in: context
        )

        for scale in [0, -1, .nan, .infinity] {
            XCTAssertTrue(reducer.reduce(
                .pinchChanged(scaleFromStart: scale, currentScreenCentroid: .init(x: 20, y: 20)),
                in: context
            ).isEmpty)
            XCTAssertPinching(reducer.state)
        }

        _ = reducer.reduce(.pinchEnded, in: context)
        XCTAssertIdle(reducer.state)
    }

    func testPinchRejectsFiniteScaleWhoseZoomProductOverflows() throws {
        let viewport = try CanvasViewport(
            zoom: CanvasViewport.zoomRange.upperBound,
            translation: .init(x: 0, y: 0),
            viewportSize: .init(width: 500, height: 400)
        )
        let context = makeContext(viewport: viewport)
        var reducer = CanvasInteractionReducer()
        _ = reducer.reduce(
            .pinchBegan(canvasAnchor: .init(x: 20, y: 20), screenCentroid: .init(x: 20, y: 20)),
            in: context
        )

        XCTAssertTrue(
            reducer.reduce(
                .pinchChanged(
                    scaleFromStart: .greatestFiniteMagnitude,
                    currentScreenCentroid: .init(x: 20, y: 20)
                ),
                in: context
            ).isEmpty
        )
        XCTAssertPinching(reducer.state)
    }

    func testPencilCancellationClearsPreviewAndDoesNotCommitForEveryTool() throws {
        let context = makeContext()

        for tool in CanvasTool.allCases {
            var reducer = CanvasInteractionReducer(activeTool: tool)
            let generation = reducer.recognitionGeneration
            _ = reducer.reduce(.pencilDown(.init(x: 1, y: 2)), in: context)
            _ = reducer.reduce(.pencilMoved(.init(x: 3, y: 4)), in: context)

            let effects = reducer.reduce(.pencilCancelled, in: context)

            XCTAssertIdle(reducer.state, tool.rawValue)
            XCTAssertFalse(effects.containsCancelPreview, tool.rawValue)
            XCTAssertTrue(effects.containsEmptyGuides, tool.rawValue)
            XCTAssertFalse(effects.containsCommit, tool.rawValue)
            XCTAssertNotEqual(reducer.recognitionGeneration, generation, tool.rawValue)
        }
    }

    func testLineDownMoveUpCommitsOneLineWithSnappedEndpointsAndFixedID() throws {
        let id = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let context = makeContext(
            proposedElementID: id,
            snapConfiguration: .init(screenThreshold: 8, gridSpacing: 10, snapToGrid: true)
        )
        var reducer = CanvasInteractionReducer(activeTool: .line)

        let down = reducer.reduce(.pencilDown(.init(x: 12, y: 18)), in: context)
        let moved = reducer.reduce(.pencilMoved(.init(x: 97, y: 43)), in: context)
        var changedContext = context
        changedContext.proposedElementID = UUID()
        let up = reducer.reduce(.pencilUp(.init(x: 103, y: 39)), in: changedContext)

        XCTAssertEqual(down.transientPreview?.id, id)
        XCTAssertEqual(moved.transientPreview?.id, id)
        let inserted = try XCTUnwrap(up.insertedElement)
        XCTAssertEqual(inserted.id, id)
        guard case .line(let line) = inserted.geometry else {
            return XCTFail("Expected line geometry")
        }
        XCTAssertEqual(line.start, .init(x: 10, y: 20))
        XCTAssertEqual(line.end, .init(x: 100, y: 40))
        XCTAssertEqual(up.filter(\.isPerform).count, 1)
        XCTAssertNil(up.transientPreview)
        XCTAssertIdle(reducer.state)
    }

    func testRectangleDownMoveUpCommitsOneNormalizedRectangle() throws {
        let id = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let context = makeContext(proposedElementID: id)
        var reducer = CanvasInteractionReducer(activeTool: .rectangle)

        _ = reducer.reduce(.pencilDown(.init(x: 90, y: 80)), in: context)
        _ = reducer.reduce(.pencilMoved(.init(x: 40, y: 45)), in: context)
        let effects = reducer.reduce(.pencilUp(.init(x: 20, y: 30)), in: context)

        let inserted = try XCTUnwrap(effects.insertedElement)
        XCTAssertEqual(inserted.id, id)
        guard case .rectangle(let rectangle) = inserted.geometry else {
            return XCTFail("Expected rectangle geometry")
        }
        XCTAssertEqual(rectangle.rect, .init(x: 20, y: 30, width: 70, height: 50))
        XCTAssertIdle(reducer.state)
    }

    func testArchUsesTwoPencilStrokesAndSignedSagittaWithEndpointExactPath() throws {
        let id = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        let context = makeContext(proposedElementID: id)
        var reducer = CanvasInteractionReducer(activeTool: .arch)

        _ = reducer.reduce(.pencilDown(.init(x: 0, y: 0)), in: context)
        _ = reducer.reduce(.pencilMoved(.init(x: 75, y: 0)), in: context)
        let baseUp = reducer.reduce(.pencilUp(.init(x: 100, y: 0)), in: context)
        XCTAssertFalse(baseUp.containsCommit)
        XCTAssertArchSagittaDraft(reducer.state, start: .init(x: 0, y: 0), end: .init(x: 100, y: 0))

        _ = reducer.reduce(.pencilDown(.init(x: 50, y: -5)), in: context)
        _ = reducer.reduce(.pencilMoved(.init(x: 50, y: -20)), in: context)
        let sagittaUp = reducer.reduce(.pencilUp(.init(x: 50, y: -25)), in: context)

        let inserted = try XCTUnwrap(sagittaUp.insertedElement)
        guard case .arch(let arch) = inserted.geometry else {
            return XCTFail("Expected arch geometry")
        }
        XCTAssertEqual(arch.start, .init(x: 0, y: 0))
        XCTAssertEqual(arch.end, .init(x: 100, y: 0))
        XCTAssertEqual(arch.sagitta, -25, accuracy: 0.000_001)
        let path = inserted.geometry.renderPath
        XCTAssertEqual(path.commands.first?.terminalPoint, arch.start)
        XCTAssertEqual(path.commands.last?.terminalPoint, arch.end)
        XCTAssertIdle(reducer.state)
    }

    func testFreehandCommitsRawImmediatelyThenRecognitionIsSecondReversibleCommand() throws {
        let id = UUID(uuidString: "10000000-0000-0000-0000-000000000004")!
        let session = CanvasSession()
        var reducer = CanvasInteractionReducer(activeTool: .freehand)
        var context = makeContext(
            elements: session.document.elements,
            proposedElementID: id,
            documentReplacementGeneration: session.documentReplacementGeneration
        )

        _ = try beginFreehand(&reducer, at: .init(x: 0, y: 0), in: context, session: session)
        try apply(reducer.reduce(.pencilMoved(.init(x: 10, y: 7)), in: context), to: session)
        XCTAssertTrue(session.document.elements.isEmpty)
        XCTAssertTrue(session.presentationDocument.elements.isEmpty)
        guard case .freehand(let draft) = session.preview?.payload else {
            return XCTFail("Expected a point-backed freehand draft")
        }
        XCTAssertEqual(draft.samples.count, 2)
        let up = reducer.reduce(.pencilUp(.init(x: 20, y: 0)), in: context)
        XCTAssertEqual(up.filter(\.isCommitPreview).count, 1)
        let request = try XCTUnwrap(up.recognitionRequest)
        try apply(up, to: session)
        XCTAssertEqual(session.document.elements.map(\.id), [id])
        guard case .freehand = session.document.elements[0].geometry else {
            return XCTFail("Raw stroke must commit before recognition")
        }

        context = makeContext(
            elements: session.document.elements,
            proposedElementID: UUID(),
            documentReplacementGeneration: session.documentReplacementGeneration
        )
        let recognized = RecognitionResult(
            geometry: .line(.init(start: .init(x: 0, y: 0), end: .init(x: 20, y: 0))),
            confidence: 0.95
        )
        let completion = reducer.reduce(
            .recognitionCompleted(request: request, result: recognized),
            in: context
        )
        XCTAssertEqual(completion.filter(\.isPerform).count, 1)
        try apply(completion, to: session)
        XCTAssertEqual(session.document.elements[0].id, id)
        XCTAssertEqual(session.document.elements[0].contentRevision, 1)
        guard case .line = session.document.elements[0].geometry else {
            return XCTFail("Expected recognized replacement")
        }

        try session.undo()
        XCTAssertEqual(session.document.elements[0].id, id)
        guard case .freehand = session.document.elements[0].geometry else {
            return XCTFail("First undo must restore raw stroke")
        }
        try session.undo()
        XCTAssertTrue(session.document.elements.isEmpty)
    }

    func testFreehandCommitDoesNotCreateRecognitionWorkWhenRecognitionIsDisabled() throws {
        let id = UUID()
        var reducer = CanvasInteractionReducer(activeTool: .freehand)
        let context = makeContext(proposedElementID: id, recognitionEnabled: false)
        let began = reducer.reduce(
            .pencilSamples(
                phase: .began,
                confirmed: [.init(point: .init(x: 0, y: 0), pressure: 0.2)],
                predicted: []
            ),
            in: context
        )
        XCTAssertTrue(began.contains { effect in
            if case .requestPreview = effect { return true }
            return false
        })
        _ = reducer.reduce(.previewAcquired(CanvasPreviewToken()), in: context)
        let middle = (1..<29_999).map { index in
            CanvasInkSample(
                point: .init(x: Double(index), y: Double(index % 23)),
                pressure: Double(index % 31) / 30
            )
        }
        _ = reducer.reduce(
            .pencilSamples(phase: .moved, confirmed: middle, predicted: []),
            in: context
        )

        let ended = reducer.reduce(
            .pencilSamples(
                phase: .ended,
                confirmed: [.init(point: .init(x: 29_999, y: 4), pressure: 1)],
                predicted: []
            ),
            in: context
        )

        XCTAssertTrue(ended.containsCommit)
        XCTAssertNil(ended.recognitionRequest)
    }

    func testInkRecognitionRequestRetainsOrderedPressureSamples() throws {
        let id = UUID()
        var reducer = CanvasInteractionReducer(activeTool: .freehand)
        let context = makeContext(proposedElementID: id, recognitionEnabled: true)
        let first = CanvasInkSample(point: .init(x: 0, y: 0), pressure: 0.2)
        let middle = CanvasInkSample(point: .init(x: 10, y: 7), pressure: 0.6)
        let last = CanvasInkSample(point: .init(x: 20, y: 0), pressure: 1)
        _ = reducer.reduce(
            .pencilSamples(phase: .began, confirmed: [first], predicted: []),
            in: context
        )
        _ = reducer.reduce(.previewAcquired(CanvasPreviewToken()), in: context)
        _ = reducer.reduce(
            .pencilSamples(phase: .moved, confirmed: [middle], predicted: []),
            in: context
        )

        let ended = reducer.reduce(
            .pencilSamples(phase: .ended, confirmed: [last], predicted: []),
            in: context
        )
        let request = try XCTUnwrap(ended.recognitionRequest)

        XCTAssertEqual(request.inkSamples, [first, middle, last])
        XCTAssertEqual(request.points, [first.point, middle.point, last.point])
    }

    func testToolSwitchAfterPencilUpPreservesCommitAndBeforePencilUpCancelsDraft() throws {
        let context = makeContext()
        var completed = CanvasInteractionReducer(activeTool: .line)
        _ = completed.reduce(.pencilDown(.init(x: 0, y: 0)), in: context)
        let up = completed.reduce(.pencilUp(.init(x: 100, y: 0)), in: context)
        XCTAssertNotNil(up.insertedElement)
        let after = completed.reduce(.toolChanged(.rectangle), in: context)
        XCTAssertFalse(after.containsCommit)
        XCTAssertEqual(completed.activeTool, .rectangle)

        var incomplete = CanvasInteractionReducer(activeTool: .line)
        _ = incomplete.reduce(.pencilDown(.init(x: 0, y: 0)), in: context)
        let before = incomplete.reduce(.toolChanged(.rectangle), in: context)
        XCTAssertFalse(before.containsCancelPreview)
        XCTAssertFalse(before.containsCommit)
        XCTAssertEqual(incomplete.activeTool, .rectangle)
        XCTAssertIdle(incomplete.state)
    }

    func testSameToolNotificationDoesNotCancelIncompleteDraft() throws {
        let context = makeContext()
        var reducer = CanvasInteractionReducer(
            activeTool: .line,
            state: .drawing(.line(start: .init(x: 0, y: 0), current: .init(x: 0, y: 0)))
        )
        let generation = reducer.recognitionGeneration

        XCTAssertTrue(reducer.reduce(.toolChanged(.line), in: context).isEmpty)
        XCTAssertDrawingPointCount(reducer.state, 1)
        XCTAssertEqual(reducer.recognitionGeneration, generation)
    }

    func testEscapeProducesCancelEffectClearsGuidesAndInvalidatesRecognition() throws {
        let context = makeContext()
        var reducer = CanvasInteractionReducer(
            activeTool: .arch,
            state: .drawing(.archBase(start: .init(x: 1, y: 1), current: .init(x: 1, y: 1)))
        )
        let generation = reducer.recognitionGeneration

        let effects = reducer.reduce(.cancel, in: context)

        XCTAssertFalse(effects.containsCancelPreview)
        XCTAssertTrue(effects.containsEmptyGuides)
        XCTAssertFalse(effects.containsCommit)
        XCTAssertNotEqual(reducer.recognitionGeneration, generation)
        XCTAssertIdle(reducer.state)
    }

    func testRecognitionGenerationCarriesPastMaximumWord() throws {
        let context = makeContext()
        let boundary = CanvasGeneration(words: [.max])
        var reducer = CanvasInteractionReducer(recognitionGeneration: boundary)

        _ = reducer.reduce(.cancel, in: context)

        XCTAssertNotEqual(reducer.recognitionGeneration, boundary)
        XCTAssertEqual(reducer.recognitionGeneration, CanvasGeneration(words: [0, 1]))
    }

    func testEveryRecognitionInvalidationProducesANewGeneration() throws {
        let context = makeContext()
        let boundary = CanvasGeneration(words: [.max])
        var cancelled = CanvasInteractionReducer(recognitionGeneration: boundary)
        var toolChanged = CanvasInteractionReducer(recognitionGeneration: boundary)

        _ = cancelled.reduce(.cancel, in: context)
        let first = cancelled.recognitionGeneration
        _ = cancelled.reduce(.cancel, in: context)
        let second = cancelled.recognitionGeneration
        _ = toolChanged.reduce(.toolChanged(.line), in: context)

        XCTAssertNotEqual(first, boundary)
        XCTAssertNotEqual(second, first)
        XCTAssertNotEqual(toolChanged.recognitionGeneration, boundary)
    }

    func testManipulationCancellationRestoresPreviewAndInvalidatesRecognition() throws {
        let element = rectangle(x: 0, y: 0, width: 10, height: 10)
        let context = makeContext(elements: [element], selectedElementID: element.id)
        var reducer = CanvasInteractionReducer()
        _ = beginManipulation(&reducer, at: .init(x: 5, y: 5), in: context)
        let generation = reducer.recognitionGeneration

        let effects = reducer.reduce(.manipulationCancelled, in: context)

        XCTAssertTrue(effects.containsCancelPreview)
        XCTAssertTrue(effects.containsEmptyGuides)
        XCTAssertNotEqual(reducer.recognitionGeneration, generation)
        XCTAssertIdle(reducer.state)
    }

    func testTapSelectsTopmostHitAndMissDeselects() throws {
        let bottom = rectangle(x: 0, y: 0, width: 100, height: 100)
        let top = rectangle(x: 20, y: 20, width: 100, height: 100)
        let context = makeContext(elements: [bottom, top])
        var reducer = CanvasInteractionReducer()

        XCTAssertSelect(reducer.reduce(.tap(.init(x: 30, y: 30)), in: context), id: top.id)
        XCTAssertSelect(reducer.reduce(.tap(.init(x: 500, y: 500)), in: context), id: nil)
    }

    func testMoveAndResizePreviewPreserveUUID() throws {
        let element = CanvasElement.rectangle(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000005")!,
            rect: .init(x: 0, y: 0, width: 100, height: 80)
        )
        let context = makeContext(elements: [element], selectedElementID: element.id)

        var move = CanvasInteractionReducer()
        _ = beginManipulation(&move, at: .init(x: 50, y: 40), in: context)
        let moved = try XCTUnwrap(
            move.reduce(
                .manipulationChanged(cumulativeScreenDelta: .init(x: 20, y: 10)),
                in: context
            ).updatedElement
        )
        XCTAssertEqual(moved.id, element.id)

        var resize = CanvasInteractionReducer()
        _ = beginManipulation(&resize, at: .init(x: 100, y: 80), in: context)
        let resized = try XCTUnwrap(
            resize.reduce(
                .manipulationChanged(cumulativeScreenDelta: .init(x: 20, y: 10)),
                in: context
            ).updatedElement
        )
        XCTAssertEqual(resized.id, element.id)
    }

    func testRecognitionCompletionRejectsEditUndoRemovalToolSwitchReplacementAndTeardownRaces() throws {
        enum Race: CaseIterable { case edit, undoRemove, toolSwitch, replacement, teardown }

        for race in Race.allCases {
            let id = UUID()
            let session = CanvasSession()
            var reducer = CanvasInteractionReducer(activeTool: .freehand)
            var context = makeContext(
                elements: [],
                proposedElementID: id,
                documentReplacementGeneration: session.documentReplacementGeneration
            )
            _ = try beginFreehand(&reducer, at: .init(x: 0, y: 0), in: context, session: session)
            let rawEffects = reducer.reduce(.pencilUp(.init(x: 20, y: 10)), in: context)
            let request = try XCTUnwrap(rawEffects.recognitionRequest)
            try apply(rawEffects, to: session)

            switch race {
            case .edit:
                try session.perform(.setGeometry(
                    id: id,
                    .line(.init(start: .init(x: 0, y: 0), end: .init(x: 30, y: 0)))
                ))
            case .undoRemove:
                try session.undo()
            case .toolSwitch:
                _ = reducer.reduce(.toolChanged(.line), in: context)
            case .replacement:
                let sameIdentity = CanvasElement(
                    id: id,
                    contentRevision: request.contentRevision,
                    geometry: .freehand(.init(
                        samples: [
                            .init(point: .init(x: 0, y: 0), pressure: 1),
                            .init(point: .init(x: 20, y: 10), pressure: 1),
                        ],
                        pressureEnabled: false
                    ))
                )
                try session.replaceDocument(CanvasDocument(elements: [sameIdentity]))
            case .teardown:
                _ = reducer.reduce(.cancel, in: context)
            }

            context = makeContext(
                elements: session.document.elements,
                proposedElementID: UUID(),
                documentReplacementGeneration: session.documentReplacementGeneration
            )
            let completion = reducer.reduce(
                .recognitionCompleted(
                    request: request,
                    result: .init(
                        geometry: .line(.init(start: .init(x: 0, y: 0), end: .init(x: 20, y: 10))),
                        confidence: 1
                    )
                ),
                in: context
            )
            XCTAssertFalse(completion.containsCommit, "Race \(race) must be stale")
        }
    }

    func testRecognitionRejectsSameIDAndRevisionWhenOriginatingGeometryChanged() throws {
        let id = UUID()
        var reducer = CanvasInteractionReducer(activeTool: .freehand)
        var context = makeContext(proposedElementID: id)
        _ = try beginFreehand(&reducer, at: .init(x: 0, y: 0), in: context)
        let effects = reducer.reduce(.pencilUp(.init(x: 20, y: 10)), in: context)
        let request = try XCTUnwrap(effects.recognitionRequest)
        let conflicting = CanvasElement(
            id: id,
            contentRevision: request.contentRevision,
            geometry: .freehand(inkStroke([.init(x: 0, y: 0), .init(x: 50, y: 50)]))
        )
        context = makeContext(elements: [conflicting])

        let completion = reducer.reduce(
            .recognitionCompleted(
                request: request,
                result: .init(
                    geometry: .line(.init(start: .init(x: 0, y: 0), end: .init(x: 20, y: 10))),
                    confidence: 1
                )
            ),
            in: context
        )

        XCTAssertTrue(completion.isEmpty)
    }

    func testDrawingPreviewIsTransientAndNeverInsertedBeforePencilUp() throws {
        let id = UUID()
        let context = makeContext(proposedElementID: id)
        var reducer = CanvasInteractionReducer(activeTool: .rectangle)

        let down = reducer.reduce(.pencilDown(.init(x: 10, y: 10)), in: context)
        let moved = reducer.reduce(.pencilMoved(.init(x: 30, y: 40)), in: context)

        XCTAssertTrue(context.elements.isEmpty)
        XCTAssertFalse(down.containsCommit)
        XCTAssertFalse(moved.containsCommit)
        XCTAssertEqual(moved.transientPreview?.id, id)
        guard case .rectangle(let rectangle) = try XCTUnwrap(moved.transientPreview).geometry else {
            return XCTFail("Expected rectangle preview")
        }
        XCTAssertEqual(rectangle.rect, .init(x: 10, y: 10, width: 20, height: 30))
    }

    func testCommitCapacityAndLateUUIDCollisionKeepDraftInsteadOfEmittingRejectedInsert() throws {
        let id = UUID()
        var reducer = CanvasInteractionReducer(activeTool: .line)
        let start = makeContext(proposedElementID: id)
        _ = reducer.reduce(.pencilDown(.init(x: 0, y: 0)), in: start)

        let exhausted = makeContext(
            proposedElementID: UUID(),
            documentRevision: .max - 2
        )
        let exhaustedEffects = reducer.reduce(.pencilUp(.init(x: 100, y: 0)), in: exhausted)
        XCTAssertFalse(exhaustedEffects.containsCommit)
        XCTAssertLinePreview(exhaustedEffects, start: .init(x: 0, y: 0), end: .init(x: 100, y: 0))
        XCTAssertDrawingLine(reducer.state, start: .init(x: 0, y: 0), current: .init(x: 100, y: 0))

        let collision = CanvasElement.rectangle(
            id: id,
            rect: .init(x: 200, y: 200, width: 10, height: 10)
        )
        let collided = makeContext(elements: [collision], proposedElementID: UUID())
        let collisionEffects = reducer.reduce(.pencilUp(.init(x: 100, y: 0)), in: collided)
        XCTAssertFalse(collisionEffects.containsCommit)
        XCTAssertLinePreview(collisionEffects, start: .init(x: 0, y: 0), end: .init(x: 100, y: 0))
        XCTAssertDrawingLine(reducer.state, start: .init(x: 0, y: 0), current: .init(x: 100, y: 0))
    }

    func testManipulationCannotBeginWhenDocumentCannotReserveCommitAndUndo() throws {
        let element = rectangle(x: 0, y: 0, width: 100, height: 80)
        let context = makeContext(
            elements: [element],
            selectedElementID: element.id,
            documentRevision: .max - 2
        )
        var reducer = CanvasInteractionReducer()

        let effects = reducer.reduce(
            .manipulationBegan(point: .init(x: 50, y: 40)),
            in: context
        )

        XCTAssertTrue(effects.isEmpty)
        XCTAssertIdle(reducer.state)
    }

    func testRecognitionRejectsSemanticallyDegenerateGeometry() throws {
        let id = UUID()
        let session = CanvasSession()
        var reducer = CanvasInteractionReducer(activeTool: .freehand)
        var context = makeContext(proposedElementID: id)
        _ = try beginFreehand(&reducer, at: .init(x: 0, y: 0), in: context, session: session)
        let raw = reducer.reduce(.pencilUp(.init(x: 20, y: 10)), in: context)
        let request = try XCTUnwrap(raw.recognitionRequest)
        try apply(raw, to: session)
        let element = try XCTUnwrap(session.document.elements.first)
        context = makeContext(elements: [element])
        let point = CanvasPoint(x: 4, y: 4)
        let results: [RecognitionResult] = [
            .init(geometry: .line(.init(start: point, end: point)), confidence: 1),
            .init(
                geometry: .rectangle(.init(rect: .init(x: 1, y: 1, width: 0, height: 10))),
                confidence: 1
            ),
            .init(
                geometry: .freehand(inkStroke([point, point])),
                confidence: 1
            ),
            .init(
                geometry: .freehand(inkStroke([point])),
                confidence: 1
            ),
        ]

        for result in results {
            XCTAssertTrue(
                reducer.reduce(
                    .recognitionCompleted(request: request, result: result),
                    in: context
                ).isEmpty
            )
        }
    }

    func testMoreThanTwoHundredRecognitionPointsRunOffMainActor() async throws {
        let recognizer = ThreadRecordingRecognizer()
        let points = (0 ... 200).map { CanvasPoint(x: Double($0), y: 0) }
        let elementID = UUID()
        let request = RecognitionRequest(
            fingerprint: .init(
                documentID: UUID(),
                replacementGeneration: .zero,
                elementID: elementID,
                contentRevision: 0
            ),
            points: points,
            recognitionGeneration: .zero
        )

        let result = await RecognitionExecutor.recognize(request, with: recognizer)

        XCTAssertNotNil(result)
        XCTAssertFalse(recognizer.wasCalledOnMainThread)
    }

    func testDismantleCancelsLongRunningRecognitionWork() async throws {
        let recognizer = CancellationAwareRecognizer()
        let session = CanvasSession()
        session.selectTool(.freehand)
        let renderer = RecordingRenderer()
        let coordinator = CadCanvasCoordinator(
            session: session,
            recognizer: recognizer,
            renderer: renderer
        )
        let host = coordinator.makeHostView()
        _ = host
        coordinator.receive(.pencilDown(.init(x: 0, y: 0)))
        for index in 1 ... 199 {
            coordinator.receive(.pencilMoved(.init(x: Double(index), y: 1)))
        }
        coordinator.receive(.pencilUp(.init(x: 200, y: 0)))
        await fulfillment(of: [recognizer.started], timeout: 1)

        coordinator.dismantle()

        await fulfillment(of: [recognizer.cancelled], timeout: 1)
        XCTAssertTrue(recognizer.observedCancellation)
    }

    func testToolChangeCancelsLongRunningRecognitionWork() async throws {
        let recognizer = CancellationAwareRecognizer()
        let session = CanvasSession()
        session.selectTool(.freehand)
        let coordinator = CadCanvasCoordinator(
            session: session,
            recognizer: recognizer,
            renderer: RecordingRenderer()
        )
        let host = coordinator.makeHostView()
        _ = host
        coordinator.receive(.pencilDown(.init(x: 0, y: 0)))
        for index in 1 ... 199 {
            coordinator.receive(.pencilMoved(.init(x: Double(index), y: 1)))
        }
        coordinator.receive(.pencilUp(.init(x: 200, y: 0)))
        await fulfillment(of: [recognizer.started], timeout: 1)

        session.selectTool(.line)
        coordinator.update()

        await fulfillment(of: [recognizer.cancelled], timeout: 1)
        XCTAssertTrue(recognizer.observedCancellation)
    }

    func testCadCanvasViewHasExactInitializerAndCoordinatorLifecycle() throws {
        let session = CanvasSession()
        let recognizer = ThreadRecordingRecognizer()
        let renderer = RecordingRenderer()
        let publicView: CadCanvasView = CadCanvasView(
            session: session,
            recognizer: recognizer,
            renderer: renderer
        )
        _ = publicView

        let coordinator = CadCanvasCoordinator(
            session: session,
            recognizer: recognizer,
            renderer: renderer
        )
        let host = coordinator.makeHostView()
        coordinator.update()

        XCTAssertTrue(host.renderView === renderer.renderView)
        XCTAssertEqual(renderer.snapshots.count, 1)
        XCTAssertGreaterThanOrEqual(host.gestureRecognizers?.count ?? 0, 4)
        XCTAssertEqual(host.interactions.compactMap { $0 as? UIPointerInteraction }.count, 1)
        XCTAssertEqual(host.interactions.compactMap { $0 as? UIPencilInteraction }.count, 1)
        XCTAssertTrue(host.isUserInteractionEnabled)

        coordinator.dismantle()
        XCTAssertTrue(host.gestureRecognizers?.isEmpty ?? true)
        XCTAssertTrue(host.interactions.compactMap { $0 as? UIPencilInteraction }.isEmpty)
        XCTAssertTrue(coordinator.isDismantled)
    }

    func testHostHandledPencilShortcutSuppressesBuiltInToolChange() {
        let session = CanvasSession()
        session.selectTool(.line)
        let presenter = RecordingPencilPalettePresenter()
        let coordinator = CadCanvasCoordinator(
            session: session,
            recognizer: nil,
            renderer: RecordingRenderer(),
            pencilShortcutHandler: { _ in .handled },
            pencilPalettePresenter: presenter
        )
        _ = coordinator.makeHostView()

        coordinator.dispatchPencilShortcut(.init(
            action: .switchEraser,
            screenAnchor: .init(x: 20, y: 30)
        ))

        XCTAssertEqual(session.activeTool, .line)
        XCTAssertEqual(presenter.dismissCount, 1)
    }

    func testDefaultPencilShortcutsToggleToolsAndForwardPaletteRequests() {
        let session = CanvasSession()
        session.selectTool(.line)
        let presenter = RecordingPencilPalettePresenter()
        let coordinator = CadCanvasCoordinator(
            session: session,
            recognizer: nil,
            renderer: RecordingRenderer(),
            pencilShortcutHandler: { _ in .useDefault },
            pencilPalettePresenter: presenter
        )
        let host = coordinator.makeHostView()

        coordinator.dispatchPencilShortcut(.init(
            action: .switchEraser,
            screenAnchor: .init(x: 20, y: 30)
        ))
        XCTAssertEqual(session.activeTool, .eraser)

        coordinator.dispatchPencilShortcut(.init(
            action: .switchEraser,
            screenAnchor: .init(x: 20, y: 30)
        ))
        XCTAssertEqual(session.activeTool, .line)

        coordinator.dispatchPencilShortcut(.init(
            action: .showInkAttributes,
            screenAnchor: .init(x: 60, y: 70)
        ))
        XCTAssertEqual(presenter.presentedAction, .showInkAttributes)
        XCTAssertEqual(presenter.lastAnchor, .init(x: 60, y: 70))
        XCTAssertTrue(presenter.lastHostView === host)
        XCTAssertEqual(presenter.lastStyleTool, .line)
    }

    func testDocumentReplacementAndDismantleDismissPencilPalettes() throws {
        let session = CanvasSession()
        let presenter = RecordingPencilPalettePresenter()
        let coordinator = CadCanvasCoordinator(
            session: session,
            recognizer: nil,
            renderer: RecordingRenderer(),
            pencilPalettePresenter: presenter
        )
        let host = coordinator.makeHostView()
        let request = CanvasPencilShortcutContext(
            action: .showContextualPalette,
            screenAnchor: .init(x: 20, y: 30)
        )

        coordinator.dispatchPencilShortcut(request)
        try session.replaceDocument(.empty())
        coordinator.update()

        XCTAssertEqual(presenter.dismissCount, 1)

        coordinator.dispatchPencilShortcut(request)
        coordinator.dismantle()

        XCTAssertEqual(presenter.dismissCount, 2)
        withExtendedLifetime(host) {}
    }

    func testPencilHoverCoordinatorOwnsOnlyPencilHoverAndTearsDownCleanly() throws {
        let firstHost = UIView()
        let secondHost = UIView()
        var delivered: [CGPoint?] = []
        let coordinator = CanvasPencilHoverCoordinator { delivered.append($0) }

        coordinator.install(on: firstHost)

        XCTAssertEqual(firstHost.gestureRecognizers, [coordinator.recognizer])
        XCTAssertEqual(
            coordinator.recognizer.allowedTouchTypes,
            [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        )

        coordinator.deliver(screenPoint: .init(x: 12, y: 34))
        coordinator.deliver(screenPoint: .init(x: CGFloat.infinity, y: 34))
        coordinator.install(on: secondHost)

        XCTAssertTrue(firstHost.gestureRecognizers?.isEmpty ?? true)
        XCTAssertEqual(secondHost.gestureRecognizers, [coordinator.recognizer])
        XCTAssertEqual(delivered.count, 3)
        XCTAssertEqual(delivered[0], .init(x: 12, y: 34))
        XCTAssertNil(delivered[1])
        XCTAssertNil(delivered[2])

        coordinator.uninstall()

        XCTAssertTrue(secondHost.gestureRecognizers?.isEmpty ?? true)
        XCTAssertNil(delivered.last ?? .zero)
    }

    func testPencilHoverProjectsThroughViewportAndUpdatesEraserHalo() throws {
        let element = rectangle(x: 10, y: 20, width: 30, height: 40)
        let viewport = try CanvasViewport(
            zoom: 2,
            translation: .init(x: 100, y: 50),
            viewportSize: .init(width: 500, height: 400)
        )
        let session = try CanvasSession(
            document: CanvasDocument(elements: [element]),
            viewport: viewport
        )
        session.selectTool(.eraser)
        let renderer = RecordingRenderer()
        let coordinator = CadCanvasCoordinator(
            session: session,
            recognizer: nil,
            renderer: renderer
        )
        let host = coordinator.makeHostView()

        coordinator.sendPencilHover(.init(x: 150, y: 130))

        XCTAssertEqual(renderer.snapshots.last?.selectionBounds, element.bounds)

        coordinator.sendPencilHover(nil)

        XCTAssertNil(renderer.snapshots.last?.selectionBounds)
        withExtendedLifetime(host) {}
    }

    func testCadCanvasViewRecognizesByDefaultAndExplicitNilPreservesRawStroke() async throws {
        let points = (0 ... 30).map { CanvasPoint(x: Double($0) * 4, y: 12) }
        let defaultSession = CanvasSession()
        defaultSession.selectTool(.freehand)
        let defaultCoordinator = CadCanvasView(
            session: defaultSession,
            renderer: RecordingRenderer()
        ).makeCoordinator()

        defaultCoordinator.receive(.pencilDown(points[0]))
        for point in points.dropFirst().dropLast() {
            defaultCoordinator.receive(.pencilMoved(point))
        }
        defaultCoordinator.receive(.pencilUp(try XCTUnwrap(points.last)))

        let didRecognize = await eventually {
            defaultSession.document.elements.first?.geometry.kind == .line
        }
        XCTAssertTrue(didRecognize)

        let optOutSession = CanvasSession()
        optOutSession.selectTool(.freehand)
        let optOutCoordinator = CadCanvasView(
            session: optOutSession,
            recognizer: nil,
            renderer: RecordingRenderer()
        ).makeCoordinator()

        optOutCoordinator.receive(.pencilDown(points[0]))
        for point in points.dropFirst().dropLast() {
            optOutCoordinator.receive(.pencilMoved(point))
        }
        optOutCoordinator.receive(.pencilUp(try XCTUnwrap(points.last)))

        XCTAssertEqual(optOutSession.document.elements.first?.geometry.kind, .freehand)
        await Task.yield()
        XCTAssertEqual(optOutSession.document.elements.first?.geometry.kind, .freehand)
    }

    func testKeyboardDeleteAndDuplicateUseReversibleSessionCommands() throws {
        let original = CanvasElement(
            id: UUID(),
            contentRevision: 7,
            geometry: .rectangle(.init(rect: .init(x: 10, y: 20, width: 30, height: 40))),
            style: .init(
                stroke: .init(red: 0.1, green: 0.2, blue: 0.3),
                fill: .init(red: 0.4, green: 0.5, blue: 0.6),
                lineWidth: 3
            )
        )
        let duplicateID = UUID()
        let session = try CanvasSession(document: CanvasDocument(elements: [original]))
        session.selectedElementID = original.id
        let actions = CanvasCommandActions(session: session, makeElementID: { duplicateID })

        XCTAssertTrue(actions.canDeleteSelection)
        XCTAssertTrue(actions.canDuplicateSelection)
        XCTAssertTrue(actions.duplicateSelection())
        XCTAssertEqual(session.document.elements.map(\.id), [original.id, duplicateID])
        XCTAssertEqual(session.document.elements[1].contentRevision, 0)
        XCTAssertEqual(session.document.elements[1].geometry, original.geometry)
        XCTAssertEqual(session.document.elements[1].style, original.style)
        XCTAssertEqual(session.selectedElementID, duplicateID)
        XCTAssertTrue(actions.undo())
        XCTAssertEqual(session.document.elements.map(\.id), [original.id])
        XCTAssertTrue(actions.redo())
        XCTAssertEqual(session.document.elements.map(\.id), [original.id, duplicateID])

        session.selectedElementID = duplicateID
        XCTAssertTrue(actions.deleteSelection())
        XCTAssertEqual(session.document.elements.map(\.id), [original.id])
        XCTAssertNil(session.selectedElementID)
        XCTAssertTrue(actions.undo())
        XCTAssertEqual(session.document.elements.map(\.id), [original.id, duplicateID])
    }

    func testKeyboardCommandStructureBuildsWithSessionBackedUndoRedoBehavior() throws {
        let element = rectangle(x: 0, y: 0, width: 10, height: 10)
        let session = CanvasSession()
        let actions = CanvasCommandActions(session: session)
        let commands = CanvasKeyboardCommands(actions: actions)

        _ = commands.body
        try session.perform(.insert(element, at: 0))
        XCTAssertTrue(actions.canUndo)
        XCTAssertTrue(actions.undo())
        XCTAssertTrue(session.document.elements.isEmpty)
        XCTAssertTrue(actions.canRedo)
        XCTAssertTrue(actions.redo())
        XCTAssertEqual(session.document.elements.map(\.id), [element.id])
    }

    func testKeyboardDeleteDuplicateUndoAndRedoNoOpWhenUnavailableOrRejected() throws {
        let element = rectangle(x: 0, y: 0, width: 10, height: 10)
        let session = try CanvasSession(document: CanvasDocument(elements: [element]))
        let actions = CanvasCommandActions(session: session, makeElementID: { element.id })
        let originalDocument = session.document

        XCTAssertFalse(actions.canDeleteSelection)
        XCTAssertFalse(actions.canDuplicateSelection)
        XCTAssertFalse(actions.canUndo)
        XCTAssertFalse(actions.canRedo)
        XCTAssertFalse(actions.deleteSelection())
        XCTAssertFalse(actions.duplicateSelection())
        XCTAssertFalse(actions.undo())
        XCTAssertFalse(actions.redo())
        XCTAssertEqual(session.document.revision, originalDocument.revision)
        XCTAssertEqual(session.document.elements.map(\.id), originalDocument.elements.map(\.id))

        session.selectedElementID = element.id
        XCTAssertFalse(actions.duplicateSelection())
        XCTAssertEqual(session.document.revision, originalDocument.revision)
        XCTAssertEqual(session.document.elements.map(\.id), [element.id])
        XCTAssertEqual(session.selectedElementID, element.id)

        let exhausted = try CanvasSession(
            document: CanvasDocument(revision: .max - 2, elements: [element])
        )
        exhausted.selectedElementID = element.id
        let exhaustedActions = CanvasCommandActions(session: exhausted)
        XCTAssertFalse(exhaustedActions.deleteSelection())
        XCTAssertFalse(exhaustedActions.duplicateSelection())
        XCTAssertEqual(exhausted.document.revision, .max - 2)
        XCTAssertEqual(exhausted.document.elements.map(\.id), [element.id])
        XCTAssertEqual(exhausted.selectedElementID, element.id)
    }

    func testKeyboardZoomInAndOutAnchorAtViewportCenterAndOnlyMutateViewport() throws {
        let element = rectangle(x: 5, y: 6, width: 20, height: 30)
        let viewport = try CanvasViewport(
            zoom: 2,
            translation: .init(x: 30, y: -10),
            viewportSize: .init(width: 400, height: 300)
        )
        let session = try CanvasSession(document: CanvasDocument(elements: [element]), viewport: viewport)
        session.selectTool(.arch)
        session.selectedElementID = element.id
        let actions = CanvasCommandActions(session: session, zoomFactor: 2)
        let center = CanvasPoint(x: 200, y: 150)
        let fixedCanvasPoint = viewport.canvasPoint(fromScreen: center)
        let originalDocument = session.document

        XCTAssertTrue(actions.zoomIn())
        XCTAssertEqual(session.viewport.zoom, 4)
        XCTAssertEqual(session.viewport.canvasPoint(fromScreen: center), fixedCanvasPoint)
        XCTAssertTrue(actions.zoomOut())
        XCTAssertEqual(session.viewport, viewport)
        XCTAssertEqual(session.document.revision, originalDocument.revision)
        XCTAssertEqual(session.document.elements.map(\.geometry), originalDocument.elements.map(\.geometry))
        XCTAssertEqual(session.activeTool, .arch)
        XCTAssertEqual(session.selectedElementID, element.id)
        XCTAssertFalse(actions.canUndo)
        XCTAssertFalse(actions.canRedo)
    }

    func testKeyboardZoomClampsAndCommandZeroFitsOrResetsEmptyDocument() throws {
        let element = rectangle(x: 100, y: 200, width: 100, height: 50)
        let fitSession = try CanvasSession(
            document: CanvasDocument(elements: [element]),
            viewport: try .identity(size: .init(width: 1000, height: 800))
        )
        let fitActions = CanvasCommandActions(session: fitSession, zoomFactor: 100)
        XCTAssertTrue(fitActions.zoomIn())
        XCTAssertEqual(fitSession.viewport.zoom, CanvasViewport.zoomRange.upperBound)
        XCTAssertTrue(fitActions.zoomToFitOrReset())
        XCTAssertNotEqual(fitSession.viewport, try .identity(size: .init(width: 1000, height: 800)))

        let emptySession = CanvasSession(
            viewport: try CanvasViewport(
                zoom: 6,
                translation: .init(x: 70, y: -30),
                viewportSize: .init(width: 500, height: 400)
            )
        )
        let emptyActions = CanvasCommandActions(session: emptySession)
        XCTAssertTrue(emptyActions.zoomToFitOrReset())
        XCTAssertEqual(emptySession.viewport, try .identity(size: .init(width: 500, height: 400)))
        XCTAssertFalse(emptyActions.zoomOut())
        XCTAssertEqual(emptySession.viewport.zoom, CanvasViewport.zoomRange.lowerBound)
    }

    func testInvalidKeyboardZoomFactorsCannotReverseOrMutateZoomSemantics() throws {
        for factor in [0, 1, 0.5, Double.nan, .infinity, -.infinity] {
            let viewport = try CanvasViewport(
                zoom: 2,
                translation: .init(x: 20, y: 30),
                viewportSize: .init(width: 500, height: 400)
            )
            let session = CanvasSession(viewport: viewport)
            let actions = CanvasCommandActions(session: session, zoomFactor: factor)

            XCTAssertFalse(actions.zoomIn(), "factor: \(factor)")
            XCTAssertFalse(actions.zoomOut(), "factor: \(factor)")
            XCTAssertEqual(session.viewport, viewport, "factor: \(factor)")
        }
    }

    func testEscapeCancelsDraftAndSessionManipulationPreviewAndIsIdempotent() throws {
        let element = rectangle(x: 0, y: 0, width: 100, height: 80)
        let snapTarget = rectangle(x: 200, y: 0, width: 100, height: 80)
        let session = try CanvasSession(document: CanvasDocument(elements: [element, snapTarget]))
        session.selectedElementID = element.id
        let renderer = RecordingRenderer()
        let coordinator = CadCanvasCoordinator(session: session, recognizer: nil, renderer: renderer)
        let host = coordinator.makeHostView()
        _ = host
        let actions = CanvasCommandActions(session: session)
        actions.attach(to: coordinator)

        coordinator.receive(.manipulationBegan(point: .init(x: 50, y: 40)))
        coordinator.receive(.manipulationChanged(cumulativeScreenDelta: .init(x: 100, y: 0)))
        XCTAssertEqual(session.document.elements[0].geometry, element.geometry)
        guard case .immutable(let previewPath) = try XCTUnwrap(
            renderer.snapshots.last?.geometry.first?.path
        ) else {
            return XCTFail("Expected immutable manipulation preview")
        }
        XCTAssertNotEqual(previewPath, element.geometry.renderPath)
        XCTAssertFalse(renderer.snapshots.last?.guides.isEmpty ?? true)

        XCTAssertTrue(actions.escape())
        XCTAssertEqual(session.document.elements[0].geometry, element.geometry)
        XCTAssertFalse(renderer.snapshots.last?.containsPreviewNode ?? true)
        XCTAssertTrue(renderer.snapshots.last?.guides.isEmpty ?? false)
        let revision = session.document.revision
        XCTAssertTrue(actions.escape())
        XCTAssertEqual(session.document.revision, revision)

        session.selectTool(.line)
        coordinator.receive(.pencilDown(.init(x: 1, y: 1)))
        coordinator.receive(.pencilMoved(.init(x: 20, y: 30)))
        XCTAssertTrue(renderer.snapshots.last?.containsPreviewNode ?? false)
        XCTAssertTrue(actions.escape())
        XCTAssertFalse(renderer.snapshots.last?.containsPreviewNode ?? true)
        XCTAssertTrue(renderer.snapshots.last?.guides.isEmpty ?? false)
    }

    func testEscapeDiscardsDirtyTextAndEndsFocusWithoutCommittingReplace() throws {
        let textID = UUID()
        let text = CanvasElement(
            id: textID,
            geometry: .text(
                .init(
                    frame: .init(x: 30, y: 40, width: 75.6, height: 16.8),
                    text: "canonical",
                    font: .init(familyName: "Helvetica", pointSize: 14),
                    color: .black
                )
            )
        )
        let session = try CanvasSession(document: CanvasDocument(elements: [text]))
        session.selectTool(.text)
        let coordinator = CadCanvasCoordinator(
            session: session,
            recognizer: nil,
            renderer: RecordingRenderer()
        )
        let host = coordinator.makeHostView()
        coordinator.update()
        let overlay = try XCTUnwrap(host.subviews.compactMap { $0 as? UITextView }.first)
        overlay.delegate?.textViewDidBeginEditing?(overlay)
        overlay.text = "dirty transient"
        overlay.delegate?.textViewDidChange?(overlay)
        let revision = session.document.revision
        let actions = CanvasCommandActions(session: session)
        actions.attach(to: coordinator)

        XCTAssertTrue(actions.escape())

        XCTAssertEqual(session.document.revision, revision)
        guard case .text(let canonical) = session.document.elements[0].geometry else {
            return XCTFail("Expected text element")
        }
        XCTAssertEqual(canonical.text, "canonical")
        XCTAssertEqual(overlay.text, "canonical")
        XCTAssertFalse(overlay.isFirstResponder)
    }

    func testCanvasEditingCommandsYieldToFocusedTextResponder() throws {
        let text = textElement(
            frame: .init(x: 10, y: 20, width: 200, height: 24),
            text: "Edit me"
        )
        let session = try CanvasSession(document: CanvasDocument(elements: [text]))
        session.selectTool(.text)
        session.selectedElementID = text.id
        let coordinator = CadCanvasCoordinator(
            session: session,
            recognizer: nil,
            renderer: RecordingRenderer()
        )
        let host = coordinator.makeHostView()
        let actions = CanvasCommandActions(session: session)
        actions.attach(to: coordinator)
        let overlay = try XCTUnwrap(host.subviews.compactMap { $0 as? UITextView }.first)

        overlay.delegate?.textViewDidBeginEditing?(overlay)

        XCTAssertTrue(actions.isTextEditing)
        XCTAssertFalse(actions.canUndo)
        XCTAssertFalse(actions.canRedo)
        XCTAssertFalse(actions.canDeleteSelection)
        XCTAssertFalse(actions.canDuplicateSelection)
        XCTAssertFalse(actions.undo())
        XCTAssertFalse(actions.redo())
        XCTAssertFalse(actions.deleteSelection())
        XCTAssertFalse(actions.duplicateSelection())
        XCTAssertEqual(session.document.elements.map(\.id), [text.id])

        XCTAssertTrue(actions.escape())
        XCTAssertFalse(actions.isTextEditing)
    }

    func testEscapeDiscardsDirtyTextWhenRevisionCannotReserveAReplace() throws {
        let text = CanvasElement(
            id: UUID(),
            geometry: .text(
                .init(
                    frame: .init(x: 10, y: 20, width: 75.6, height: 16.8),
                    text: "canonical",
                    font: .init(familyName: "Helvetica", pointSize: 14),
                    color: .black
                )
            )
        )
        let session = try CanvasSession(
            document: CanvasDocument(revision: .max - 2, elements: [text])
        )
        session.selectTool(.text)
        let coordinator = CadCanvasCoordinator(
            session: session,
            recognizer: nil,
            renderer: RecordingRenderer()
        )
        let host = coordinator.makeHostView()
        coordinator.update()
        let overlay = try XCTUnwrap(host.subviews.compactMap { $0 as? UITextView }.first)
        overlay.delegate?.textViewDidBeginEditing?(overlay)
        overlay.text = "dirty transient"
        overlay.delegate?.textViewDidChange?(overlay)
        let actions = CanvasCommandActions(session: session)
        actions.attach(to: coordinator)

        XCTAssertTrue(actions.escape())

        XCTAssertEqual(session.document.revision, .max - 2)
        XCTAssertEqual(overlay.text, "canonical")
        XCTAssertFalse(overlay.isFirstResponder)
    }

    func testEscapeCancelsPendingRecognitionWork() async throws {
        let recognizer = CancellationAwareRecognizer()
        let session = CanvasSession()
        session.selectTool(.freehand)
        let coordinator = CadCanvasCoordinator(
            session: session,
            recognizer: recognizer,
            renderer: RecordingRenderer()
        )
        _ = coordinator.makeHostView()
        let actions = CanvasCommandActions(session: session)
        actions.attach(to: coordinator)
        coordinator.receive(.pencilDown(.init(x: 0, y: 0)))
        for index in 1 ... 199 {
            coordinator.receive(.pencilMoved(.init(x: Double(index), y: 1)))
        }
        coordinator.receive(.pencilUp(.init(x: 200, y: 0)))
        await fulfillment(of: [recognizer.started], timeout: 1)

        XCTAssertTrue(actions.escape())

        await fulfillment(of: [recognizer.cancelled], timeout: 1)
        XCTAssertTrue(recognizer.observedCancellation)
    }

    func testCommandActionsReconcileAToNilAToBAndDismantle() throws {
        let session = CanvasSession()
        let first = CanvasCommandActions(session: session)
        let second = CanvasCommandActions(session: session)
        let coordinator = CadCanvasCoordinator(session: session, recognizer: nil, renderer: RecordingRenderer())
        _ = coordinator.makeHostView()

        coordinator.reconcileCommandActions(first)
        XCTAssertTrue(first.escape())
        coordinator.reconcileCommandActions(nil)
        XCTAssertFalse(first.escape())

        coordinator.reconcileCommandActions(first)
        coordinator.reconcileCommandActions(second)
        XCTAssertFalse(first.escape())
        XCTAssertTrue(second.escape())

        coordinator.dismantle()

        XCTAssertFalse(first.escape())
        XCTAssertFalse(second.escape())
    }

    func testSharedActionsViewDerivesItsOnlySessionFromCommandActions() throws {
        let actionsSession = CanvasSession()
        actionsSession.selectTool(.line)
        let unrelatedElement = rectangle(x: 0, y: 0, width: 10, height: 10)
        let unrelatedSession = try CanvasSession(
            document: CanvasDocument(elements: [unrelatedElement])
        )
        let actions = CanvasCommandActions(session: actionsSession)
        let view = CadCanvasView(
            commandActions: actions,
            renderer: RecordingRenderer()
        )
        let configuredSession = Mirror(reflecting: view).children.first {
            $0.label == "session"
        }?.value as? CanvasSession

        XCTAssertTrue(configuredSession === actionsSession)
        XCTAssertFalse(configuredSession === unrelatedSession)
        XCTAssertEqual(unrelatedSession.document.elements.map(\.id), [unrelatedElement.id])
    }

    func testCoordinatorSynchronizesToolBeforeImmediatePencilEvent() throws {
        let session = CanvasSession()
        session.selectTool(.rectangle)
        let renderer = RecordingRenderer()
        let coordinator = CadCanvasCoordinator(session: session, recognizer: nil, renderer: renderer)
        let host = coordinator.makeHostView()
        _ = host

        coordinator.receive(.pencilDown(.init(x: 10, y: 10)))
        coordinator.receive(.pencilMoved(.init(x: 30, y: 40)))

        let preview = try XCTUnwrap(renderer.snapshots.last?.geometry.first)
        guard case .immutable(let previewPath) = preview.path else {
            return XCTFail("Expected immutable rectangle preview")
        }
        XCTAssertEqual(previewPath, CanvasElement.rectangle(
            id: preview.id,
            rect: .init(x: 10, y: 10, width: 20, height: 30)
        ).geometry.renderPath)
    }

    func testManipulationArbitrationIncludesSelectedHandleOutsideGeometryTolerance() throws {
        let line = CanvasElement(
            id: UUID(),
            geometry: .line(.init(start: .init(x: 0, y: 20), end: .init(x: 100, y: 20)))
        )
        let context = makeContext(elements: [line], selectedElementID: line.id)
        let pointInHandleOnlyBand = CanvasPoint(x: -10, y: 20)
        let reducer = CanvasInteractionReducer()

        XCTAssertTrue(reducer.canBeginManipulation(at: pointInHandleOnlyBand, in: context))
    }

    func testPencilSampleDeliveryPreservesCoalescedOrder() throws {
        let host = CanvasHostView(renderView: UIView())
        var delivered: [CGPoint] = []
        var deliveryCount = 0
        host.sendPencil = { phase, confirmed, _ in
            if case .moved = phase {
                deliveryCount += 1
                delivered.append(contentsOf: confirmed.map(\.location))
            }
        }
        let samples = [
            CGPoint(x: 30, y: 4),
            CGPoint(x: 10, y: 2),
            CGPoint(x: 20, y: 3),
        ]

        let primaryIdentity = NSObject()
        host.deliverPencilSamples(
            coalesced: samples.dropLast().map { .init(identity: NSObject(), location: $0) },
            primary: .init(identity: primaryIdentity, location: samples[2]),
            phase: .moved
        )

        XCTAssertEqual(delivered, samples)
        XCTAssertEqual(deliveryCount, 1)
    }

    func testMismatchedOutOfOrderAndConflictingEventsAreIgnored() throws {
        let element = rectangle(x: 0, y: 0, width: 100, height: 100)
        let context = makeContext(elements: [element], selectedElementID: element.id)
        let outOfOrder: [CanvasInput] = [
            .pencilMoved(.init(x: 1, y: 1)),
            .pencilUp(.init(x: 1, y: 1)),
            .panChanged(cumulativeScreenDelta: .init(x: 1, y: 1)),
            .panEnded(screenVelocity: .init(x: 1, y: 1)),
            .pinchChanged(scaleFromStart: 2, currentScreenCentroid: .init(x: 1, y: 1)),
            .pinchEnded,
            .manipulationChanged(cumulativeScreenDelta: .init(x: 1, y: 1)),
            .manipulationEnded,
            .manipulationCancelled,
        ]
        var reducer = CanvasInteractionReducer()
        for input in outOfOrder {
            XCTAssertTrue(reducer.reduce(input, in: context).isEmpty)
            XCTAssertIdle(reducer.state)
        }

        _ = reducer.reduce(.panBegan(.init(x: 1, y: 1)), in: context)
        XCTAssertTrue(reducer.reduce(
            .pinchBegan(canvasAnchor: .init(x: 1, y: 1), screenCentroid: .init(x: 1, y: 1)),
            in: context
        ).isEmpty)
        XCTAssertTrue(reducer.reduce(.manipulationBegan(point: .init(x: 10, y: 10)), in: context).isEmpty)
        XCTAssertPanning(reducer.state)

        _ = reducer.reduce(.cancel, in: context)
        _ = reducer.reduce(
            .pinchBegan(canvasAnchor: .init(x: 1, y: 1), screenCentroid: .init(x: 1, y: 1)),
            in: context
        )
        XCTAssertTrue(reducer.reduce(.panBegan(.init(x: 1, y: 1)), in: context).isEmpty)
        XCTAssertTrue(reducer.reduce(.pencilDown(.init(x: 1, y: 1)), in: context).isEmpty)
        XCTAssertPinching(reducer.state)
    }

    func testNonfinitePointsDeltasAndVelocityCannotProduceEffects() throws {
        let element = rectangle(x: 0, y: 0, width: 100, height: 100)
        let context = makeContext(elements: [element], selectedElementID: element.id)
        var reducer = CanvasInteractionReducer()

        XCTAssertTrue(reducer.reduce(.pencilDown(.init(x: .nan, y: 0)), in: context).isEmpty)
        XCTAssertTrue(reducer.reduce(.tap(.init(x: 0, y: .infinity)), in: context).isEmpty)
        XCTAssertTrue(reducer.reduce(.panBegan(.init(x: .infinity, y: 0)), in: context).isEmpty)
        XCTAssertTrue(reducer.reduce(
            .pinchBegan(canvasAnchor: .init(x: 0, y: .nan), screenCentroid: .init(x: 0, y: 0)),
            in: context
        ).isEmpty)
        XCTAssertTrue(reducer.reduce(.manipulationBegan(point: .init(x: .nan, y: 0)), in: context).isEmpty)
        XCTAssertIdle(reducer.state)

        _ = reducer.reduce(.panBegan(.init(x: 1, y: 1)), in: context)
        XCTAssertTrue(
            reducer.reduce(
                .panChanged(cumulativeScreenDelta: .init(x: .infinity, y: 0)),
                in: context
            ).isEmpty
        )
        XCTAssertTrue(
            reducer.reduce(.panEnded(screenVelocity: .init(x: .nan, y: 0)), in: context).isEmpty
        )
        XCTAssertIdle(reducer.state)

        _ = beginManipulation(&reducer, at: .init(x: 50, y: 50), in: context)
        XCTAssertTrue(
            reducer.reduce(
                .manipulationChanged(cumulativeScreenDelta: .init(x: 0, y: .infinity)),
                in: context
            ).isEmpty
        )
        XCTAssertManipulating(reducer.state)
    }

    func testPencilMoveAndUpRequireMatchingDrawingStateAndFinitePoints() throws {
        let context = makeContext()
        var reducer = CanvasInteractionReducer(activeTool: .freehand)
        _ = try beginFreehand(&reducer, at: .init(x: 1, y: 2), in: context)

        XCTAssertTrue(reducer.reduce(.pencilMoved(.init(x: .nan, y: 3)), in: context).isEmpty)
        XCTAssertTrue(reducer.reduce(.pencilUp(.init(x: 4, y: .infinity)), in: context).isEmpty)
        XCTAssertDrawingPointCount(reducer.state, 1)

        _ = reducer.reduce(.pencilMoved(.init(x: 3, y: 4)), in: context)
        _ = reducer.reduce(.pencilUp(.init(x: 5, y: 6)), in: context)
        XCTAssertIdle(reducer.state)
    }

    func testCoordinatorMapsEveryUIKitRoleWithoutSynthesizingPencilInput() throws {
        let viewport = try CanvasViewport(
            zoom: 2,
            translation: .init(x: 10, y: 20),
            viewportSize: .init(width: 500, height: 400)
        )
        let coordinator = CanvasGestureCoordinator(viewport: { viewport }, send: { _ in })

        XCTAssertPencilFree(
            try XCTUnwrap(
                coordinator.map(
                    role: .pan,
                    state: .began,
                    screenLocation: .init(x: 30, y: 60)
                )
            )
        )
        XCTAssertPencilFree(
            try XCTUnwrap(
                coordinator.map(
                    role: .pan,
                    state: .changed,
                    cumulativeScreenDelta: .init(x: 11, y: 12)
                )
            )
        )
        XCTAssertPencilFree(
            try XCTUnwrap(
                coordinator.map(
                    role: .pinch,
                    state: .began,
                    screenLocation: .init(x: 30, y: 60)
                )
            )
        )
        XCTAssertPencilFree(
            try XCTUnwrap(
                coordinator.map(
                    role: .manipulation,
                    state: .changed,
                    cumulativeScreenDelta: .init(x: 13, y: 14)
                )
            )
        )
        XCTAssertPencilFree(
            try XCTUnwrap(
                coordinator.map(role: .tap, state: .ended, screenLocation: .init(x: 30, y: 60))
            )
        )

        guard case .panBegan(let canvasPoint) = coordinator.map(
            role: .pan,
            state: .began,
            screenLocation: .init(x: 30, y: 60)
        ) else {
            return XCTFail("Expected pan began")
        }
        XCTAssertEqual(canvasPoint, .init(x: 10, y: 20))
        XCTAssertNil(coordinator.map(role: .pan, state: .failed))
        XCTAssertNil(coordinator.map(role: .pinch, state: .failed))
        XCTAssertNil(coordinator.map(role: .manipulation, state: .failed))
    }

    func testCoordinatorMapsCancellationToRoleSpecificTerminalInput() throws {
        let coordinator = CanvasGestureCoordinator(
            viewport: { try! .identity(size: .init(width: 100, height: 100)) },
            send: { _ in }
        )

        guard case .panEnded = try XCTUnwrap(coordinator.map(role: .pan, state: .cancelled)) else {
            return XCTFail("Expected role-specific pan terminal input")
        }
        guard case .pinchCancelled = try XCTUnwrap(coordinator.map(role: .pinch, state: .cancelled)) else {
            return XCTFail("Expected role-specific pinch terminal input")
        }
        guard case .manipulationCancelled = try XCTUnwrap(
            coordinator.map(role: .manipulation, state: .cancelled)
        ) else {
            return XCTFail("Expected role-specific manipulation cancellation")
        }
    }

    func testCoordinatorChoosesPanOrManipulationBeforeRecognition() throws {
        let coordinator = CanvasGestureCoordinator(
            viewport: { try! .identity(size: .init(width: 100, height: 100)) },
            canManipulate: { $0.x >= 50 },
            send: { _ in }
        )

        XCTAssertTrue(
            coordinator.shouldBegin(role: .pan, screenLocation: .init(x: 25, y: 20))
        )
        XCTAssertFalse(
            coordinator.shouldBegin(role: .manipulation, screenLocation: .init(x: 25, y: 20))
        )
        XCTAssertFalse(
            coordinator.shouldBegin(role: .pan, screenLocation: .init(x: 75, y: 20))
        )
        XCTAssertTrue(
            coordinator.shouldBegin(role: .manipulation, screenLocation: .init(x: 75, y: 20))
        )
    }

    func testPointerHitUsesTopmostGeometryInCanvasCoordinatesAndReducerTolerance() throws {
        let bottom = rectangle(x: 0, y: 0, width: 100, height: 100)
        let top = CanvasElement(
            id: UUID(),
            geometry: .line(.init(start: .init(x: 0, y: 10), end: .init(x: 100, y: 10)))
        )
        let viewport = try CanvasViewport(
            zoom: 2,
            translation: .init(x: 10, y: 20),
            viewportSize: .init(width: 500, height: 400)
        )
        let coordinator = CanvasGestureCoordinator(
            viewport: { viewport },
            elements: { [bottom, top] },
            send: { _ in }
        )

        XCTAssertEqual(
            coordinator.hitElementID(atScreenPoint: .init(x: 50, y: 47.9)),
            top.id
        )
        XCTAssertEqual(
            coordinator.hitElementID(atScreenPoint: .init(x: 50, y: 48)),
            top.id,
            "Eight screen points must hit at zoom 2"
        )
        XCTAssertEqual(
            coordinator.hitElementID(atScreenPoint: .init(x: 50, y: 48.1)),
            bottom.id,
            "Past the line tolerance, the underlying topmost geometry must win"
        )

        var reducer = CanvasInteractionReducer()
        let context = makeContext(viewport: viewport, elements: [bottom, top])
        let mapped = viewport.canvasPoint(fromScreen: .init(x: 50, y: 48))
        XCTAssertSelect(reducer.reduce(.tap(mapped), in: context), id: top.id)
    }

    func testPointerHitMissAndNonfiniteInputsReturnNil() throws {
        let element = rectangle(x: 0, y: 0, width: 20, height: 20)
        let viewport = MutableViewport(try .identity(size: .init(width: 100, height: 100)))
        let coordinator = CanvasGestureCoordinator(
            viewport: { viewport.value },
            elements: { [element] },
            send: { _ in }
        )

        XCTAssertNil(coordinator.hitElementID(atScreenPoint: .init(x: 80, y: 80)))
        XCTAssertNil(coordinator.hitElementID(atScreenPoint: .init(x: .nan, y: 10)))
        XCTAssertNil(coordinator.hitElementID(atScreenPoint: .init(x: 10, y: .infinity)))
    }

    func testViewportRejectsEveryInvalidDimension() {
        let invalidSizes = [
            CanvasSize(width: .nan, height: 100),
            CanvasSize(width: .infinity, height: 100),
            CanvasSize(width: 100, height: .nan),
            CanvasSize(width: 100, height: .infinity),
            CanvasSize(width: -1, height: 100),
            CanvasSize(width: 100, height: -1),
        ]

        for size in invalidSizes {
            XCTAssertThrowsError(try CanvasViewport(
                zoom: 1,
                translation: .init(x: 0, y: 0),
                viewportSize: size
            ), "size: \(size)")
        }
    }

    func testPointerRegionsAreStableAndInteractionRehostsWithoutDuplication() throws {
        let element = rectangle(x: 10, y: 20, width: 30, height: 40)
        let coordinator = CanvasGestureCoordinator(
            viewport: { try! .identity(size: .init(width: 200, height: 200)) },
            elements: { [element] },
            send: { _ in }
        )
        let firstHost = UIView(frame: .init(x: 0, y: 0, width: 200, height: 200))
        let secondHost = UIView(frame: firstHost.frame)

        coordinator.install(on: firstHost)
        coordinator.install(on: firstHost)
        XCTAssertEqual(firstHost.interactions.compactMap { $0 as? UIPointerInteraction }.count, 1)
        let first = try XCTUnwrap(
            coordinator.pointerRegion(atScreenPoint: .init(x: 20, y: 30))
        )
        let second = try XCTUnwrap(
            coordinator.pointerRegion(atScreenPoint: .init(x: 30, y: 40))
        )
        XCTAssertEqual(first.identifier, AnyHashable(element.id))
        XCTAssertEqual(second.identifier, AnyHashable(element.id))
        XCTAssertEqual(first.rect, second.rect)

        coordinator.install(on: secondHost)
        XCTAssertTrue(firstHost.interactions.compactMap { $0 as? UIPointerInteraction }.isEmpty)
        XCTAssertEqual(secondHost.interactions.compactMap { $0 as? UIPointerInteraction }.count, 1)
        coordinator.uninstall()
        XCTAssertTrue(secondHost.interactions.compactMap { $0 as? UIPointerInteraction }.isEmpty)
        XCTAssertTrue(secondHost.gestureRecognizers?.isEmpty ?? true)
    }

    func testUIKitRecognizersPreserveDirectOwnershipAndAllowIndirectPointerTapSelection() throws {
        let element = rectangle(x: 0, y: 0, width: 20, height: 20)
        let viewport = try CanvasViewport.identity(size: .init(width: 100, height: 100))
        let coordinator = CanvasGestureCoordinator(
            viewport: { viewport },
            elements: { [element] },
            send: { _ in }
        )
        let view = UIView(frame: .init(x: 0, y: 0, width: 100, height: 100))

        coordinator.install(on: view)

        XCTAssertEqual(coordinator.recognizers.count, 4)
        XCTAssertEqual(
            coordinator.tapRecognizer.allowedTouchTypes,
            [
                NSNumber(value: UITouch.TouchType.direct.rawValue),
                NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
            ]
        )
        for recognizer in coordinator.recognizers where recognizer !== coordinator.tapRecognizer {
            XCTAssertEqual(
                recognizer.allowedTouchTypes,
                [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            )
        }
        let tap = try XCTUnwrap(
            coordinator.map(role: .tap, state: .ended, screenLocation: .init(x: 10, y: 10))
        )
        var reducer = CanvasInteractionReducer()
        XCTAssertSelect(
            reducer.reduce(tap, in: makeContext(viewport: viewport, elements: [element])),
            id: element.id
        )
    }

    func testManipulationAndPinchCannotRunSimultaneouslyInEitherOrder() throws {
        let coordinator = CanvasGestureCoordinator(
            viewport: { try! .identity(size: .init(width: 100, height: 100)) },
            send: { _ in }
        )

        XCTAssertFalse(coordinator.allowsSimultaneousRecognition(.manipulation, .pinch))
        XCTAssertFalse(coordinator.allowsSimultaneousRecognition(.pinch, .manipulation))
    }

    func testEraserHoverTargetsTopmostElementWithoutSelectingIt() {
        let back = rectangle(x: 0, y: 0, width: 100, height: 100)
        let front = CanvasElement(
            id: UUID(),
            geometry: .line(.init(start: .init(x: 50, y: 0), end: .init(x: 50, y: 100)))
        )
        var reducer = CanvasInteractionReducer(activeTool: .eraser)
        let context = makeContext(elements: [back, front])

        let effects = reducer.reduce(.pencilHover(.init(x: 50, y: 50)), in: context)

        XCTAssertEqual(effects.eraserTargetID, front.id)
        XCTAssertFalse(effects.contains { if case .select = $0 { true } else { false } })
    }

    func testEraserBatchesSweptTargetsAndCommitsOnePreview() throws {
        let first = CanvasElement(
            id: UUID(),
            geometry: .line(.init(start: .init(x: 25, y: 0), end: .init(x: 25, y: 100)))
        )
        let second = CanvasElement(
            id: UUID(),
            geometry: .line(.init(start: .init(x: 75, y: 0), end: .init(x: 75, y: 100)))
        )
        let context = makeContext(elements: [first, second])
        var reducer = CanvasInteractionReducer(activeTool: .eraser)

        let began = reducer.reduce(
            .pencilSamples([.init(x: 0, y: 50)], phase: .down),
            in: context
        )
        guard case .requestPreview(.erasing) = began.first else {
            return XCTFail("Expected eraser preview acquisition")
        }

        let token = CanvasPreviewToken()
        XCTAssertTrue(reducer.reduce(.previewAcquired(token), in: context).isEmpty)
        let moved = reducer.reduce(
            .pencilSamples(
                [.init(x: 10, y: 50), .init(x: 50, y: 50)],
                phase: .moved
            ),
            in: context
        )
        XCTAssertEqual(moved.erasedElementIDs, [first.id])

        let ended = reducer.reduce(
            .pencilSamples([.init(x: 100, y: 50)], phase: .up),
            in: context
        )
        XCTAssertEqual(ended.erasedElementIDs, [first.id, second.id])
        XCTAssertEqual(ended.filter(\.isCommitPreview).count, 1)
        XCTAssertNil(ended.eraserTargetID)
    }

    func testNonfinitePencilUpStillFinishesOwnedEraserPreview() throws {
        let element = rectangle(x: 0, y: 0, width: 100, height: 100)
        let context = makeContext(elements: [element])
        var reducer = CanvasInteractionReducer(activeTool: .eraser)
        _ = reducer.reduce(
            .pencilSamples([.init(x: 50, y: 50)], phase: .down),
            in: context
        )
        let token = CanvasPreviewToken()
        _ = reducer.reduce(.previewAcquired(token), in: context)

        let effects = reducer.reduce(
            .pencilSamples([.init(x: .nan, y: .infinity)], phase: .up),
            in: context
        )

        XCTAssertEqual(effects.filter(\.isCommitPreview).count, 1)
        XCTAssertIdle(reducer.state)
    }

    func testEraserCancellationAndStaleDocumentCancelOwnedPreview() {
        let element = rectangle(x: 0, y: 0, width: 100, height: 100)
        let context = makeContext(elements: [element])
        var reducer = CanvasInteractionReducer(activeTool: .eraser)
        _ = reducer.reduce(.pencilDown(.init(x: 10, y: 10)), in: context)
        _ = reducer.reduce(.previewAcquired(CanvasPreviewToken()), in: context)

        var generation = CanvasGeneration.zero
        generation.advance()
        let stale = makeContext(
            documentID: UUID(),
            elements: [element],
            documentReplacementGeneration: generation
        )
        let effects = reducer.reduce(.pencilMoved(.init(x: 20, y: 20)), in: stale)

        XCTAssertTrue(effects.containsCancelPreview)
        XCTAssertNil(effects.eraserTargetID)
        if case .idle = reducer.state {} else { XCTFail("Expected idle state") }
    }

    func testManipulationPanAndPinchPairsAreRejectedSymmetrically() throws {
        let coordinator = CanvasGestureCoordinator(
            viewport: { try! .identity(size: .init(width: 100, height: 100)) },
            send: { _ in }
        )

        XCTAssertFalse(coordinator.allowsSimultaneousRecognition(.manipulation, .pan))
        XCTAssertFalse(coordinator.allowsSimultaneousRecognition(.pan, .manipulation))
        XCTAssertFalse(coordinator.allowsSimultaneousRecognition(.pan, .pinch))
        XCTAssertFalse(coordinator.allowsSimultaneousRecognition(.pinch, .pan))
    }
}

private extension InteractionReducerTests {
    func beginManipulation(
        _ reducer: inout CanvasInteractionReducer,
        at point: CanvasPoint,
        in context: CanvasInteractionContext
    ) -> [CanvasEffect] {
        let effects = reducer.reduce(.manipulationBegan(point: point), in: context)
        guard effects.contains(where: {
            if case .requestPreview = $0 { return true }
            return false
        }) else {
            return effects
        }
        _ = reducer.reduce(.previewAcquired(CanvasPreviewToken()), in: context)
        return effects
    }

    func makeContext(
        documentID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
        viewport: CanvasViewport = try! .identity(size: .init(width: 500, height: 400)),
        elements: [CanvasElement] = [],
        selectedElementID: UUID? = nil,
        minimumElementSize: Double = 10,
        proposedElementID: UUID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
        documentReplacementGeneration: CanvasGeneration = .zero,
        documentRevision: UInt64 = 0,
        recognitionEnabled: Bool = true,
        snapConfiguration: SnapConfiguration = .init(
            screenThreshold: 8,
            gridSpacing: 10,
            snapToGrid: false
        )
    ) -> CanvasInteractionContext {
        CanvasInteractionContext(
            documentID: documentID,
            viewport: viewport,
            elements: elements,
            selectedElementID: selectedElementID,
            proposedElementID: proposedElementID,
            documentReplacementGeneration: documentReplacementGeneration,
            documentRevision: documentRevision,
            snapConfiguration: snapConfiguration,
            recognitionEnabled: recognitionEnabled,
            hitToleranceScreen: 8,
            resizeHandleToleranceScreen: 12,
            minimumElementSize: minimumElementSize
        )
    }

    @discardableResult
    func beginFreehand(
        _ reducer: inout CanvasInteractionReducer,
        at point: CanvasPoint,
        in context: CanvasInteractionContext,
        session: CanvasSession? = nil
    ) throws -> CanvasPreviewToken {
        let effects = reducer.reduce(.pencilDown(point), in: context)
        let kind = try XCTUnwrap(effects.compactMap { effect -> CanvasPreviewKind? in
            guard case .requestPreview(let kind) = effect else { return nil }
            return kind
        }.last)
        let token = try session?.acquirePreview(kind) ?? CanvasPreviewToken()
        let acknowledgement = reducer.reduce(.previewAcquired(token), in: context)
        if let session {
            try apply(acknowledgement, to: session)
        }
        return token
    }

    func rectangle(x: Double, y: Double, width: Double, height: Double) -> CanvasElement {
        CanvasElement.rectangle(
            id: UUID(),
            rect: .init(x: x, y: y, width: width, height: height)
        )
    }

    func textElement(frame: CanvasRect, text: String) -> CanvasElement {
        CanvasElement(
            id: UUID(),
            geometry: .text(.init(
                frame: frame,
                text: text,
                font: .init(familyName: "Helvetica", pointSize: 20),
                color: .black
            ))
        )
    }

    func inkStroke(_ points: [CanvasPoint]) -> CanvasInkStroke {
        CanvasInkStroke(
            samples: points.map { CanvasInkSample(point: $0, pressure: 1) },
            pressureEnabled: false
        )
    }

    func apply(_ effects: [CanvasEffect], to session: CanvasSession) throws {
        for effect in effects {
            switch effect {
            case .perform(let command):
                try session.perform(command)
            case .select(let id):
                session.selectedElementID = id
            case .setViewport(let viewport):
                session.setViewport(viewport)
            case .requestPreview:
                XCTFail("Preview acquisition requires a reducer acknowledgement")
            case .updatePreview(let payload, let token):
                try session.updatePreview(payload, token: token)
            case .commitPreview(let token):
                try session.commitPreview(token: token)
            case .cancelPreview(let token):
                try session.cancelPreview(token: token)
            case .appendFreehandPreview(let id, let style, let points, let token):
                try session.appendFreehandPreview(id: id, style: style, points: points, token: token)
            case .appendFreehandInkPreview(
                let id,
                let style,
                let confirmed,
                let predicted,
                let pressureEnabled,
                let widthMode,
                let token
            ):
                try session.appendFreehandInkPreview(
                    id: id,
                    style: style,
                    confirmed: confirmed,
                    predicted: predicted,
                    pressureEnabled: pressureEnabled,
                    widthMode: widthMode,
                    token: token
                )
            case .setGuides, .setTransientPreview, .recognize, .setEraserTarget:
                break
            }
        }
    }
}

private extension CanvasEffect {
    var updatedElement: CanvasElement? {
        guard case .updatePreview(let payload, _) = self else { return nil }
        guard case .element(let element) = payload else { return nil }
        return element
    }

    var viewport: CanvasViewport? {
        guard case .setViewport(let viewport) = self else { return nil }
        return viewport
    }

    var recognitionRequest: RecognitionRequest? {
        guard case .recognize(let request) = self else { return nil }
        return request
    }

    var isCommitPreview: Bool {
        if case .commitPreview = self { return true }
        return false
    }

    var isPerform: Bool {
        if case .perform = self { return true }
        return false
    }
}

private extension Array where Element == CanvasEffect {
    var insertedElement: CanvasElement? {
        let inserted: [CanvasElement] = compactMap { effect in
            guard case .perform(.insert(let element, _)) = effect else { return nil }
            return element
        }
        return inserted.last
    }

    var recognitionRequest: RecognitionRequest? {
        compactMap(\.recognitionRequest).last
    }

    var transientPreview: CanvasElement? {
        for effect in reversed() {
            guard case .setTransientPreview(let preview) = effect else { continue }
            return preview
        }
        return nil
    }

    var updatedElement: CanvasElement? {
        compactMap(\.updatedElement).last
    }

    var containsCancelPreview: Bool {
        contains { if case .cancelPreview = $0 { true } else { false } }
    }

    var containsCommit: Bool {
        contains {
            switch $0 {
            case .commitPreview, .perform:
                true
            default:
                false
            }
        }
    }

    var containsEmptyGuides: Bool {
        containsGuides([])
    }

    var eraserTargetID: UUID? {
        for effect in reversed() {
            guard case .setEraserTarget(let id) = effect else { continue }
            return id
        }
        return nil
    }

    var erasedElementIDs: [UUID]? {
        for effect in reversed() {
            guard case .updatePreview(.erasedElementIDs(let ids), _) = effect else { continue }
            return ids
        }
        return nil
    }

    func containsGuides(_ expected: [SnapGuide]) -> Bool {
        contains {
            guard case .setGuides(let guides) = $0 else { return false }
            return guides == expected
        }
    }
}

private func XCTAssertBeginPreview(
    _ effects: [CanvasEffect],
    id: UUID,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertTrue(
        effects.contains {
            if case .requestPreview(.editing(elementID: id)) = $0 { return true }
            return false
        },
        file: file,
        line: line
    )
}

private func XCTAssertSelect(
    _ effects: [CanvasEffect],
    id expected: UUID?,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertTrue(
        effects.contains {
            guard case .select(let actual) = $0 else { return false }
            return actual == expected
        },
        file: file,
        line: line
    )
}

private func XCTAssertIdle(
    _ state: CanvasInteractionState,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case .idle = state else {
        return XCTFail("Expected idle. \(message)", file: file, line: line)
    }
}

private func XCTAssertPanning(
    _ state: CanvasInteractionState,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case .panning = state else { return XCTFail("Expected panning", file: file, line: line) }
}

private func XCTAssertPinching(
    _ state: CanvasInteractionState,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case .pinching = state else { return XCTFail("Expected pinching", file: file, line: line) }
}

private func XCTAssertManipulating(
    _ state: CanvasInteractionState,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case .manipulating = state else {
        return XCTFail("Expected manipulating", file: file, line: line)
    }
}

private func XCTAssertManipulationHandle(
    _ state: CanvasInteractionState,
    expected: CanvasManipulationHandle,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case .manipulating(_, let actual, _) = state else {
        return XCTFail("Expected manipulating", file: file, line: line)
    }
    XCTAssertEqual(actual, expected, file: file, line: line)
}

private func XCTAssertDrawingPointCount(
    _ state: CanvasInteractionState,
    _ expected: Int,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let count: Int
    switch state {
    case .drawing(.line):
        count = 1
    case .drawing(.rectangle):
        count = 1
    case .drawing(.archBase):
        count = 1
    case .drawing(.archSagitta):
        count = 2
    case .drawing(.freehand(let pointCount)):
        count = pointCount
    default:
        return XCTFail("Expected drawing", file: file, line: line)
    }
    XCTAssertEqual(count, expected, file: file, line: line)
}

private func XCTAssertArchSagittaDraft(
    _ state: CanvasInteractionState,
    start: CanvasPoint,
    end: CanvasPoint,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case .drawing(.archSagitta(let actualStart, let actualEnd, _)) = state else {
        return XCTFail("Expected arch sagitta draft", file: file, line: line)
    }
    XCTAssertEqual(actualStart, start, file: file, line: line)
    XCTAssertEqual(actualEnd, end, file: file, line: line)
}

private func XCTAssertDrawingLine(
    _ state: CanvasInteractionState,
    start: CanvasPoint,
    current: CanvasPoint,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case .drawing(.line(let actualStart, let actualCurrent)) = state else {
        return XCTFail("Expected line draft", file: file, line: line)
    }
    XCTAssertEqual(actualStart, start, file: file, line: line)
    XCTAssertEqual(actualCurrent, current, file: file, line: line)
}

private func XCTAssertLinePreview(
    _ effects: [CanvasEffect],
    start: CanvasPoint,
    end: CanvasPoint,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard let preview = effects.transientPreview,
          case .line(let geometry) = preview.geometry else {
        return XCTFail("Expected a line transient preview", file: file, line: line)
    }
    XCTAssertEqual(geometry.start, start, file: file, line: line)
    XCTAssertEqual(geometry.end, end, file: file, line: line)
}

private extension CanvasPathCommand {
    var terminalPoint: CanvasPoint? {
        switch self {
        case .move(let point), .line(let point): point
        case .quad(_, let end), .cubic(_, _, let end): end
        case .close: nil
        }
    }
}

private final class ThreadRecordingRecognizer: @unchecked Sendable, ShapeRecognizing {
    private let lock = NSLock()
    private var calledOnMainThread = true

    var wasCalledOnMainThread: Bool {
        lock.withLock { calledOnMainThread }
    }

    func recognize(_ sample: StrokeSample) -> RecognitionResult? {
        lock.withLock { calledOnMainThread = Thread.isMainThread }
        guard let start = sample.points.first, let end = sample.points.last else { return nil }
        return RecognitionResult(geometry: .line(.init(start: start, end: end)), confidence: 1)
    }
}

private final class CancellationAwareRecognizer: @unchecked Sendable, ShapeRecognizing {
    let started = XCTestExpectation(description: "recognition started")
    let cancelled = XCTestExpectation(description: "recognition observed cancellation")

    private let lock = NSLock()
    private var didObserveCancellation = false

    var observedCancellation: Bool {
        lock.withLock { didObserveCancellation }
    }

    func recognize(_ sample: StrokeSample) -> RecognitionResult? {
        started.fulfill()
        for _ in 0 ..< 1_000 {
            if Task.isCancelled {
                lock.withLock { didObserveCancellation = true }
                cancelled.fulfill()
                return nil
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return nil
    }
}

@MainActor
private final class MutableViewport {
    var value: CanvasViewport

    init(_ value: CanvasViewport) {
        self.value = value
    }
}

@MainActor
private func eventually(
    timeout: Duration = .seconds(1),
    condition: @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

@MainActor
private final class RecordingRenderer: CanvasRenderer {
    let renderView = UIView()
    var snapshots: [CanvasPreparedScene] = []

    func makeRenderView() -> UIView { renderView }

    func update(_ snapshot: CanvasPreparedScene, in renderView: UIView) {
        XCTAssertTrue(renderView === self.renderView)
        snapshots.append(snapshot)
    }
}

@MainActor
private final class RecordingPencilPalettePresenter: CanvasPencilPalettePresenting {
    private(set) var presentedAction: CanvasPencilShortcutAction?
    private(set) var lastAnchor: CanvasPoint?
    private(set) weak var lastHostView: UIView?
    private(set) var lastStyleTool: CanvasTool?
    private(set) var dismissCount = 0

    func toggle(
        _ action: CanvasPencilShortcutAction,
        anchor: CanvasPoint,
        hostView: UIView,
        actions: CanvasActions,
        styleTool: CanvasTool
    ) {
        presentedAction = action
        lastAnchor = anchor
        lastHostView = hostView
        lastStyleTool = styleTool
    }

    func dismiss() {
        presentedAction = nil
        dismissCount += 1
    }
}

private extension CanvasPreparedScene {
    var containsPreviewNode: Bool {
        geometry.contains {
            if case .preview = $0.renderKey { return true }
            return false
        }
    }
}

private func XCTAssertPencilFree(
    _ input: CanvasInput,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    switch input {
    case .pencilDown, .pencilMoved, .pencilUp, .pencilCancelled, .pencilHover:
        XCTFail("UIKit touch recognizer synthesized Pencil input", file: file, line: line)
    default:
        break
    }
}

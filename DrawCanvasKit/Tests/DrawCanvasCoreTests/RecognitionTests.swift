import XCTest
@testable import DrawCanvasCore

final class RecognitionTests: XCTestCase {
    func testSimplifierStopsAdversarialWorkAtItsBudget() {
        let points = (0..<50_000).map { index in
            CanvasPoint(x: Double(index), y: index.isMultiple(of: 2) ? 1 : -1)
        }

        XCTAssertNil(PathSimplifier.simplify(points, tolerance: 0, operationBudget: 1_000))
    }

    func testSimplifierKeepsEndpointsAndRetainsMaximumDeviationInInputOrder() {
        let points = [
            CanvasPoint(x: 0, y: 0),
            .init(x: 1, y: 0.1),
            .init(x: 2, y: 3),
            .init(x: 3, y: 0.1),
            .init(x: 4, y: 0),
        ]

        XCTAssertEqual(
            PathSimplifier.simplify(points, tolerance: 1),
            [points[0], points[2], points[4]]
        )
    }

    func testSimplifierTreatsZeroLengthBaselineAsPointDistance() {
        let points = [
            CanvasPoint(x: 0, y: 0),
            .init(x: 3, y: 4),
            .init(x: 0, y: 0),
        ]

        XCTAssertEqual(PathSimplifier.simplify(points, tolerance: 4), points)
        XCTAssertEqual(
            PathSimplifier.simplify(points, tolerance: 5),
            [points[0], points[2]]
        )
    }

    func testSimplifierHandlesEmptySingletonAndInvalidToleranceSafely() {
        let point = CanvasPoint(x: 2, y: 3)

        XCTAssertEqual(PathSimplifier.simplify([], tolerance: 1), [])
        XCTAssertEqual(PathSimplifier.simplify([point], tolerance: 1), [point])
        XCTAssertEqual(PathSimplifier.simplify([point, point], tolerance: .nan), [point, point])
        XCTAssertEqual(PathSimplifier.simplify([point, point], tolerance: -1), [point, point])
    }

    func testSimplifierRetainsLargeTranslatedDeviationWithoutProductOverflow() {
        let points = [
            CanvasPoint(x: 1e200, y: 1e200),
            .init(x: 1e200 + 5e190, y: 1e200 + 1e190),
            .init(x: 1e200 + 1e191, y: 1e200),
        ]

        XCTAssertEqual(PathSimplifier.simplify(points, tolerance: 1e189), points)
    }

    func testFifteenToTwentyPointLineIsRecognizedAsLine() {
        let points = [CanvasPoint(x: 0, y: 0), .init(x: 8, y: 0), .init(x: 16, y: 0)]

        XCTAssertEqual(HeuristicShapeRecognizer().recognize(.init(points: points))?.geometry.kind, .line)
    }

    func testQuarterArcNeverProducesEmptyReplacement() {
        let points = stride(from: 0.0, through: Double.pi / 2, by: 0.05).map {
            CanvasPoint(x: 100 + 50 * cos($0), y: 100 + 50 * sin($0))
        }

        guard let result = HeuristicShapeRecognizer().recognize(.init(points: points)) else {
            return XCTFail("Expected the quarter arc to be recognized")
        }
        XCTAssertEqual(result.geometry.kind, .arch)
        XCTAssertFalse(result.geometry.renderPath.commands.isEmpty)
        XCTAssertTrue(result.geometry.bounds.isFinite)
    }

    func testAmbiguousArcFallsBackToNilInsteadOfEmptyGeometry() {
        let points = [
            CanvasPoint(x: 0, y: 0),
            .init(x: 40, y: 40),
            .init(x: 80, y: 5),
            .init(x: 120, y: 50),
        ]

        XCTAssertNil(HeuristicShapeRecognizer().recognize(.init(points: points)))
    }

    func testNoisyHorizontalAndDiagonalLinesAreRecognizedAsLines() {
        let horizontal = (0 ... 20).map {
            CanvasPoint(x: Double($0) * 5, y: $0.isMultiple(of: 2) ? 0.5 : -0.5)
        }
        let diagonal = (0 ... 20).map {
            CanvasPoint(
                x: Double($0) * 4,
                y: Double($0) * 4 + ($0.isMultiple(of: 2) ? 0.6 : -0.6)
            )
        }
        let recognizer = HeuristicShapeRecognizer()

        XCTAssertEqual(recognizer.recognize(.init(points: horizontal))?.geometry.kind, .line)
        XCTAssertEqual(recognizer.recognize(.init(points: diagonal))?.geometry.kind, .line)
    }

    func testExactLargeLineIsRecognizedWhenSquaredLengthWouldOverflow() {
        let points = [
            CanvasPoint(x: 0, y: 0),
            .init(x: 5e199, y: 0),
            .init(x: 1e200, y: 0),
        ]

        XCTAssertEqual(
            HeuristicShapeRecognizer().recognize(.init(points: points))?.geometry.kind,
            .line
        )
    }

    func testClosedRectangleIsRecognizedAsRectangle() {
        let points = [
            CanvasPoint(x: 10, y: 10),
            .init(x: 50, y: 10.5),
            .init(x: 90, y: 10),
            .init(x: 90.5, y: 40),
            .init(x: 90, y: 70),
            .init(x: 50, y: 69.5),
            .init(x: 10, y: 70),
            .init(x: 9.5, y: 40),
            .init(x: 10.5, y: 10.5),
        ]

        let result = HeuristicShapeRecognizer().recognize(.init(points: points))

        XCTAssertEqual(result?.geometry.kind, .rectangle)
        XCTAssertEqual(result?.geometry.bounds, CanvasRect(x: 9.5, y: 10, width: 81, height: 60))
    }

    func testCornerOnlyClosedRectangleIsRecognizedAsRectangle() {
        let points = [
            CanvasPoint(x: 0, y: 0),
            .init(x: 80, y: 0),
            .init(x: 80, y: 0),
            .init(x: 80, y: 50),
            .init(x: 0, y: 50),
            .init(x: 0, y: 0),
        ]

        XCTAssertEqual(
            HeuristicShapeRecognizer().recognize(.init(points: points))?.geometry.kind,
            .rectangle
        )
    }

    func testSelfIntersectingBowTieIsNotRecognizedAsRectangle() {
        let points = [
            CanvasPoint(x: 0, y: 0),
            .init(x: 100, y: 100),
            .init(x: 100, y: 0),
            .init(x: 0, y: 100),
            .init(x: 0, y: 0),
        ]

        XCTAssertNil(HeuristicShapeRecognizer().recognize(.init(points: points)))
    }

    func testBacktrackingPathThatNeverTraversesRightSideIsNotRectangle() {
        let points = [
            CanvasPoint(x: 0, y: 0),
            .init(x: 100, y: 0),
            .init(x: 0, y: 0),
            .init(x: 0, y: 100),
            .init(x: 100, y: 100),
            .init(x: 0, y: 100),
            .init(x: 0, y: 0),
        ]

        XCTAssertNil(HeuristicShapeRecognizer().recognize(.init(points: points)))
    }

    func testRepeatedCornerCannotCountAnUntraversedSide() {
        let points = [
            CanvasPoint(x: 0, y: 0),
            .init(x: 100, y: 0),
            .init(x: 100, y: 0),
            .init(x: 0, y: 0),
            .init(x: 0, y: 100),
            .init(x: 100, y: 100),
            .init(x: 0, y: 100),
            .init(x: 0, y: 0),
        ]

        XCTAssertNil(HeuristicShapeRecognizer().recognize(.init(points: points)))
    }

    func testRandomZigzagIsNotRecognized() {
        let points = [
            CanvasPoint(x: 0, y: 0),
            .init(x: 15, y: 35),
            .init(x: 30, y: -20),
            .init(x: 45, y: 45),
            .init(x: 60, y: -10),
            .init(x: 75, y: 30),
            .init(x: 90, y: -30),
        ]

        XCTAssertNil(HeuristicShapeRecognizer().recognize(.init(points: points)))
    }

    func testRepeatedPointsDoNotPreventLineRecognition() {
        let points = [
            CanvasPoint(x: 0, y: 0),
            .init(x: 0, y: 0),
            .init(x: 20, y: 20),
            .init(x: 20, y: 20),
            .init(x: 40, y: 40),
        ]

        XCTAssertEqual(HeuristicShapeRecognizer().recognize(.init(points: points))?.geometry.kind, .line)
    }

    func testAllEqualPointsAreRejected() {
        let points = Array(repeating: CanvasPoint(x: 7, y: 7), count: 8)

        XCTAssertNil(HeuristicShapeRecognizer().recognize(.init(points: points)))
    }

    func testNonfinitePointsAreRejected() {
        for points in [
            [CanvasPoint(x: 0, y: 0), .init(x: .nan, y: 1), .init(x: 10, y: 10)],
            [CanvasPoint(x: 0, y: 0), .init(x: 5, y: .infinity), .init(x: 10, y: 10)],
        ] {
            XCTAssertNil(HeuristicShapeRecognizer().recognize(.init(points: points)))
        }
    }

    func testRecognitionIsDeterministic() {
        let points = (0 ... 20).map {
            CanvasPoint(x: Double($0) * 5, y: $0.isMultiple(of: 2) ? 0.25 : -0.25)
        }
        let recognizer = HeuristicShapeRecognizer()
        let expected = recognizer.recognize(.init(points: points))

        XCTAssertNotNil(expected)
        for _ in 0..<20 {
            XCTAssertEqual(recognizer.recognize(.init(points: points)), expected)
        }
    }
}

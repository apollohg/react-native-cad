import XCTest
import CadCanvasCore
@testable import CadCanvasUI

final class CanvasGridPlannerTests: XCTestCase {
    func testRoundedExactBoundaryDoesNotForceDecimation() throws {
        let baseSpacing = 0.003
        let extent = baseSpacing * 3

        let plan = try CanvasGridPlanner.plan(
            visibleRect: .init(x: 0, y: 0, width: extent, height: extent),
            baseSpacing: baseSpacing,
            maximumLineCount: 6
        )

        XCTAssertEqual(plan.visualSpacing, baseSpacing)
        assertCoordinatesEqual(
            plan.verticalCoordinates,
            [0, 0.003, 0.006],
            accuracy: baseSpacing.ulp * 2
        )
        assertCoordinatesEqual(
            plan.horizontalCoordinates,
            [0, 0.003, 0.006],
            accuracy: baseSpacing.ulp * 2
        )
    }

    func testSparseTranslatedGridKeepsTheSingleVisibleLine() throws {
        let plan = try CanvasGridPlanner.plan(
            visibleRect: .init(x: -10, y: 40, width: 20, height: 20),
            baseSpacing: 100,
            maximumLineCount: 100
        )
        XCTAssertEqual(plan.verticalCoordinates, [0])
        XCTAssertEqual(plan.horizontalCoordinates, [])
        XCTAssertEqual(plan.visualSpacing, 100)
    }

    func testDenseGridUsesAlignedPowerOfTwoMultiple() throws {
        let plan = try CanvasGridPlanner.plan(
            visibleRect: .init(x: 0, y: 0, width: 1_000, height: 1_000),
            baseSpacing: 1,
            maximumLineCount: 100
        )
        XCTAssertEqual(plan.visualSpacing / plan.baseSpacing, 32)
        XCTAssertLessThanOrEqual(
            plan.verticalCoordinates.count + plan.horizontalCoordinates.count,
            100
        )
        XCTAssertTrue(plan.verticalCoordinates.allSatisfy { $0.truncatingRemainder(dividingBy: 1) == 0 })
    }

    func testPositiveAndNegativeExactBoundariesAreHalfOpen() throws {
        let cases: [(rect: CanvasRect, vertical: [Double], horizontal: [Double])] = [
            (
                .init(x: 0, y: 10, width: 20, height: 20),
                [0, 10],
                [10, 20]
            ),
            (
                .init(x: -20, y: -10, width: 20, height: 20),
                [-20, -10],
                [-10, 0]
            ),
        ]

        for testCase in cases {
            let plan = try CanvasGridPlanner.plan(
                visibleRect: testCase.rect,
                baseSpacing: 10,
                maximumLineCount: 10
            )
            XCTAssertEqual(plan.verticalCoordinates, testCase.vertical)
            XCTAssertEqual(plan.horizontalCoordinates, testCase.horizontal)
        }
    }

    func testZeroLengthAxesHaveNoCoordinates() throws {
        let cases: [(rect: CanvasRect, vertical: [Double], horizontal: [Double])] = [
            (
                .init(x: 10, y: 20, width: 0, height: 20),
                [],
                [20, 30]
            ),
            (
                .init(x: 10, y: 20, width: 20, height: 0),
                [10, 20],
                []
            ),
        ]

        for testCase in cases {
            let plan = try CanvasGridPlanner.plan(
                visibleRect: testCase.rect,
                baseSpacing: 10,
                maximumLineCount: 10
            )
            XCTAssertEqual(plan.verticalCoordinates, testCase.vertical)
            XCTAssertEqual(plan.horizontalCoordinates, testCase.horizontal)
        }
    }

    func testInvalidRectanglesAreRejected() {
        let invalidRectangles: [CanvasRect] = [
            .init(x: .nan, y: 0, width: 10, height: 10),
            .init(x: 0, y: .infinity, width: 10, height: 10),
            .init(x: 0, y: 0, width: -1, height: 10),
            .init(x: 0, y: 0, width: 10, height: -1),
            .init(x: .greatestFiniteMagnitude, y: 0, width: .greatestFiniteMagnitude, height: 10),
        ]

        for rect in invalidRectangles {
            XCTAssertThrowsError(
                try CanvasGridPlanner.plan(
                    visibleRect: rect,
                    baseSpacing: 10,
                    maximumLineCount: 10
                )
            ) { error in
                XCTAssertEqual(error as? CanvasGridPlannerError, .invalidVisibleRect)
            }
        }
    }

    func testInvalidSpacingsAreRejected() {
        let invalidSpacings: [Double] = [
            .nan,
            .infinity,
            0,
            -1,
            .leastNonzeroMagnitude,
        ]

        for spacing in invalidSpacings {
            XCTAssertThrowsError(
                try CanvasGridPlanner.plan(
                    visibleRect: .init(x: 0, y: 0, width: 10, height: 10),
                    baseSpacing: spacing,
                    maximumLineCount: 10
                )
            ) { error in
                XCTAssertEqual(error as? CanvasGridPlannerError, .invalidSpacing)
            }
        }
    }

    func testNonpositiveLineBudgetsAreRejected() {
        for budget in [0, -1] {
            XCTAssertThrowsError(
                try CanvasGridPlanner.plan(
                    visibleRect: .init(x: 0, y: 0, width: 10, height: 10),
                    baseSpacing: 10,
                    maximumLineCount: budget
                )
            ) { error in
                XCTAssertEqual(error as? CanvasGridPlannerError, .invalidLineBudget)
            }
        }
    }

    func testExtremeIndexCountDecimatesWithoutConversionOverflow() throws {
        let plan = try CanvasGridPlanner.plan(
            visibleRect: .init(
                x: 0,
                y: 1,
                width: .greatestFiniteMagnitude,
                height: 0
            ),
            baseSpacing: 1,
            maximumLineCount: 2
        )

        XCTAssertTrue(plan.visualSpacing.isFinite)
        XCTAssertEqual(plan.verticalCoordinates.count, 2)
        XCTAssertEqual(plan.horizontalCoordinates, [])
    }

    func testSpacingMultiplicationOverflowThrowsTypedError() {
        XCTAssertThrowsError(
            try CanvasGridPlanner.plan(
                visibleRect: .init(x: 0, y: 0, width: 1, height: 1),
                baseSpacing: .greatestFiniteMagnitude,
                maximumLineCount: 1
            )
        ) { error in
            XCTAssertEqual(error as? CanvasGridPlannerError, .invalidSpacing)
        }
    }

    func testTightBudgetUsesSmallestFittingPowerOfTwoSpacing() throws {
        let plan = try CanvasGridPlanner.plan(
            visibleRect: .init(x: 0, y: 0, width: 100, height: 100),
            baseSpacing: 10,
            maximumLineCount: 2
        )

        XCTAssertEqual(plan.visualSpacing, 160)
        XCTAssertEqual(plan.verticalCoordinates, [0])
        XCTAssertEqual(plan.horizontalCoordinates, [0])
    }

    func testEveryEmittedPlanRespectsItsLineBudget() throws {
        let cases: [(rect: CanvasRect, spacing: Double, budget: Int)] = [
            (.init(x: -101, y: -51, width: 203, height: 107), 7, 13),
            (.init(x: 0, y: 0, width: 1_000, height: 1), 0.25, 17),
            (.init(x: -10, y: 40, width: 20, height: 20), 100, 2),
            (.init(x: 0, y: 0, width: 0.009, height: 0.009), 0.003, 6),
        ]

        for testCase in cases {
            let plan = try CanvasGridPlanner.plan(
                visibleRect: testCase.rect,
                baseSpacing: testCase.spacing,
                maximumLineCount: testCase.budget
            )
            XCTAssertLessThanOrEqual(
                plan.verticalCoordinates.count + plan.horizontalCoordinates.count,
                testCase.budget
            )
        }
    }

    private func assertCoordinatesEqual(
        _ actual: [Double],
        _ expected: [Double],
        accuracy: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (actualCoordinate, expectedCoordinate) in zip(actual, expected) {
            XCTAssertEqual(
                actualCoordinate,
                expectedCoordinate,
                accuracy: accuracy,
                file: file,
                line: line
            )
        }
    }
}

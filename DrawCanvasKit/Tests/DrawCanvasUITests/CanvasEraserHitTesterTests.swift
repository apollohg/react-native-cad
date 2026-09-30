import XCTest
import DrawCanvasCore
@testable import DrawCanvasUI

final class CanvasEraserHitTesterTests: XCTestCase {
    func testHoverReturnsTopmostElementAndSweepReturnsFrontToBack() throws {
        let back = CanvasElement.rectangle(
            id: UUID(),
            rect: .init(x: 0, y: 0, width: 100, height: 100)
        )
        let front = CanvasElement(
            id: UUID(),
            geometry: .line(.init(start: .init(x: 50, y: 0), end: .init(x: 50, y: 100)))
        )
        let viewport = try CanvasViewport.identity(size: .init(width: 100, height: 100))

        XCTAssertEqual(
            CanvasEraserHitTester.hoverTarget(
                at: .init(x: 50, y: 50),
                elements: [back, front],
                viewport: viewport,
                toleranceScreen: 8
            ),
            front.id
        )
        XCTAssertEqual(
            CanvasEraserHitTester.sweptTargets(
                from: .init(x: 0, y: 50),
                to: .init(x: 100, y: 50),
                elements: [back, front],
                viewport: viewport,
                toleranceScreen: 8
            ),
            [front.id, back.id]
        )
    }

    func testToleranceRemainsScreenSizedAcrossZoom() throws {
        let line = CanvasElement(
            id: UUID(),
            geometry: .line(.init(start: .init(x: 0, y: 0), end: .init(x: 100, y: 0)))
        )
        let viewport = try CanvasViewport(
            zoom: 4,
            translation: .init(x: 0, y: 0),
            viewportSize: .init(width: 100, height: 100)
        )

        XCTAssertEqual(
            CanvasEraserHitTester.hoverTarget(
                at: .init(x: 50, y: 1.9),
                elements: [line],
                viewport: viewport,
                toleranceScreen: 8
            ),
            line.id
        )
        XCTAssertNil(CanvasEraserHitTester.hoverTarget(
            at: .init(x: 50, y: 2.1),
            elements: [line],
            viewport: viewport,
            toleranceScreen: 8
        ))
    }
}

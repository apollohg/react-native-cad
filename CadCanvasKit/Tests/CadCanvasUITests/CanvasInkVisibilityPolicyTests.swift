import CadCanvasCore
import XCTest
@testable import CadCanvasUI

final class CanvasInkVisibilityPolicyTests: XCTestCase {
    func testMinimumPressureIsAtLeastOnePhysicalPixelAtRepresentativeScales() throws {
        let vertex = CanvasInkVertex(point: .init(x: 10, y: 20), widthFactor: 0.2)

        for scale in [1.0, 2.0, 4.0] {
            let result = try CanvasInkVisibilityPolicy.apply(
                to: [vertex],
                lineWidth: 1,
                pixelsPerCanvasUnit: scale,
                pressureEnabled: true
            )
            let physicalWidth = try XCTUnwrap(result.first).widthFactor * scale
            XCTAssertGreaterThanOrEqual(physicalWidth, 1)
        }
    }

    func testWidthsAboveFloorArePreserved() throws {
        let vertices = [
            CanvasInkVertex(point: .init(x: 0, y: 0), widthFactor: 0.2),
            CanvasInkVertex(point: .init(x: 1, y: 0), widthFactor: 0.75),
            CanvasInkVertex(point: .init(x: 2, y: 0), widthFactor: 1),
        ]

        let result = try CanvasInkVisibilityPolicy.apply(
            to: vertices,
            lineWidth: 1,
            pixelsPerCanvasUnit: 2,
            pressureEnabled: true
        )

        XCTAssertEqual(result.map(\.widthFactor), [0.5, 0.75, 1])
    }

    func testPressureDisabledInkIsUnchanged() throws {
        let vertices = [CanvasInkVertex(
            point: .init(x: 0, y: 0),
            widthFactor: 0.2
        )]

        let result = try CanvasInkVisibilityPolicy.apply(
            to: vertices,
            lineWidth: 1,
            pixelsPerCanvasUnit: 1,
            pressureEnabled: false
        )

        XCTAssertEqual(result, vertices)
    }
}

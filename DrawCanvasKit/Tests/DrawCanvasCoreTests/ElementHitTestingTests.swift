import XCTest
@testable import DrawCanvasCore

final class ElementHitTestingTests: XCTestCase {
    func testCanvasScaledFreehandHitExtentGrowsWithZoom() throws {
        func element(widthMode: CanvasInkWidthMode) -> CanvasElement {
            CanvasElement(
                id: UUID(),
                geometry: .freehand(.init(
                    samples: [
                        .init(point: .init(x: 0, y: 0), pressure: 1),
                        .init(point: .init(x: 20, y: 0), pressure: 1),
                    ],
                    pressureEnabled: true,
                    widthMode: widthMode
                )),
                style: .init(stroke: .black, lineWidth: 4)
            )
        }
        let viewport = try CanvasViewport(
            zoom: 2,
            translation: .init(x: 0, y: 0),
            viewportSize: .init(width: 100, height: 100)
        )

        XCTAssertTrue(element(widthMode: .canvasScaled).hitTest(
            .init(x: 10, y: 3.4),
            tolerance: 0,
            viewport: viewport
        ))
        XCTAssertFalse(element(widthMode: .screenConstant).hitTest(
            .init(x: 10, y: 3.4),
            tolerance: 0,
            viewport: viewport
        ))
    }

    func testCanvasElementHitWidthUsesPressureMode() throws {
        func element(pressureEnabled: Bool) -> CanvasElement {
            CanvasElement(
                id: UUID(),
                geometry: .freehand(.init(
                    samples: [
                        .init(point: .init(x: 0, y: 0), pressure: 1),
                        .init(point: .init(x: 20, y: 0), pressure: 1),
                    ],
                    pressureEnabled: pressureEnabled
                )),
                style: .init(stroke: .black, lineWidth: 4)
            )
        }
        let viewport = try CanvasViewport.identity(size: .init(width: 100, height: 100))

        XCTAssertTrue(element(pressureEnabled: true).hitTest(
            .init(x: 10, y: 3.4),
            tolerance: 0,
            viewport: viewport
        ))
        XCTAssertFalse(element(pressureEnabled: false).hitTest(
            .init(x: 10, y: 3.4),
            tolerance: 0,
            viewport: viewport
        ))
    }

    func testSweptSegmentHitsEveryCanvasGeometryKind() {
        let sweepStart = CanvasPoint(x: 0, y: 50)
        let sweepEnd = CanvasPoint(x: 100, y: 50)
        let geometries: [CanvasGeometry] = [
            .line(.init(start: .init(x: 50, y: 0), end: .init(x: 50, y: 100))),
            .rectangle(.init(rect: .init(x: 40, y: 40, width: 20, height: 20))),
            .arch(.init(start: .init(x: 25, y: 50), end: .init(x: 75, y: 50), sagitta: 20)),
            .freehand(.init(
                samples: [
                    .init(point: .init(x: 50, y: 0), pressure: 1),
                    .init(point: .init(x: 50, y: 100), pressure: 1),
                ],
                pressureEnabled: false
            )),
            .text(.init(
                frame: .init(x: 40, y: 40, width: 20, height: 20),
                text: "Text",
                font: .init(familyName: "Helvetica", pointSize: 14),
                color: .black
            )),
        ]

        for geometry in geometries {
            XCTAssertTrue(geometry.hitTest(
                segmentFrom: sweepStart,
                to: sweepEnd,
                tolerance: 2,
                textBounds: geometry.bounds
            ), "Expected a swept hit for \(geometry.kind)")
        }
    }

    func testZeroLengthSweepMatchesPointHitAndRejectsInvalidInput() {
        let geometry = CanvasGeometry.line(.init(
            start: .init(x: 0, y: 0),
            end: .init(x: 100, y: 0)
        ))
        let point = CanvasPoint(x: 50, y: 1)

        XCTAssertEqual(
            geometry.hitTest(segmentFrom: point, to: point, tolerance: 2, textBounds: nil),
            geometry.hitTest(point, tolerance: 2, textBounds: nil)
        )
        XCTAssertFalse(geometry.hitTest(
            segmentFrom: .init(x: .nan, y: 0),
            to: point,
            tolerance: 2,
            textBounds: nil
        ))
        XCTAssertFalse(geometry.hitTest(
            segmentFrom: point,
            to: point,
            tolerance: -1,
            textBounds: nil
        ))
    }

    func testCubicUsesFlattenedCurveRatherThanControlBounds() {
        let path = CanvasPath(commands: [
            .move(.init(x: 0, y: 0)),
            .cubic(
                control1: .init(x: 0, y: 100),
                control2: .init(x: 100, y: 100),
                end: .init(x: 100, y: 0)
            ),
        ])

        XCTAssertFalse(path.hitTest(
            segmentFrom: .init(x: 25, y: 90),
            to: .init(x: 75, y: 90),
            tolerance: 1
        ))
    }
}

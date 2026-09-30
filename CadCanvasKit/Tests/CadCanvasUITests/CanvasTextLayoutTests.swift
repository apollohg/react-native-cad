import XCTest
import CadCanvasCore
@testable import CadCanvasUI

@MainActor
final class CanvasTextLayoutTests: XCTestCase {
    func testLeftAndRightResizeAnchorTheOppositeEdgeAndAutoFitHeight() throws {
        let engine = CanvasTextLayoutEngine()
        let text = CanvasText(
            frame: .init(x: 100, y: 20, width: 120, height: 24),
            text: "This value wraps over several words",
            font: .init(familyName: "Helvetica", pointSize: 18),
            color: .black
        )
        let element = CanvasElement(id: UUID(), geometry: .text(text))
        let viewport = try! CanvasViewport.identity(size: .init(width: 600, height: 400))

        let right = try engine.resizedElement(
            element,
            edge: .right,
            cumulativeScreenDelta: .init(x: -60, y: 0),
            viewport: viewport
        )
        XCTAssertEqual(right.bounds.minX, element.bounds.minX)
        XCTAssertEqual(right.bounds.width, 60)
        XCTAssertGreaterThan(right.bounds.height, element.bounds.height)

        let left = try engine.resizedElement(
            element,
            edge: .left,
            cumulativeScreenDelta: .init(x: 40, y: 0),
            viewport: viewport
        )
        XCTAssertEqual(left.bounds.maxX, element.bounds.maxX)
        XCTAssertEqual(left.bounds.width, 80)
    }

    func testResizeUsesOnlyCumulativeScreenXAtStartZoomAndIncrementsOnce() throws {
        let engine = CanvasTextLayoutEngine()
        let element = CanvasElement(
            id: UUID(),
            contentRevision: 7,
            geometry: .text(.init(
                frame: .init(x: 20, y: 30, width: 100, height: 24),
                text: "Width only resize ignores vertical motion",
                font: .init(familyName: "Helvetica", pointSize: 16),
                color: .black
            ))
        )
        let viewport = try! CanvasViewport(
            zoom: 2,
            translation: .init(x: 500, y: -300),
            viewportSize: .init(width: 600, height: 400)
        )

        let resized = try engine.resizedElement(
            element,
            edge: .right,
            cumulativeScreenDelta: .init(x: -40, y: 10_000),
            viewport: viewport
        )

        XCTAssertEqual(resized.bounds.x, 20)
        XCTAssertEqual(resized.bounds.width, 80)
        XCTAssertEqual(resized.contentRevision, 8)
        XCTAssertEqual(element.contentRevision, 7)
    }

    func testResizeClampsToOneResolvedFontEmAndRejectsInvalidInputs() throws {
        let engine = CanvasTextLayoutEngine()
        let element = CanvasElement(
            id: UUID(),
            geometry: .text(.init(
                frame: .init(x: 10, y: 20, width: 80, height: 24),
                text: "Minimum width",
                font: .init(familyName: "Helvetica", pointSize: 18),
                color: .black
            ))
        )
        let viewport = try! CanvasViewport.identity(size: .init(width: 600, height: 400))

        let left = try engine.resizedElement(
            element,
            edge: .left,
            cumulativeScreenDelta: .init(x: 1_000, y: 0),
            viewport: viewport
        )
        XCTAssertEqual(left.bounds.width, 18)
        XCTAssertEqual(left.bounds.maxX, element.bounds.maxX)

        XCTAssertThrowsError(try engine.resizedElement(
            element,
            edge: .right,
            cumulativeScreenDelta: .init(x: .nan, y: 0),
            viewport: viewport
        ))

        var exhausted = element
        exhausted.contentRevision = .max
        XCTAssertThrowsError(try engine.resizedElement(
            exhausted,
            edge: .right,
            cumulativeScreenDelta: .init(x: 10, y: 0),
            viewport: viewport
        ))
    }

    func testNaturalWidthAndConstrainedWidthUseMeasuredAutomaticHeight() throws {
        let engine = CanvasTextLayoutEngine()
        let font = CanvasFont(familyName: "Helvetica", pointSize: 20)
        let natural = try engine.frame(
            origin: .init(x: 10, y: 20),
            text: "Wide text value",
            font: font,
            constrainedWidth: nil
        )
        let wrapped = try engine.frame(
            origin: .init(x: 10, y: 20),
            text: "Wide text value",
            font: font,
            constrainedWidth: natural.width / 2
        )

        XCTAssertGreaterThan(natural.width, 20)
        XCTAssertEqual(wrapped.width, natural.width / 2, accuracy: 0.001)
        XCTAssertGreaterThan(wrapped.height, natural.height)
    }

    func testMissingFontUsesTheSameSystemFallbackForMeasurement() throws {
        let engine = CanvasTextLayoutEngine()
        let frame = try engine.frame(
            origin: .init(x: 0, y: 0),
            text: "Fallback",
            font: .init(familyName: "Definitely Missing Font", pointSize: 18),
            constrainedWidth: 90
        )
        XCTAssertEqual(frame.width, 90)
        XCTAssertGreaterThan(frame.height, 0)
    }

    func testRealUIKitMeasurementCasesStayFiniteExactAndMonotonicWhenNarrowed() throws {
        let engine = CanvasTextLayoutEngine()
        let cases = [
            ("WWW", CanvasFont(familyName: "Helvetica", pointSize: 18)),
            ("iii", CanvasFont(familyName: "Helvetica", pointSize: 18)),
            ("e\u{301}", CanvasFont(familyName: "Helvetica", pointSize: 18)),
            ("👩🏽‍💻🙂", CanvasFont(familyName: "Helvetica", pointSize: 18)),
            ("first line\nsecond line", CanvasFont(familyName: "Helvetica", pointSize: 18)),
            ("", CanvasFont(familyName: "Helvetica", pointSize: 18)),
            ("fallback", CanvasFont(familyName: "Missing Task Seven Font", pointSize: 18)),
        ]

        for (value, font) in cases {
            let wide = try engine.frame(
                origin: .init(x: 3, y: 4),
                text: value,
                font: font,
                constrainedWidth: 140
            )
            let narrow = try engine.frame(
                origin: .init(x: 3, y: 4),
                text: value,
                font: font,
                constrainedWidth: 45
            )

            XCTAssertTrue(wide.isFinite, "wide: \(value)")
            XCTAssertTrue(narrow.isFinite, "narrow: \(value)")
            XCTAssertEqual(wide.width, 140, "wide: \(value)")
            XCTAssertEqual(narrow.width, 45, "narrow: \(value)")
            XCTAssertGreaterThan(wide.height, 0, "wide: \(value)")
            XCTAssertGreaterThanOrEqual(narrow.height, wide.height, "narrow: \(value)")
        }
    }
}

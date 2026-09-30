import XCTest
import DrawCanvasCore

final class PublicValidationErrorTests: XCTestCase {
    func testValidationRejectsDerivedRectangleOverflowAndDegenerateArches() throws {
        let overflowing = CanvasElement.rectangle(
            id: UUID(),
            rect: .init(
                x: .greatestFiniteMagnitude,
                y: 0,
                width: .greatestFiniteMagnitude,
                height: 10
            )
        )
        let flatArch = CanvasElement(
            id: UUID(),
            geometry: .arch(.init(
                start: .init(x: 0, y: 0),
                end: .init(x: 10, y: 0),
                sagitta: 0
            ))
        )

        XCTAssertThrowsError(try CanvasDocument(elements: [overflowing]).validate())
        XCTAssertThrowsError(try CanvasDocument(elements: [flatArch]).validate())
    }

    func testPublicValidationAPIsRejectInvalidNumericFamiliesWithTypedErrors() {
        let expected = CanvasValidationError(
            field: "elements[0].geometry.line.start.x",
            reason: "must be finite"
        )
        let invalid = CanvasDocument(elements: [
            CanvasElement(
                id: UUID(),
                geometry: .line(.init(
                    start: .init(x: .infinity, y: 0),
                    end: .init(x: 1, y: 1)
                ))
            ),
        ])

        requireSendable(expected)
        XCTAssertEqual(expected.description, "elements[0].geometry.line.start.x: must be finite")
        XCTAssertThrowsError(try invalid.validate()) { error in
            XCTAssertEqual(error as? CanvasValidationError, expected)
        }

        let invalidColors: [(CanvasColor, CanvasValidationError)] = [
            (.init(red: .nan, green: 0, blue: 0), .init(field: "color.red", reason: "must be finite")),
            (.init(red: 0, green: .infinity, blue: 0), .init(field: "color.green", reason: "must be finite")),
            (.init(red: 0, green: 0, blue: -0.1), .init(field: "color.blue", reason: "must be between zero and one")),
            (.init(red: 0, green: 0, blue: 0, alpha: 1.1), .init(field: "color.alpha", reason: "must be between zero and one")),
        ]
        for (color, expected) in invalidColors {
            assertValidationError(expected) { try color.validate() }
        }

        for pointSize in [Double.nan, .infinity, 0, -1] {
            let expected = CanvasValidationError(
                field: "font.pointSize",
                reason: pointSize.isFinite ? "must be greater than zero" : "must be finite"
            )
            assertValidationError(expected) {
                try CanvasFont(familyName: "Helvetica", pointSize: pointSize).validate()
            }
        }

        let invalidStyles: [(CanvasStyle, CanvasValidationError)] = [
            (.init(stroke: .black, lineWidth: .nan), .init(field: "style.lineWidth", reason: "must be finite")),
            (.init(stroke: .black, lineWidth: .infinity), .init(field: "style.lineWidth", reason: "must be finite")),
            (.init(stroke: .black, lineWidth: 0), .init(field: "style.lineWidth", reason: "must be greater than zero")),
            (.init(stroke: .black, lineWidth: -1), .init(field: "style.lineWidth", reason: "must be greater than zero")),
            (
                .init(stroke: .init(red: 1.1, green: 0, blue: 0), lineWidth: 1),
                .init(field: "style.stroke.red", reason: "must be between zero and one")
            ),
            (
                .init(stroke: .black, fill: .init(red: 0, green: .nan, blue: 0), lineWidth: 1),
                .init(field: "style.fill.green", reason: "must be finite")
            ),
        ]
        for (style, expected) in invalidStyles {
            assertValidationError(expected) { try style.validate() }
        }

        let invalidSnapConfigurations: [(SnapConfiguration, CanvasValidationError)] = [
            (.init(screenThreshold: .nan, gridSpacing: 10, snapToGrid: false), .init(field: "snapConfiguration.screenThreshold", reason: "must be finite")),
            (.init(screenThreshold: .infinity, gridSpacing: 10, snapToGrid: false), .init(field: "snapConfiguration.screenThreshold", reason: "must be finite")),
            (.init(screenThreshold: -1, gridSpacing: 10, snapToGrid: false), .init(field: "snapConfiguration.screenThreshold", reason: "must not be negative")),
            (.init(screenThreshold: 8, gridSpacing: .nan, snapToGrid: true), .init(field: "snapConfiguration.gridSpacing", reason: "must be finite")),
            (.init(screenThreshold: 8, gridSpacing: .infinity, snapToGrid: true), .init(field: "snapConfiguration.gridSpacing", reason: "must be finite")),
            (.init(screenThreshold: 8, gridSpacing: 0, snapToGrid: true), .init(field: "snapConfiguration.gridSpacing", reason: "must be greater than zero")),
            (.init(screenThreshold: 8, gridSpacing: -1, snapToGrid: true), .init(field: "snapConfiguration.gridSpacing", reason: "must be greater than zero")),
            (.init(screenThreshold: 8, gridSpacing: .leastNonzeroMagnitude, snapToGrid: true), .init(field: "snapConfiguration.gridSpacing", reason: "must be normal")),
        ]
        for (configuration, expected) in invalidSnapConfigurations {
            assertValidationError(expected) { try configuration.validate() }
        }
    }
}

private func requireSendable<T: Sendable>(_ value: T) {
    _ = value
}

private func assertValidationError(
    _ expected: CanvasValidationError,
    operation: () throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertThrowsError(try operation(), file: file, line: line) { error in
        XCTAssertEqual(error as? CanvasValidationError, expected, file: file, line: line)
    }
}

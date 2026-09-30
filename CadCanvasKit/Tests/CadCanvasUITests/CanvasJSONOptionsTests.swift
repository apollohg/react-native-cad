import XCTest
import CadCanvasCore
@testable import CadCanvasUI

@MainActor
final class CanvasJSONOptionsTests: XCTestCase {
    func testPartialOptionsPreserveDefaultsAndReplaceArrays() throws {
        let options = try CanvasJSONOptions.decode(#"{"configuration":{"enabledTools":["freehand"],"measurements":{"unit":"inches"}},"theme":{"background":{"red":0.2,"green":0.3,"blue":0.4,"alpha":1}}}"#)
        XCTAssertEqual(options.configuration.enabledTools, [.freehand])
        XCTAssertEqual(options.configuration.measurements.unit, .inches)
        XCTAssertEqual(options.configuration.controls, CanvasControlsConfiguration())
        XCTAssertEqual(options.theme.background.red, 0.2)
        XCTAssertEqual(options.theme.grid, CanvasTheme.default.grid)
    }

    func testInvalidOptionsDoNotMutateSession() throws {
        let session = CanvasSession()
        let before = session.configuration
        XCTAssertThrowsError(try CanvasJSONOptions.decode(#"{"configuration":{"measurements":{"fractionDigits":99}}}"#).apply(to: session))
        XCTAssertEqual(session.configuration, before)
        XCTAssertThrowsError(try CanvasJSONOptions.decode(#"{"configuration":{"controls":{"lineWidth":{"bounds":[20,1],"step":1}}}}"#))
        XCTAssertThrowsError(try CanvasJSONOptions.decode(#"{"strokeStyle":{"lineWidth":0}}"#))
    }

    func testNullFillAndConfigurationRoundTrip() throws {
        let options = try CanvasJSONOptions.decode(#"{"strokeStyle":{"fill":null},"inkConfiguration":{"widthMode":"screenConstant"},"configuration":{"measurements":{"roles":["overall"]}}}"#)
        XCTAssertNil(options.strokeStyle.fill)
        XCTAssertEqual(options.inkConfiguration.widthMode, .screenConstant)
        XCTAssertEqual(options.configuration.measurements.roles, [.overall])
        let session = CanvasSession()
        try options.apply(to: session)
        XCTAssertEqual(session.inkConfiguration, options.inkConfiguration)
    }
}

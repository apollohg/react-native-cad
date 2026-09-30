import XCTest

final class CADExpoSmokeTests: XCTestCase {
    func testCanvasOnlyHostHasNoBuiltInControls() {
        let app = XCUIApplication(bundleIdentifier: "com.apollohg.reactnativecad.example")
        app.launch()
        XCTAssertTrue(app.otherElements["cad-canvas"].waitForExistence(timeout: 30), app.debugDescription)
        for title in ["Stroke Style", "Save snapshot", "Restore snapshot", "Load sample", "Tools"] {
            XCTAssertFalse(app.buttons[title].exists, "Unexpected built-in control: \(title)")
            XCTAssertFalse(app.staticTexts[title].exists, "Unexpected built-in label: \(title)")
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

import XCTest

final class LectureClipUITests: XCTestCase {
    @MainActor
    func testLaunchAndEmptySessionControls() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["recordButton"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Download / Retry Parakeet V3"].exists)
        XCTAssertFalse(app.buttons["Quick Export + Copy"].isEnabled)
        XCTAssertFalse(app.buttons["Advanced Export"].isEnabled)
    }
}

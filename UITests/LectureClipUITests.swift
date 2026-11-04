import XCTest

final class LectureClipUITests: XCTestCase {
    @MainActor
    func testRecordAndExportAudioWithoutModel() {
        let app = XCUIApplication()
        addUIInterruptionMonitor(withDescription: "Microphone permission") { alert in
            for title in ["Allow", "OK"] where alert.buttons[title].exists {
                alert.buttons[title].tap()
                return true
            }
            return false
        }
        app.launch()
        app.buttons["recordButton"].tap()
        app.tap() // Lets XCTest handle a pending system microphone permission alert.
        XCTAssertTrue(app.buttons["Stop recording"].waitForExistence(timeout: 10))
        let advanced = app.buttons["Advanced Export"]
        let savedAudio = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: advanced)
        XCTAssertEqual(XCTWaiter.wait(for: [savedAudio], timeout: 15), .completed)
        app.buttons["recordButton"].tap()
        XCTAssertTrue(app.buttons["New recording"].waitForExistence(timeout: 10))
        advanced.tap()
        app.buttons["Export selected audio + transcript"].tap()
        XCTAssertTrue(app.buttons["Share clip"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["Quick Export + Copy"].isEnabled)
    }

    @MainActor
    func testLaunchControls() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["recordButton"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Download / Retry Parakeet V3"].exists)
    }
}

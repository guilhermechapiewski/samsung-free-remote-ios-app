import XCTest

/// Captures screenshots of demo mode (fictional TVs only). Run by `scripts/screenshots.sh`,
/// which exports the attachments below; skipped otherwise.
final class ScreenshotTests: XCTestCase {
    override func setUpWithError() throws {
        // Skipped in normal test runs (they only take pictures); the script sets this.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SAMSUNG_REMOTE_SCREENSHOTS"] == "1",
                          "Run by scripts/screenshots.sh")
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    @MainActor
    private func waitForRemote(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["TV picker"].waitForExistence(timeout: 10))
        let volumeUp = app.buttons["Volume up"]
        XCTAssertTrue(volumeUp.waitForExistence(timeout: 10))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: volumeUp)], timeout: 10)
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 1) // let animations settle
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testRemoteScreen() {
        let app = launch(["-demo"])
        waitForRemote(app)
        capture(app, "01-remote")
    }

    @MainActor
    func testPickerMenu() {
        let app = launch(["-demo", "-demo-choose"])
        XCTAssertTrue(app.staticTexts["Choose your TV"].waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Living Room'")).firstMatch.tap()
        waitForRemote(app)
        openMenu(app)
        XCTAssertTrue(app.buttons["Rename…"].waitForExistence(timeout: 5))
        capture(app, "02-picker")
    }

    @MainActor
    func testRenameSheet() {
        let app = launch(["-demo"])
        waitForRemote(app)
        openMenu(app)
        app.buttons["Rename…"].tap()
        XCTAssertTrue(app.textFields["TV name"].waitForExistence(timeout: 5))
        // A fresh simulator shows the keyboard's swipe-typing intro once; dismiss it.
        let intro = app.buttons["Continue"]
        if intro.waitForExistence(timeout: 3) { intro.tap() }
        capture(app, "03-rename")
    }
}

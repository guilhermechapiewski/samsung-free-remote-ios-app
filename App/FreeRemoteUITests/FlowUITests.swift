import XCTest

final class FlowUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testDemoRemoteIsUsable() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.launch()

        let picker = app.buttons["TV picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        if !(picker.value as? String ?? "").hasPrefix("Living Room") {
            picker.tap()
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Living Room'")).firstMatch.tap()
        }

        let volumeUp = app.buttons["Volume up"]
        XCTAssertTrue(volumeUp.waitForExistence(timeout: 10))
        let enabled = NSPredicate(format: "isEnabled == true")
        wait(for: [expectation(for: enabled, evaluatedWith: volumeUp)], timeout: 10)
        volumeUp.tap()
        XCTAssertTrue(app.buttons["Power"].exists)
    }
}

import XCTest

final class FlowUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ arguments: [String] = ["-demo"]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    /// Waits until the demo remote is connected to the living room TV.
    @MainActor
    private func waitForRemote(_ app: XCUIApplication) {
        let picker = app.buttons["TV picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        let volumeUp = app.buttons["Volume up"]
        XCTAssertTrue(volumeUp.waitForExistence(timeout: 10))
        let enabled = NSPredicate(format: "isEnabled == true")
        wait(for: [expectation(for: enabled, evaluatedWith: volumeUp)], timeout: 10)
    }

    /// The demo session's record of the last key sent (label) and how many were sent (value).
    @MainActor
    private func lastKey(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["demo-last-key"]
    }

    @MainActor
    private func waitForLastKey(_ app: XCUIApplication, _ key: String, count: Int? = nil,
                                file: StaticString = #filePath, line: UInt = #line) {
        let element = lastKey(app)
        var format = "label == %@"
        var args: [Any] = [key]
        if let count {
            format += " AND value == %@"
            args.append(String(count))
        }
        let predicate = NSPredicate(format: format, argumentArray: args)
        let result = XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: 5)
        XCTAssertEqual(result, .completed,
                       "last key \(element.label) (\(element.value as? String ?? "?")), expected \(key)",
                       file: file, line: line)
    }

    @MainActor
    func testDemoRemoteSendsKeys() {
        let app = launch()
        waitForRemote(app)
        XCTAssertTrue(app.buttons["Power"].exists)

        // A hold key tapped once sends exactly one key.
        app.buttons["Volume up"].tap()
        waitForLastKey(app, "KEY_VOLUP", count: 1)

        app.buttons["OK"].tap()
        waitForLastKey(app, "KEY_ENTER", count: 2)

        app.buttons["Channel down"].tap()
        waitForLastKey(app, "KEY_CHDOWN", count: 3)
    }

    @MainActor
    func testRenameUpdatesPicker() {
        let app = launch()
        waitForRemote(app)
        let picker = app.buttons["TV picker"]
        picker.tap()
        app.buttons["Rename…"].tap()

        let field = app.textFields["TV name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "Living Room")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'This name is only on your devices.'"))
            .firstMatch.exists)
        // Put the cursor at the end, then replace the name.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20) + "Den")
        app.buttons["Save"].tap()

        let renamed = NSPredicate(format: "value BEGINSWITH 'Den'")
        wait(for: [expectation(for: renamed, evaluatedWith: picker)], timeout: 5)
    }

    @MainActor
    func testNumberPadSendsDigits() {
        let app = launch()
        waitForRemote(app)
        app.buttons["Number pad"].tap()
        let five = app.buttons["5"]
        XCTAssertTrue(five.waitForExistence(timeout: 5))
        five.tap()
        waitForLastKey(app, "KEY_5", count: 1)
        app.buttons["0"].tap()
        waitForLastKey(app, "KEY_0", count: 2)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Volume up"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testAddTVRejectsPublicIP() {
        let app = launch()
        waitForRemote(app)
        app.buttons["TV picker"].tap()
        app.buttons["Add TV by IP Address…"].tap()

        let field = app.textFields["IP address"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("8.8.8.8")
        app.buttons["Add"].tap()
        XCTAssertTrue(app.staticTexts["Enter a local IP address like 192.168.0.20."].waitForExistence(timeout: 5))
    }

    @MainActor
    func testEmptyStateShowsScanAgain() {
        let app = launch(["-demo", "-demo-empty"])
        let scanAgain = app.buttons["Scan Again"]
        XCTAssertTrue(scanAgain.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Add TV by IP Address"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'No TVs found.'")).firstMatch.exists)
        scanAgain.tap()
        XCTAssertTrue(scanAgain.waitForExistence(timeout: 10))
    }

    @MainActor
    func testChooseTVSelectsTV() {
        let app = launch(["-demo", "-demo-choose"])
        XCTAssertTrue(app.staticTexts["Choose your TV"].waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Living Room'")).firstMatch.tap()
        waitForRemote(app)
    }
}

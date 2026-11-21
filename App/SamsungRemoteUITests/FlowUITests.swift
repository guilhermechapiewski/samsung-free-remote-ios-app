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

        // Number pad.
        app.buttons["Number pad"].tap()
        let five = app.buttons["5"]
        XCTAssertTrue(five.waitForExistence(timeout: 5))
        five.tap()
        waitForLastKey(app, "KEY_5", count: 4)
        app.buttons["0"].tap()
        waitForLastKey(app, "KEY_0", count: 5)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Volume up"].waitForExistence(timeout: 5))
    }

    /// The TV menu, end to end in one launch (each launch costs seconds): closing by tapping outside, TV
    /// Details, Scan Again (the menu stays open), then choosing another TV.
    @MainActor
    func testTVMenu() {
        let app = launch()
        waitForRemote(app)
        let picker = app.buttons["TV picker"]
        let close = app.buttons["Close menu"]

        openMenu(app)
        XCTAssertTrue(app.buttons["Feedback & Bug Reports"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Privacy Policy"].exists) // required in the app by App Review 5.1.1(i)
        attachScreenshot(app, "menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Volume up"].isHittable)

        // TV Details: each row reads as one element, "label, value".
        openMenu(app)
        app.buttons["TV Details"].tap()
        XCTAssertTrue(app.staticTexts["IP Address, 10.0.0.21"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Last Seen, Just now"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Resolution, 3840 × 2160 (4K)"].exists)
        attachScreenshot(app, "tv-details")
        app.buttons["Done"].tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 5))

        // Scan Again keeps the menu open; its header shows the progress, then the result.
        openMenu(app)
        app.buttons["Scan Again"].tap()
        XCTAssertTrue(app.staticTexts["Looking for TVs…"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Scanning…"].exists)
        XCTAssertTrue(app.staticTexts["No new TVs found"].waitForExistence(timeout: 10))
        attachScreenshot(app, "scan-result")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))

        // Can't Find Your TV? opens the help; its Scan Again closes the sheet and scans.
        openMenu(app)
        app.buttons["Can't Find Your TV?"].tap()
        let help = app.scrollViews["find-tv-help"]
        XCTAssertTrue(help.staticTexts["Turn on AirPlay on the TV."].waitForExistence(timeout: 5))
        help.buttons["Scan Again"].tap()
        XCTAssertTrue(help.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No new TVs found"].waitForExistence(timeout: 10))

        // Choosing another TV closes the menu.
        openMenu(app)

        // Choosing another TV closes the menu.
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Bedroom'")).firstMatch.tap()
        // The status line shows the connection happening, then confirms it (demo switches take a second).
        let status = app.descendants(matching: .any)["status"].firstMatch
        // Polled every 0.1 s: predicate expectations check about once a second and can miss a short state.
        XCTAssertTrue(status.waitForLabel("Connecting to Bedroom…", timeout: 5))
        attachScreenshot(app, "connecting")
        XCTAssertTrue(status.waitForLabel("Connected to Bedroom", timeout: 5))
        attachScreenshot(app, "connected")
        XCTAssertFalse(close.exists)
        XCTAssertTrue(picker.waitForValue(containing: "Bedroom", timeout: 5))
        // The demo Bedroom TV is in standby: the presence check soon shows it as off and asleep.
        XCTAssertTrue(status.waitForLabel("The TV is off", timeout: 8))
        XCTAssertTrue(picker.waitForValue(containing: "Asleep", timeout: 5))
        Thread.sleep(forTimeInterval: 0.5) // let the crossfade finish for the screenshot
        attachScreenshot(app, "tv-off")
    }

    @MainActor
    func testRenameUpdatesPicker() {
        let app = launch()
        waitForRemote(app)
        let picker = app.buttons["TV picker"]
        openMenu(app)
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
    func testAddTVRejectsPublicIP() {
        let app = launch()
        waitForRemote(app)
        openMenu(app)
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

        app.buttons["Can't Find Your TV?"].tap()
        let help = app.scrollViews["find-tv-help"]
        XCTAssertTrue(help.staticTexts["Restart the TV."].waitForExistence(timeout: 5))
        help.buttons["Add TV by IP Address"].tap()
        XCTAssertTrue(app.textFields["IP address"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testMenuScrollsAtLargestTextSize() {
        let app = launch(["-demo", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(app.buttons["TV picker"].waitForExistence(timeout: 10))
        openMenu(app)
        let lastRow = app.buttons["Privacy Policy"]
        XCTAssertTrue(lastRow.waitForExistence(timeout: 5))
        attachScreenshot(app, "menu-large-text")
        let panel = app.scrollViews.firstMatch
        for _ in 0..<6 where !lastRow.isHittable { panel.swipeUp() }
        XCTAssertTrue(lastRow.isHittable, "the last row must be reachable by scrolling")
        attachScreenshot(app, "menu-large-text-scrolled")

        // The help sheet scrolls to its last button at the largest text size.
        app.buttons["Close menu"].tap()
        XCTAssertTrue(app.buttons["Close menu"].waitForNonExistence(timeout: 5))
        openMenu(app)
        app.buttons["Can't Find Your TV?"].tap()
        let help = app.scrollViews["find-tv-help"]
        let addTV = help.buttons["Add TV by IP Address"]
        XCTAssertTrue(help.waitForExistence(timeout: 5))
        for _ in 0..<8 where !addTV.isHittable { help.swipeUp() }
        XCTAssertTrue(addTV.isHittable, "Add TV by IP Address must be reachable by scrolling")
        attachScreenshot(app, "find-tv-help-large-text")
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testChooseTVSelectsTV() {
        let app = launch(["-demo", "-demo-choose"])
        XCTAssertTrue(app.staticTexts["Choose your TV"].waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Living Room'")).firstMatch.tap()
        waitForRemote(app)
    }

    @MainActor
    func testTextEntrySheetAppearsAndDismisses() {
        let app = launch(["-demo", "-demo-keyboard"])
        let field = app.textFields["Text for the TV"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.typeText("hello")
        app.buttons["send-text"].tap()
        let lastText = app.descendants(matching: .any)["demo-last-text"]
        let sent = NSPredicate(format: "label == 'hello'")
        wait(for: [expectation(for: sent, evaluatedWith: lastText)], timeout: 5)

        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Volume up"].waitForExistence(timeout: 5))
        XCTAssertFalse(field.exists)
        // It does not reappear on its own.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(field.exists)
    }
}

/// Taps the TV card and waits for the menu panel, so the next tap never races its opening animation (the
/// app may not go idle while a status spinner runs, so XCUITest's own wait is not enough).
@MainActor
func openMenu(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    app.buttons["TV picker"].tap()
    XCTAssertTrue(app.buttons["Close menu"].waitForExistence(timeout: 5), "the TV menu did not open",
                  file: file, line: line)
}

private extension XCUIElement {
    /// Waits until the accessibility label equals `text`, checking every 0.1 s.
    func waitForLabel(_ text: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if exists, label == text { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    /// Waits until the accessibility value contains `text` (and not `excluding`, when given).
    func waitForValue(containing text: String, excluding: String? = nil, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let value = (self.value as? String) ?? ""
            if (text.isEmpty || value.contains(text)), excluding.map({ !value.contains($0) }) ?? true { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }
}

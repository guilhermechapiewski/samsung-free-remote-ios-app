import XCTest

final class LaunchTests: XCTestCase {
    @MainActor
    func testLaunchShowsPlaceholder() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Free Remote"].waitForExistence(timeout: 10))
    }
}

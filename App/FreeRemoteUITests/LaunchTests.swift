import XCTest

final class LaunchTests: XCTestCase {
    @MainActor
    func testLaunchShowsRemote() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["TV picker"].waitForExistence(timeout: 10))
    }
}

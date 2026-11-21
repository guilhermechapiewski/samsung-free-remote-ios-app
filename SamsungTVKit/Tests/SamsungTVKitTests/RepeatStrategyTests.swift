import Testing
@testable import SamsungTVKit

@Suite struct RepeatStrategyTests {
    @Test func defaultIsClickEvery100msAfter400ms() {
        #expect(RepeatStrategy.default == .clickEvery(.milliseconds(100), initialDelay: .milliseconds(400)))
        #expect(RepeatStrategy.default != .pressRelease)
    }
}

import Testing
@testable import SamsungTVKit

@Suite struct RepeatStrategyTests {
    @Test func defaultIsClickEvery150ms() {
        #expect(RepeatStrategy.default == .clickEvery(.milliseconds(150)))
        #expect(RepeatStrategy.default != .pressRelease)
    }
}

import Testing
@testable import SamsungTVKit

@Suite struct BackoffTests {
    @Test(arguments: [
        (0, Duration.milliseconds(500)),
        (1, Duration.seconds(1)),
        (2, Duration.seconds(2)),
        (3, Duration.seconds(4)),
        (6, Duration.seconds(30)),
        (10, Duration.seconds(30)),
        (1000, Duration.seconds(30)),
    ])
    func delayTable(attempt: Int, expected: Duration) {
        #expect(Backoff().delay(attempt: attempt) == expected)
    }

    @Test func negativeAttemptUsesBase() {
        #expect(Backoff().delay(attempt: -1) == .milliseconds(500))
    }

    @Test func customBaseAndMax() {
        let backoff = Backoff(base: .seconds(1), max: .seconds(5))
        #expect(backoff.delay(attempt: 2) == .seconds(4))
        #expect(backoff.delay(attempt: 3) == .seconds(5))
    }
}

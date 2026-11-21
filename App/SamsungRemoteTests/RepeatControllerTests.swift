import Synchronization
import Testing
import SamsungTVKit
@testable import SamsungRemote

/// Records every key sent by a `RepeatController`.
private final class SendLog: Sendable {
    private let entries = Mutex<[String]>([])

    var all: [String] { entries.withLock { $0 } }

    func record(_ key: RemoteKey, _ action: KeyAction) {
        entries.withLock { $0.append("\(key.rawValue) \(action.rawValue)") }
    }
}

/// Yields until `condition` holds (bounded, no real sleeps).
@MainActor
private func settle(_ condition: () -> Bool) async {
    for _ in 0..<10_000 where !condition() { await Task.yield() }
}

@MainActor
@Suite struct RepeatControllerTests {
    @Test func clickEverySendsImmediatelyThenEveryInterval() async {
        let clock = TestClock()
        let log = SendLog()
        let controller = RepeatController(clock: clock, strategy: .clickEvery(.milliseconds(150), initialDelay: .milliseconds(150))) { log.record($0, $1) }

        controller.begin(.volumeUp)
        await clock.waitForSleepers(1)
        #expect(log.all == ["KEY_VOLUP Click"])
        #expect(clock.requestedSleeps == [.milliseconds(150)])

        clock.advance(by: .milliseconds(150))
        await settle { log.all.count == 2 }
        await clock.waitForSleepers(1)
        #expect(log.all == ["KEY_VOLUP Click", "KEY_VOLUP Click"])
        controller.end()
    }

    @Test func initialDelayThenRepeatsEveryInterval() async {
        let clock = TestClock()
        let log = SendLog()
        let controller = RepeatController(clock: clock, strategy: .default) { log.record($0, $1) }

        controller.begin(.volumeUp)
        await clock.waitForSleepers(1)
        #expect(log.all.count == 1)

        clock.advance(by: .milliseconds(399)) // released just before the delay: a tap, one click
        for _ in 0..<100 { await Task.yield() }
        #expect(log.all.count == 1)

        clock.advance(by: .milliseconds(1)) // 400 ms: the second click
        await settle { log.all.count == 2 }
        await clock.waitForSleepers(1)
        #expect(log.all.count == 2)

        clock.advance(by: .milliseconds(100))
        await settle { log.all.count == 3 }
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(100))
        await settle { log.all.count == 4 }
        #expect(log.all.count == 4)

        controller.end()
        await clock.waitForSleepers(0)
        clock.advance(by: .seconds(1))
        for _ in 0..<100 { await Task.yield() }
        #expect(log.all.count == 4)
    }

    @Test func reportsEveryRepeatButNotTheFirstClick() async {
        let clock = TestClock()
        let log = SendLog()
        let controller = RepeatController(clock: clock, strategy: .default) { log.record($0, $1) }
        var repeats = 0
        controller.onRepeat = { repeats += 1 }

        controller.begin(.up)
        await clock.waitForSleepers(1)
        #expect(repeats == 0)
        clock.advance(by: .milliseconds(400))
        await settle { log.all.count == 2 }
        await clock.waitForSleepers(1)
        #expect(repeats == 1)
        clock.advance(by: .milliseconds(100))
        await settle { log.all.count == 3 }
        #expect(repeats == 2)
        controller.end()
    }

    @Test func cancelStopsRepeatingAndSendsRelease() async {
        // .clickEvery: end() stops the repetition.
        let clock = TestClock()
        let clicks = SendLog()
        let repeating = RepeatController(clock: clock, strategy: .clickEvery(.milliseconds(150), initialDelay: .milliseconds(150))) { clicks.record($0, $1) }
        repeating.begin(.up)
        await clock.waitForSleepers(1)
        repeating.end()
        await clock.waitForSleepers(0)
        clock.advance(by: .seconds(1))
        for _ in 0..<100 { await Task.yield() }
        #expect(clicks.all == ["KEY_UP Click"])

        // .pressRelease: press on begin, release on end — once, however often end() is called.
        let held = SendLog()
        let pressRelease = RepeatController(clock: clock, strategy: .pressRelease) { held.record($0, $1) }
        pressRelease.begin(.volumeDown)
        await settle { held.all.count == 1 }
        #expect(held.all == ["KEY_VOLDOWN Press"])
        pressRelease.end()
        pressRelease.end()
        await settle { held.all.count == 2 }
        for _ in 0..<100 { await Task.yield() }
        #expect(held.all == ["KEY_VOLDOWN Press", "KEY_VOLDOWN Release"])
    }

    @Test func beginWhileHoldingReleasesThePreviousKey() async {
        let log = SendLog()
        let controller = RepeatController(clock: TestClock(), strategy: .pressRelease) { log.record($0, $1) }
        controller.begin(.left)
        controller.begin(.right)
        controller.end()
        await settle { log.all.count == 4 }
        #expect(log.all == ["KEY_LEFT Press", "KEY_LEFT Release", "KEY_RIGHT Press", "KEY_RIGHT Release"])
    }

    @Test func endWithoutBeginSendsNothing() async {
        let log = SendLog()
        let controller = RepeatController(clock: TestClock(), strategy: .pressRelease) { log.record($0, $1) }
        controller.end()
        for _ in 0..<100 { await Task.yield() }
        #expect(log.all.isEmpty)
    }
}

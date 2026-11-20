import Foundation
import Synchronization
import Testing
@testable import SamsungTVKit

private let tvID = TVID(rawValue: "tv-1")
private let host = "10.0.0.5"
private let mac = MACAddress("02:00:00:00:00:aa")!
private let wifi = IPv4Interface(name: "en0", address: 0x0A00_0002, netmask: 0xFFFF_FF00)

private func knownTV(mac: MACAddress? = mac) -> KnownTV {
    KnownTV(id: tvID, lastHost: host, wifiMAC: mac, modelName: "Model", reportedName: "TV", lastSeen: Date(timeIntervalSince1970: 0))
}

private func info(_ power: TVPowerState) -> TVDeviceInfo {
    TVDeviceInfo(
        id: tvID, host: host, name: "TV", modelName: "Model", modelCode: "Code",
        wifiMAC: mac, networkType: "wireless", powerState: power, tokenAuthSupported: true
    )
}

/// Returns scripted results in order; once exhausted, repeats the last one.
private final class FakeFetcher: TVInfoFetching {
    private let script: Mutex<[Result<TVPowerState, TVInfoError>]>
    private let hosts = Mutex<[String]>([])

    init(_ script: [Result<TVPowerState, TVInfoError>]) {
        self.script = Mutex(script)
    }

    var fetchedHosts: [String] { hosts.withLock { $0 } }

    func fetchInfo(host: String) async throws(TVInfoError) -> TVDeviceInfo {
        hosts.withLock { $0.append(host) }
        let next = script.withLock { s in s.count > 1 ? s.removeFirst() : s[0] }
        return info(try next.get())
    }
}

private final class FakeSender: PowerKeySending {
    private let result: Result<Void, SessionError>
    private let calls = Mutex<[(RemoteKey, Duration)]>([])

    init(_ result: Result<Void, SessionError> = .success(())) {
        self.result = result
    }

    var sent: [RemoteKey] { calls.withLock { $0.map(\.0) } }
    var timeouts: [Duration] { calls.withLock { $0.map(\.1) } }

    func sendEnsuringConnection(_ key: RemoteKey, timeout: Duration) async throws(SessionError) {
        calls.withLock { $0.append((key, timeout)) }
        try result.get()
    }
}

final class WakeRecorder: Sendable {
    private let calls = Mutex<[(MACAddress, IPv4Interface, String)]>([])
    var macs: [MACAddress] { calls.withLock { $0.map(\.0) } }
    var interfaces: [IPv4Interface] { calls.withLock { $0.map(\.1) } }
    var hosts: [String] { calls.withLock { $0.map(\.2) } }
    func record(_ mac: MACAddress, _ iface: IPv4Interface, _ host: String) {
        calls.withLock { $0.append((mac, iface, host)) }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct PowerControllerTests {
    let clock = TestClock()
    let wakes = WakeRecorder()

    private func controller(_ fetcher: FakeFetcher, interface: IPv4Interface? = wifi) -> PowerController {
        let wakes = wakes
        return PowerController(
            fetcher: fetcher,
            wake: { mac, iface, host in wakes.record(mac, iface, host) },
            interface: { interface },
            clock: clock
        )
    }

    /// One poll per second for the whole power-on wait.
    private let wakePolls = Int(PowerController.defaultWakeTimeout.components.seconds)

    /// Advances the clock one second per poll until `task` finishes.
    private func drive(_ task: Task<PowerOutcome?, Never>, polls: Int) async -> PowerOutcome? {
        for _ in 0..<polls {
            await clock.waitForSleepers(1)
            #expect(clock.requestedSleeps.last == .seconds(1))
            clock.advance(by: .seconds(1))
        }
        return await task.value
    }

    // MARK: - Planner

    @Test(arguments: [
        (Result<TVPowerState, TVInfoError>.success(.on), PowerAction.turnOff),
        (.success(.standby), .wakeFromStandby),
        (.success(.unknown("Weird")), .wakeFromStandby),
        (.failure(.unreachable), .wakeOnLAN),
        (.failure(.malformed), .wakeOnLAN),
    ])
    func plannerTable(result: Result<TVPowerState, TVInfoError>, expected: PowerAction) {
        #expect(PowerPlanner.action(for: result) == expected)
    }

    // MARK: - Turn off

    @Test func onTurnsOffWithPowerKey() async {
        let fetcher = FakeFetcher([.success(.on), .success(.standby)])
        let sender = FakeSender()
        let c = controller(fetcher)
        let task = Task { await c.togglePower(tv: knownTV(), sender: sender) }
        #expect(await drive(task, polls: 1) == .turnedOff)
        #expect(sender.sent == [.power])
        #expect(sender.timeouts == [.seconds(3)])
        #expect(fetcher.fetchedHosts == [host, host])
        #expect(wakes.macs.isEmpty)
    }

    @Test func reportsThePlanBeforeActing() async {
        let plans = Mutex<[PowerAction]>([])
        let sender = FakeSender()
        let off = controller(FakeFetcher([.success(.on), .success(.standby)]))
        let task = Task {
            await off.togglePower(tv: knownTV(), sender: sender) { action in
                // Reported before the power key goes out.
                #expect(sender.sent.isEmpty)
                plans.withLock { $0.append(action) }
            }
        }
        #expect(await drive(task, polls: 1) == .turnedOff)
        let on = controller(FakeFetcher([.failure(.unreachable), .success(.on)]))
        let wake = Task { await on.togglePower(tv: knownTV(), sender: sender) { a in plans.withLock { $0.append(a) } } }
        #expect(await drive(wake, polls: 1) == .turnedOn)
        #expect(plans.withLock { $0 } == [.turnOff, .wakeOnLAN])
    }

    @Test func turnOffPollsUntilNotOn() async {
        // Still on for two polls, then unreachable (counts as off).
        let fetcher = FakeFetcher([.success(.on), .success(.on), .success(.on), .failure(.unreachable)])
        let sender = FakeSender()
        let c = controller(fetcher)
        let task = Task { await c.togglePower(tv: knownTV(), sender: sender) }
        #expect(await drive(task, polls: 3) == .turnedOff)
        #expect(fetcher.fetchedHosts.count == 4)
        #expect(sender.sent == [.power])
    }

    @Test func turnOffConfirmationTimesOutStillTurnedOff() async {
        let fetcher = FakeFetcher([.success(.on)])
        let sender = FakeSender()
        let c = controller(fetcher)
        let task = Task { await c.togglePower(tv: knownTV(), sender: sender) }
        #expect(await drive(task, polls: 5) == .turnedOff)
        #expect(fetcher.fetchedHosts.count == 6)
        #expect(sender.sent == [.power])
    }

    @Test func secondPressDuringShutdownIsIgnored() async {
        let fetcher = FakeFetcher([.success(.on), .success(.on), .success(.on), .success(.standby)])
        let sender = FakeSender()
        let c = controller(fetcher)
        let first = Task { await c.togglePower(tv: knownTV(), sender: sender) }
        await clock.waitForSleepers(1)

        // The TV still reports on: a second press must not send another power key.
        #expect(await c.togglePower(tv: knownTV(), sender: sender) == nil)
        clock.advance(by: .seconds(1))
        await clock.waitForSleepers(1)
        #expect(await c.togglePower(tv: knownTV(), sender: sender) == nil)
        clock.advance(by: .seconds(1))
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(1))

        #expect(await first.value == .turnedOff)
        #expect(sender.sent == [.power])
    }

    @Test(arguments: [SessionError.unreachable, .denied, .identityChanged, .approvalTimedOut])
    func turnOffFailureReportsReason(error: SessionError) async {
        let fetcher = FakeFetcher([.success(.on)])
        let sender = FakeSender(.failure(error))
        let outcome = await controller(fetcher).togglePower(tv: knownTV(), sender: sender)
        #expect(outcome == .failed(error))
        #expect(fetcher.fetchedHosts.count == 1)
        #expect(wakes.macs.isEmpty)
    }

    // MARK: - Wake from standby

    @Test func standbySendsPowerAndPollsUntilOn() async {
        let fetcher = FakeFetcher([.success(.standby), .success(.standby), .success(.on)])
        let sender = FakeSender()
        let c = controller(fetcher)
        let task = Task { await c.togglePower(tv: knownTV(), sender: sender) }
        #expect(await drive(task, polls: 2) == .turnedOn)
        #expect(sender.sent == [.power])
        #expect(wakes.macs.isEmpty)
        #expect(fetcher.fetchedHosts.count == 3)
    }

    @Test func standbyPowerKeyAcceptedButNeverOn() async {
        let fetcher = FakeFetcher([.success(.standby)])
        let sender = FakeSender()
        let c = controller(fetcher)
        let task = Task { await c.togglePower(tv: knownTV(), sender: sender) }
        #expect(await drive(task, polls: wakePolls) == .failedToWake)
        #expect(sender.sent == [.power])
        #expect(wakes.macs.isEmpty)
    }

    @Test(arguments: [SessionError.identityChanged, .denied])
    func standbyPairingFailureDoesNotFallBack(error: SessionError) async {
        let fetcher = FakeFetcher([.success(.standby)])
        let sender = FakeSender(.failure(error))
        let outcome = await controller(fetcher).togglePower(tv: knownTV(), sender: sender)
        #expect(outcome == .failed(error))
        #expect(sender.sent == [.power])
        #expect(wakes.macs.isEmpty)
        #expect(fetcher.fetchedHosts.count == 1)
    }

    @Test(arguments: [SessionError.unreachable, .approvalTimedOut])
    func standbyRefusesConnectionFallsBackToWoL(error: SessionError) async {
        let fetcher = FakeFetcher([.success(.standby), .success(.on)])
        let sender = FakeSender(.failure(error))
        let c = controller(fetcher)
        let task = Task { await c.togglePower(tv: knownTV(), sender: sender) }
        #expect(await drive(task, polls: 1) == .turnedOn)
        #expect(sender.sent == [.power])
        #expect(wakes.macs == [mac])
        #expect(wakes.interfaces == [wifi])
    }

    // MARK: - Wake-on-LAN

    @Test func noMACKnown() async {
        let fetcher = FakeFetcher([.failure(.unreachable)])
        let sender = FakeSender()
        let outcome = await controller(fetcher).togglePower(tv: knownTV(mac: nil), sender: sender)
        #expect(outcome == .noMACKnown)
        #expect(sender.sent.isEmpty)
        #expect(wakes.macs.isEmpty)
    }

    @Test func notOnWiFi() async {
        let fetcher = FakeFetcher([.failure(.unreachable)])
        let sender = FakeSender()
        let outcome = await controller(fetcher, interface: nil).togglePower(tv: knownTV(), sender: sender)
        #expect(outcome == .notOnWiFi)
        #expect(wakes.macs.isEmpty)
    }

    @Test func wolPollsUntilOn() async {
        // Initial check fails, then two more failed polls before the TV reports on.
        let fetcher = FakeFetcher([.failure(.unreachable), .failure(.unreachable), .failure(.unreachable), .success(.on)])
        let sender = FakeSender()
        let c = controller(fetcher)
        let task = Task { await c.togglePower(tv: knownTV(), sender: sender) }
        #expect(await drive(task, polls: 3) == .turnedOn)
        #expect(wakes.macs == [mac])
        #expect(wakes.interfaces == [wifi])
        #expect(wakes.hosts == [host])
        #expect(sender.sent.isEmpty)
        #expect(fetcher.fetchedHosts == Array(repeating: host, count: 4))
    }

    @Test func wolTimeout() async {
        let fetcher = FakeFetcher([.failure(.unreachable)])
        let sender = FakeSender()
        let c = controller(fetcher)
        let task = Task { await c.togglePower(tv: knownTV(), sender: sender) }
        #expect(await drive(task, polls: wakePolls) == .failedToWake)
        #expect(wakes.macs == [mac])
        #expect(fetcher.fetchedHosts.count == wakePolls + 1) // the plan check, then one per poll
    }

    // MARK: - Concurrency

    @Test func concurrentPressIsIgnored() async {
        let fetcher = FakeFetcher([.failure(.unreachable), .success(.on), .success(.on), .success(.standby)])
        let sender = FakeSender()
        let c = controller(fetcher)
        let first = Task { await c.togglePower(tv: knownTV(), sender: sender) }
        await clock.waitForSleepers(1)

        #expect(await c.togglePower(tv: knownTV(), sender: sender) == nil)

        clock.advance(by: .seconds(1))
        #expect(await first.value == .turnedOn)
        #expect(wakes.macs == [mac])

        // Once the first finishes, presses are accepted again (TV now on → turn off).
        let third = Task { await c.togglePower(tv: knownTV(), sender: sender) }
        #expect(await drive(third, polls: 1) == .turnedOff)
        #expect(sender.sent == [.power])
    }
}

@Test func powerOnWaitsLongEnoughForSlowTVs() {
    // A 2022 TV in testing took over 20 s to report on after waking from network standby.
    #expect(PowerController.defaultWakeTimeout >= .seconds(40))
}

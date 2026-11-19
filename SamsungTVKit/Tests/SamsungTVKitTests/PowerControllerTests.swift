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
    private let calls = Mutex<[(MACAddress, IPv4Interface)]>([])
    var macs: [MACAddress] { calls.withLock { $0.map(\.0) } }
    var interfaces: [IPv4Interface] { calls.withLock { $0.map(\.1) } }
    func record(_ mac: MACAddress, _ iface: IPv4Interface) { calls.withLock { $0.append((mac, iface)) } }
}

@Suite(.timeLimit(.minutes(1)))
struct PowerControllerTests {
    let clock = TestClock()
    let wakes = WakeRecorder()

    private func controller(_ fetcher: FakeFetcher, interface: IPv4Interface? = wifi) -> PowerController {
        let wakes = wakes
        return PowerController(
            fetcher: fetcher,
            wake: { mac, iface in wakes.record(mac, iface) },
            interface: { interface },
            clock: clock
        )
    }

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
        let fetcher = FakeFetcher([.success(.on)])
        let sender = FakeSender()
        let outcome = await controller(fetcher).togglePower(tv: knownTV(), sender: sender)
        #expect(outcome == .turnedOff)
        #expect(sender.sent == [.power])
        #expect(sender.timeouts == [.seconds(3)])
        #expect(fetcher.fetchedHosts == [host])
        #expect(wakes.macs.isEmpty)
    }

    @Test func turnOffFailureReportsFailed() async {
        let fetcher = FakeFetcher([.success(.on)])
        let sender = FakeSender(.failure(.unreachable))
        let outcome = await controller(fetcher).togglePower(tv: knownTV(), sender: sender)
        #expect(outcome == .failed)
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

    @Test func standbyRefusesConnectionFallsBackToWoL() async {
        let fetcher = FakeFetcher([.success(.standby), .success(.on)])
        let sender = FakeSender(.failure(.unreachable))
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
        #expect(sender.sent.isEmpty)
        #expect(fetcher.fetchedHosts == Array(repeating: host, count: 4))
    }

    @Test func wolTimeout() async {
        let fetcher = FakeFetcher([.failure(.unreachable)])
        let sender = FakeSender()
        let c = controller(fetcher)
        let task = Task { await c.togglePower(tv: knownTV(), sender: sender) }
        #expect(await drive(task, polls: 20) == .failedToWake)
        #expect(wakes.macs == [mac])
        #expect(fetcher.fetchedHosts.count == 21)
    }

    // MARK: - Concurrency

    @Test func concurrentPressIsIgnored() async {
        let fetcher = FakeFetcher([.failure(.unreachable), .success(.on)])
        let sender = FakeSender()
        let c = controller(fetcher)
        let first = Task { await c.togglePower(tv: knownTV(), sender: sender) }
        await clock.waitForSleepers(1)

        #expect(await c.togglePower(tv: knownTV(), sender: sender) == nil)

        clock.advance(by: .seconds(1))
        #expect(await first.value == .turnedOn)
        #expect(wakes.macs == [mac])

        // Once the first finishes, presses are accepted again (TV now on → turn off).
        #expect(await c.togglePower(tv: knownTV(), sender: sender) == .turnedOff)
    }
}

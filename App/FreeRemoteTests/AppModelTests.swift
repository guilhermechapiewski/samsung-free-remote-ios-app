import Foundation
import Synchronization
import Testing
import SamsungTVKit
import SwiftUI
@testable import FreeRemote

// MARK: - Fakes

private func info(_ id: String, host: String, name: String, model: String = "Model", power: TVPowerState = .on,
                  mac: String? = "02:00:00:00:00:01") -> TVDeviceInfo {
    TVDeviceInfo(id: TVID(rawValue: id), host: host, name: name, modelName: model, modelCode: "M",
                 wifiMAC: mac.flatMap(MACAddress.init), networkType: "wireless", powerState: power,
                 tokenAuthSupported: true)
}

private func knownTV(_ i: TVDeviceInfo) -> KnownTV {
    KnownTV(id: i.id, lastHost: i.host, wifiMAC: i.wifiMAC, modelName: i.modelName, reportedName: i.name,
            lastSeen: Date(timeIntervalSince1970: 0))
}

/// Whether the fake device is on Wi-Fi.
private final class WiFiSwitch: Sendable {
    private let state: Mutex<Bool>
    init(_ on: Bool) { state = Mutex(on) }
    var isOn: Bool {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

/// Lets a test hold async work until it opens the gate (open by default).
private final class Gate: Sendable {
    private let state = Mutex<(isOpen: Bool, waiters: [CheckedContinuation<Void, Never>])>((true, []))

    var waiting: Int { state.withLock { $0.waiters.count } }

    func close() { state.withLock { $0.isOpen = false } }

    func open() {
        let waiters = state.withLock { s in
            s.isOpen = true
            defer { s.waiters = [] }
            return s.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let now = state.withLock { s in
                if s.isOpen { return true }
                s.waiters.append(c)
                return false
            }
            if now { c.resume() }
        }
    }
}

private final class FakeSession: RemoteSessionProtocol {
    struct Log {
        var connects = 0
        var disconnects = 0
        var sent: [String] = []
        var texts: [String] = []
        var current: SessionState = .idle
    }

    let id: TVID
    let host: String
    let states: AsyncStream<SessionState>
    let keyboardEvents: AsyncStream<Bool>
    private let stateContinuation: AsyncStream<SessionState>.Continuation
    let keyboardContinuation: AsyncStream<Bool>.Continuation
    private let log = Mutex(Log())
    private let disconnectGate: Gate

    init(id: TVID, host: String, disconnectGate: Gate) {
        self.id = id
        self.host = host
        self.disconnectGate = disconnectGate
        (states, stateContinuation) = AsyncStream.makeStream()
        (keyboardEvents, keyboardContinuation) = AsyncStream.makeStream()
    }

    var snapshot: Log { log.withLock { $0 } }

    /// Simulates the session reaching `state`.
    func emit(_ state: SessionState) {
        log.withLock { $0.current = state }
        stateContinuation.yield(state)
    }

    var currentState: SessionState { log.withLock { $0.current } }
    func connect() async { log.withLock { $0.connects += 1 } }
    func disconnect() async {
        await disconnectGate.wait()
        log.withLock { $0.disconnects += 1 }
    }

    func send(_ key: RemoteKey, _ action: KeyAction) async throws(SessionError) {
        try log.withLock { (l: inout Log) throws(SessionError) in
            guard l.current == .connected else { throw .unreachable }
            l.sent.append(action == .click ? key.rawValue : "\(key.rawValue) \(action.rawValue)")
        }
    }

    func sendEnsuringConnection(_ key: RemoteKey, timeout: Duration) async throws(SessionError) {
        try await send(key, .click)
    }

    func sendText(_ s: String) async throws(SessionError) { log.withLock { $0.texts.append(s) } }
    func sendTextEnd() async throws(SessionError) { log.withLock { $0.texts.append("<end>") } }
}

private final class FakeDiscovery: Sendable {
    private let state = Mutex<(scans: [[String]], continuations: [AsyncStream<DiscoveryEvent>.Continuation])>(([], []))

    var scans: [[String]] { state.withLock { $0.scans } }

    func make(_ hosts: [String]) -> AsyncStream<DiscoveryEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: DiscoveryEvent.self)
        state.withLock {
            $0.scans.append(hosts)
            $0.continuations.append(continuation)
        }
        return stream
    }

    func yield(_ event: DiscoveryEvent) { state.withLock { $0.continuations.last }?.yield(event) }
    func finish() { state.withLock { $0.continuations.last }?.finish() }
}

private final class FakeSessions: Sendable {
    private let all = Mutex<[FakeSession]>([])
    /// Holds every session's `disconnect()` while closed.
    let disconnectGate = Gate()
    var list: [FakeSession] { all.withLock { $0 } }
    var last: FakeSession? { list.last }

    func make(_ id: TVID, _ host: String) -> FakeSession {
        let session = FakeSession(id: id, host: host, disconnectGate: disconnectGate)
        all.withLock { $0.append(session) }
        return session
    }
}

private final class FakeCredentials: CredentialStore {
    let deleted = Mutex<[TVID]>([])
    func load(_ id: TVID) -> TVCredentials? { nil }
    func save(_ c: TVCredentials, for id: TVID) throws {}
    func delete(_ id: TVID) { deleted.withLock { $0.append(id) } }
}

private final class FakeLabels: LabelStore {
    private let labels = Mutex<[TVID: String]>([:])
    let changes: AsyncStream<Void>
    let changesContinuation: AsyncStream<Void>.Continuation

    init() { (changes, changesContinuation) = AsyncStream.makeStream() }

    func label(for id: TVID) -> String? { labels.withLock { $0[id] } }
    func setLabel(_ s: String?, for id: TVID) { labels.withLock { $0[id] = s } }
}

private final class FakeKnownTVStore: KnownTVPersisting {
    let registry: Mutex<KnownTVRegistry>
    init(_ tvs: [KnownTV] = []) {
        var r = KnownTVRegistry()
        for tv in tvs {
            r.record(TVDeviceInfo(id: tv.id, host: tv.lastHost, name: tv.reportedName, modelName: tv.modelName,
                                  modelCode: "", wifiMAC: tv.wifiMAC, networkType: "", powerState: .on,
                                  tokenAuthSupported: true), at: tv.lastSeen)
        }
        registry = Mutex(r)
    }
    func load() -> KnownTVRegistry { registry.withLock { $0 } }
    func save(_ r: KnownTVRegistry) throws { registry.withLock { $0 = r } }
}

private final class FakePower: PowerToggling {
    let outcome: PowerOutcome?
    let calls = Mutex<[TVID]>([])
    /// Holds every toggle while closed.
    let gate = Gate()
    init(_ outcome: PowerOutcome?) { self.outcome = outcome }
    func togglePower(tv: KnownTV, sender: any PowerKeySending) async -> PowerOutcome? {
        calls.withLock { $0.append(tv.id) }
        await gate.wait()
        return outcome
    }
}

private final class FakeFetcher: TVInfoFetching {
    let infos: [String: TVDeviceInfo]
    let requested = Mutex<[String]>([])
    init(_ infos: [TVDeviceInfo] = []) { self.infos = Dictionary(uniqueKeysWithValues: infos.map { ($0.host, $0) }) }
    func fetchInfo(host: String) async throws(TVInfoError) -> TVDeviceInfo {
        requested.withLock { $0.append(host) }
        guard let i = infos[host] else { throw .unreachable }
        return i
    }
}

/// One model wired to fakes, with handles on every fake.
@MainActor
private struct Harness {
    let discovery = FakeDiscovery()
    let sessions = FakeSessions()
    let credentials = FakeCredentials()
    let labels = FakeLabels()
    let store: FakeKnownTVStore
    let power: FakePower
    let fetcher: FakeFetcher
    let clock = TestClock()
    let wifi: WiFiSwitch
    let defaults: UserDefaults
    let model: AppModel

    init(known: [TVDeviceInfo] = [], selected: TVID? = nil, wifi: Bool = true,
         power: PowerOutcome? = .turnedOn, fetchable: [TVDeviceInfo] = []) {
        store = FakeKnownTVStore(known.map(knownTV))
        self.wifi = WiFiSwitch(wifi)
        self.power = FakePower(power)
        fetcher = FakeFetcher(fetchable)
        defaults = UserDefaults(suiteName: "AppModelTests.\(UUID().uuidString)")!
        if let selected { defaults.set(selected.rawValue, forKey: "selectedTV") }
        let discovery = discovery, sessions = sessions, powerFake = self.power
        let iface = IPv4Interface(name: "en0", address: 0xC0A8_0102, netmask: 0xFFFF_FF00)
        let env = AppEnvironment(
            makeDiscovery: { discovery.make($0) },
            makeSession: { sessions.make($0, $1) },
            makePowerController: { powerFake },
            fetcher: fetcher,
            credentials: credentials,
            labels: labels,
            knownTVStore: store,
            wifiInterface: { [wifi = self.wifi] in wifi.isOn ? iface : nil },
            clock: clock,
            userDefaults: defaults
        )
        model = AppModel(env: env)
    }

    /// Launches the model and waits for the first scan to start.
    func appear() async {
        model.onAppear()
        await settle { !discovery.scans.isEmpty }
    }

    /// Selects nothing new; connects the current session and waits until the model sees it.
    func connectCurrent() async {
        await settle { sessions.last?.snapshot.connects == 1 }
        sessions.last?.emit(.connected)
        await settle { model.screen == .ready && model.isConnected }
    }
}

/// Yields until `condition` holds (bounded, no real sleeps).
@MainActor
private func settle(_ condition: () -> Bool) async {
    for _ in 0..<10_000 where !condition() { await Task.yield() }
}

/// Lets any queued work run (used to show something does NOT happen).
@MainActor
private func drain() async {
    for _ in 0..<200 { await Task.yield() }
}

private let tvA = info("uuid:a", host: "192.168.1.10", name: "Bravo", model: "QE55")
private let tvB = info("uuid:b", host: "192.168.1.11", name: "Zed", model: "UE43", power: .standby)
private let tvC = info("uuid:c", host: "192.168.1.12", name: "Alpha", model: "QE65")

// MARK: - Tests

@MainActor
@Suite struct AppModelTests {
    @Test func noWiFiShowsWiFiState() async {
        let h = Harness(known: [tvA], selected: tvA.id, wifi: false)
        h.model.onAppear()
        await drain()
        #expect(h.model.screen == .noWiFi)
        #expect(h.discovery.scans.isEmpty)
        #expect(h.sessions.list.isEmpty)
    }

    @Test func discoveredTVsListedOnlineFirst() async {
        let h = Harness(known: [tvC])
        await h.appear()
        #expect(h.model.screen == .chooseTV) // a known TV exists, none selected
        h.discovery.yield(.found(tvB))
        h.discovery.yield(.found(tvA))
        h.discovery.finish()
        await settle { h.model.tvs.count == 3 && h.model.tvs.first?.title == "Bravo" }
        await drain()
        // Several TVs: the user chooses.
        #expect(h.model.selectedID == nil)
        #expect(h.sessions.list.isEmpty)
        #expect(h.model.screen == .chooseTV)
        #expect(h.model.tvs.map(\.title) == ["Bravo", "Zed", "Alpha"])
        #expect(h.model.tvs.map(\.subtitle) == ["QE55", "UE43", "QE65"])
        #expect(h.model.tvs.map(\.status) == [.on, .asleep, .unreachable])
        #expect(h.discovery.scans == [[tvC.host]])
        // Found TVs are remembered.
        #expect(Set(h.store.load().tvs.keys) == [tvA.id, tvB.id, tvC.id])
    }

    @Test func searchingThenNoTVs() async {
        let h = Harness()
        await h.appear()
        #expect(h.model.screen == .searching)
        h.discovery.finish()
        await settle { h.model.screen == .noTVs }
        #expect(h.model.screen == .noTVs)
    }

    @Test func localNetworkDeniedShowsState() async {
        let h = Harness()
        await h.appear()
        h.discovery.yield(.localNetworkDenied)
        await settle { h.model.screen == .localNetworkDenied }
        #expect(h.model.screen == .localNetworkDenied)
    }

    @Test func labelOverridesReportedName() async {
        let h = Harness(known: [tvA])
        h.labels.setLabel("Den", for: tvA.id)
        await h.appear()
        #expect(h.model.tvs.map(\.title) == ["Den"])

        h.model.rename(tvA.id, to: "  Kitchen ")
        #expect(h.labels.label(for: tvA.id) == "Kitchen")
        #expect(h.model.tvs.map(\.title) == ["Kitchen"])

        h.model.rename(tvA.id, to: "   ")
        #expect(h.labels.label(for: tvA.id) == nil)
        #expect(h.model.tvs.map(\.title) == ["Bravo"])
        h.model.rename(tvA.id, to: "Kitchen")

        // A change synced from another device refreshes titles.
        h.labels.setLabel(nil, for: tvA.id)
        h.labels.changesContinuation.yield()
        await settle { h.model.tvs.first?.title == "Bravo" }
        #expect(h.model.tvs.map(\.title) == ["Bravo"])
    }

    @Test func reconnectsAfterIPChange() async throws {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        await h.connectCurrent()
        let first = try #require(h.sessions.last)
        #expect(first.host == tvA.host)

        var moved = tvA
        moved.host = "192.168.1.99"
        h.discovery.yield(.found(moved))
        await settle { h.sessions.list.count == 2 && first.snapshot.disconnects == 1 }
        let second = try #require(h.sessions.last)
        #expect(second.id == tvA.id)
        #expect(second.host == "192.168.1.99")
        await settle { second.snapshot.connects == 1 }
        #expect(second.snapshot.connects == 1)
        #expect(first.snapshot.disconnects == 1)
        #expect(h.store.load().tvs[tvA.id]?.lastHost == "192.168.1.99")
    }

    @Test func selectionRestoredOnLaunch() async {
        let h = Harness(known: [tvA, tvB], selected: tvB.id)
        await h.appear()
        #expect(h.model.selectedID == tvB.id)
        await settle { h.sessions.last?.snapshot.connects == 1 }
        #expect(h.sessions.list.map(\.id) == [tvB.id])
        #expect(h.sessions.last?.host == tvB.host)

        h.model.select(tvA.id)
        #expect(h.defaults.string(forKey: "selectedTV") == tvA.id.rawValue)
    }

    @Test func backgroundDisconnectsForegroundReconnects() async throws {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        await h.connectCurrent()
        let first = try #require(h.sessions.last)

        h.model.scenePhaseChanged(.background)
        await settle { first.snapshot.disconnects == 1 }
        #expect(first.snapshot.disconnects == 1)
        #expect(!h.model.isConnected)

        h.model.scenePhaseChanged(.inactive)
        h.model.scenePhaseChanged(.active)
        await settle { h.sessions.list.count == 2 && h.sessions.last?.snapshot.connects == 1 }
        #expect(h.sessions.list.count == 2)
        #expect(h.sessions.last?.snapshot.connects == 1)
        #expect(h.model.selectedID == tvA.id)
        await settle { h.discovery.scans.count == 2 }
        #expect(h.discovery.scans.count == 2) // rescanned on return
    }

    @Test func pressWhileDisconnectedShowsReason() async throws {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        await settle { h.sessions.last?.snapshot.connects == 1 }
        h.sessions.last?.emit(.connecting)
        await drain()

        h.model.press(.up)
        await drain()
        #expect(h.model.statusMessage != nil)
        #expect(try #require(h.sessions.last).snapshot.sent.isEmpty)

        // Once connected, presses go through and the message clears.
        h.sessions.last?.emit(.connected)
        await settle { h.model.isConnected }
        h.model.press(.up)
        await settle { h.sessions.last?.snapshot.sent == ["KEY_UP"] }
        #expect(h.sessions.last?.snapshot.sent == ["KEY_UP"])
        #expect(h.model.statusMessage == nil)
    }

    @Test func pressWithNoTVSelectedShowsReason() {
        let h = Harness()
        h.model.press(.enter)
        #expect(h.model.statusMessage != nil)
    }

    @Test func forgetRemovesEverything() async throws {
        let h = Harness(known: [tvA, tvB], selected: tvA.id)
        h.labels.setLabel("Den", for: tvA.id)
        await h.appear()
        await h.connectCurrent()
        let session = try #require(h.sessions.last)

        h.model.forget(tvA.id)
        #expect(h.store.load().tvs[tvA.id] == nil)
        #expect(h.store.load().tvs[tvB.id] != nil)
        #expect(h.labels.label(for: tvA.id) == nil)
        #expect(h.model.selectedID == nil)
        #expect(h.defaults.string(forKey: "selectedTV") == nil)
        #expect(h.model.tvs.map(\.id) == [tvB.id])
        // Credentials go once the session has disconnected.
        await settle { h.credentials.deleted.withLock { $0 } == [tvA.id] }
        #expect(session.snapshot.disconnects == 1)
        #expect(h.credentials.deleted.withLock { $0 } == [tvA.id])
    }

    @Test func addManuallyRejectsPublicIP() async {
        let h = Harness(fetchable: [tvA])
        #expect(await h.model.addManually(host: "8.8.8.8") == false)
        #expect(await h.model.addManually(host: "127.0.0.1") == false)
        #expect(await h.model.addManually(host: "not an ip") == false)
        #expect(h.fetcher.requested.withLock { $0 }.isEmpty)
        #expect(h.model.tvs.isEmpty)

        #expect(await h.model.addManually(host: " 192.168.1.10 ") == true)
        #expect(h.model.selectedID == tvA.id)
        #expect(h.store.load().tvs[tvA.id]?.lastHost == tvA.host)
        #expect(h.model.tvs.map(\.title) == ["Bravo"])
    }

    @Test func backgroundEndsHold() async throws {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        await h.connectCurrent()
        let session = try #require(h.sessions.last)

        h.model.beginHold(.volumeUp)
        await h.clock.waitForSleepers(1)
        await settle { session.snapshot.sent == ["KEY_VOLUP"] }
        #expect(session.snapshot.sent == ["KEY_VOLUP"])

        h.model.scenePhaseChanged(.background)
        await h.clock.waitForSleepers(0)
        h.clock.advance(by: .seconds(1))
        await drain()
        #expect(session.snapshot.sent == ["KEY_VOLUP"])
    }

    @Test func holdRepeatsUntilEnd() async throws {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        await h.connectCurrent()
        let session = try #require(h.sessions.last)

        h.model.beginHold(.down)
        await h.clock.waitForSleepers(1)
        h.clock.advance(by: .milliseconds(150))
        await settle { session.snapshot.sent.count == 2 }
        h.model.endHold()
        await h.clock.waitForSleepers(0)
        h.clock.advance(by: .seconds(1))
        await drain()
        #expect(session.snapshot.sent == ["KEY_DOWN", "KEY_DOWN"])
    }

    @Test func pairingStateShowsPairingScreen() async {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        await settle { h.sessions.last?.snapshot.connects == 1 }
        h.sessions.last?.emit(.awaitingApproval)
        await settle { h.model.screen == .pairing }
        #expect(h.model.screen == .pairing)
        #expect(h.model.tvs.first?.status == .pairing)

        h.sessions.last?.emit(.connected)
        await settle { h.model.screen == .ready }
        #expect(h.model.screen == .ready)
        #expect(h.model.tvs.first?.status == .on)
    }

    @Test func deniedShowsPairingDenied() async {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        await settle { h.sessions.last?.snapshot.connects == 1 }
        h.sessions.last?.emit(.failed(.denied))
        await settle { h.model.screen == .pairingDenied }
        #expect(h.model.screen == .pairingDenied)
    }

    @Test func identityChangedShowsStateAndRepairForgetsCredentials() async throws {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        await settle { h.sessions.last?.snapshot.connects == 1 }
        let first = try #require(h.sessions.last)
        first.emit(.failed(.identityChanged))
        await settle { h.model.screen == .identityChanged }
        #expect(h.model.screen == .identityChanged)

        h.model.repair()
        await settle { h.sessions.list.count == 2 && h.sessions.last?.snapshot.connects == 1 }
        #expect(h.credentials.deleted.withLock { $0 } == [tvA.id])
        #expect(first.snapshot.disconnects == 1)
        #expect(h.sessions.last?.snapshot.connects == 1)
        #expect(h.model.screen == .ready)
    }

    @Test func unreachableSessionMarksTVAndExplains() async {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        await settle { h.sessions.last?.snapshot.connects == 1 }
        h.sessions.last?.emit(.failed(.unreachable))
        await settle { h.model.statusMessage != nil }
        #expect(h.model.screen == .ready)
        #expect(h.model.tvs.first?.status == .unreachable)
        #expect(h.model.statusMessage != nil)
    }

    @Test func rescanRetriesFailedSession() async throws {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        await settle { h.sessions.last?.snapshot.connects == 1 }
        let first = try #require(h.sessions.last)
        first.emit(.failed(.denied))
        await settle { h.model.screen == .pairingDenied }

        h.model.rescan() // "Try Again"
        await settle { h.sessions.list.count == 2 && h.sessions.last?.snapshot.connects == 1 }
        #expect(h.sessions.list.count == 2)
        #expect(first.snapshot.disconnects == 1)
        #expect(h.model.screen == .ready)
    }

    @Test func powerFailureShowsMessage() async {
        let h = Harness(known: [tvA], selected: tvA.id, power: .failedToWake)
        await h.appear()
        await settle { h.sessions.last?.snapshot.connects == 1 }
        h.model.togglePower()
        #expect(h.model.powerBusy)
        await settle { !h.model.powerBusy }
        #expect(h.power.calls.withLock { $0 } == [tvA.id])
        #expect(h.model.statusMessage
            == "Couldn't turn on the TV. Turn on “Power On with Mobile” in the TV's network settings, then try again.")
    }

    @Test func powerIdentityChangedShowsIdentityStateAndEndsHold() async {
        let h = Harness(known: [tvA], selected: tvA.id, power: .failed(.identityChanged))
        await h.appear()
        await h.connectCurrent()
        h.model.beginHold(.volumeUp)
        await h.clock.waitForSleepers(1)
        h.model.togglePower()
        await settle { !h.model.powerBusy && h.model.screen == .identityChanged }
        #expect(h.model.screen == .identityChanged)
        await h.clock.waitForSleepers(0)
    }

    @Test func powerBusyIsPerTVAndSilencesUnreachable() async throws {
        let h = Harness(known: [tvA, tvB], selected: tvA.id, power: .turnedOn)
        await h.appear()
        await h.connectCurrent()
        h.power.gate.close()
        h.model.togglePower()
        #expect(h.model.powerBusy)
        await settle { h.power.gate.waiting == 1 }

        // The session giving up while power is in flight does not post its own message.
        h.sessions.last?.emit(.failed(.unreachable))
        await settle { h.model.tvs.first { $0.id == tvA.id }?.status == .unreachable }
        #expect(h.model.statusMessage == nil)

        h.model.select(tvB.id)
        #expect(!h.model.powerBusy)
        h.model.select(tvA.id)
        #expect(h.model.powerBusy)

        h.power.gate.open()
        await settle { !h.model.powerBusy }
        #expect(!h.model.powerBusy)
    }

    @Test func selectingAnotherTVDisconnectsPrevious() async throws {
        let h = Harness(known: [tvA, tvB], selected: tvA.id)
        await h.appear()
        await h.connectCurrent()
        let first = try #require(h.sessions.last)

        h.model.select(tvB.id)
        #expect(h.model.selectedID == tvB.id)
        #expect(!h.model.isConnected)
        await settle { first.snapshot.disconnects == 1 && h.sessions.last?.snapshot.connects == 1 }
        #expect(first.snapshot.disconnects == 1)
        #expect(h.sessions.list.map(\.id) == [tvA.id, tvB.id])
        #expect(h.sessions.last?.host == tvB.host)
        #expect(h.sessions.last?.snapshot.connects == 1)

        // Late events from the old session are ignored.
        first.emit(.failed(.denied))
        await drain()
        #expect(h.model.screen == .ready)
    }

    @Test func multipleTVsRequireChoice() async {
        let h = Harness()
        await h.appear()
        h.discovery.yield(.found(tvA))
        h.discovery.yield(.found(tvB))
        h.discovery.finish()
        await settle { h.model.tvs.count == 2 }
        await drain()
        #expect(h.model.screen == .chooseTV)
        #expect(h.model.selectedID == nil)
        #expect(h.sessions.list.isEmpty)

        h.model.select(tvB.id)
        #expect(h.model.screen == .ready)
    }

    @Test func singleTVAutoSelected() async {
        let h = Harness()
        await h.appear()
        h.discovery.yield(.found(tvA))
        await settle { h.model.tvs.count == 1 }
        // Not before the scan has finished: another TV may still answer.
        #expect(h.model.selectedID == nil)
        #expect(h.model.screen == .chooseTV)

        h.discovery.finish()
        await settle { h.model.selectedID == tvA.id && h.sessions.last?.snapshot.connects == 1 }
        #expect(h.model.selectedID == tvA.id)
        #expect(h.sessions.list.map(\.host) == [tvA.host])
        #expect(h.model.screen == .ready)
    }

    @Test func restoredSelectionMissingFromRegistryShowsChooseTV() async {
        let h = Harness(known: [tvA, tvB], selected: TVID(rawValue: "uuid:gone"))
        await h.appear()
        #expect(h.model.selectedID == nil)
        #expect(h.defaults.string(forKey: "selectedTV") == nil)
        #expect(h.model.screen == .chooseTV)
        h.discovery.finish()
        await drain()
        #expect(h.model.selectedID == nil)
        #expect(h.sessions.list.isEmpty)
        #expect(h.model.screen == .chooseTV)
    }

    @Test func forgetDuringScanDoesNotResurrect() async throws {
        let h = Harness(known: [tvA, tvB], selected: tvA.id, fetchable: [tvA])
        await h.appear()
        await h.connectCurrent()
        h.sessions.disconnectGate.close()

        h.model.forget(tvA.id)
        // A result for the forgotten TV still in flight from the scan.
        h.discovery.yield(.found(tvA))
        h.discovery.finish()
        await drain()
        #expect(h.store.load().tvs[tvA.id] == nil)
        #expect(h.model.tvs.map(\.id) == [tvB.id])
        #expect(h.model.selectedID == nil) // forget never selects another TV
        // Credentials go only after the disconnect…
        #expect(h.credentials.deleted.withLock { $0 }.isEmpty)

        // …and a session for the same TV, added back at once, waits for both.
        #expect(await h.model.addManually(host: tvA.host))
        await drain()
        #expect(h.sessions.list.count == 2)
        #expect(h.sessions.last?.snapshot.connects == 0)
        h.sessions.disconnectGate.open()
        await settle { h.sessions.last?.snapshot.connects == 1 }
        #expect(h.credentials.deleted.withLock { $0 } == [tvA.id])
        #expect(h.sessions.last?.snapshot.connects == 1)
    }

    @Test func foregroundWaitsForPreviousDisconnect() async {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        await h.connectCurrent()
        h.sessions.disconnectGate.close()
        h.model.scenePhaseChanged(.background)
        h.model.scenePhaseChanged(.active)
        await settle { h.sessions.list.count == 2 }
        await drain()
        #expect(h.sessions.last?.snapshot.connects == 0)

        h.sessions.disconnectGate.open()
        await settle { h.sessions.last?.snapshot.connects == 1 }
        #expect(h.sessions.list.first?.snapshot.disconnects == 1)
        #expect(h.sessions.last?.snapshot.connects == 1)
    }

    @Test func losingWiFiEndsHoldAndClosesSession() async throws {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        await h.connectCurrent()
        let session = try #require(h.sessions.last)
        h.model.beginHold(.up)
        await h.clock.waitForSleepers(1)

        h.wifi.isOn = false
        h.model.rescan()
        #expect(h.model.screen == .noWiFi)
        await h.clock.waitForSleepers(0)
        await settle { session.snapshot.disconnects == 1 }
        #expect(session.snapshot.disconnects == 1)
        #expect(h.discovery.scans.count == 1)
    }

    @Test func localNetworkDeniedPersistsUntilFound() async {
        let h = Harness()
        await h.appear()
        h.discovery.yield(.localNetworkDenied)
        h.discovery.finish()
        await settle { h.model.screen == .localNetworkDenied }

        h.model.rescan()
        await settle { h.discovery.scans.count == 2 }
        #expect(h.model.screen == .localNetworkDenied)

        h.discovery.yield(.found(tvA))
        await settle { h.model.screen != .localNetworkDenied }
        #expect(h.model.screen == .chooseTV)
    }

    @Test func statusMessageFollowsSessionProgress() async {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        await settle { h.sessions.last?.snapshot.connects == 1 }
        let session = h.sessions.last
        session?.emit(.failed(.unreachable))
        await settle { h.model.statusMessage == AppModel.unreachableMessage }
        session?.emit(.connecting)
        await settle { h.model.statusMessage == nil }
        #expect(h.model.statusMessage == nil)

        session?.emit(.failed(.approvalTimedOut))
        await settle { h.model.statusMessage == AppModel.approvalTimedOutMessage }
        session?.emit(.failed(.denied))
        await settle { h.model.screen == .pairingDenied }
        #expect(h.model.statusMessage == nil)
    }

    @Test func playPauseAlternates() async throws {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        await h.connectCurrent()
        h.model.playPause()
        h.model.playPause()
        h.model.playPause()
        let session = try #require(h.sessions.last)
        await settle { session.snapshot.sent.count == 3 }
        #expect(session.snapshot.sent == ["KEY_PAUSE", "KEY_PLAY", "KEY_PAUSE"])
    }

    @Test func keyboardEventsAndText() async throws {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        await h.connectCurrent()
        let session = try #require(h.sessions.last)
        session.keyboardContinuation.yield(true)
        await settle { h.model.keyboardRequested }
        #expect(h.model.keyboardRequested)
        h.model.sendText("hello")
        h.model.endText()
        await settle { session.snapshot.texts.count == 2 }
        #expect(session.snapshot.texts == ["hello", "<end>"])
        session.keyboardContinuation.yield(false)
        await settle { !h.model.keyboardRequested }
        #expect(!h.model.keyboardRequested)
    }

    @Test func endTextClearsKeyboardRequestSoALaterRequestPresentsAgain() async throws {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        await h.connectCurrent()
        let session = try #require(h.sessions.last)
        session.keyboardContinuation.yield(true)
        await settle { h.model.keyboardRequested }
        h.model.endText()
        #expect(!h.model.keyboardRequested)
        session.keyboardContinuation.yield(true)
        await settle { h.model.keyboardRequested }
        #expect(h.model.keyboardRequested)
    }

    @Test func turningOffSilencesUnreachableAndShowsAsleep() async throws {
        let h = Harness(known: [tvA], selected: tvA.id, power: .turnedOff)
        await h.appear()
        await h.connectCurrent()
        let session = try #require(h.sessions.last)
        h.model.togglePower()
        await settle { !h.model.powerBusy && h.discovery.scans.count == 2 }

        // The TV was turned off on purpose: its session giving up is not an error.
        session.emit(.failed(.unreachable))
        await settle { h.model.tvs.first?.status != .on }
        #expect(h.model.statusMessage == nil)
        #expect(h.model.tvs.first { $0.id == tvA.id }?.status == .asleep)
        session.emit(.failed(.approvalTimedOut))
        await drain()
        #expect(h.model.statusMessage == nil)
        // The scan after turning off does not find it; it is still shown as asleep.
        h.discovery.finish()
        await settle { !h.model.tvs.isEmpty && h.discovery.scans.count == 2 }
        await drain()
        #expect(h.model.tvs.first { $0.id == tvA.id }?.status == .asleep)

        // Once the TV is back, failures are reported again.
        session.emit(.connected)
        await settle { h.model.isConnected }
        session.emit(.failed(.unreachable))
        await settle { h.model.statusMessage == AppModel.unreachableMessage }
        #expect(h.model.statusMessage == AppModel.unreachableMessage)
        #expect(h.model.tvs.first { $0.id == tvA.id }?.status == .unreachable)
    }

    @Test func powerWithoutSessionExplainsWiFiOrTurnsOn() async {
        let h = Harness(known: [tvA], selected: tvA.id, wifi: false, power: .turnedOn)
        h.model.onAppear()
        #expect(h.model.screen == .noWiFi)
        h.model.togglePower()
        #expect(h.model.statusMessage == AppModel.notOnWiFiMessage)
        #expect(h.power.calls.withLock { $0 }.isEmpty)

        // Wi-Fi came back but nothing has refreshed yet: Power still works.
        h.wifi.isOn = true
        h.model.togglePower()
        #expect(h.model.statusMessage != "Choose a TV first.")
        await settle { h.power.calls.withLock { $0 } == [tvA.id] }
        #expect(h.power.calls.withLock { $0 } == [tvA.id])
        #expect(h.model.screen != .noWiFi)
    }
}

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
        /// Keys sent with `sendEnsuringConnection` (the power controller's path).
        var ensured: [String] = []
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
        log.withLock {
            $0.disconnects += 1
            $0.current = .idle
        }
    }

    func send(_ key: RemoteKey, _ action: KeyAction) async throws(SessionError) {
        try log.withLock { (l: inout Log) throws(SessionError) in
            guard l.current == .connected else { throw .unreachable }
            l.sent.append(action == .click ? key.rawValue : "\(key.rawValue) \(action.rawValue)")
        }
    }

    /// Like the real session: connects first when not connected (this fake then fails the send).
    func sendEnsuringConnection(_ key: RemoteKey, timeout: Duration) async throws(SessionError) {
        let connected = log.withLock { l in
            l.ensured.append(key.rawValue)
            if l.current != .connected { l.connects += 1 }
            return l.current == .connected
        }
        guard connected else { throw .unreachable }
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
    /// TVs that have a pairing token.
    let paired = Mutex<Set<TVID>>([])
    func load(_ id: TVID) -> TVCredentials? {
        paired.withLock { $0.contains(id) } ? TVCredentials(token: "t", pin: CertificatePin(sha256: Data())) : nil
    }
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
    /// Reported to `onPlan` before the gate, when set.
    let plan: PowerAction?
    let calls = Mutex<[TVID]>([])
    /// Holds every toggle while closed.
    let gate = Gate()
    init(_ outcome: PowerOutcome?, plan: PowerAction? = nil) {
        self.outcome = outcome
        self.plan = plan
    }
    func togglePower(
        tv: KnownTV, sender: any PowerKeySending, onPlan: @Sendable (PowerAction) async -> Void
    ) async -> PowerOutcome? {
        calls.withLock { $0.append(tv.id) }
        if let plan { await onPlan(plan) }
        await gate.wait()
        return outcome
    }
}

private final class FakeFetcher: TVInfoFetching {
    let infos: [String: TVDeviceInfo]
    let requested = Mutex<[String]>([])
    /// Answers counted once each fetch returns.
    let answered = Mutex(0)
    /// Holds every fetch while closed.
    let gate = Gate()
    init(_ infos: [TVDeviceInfo] = []) { self.infos = Dictionary(uniqueKeysWithValues: infos.map { ($0.host, $0) }) }
    func fetchInfo(host: String) async throws(TVInfoError) -> TVDeviceInfo {
        requested.withLock { $0.append(host) }
        await gate.wait()
        defer { answered.withLock { $0 += 1 } }
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
    /// What a real `PowerController` fetches, when the harness uses one.
    let powerFetcher: FakeFetcher
    let clock = TestClock()
    let wifi: WiFiSwitch
    let defaults: UserDefaults
    let model: AppModel

    /// `realPower` uses a real `PowerController` (fetching from `powerFetcher`, answering for
    /// `powerFetchable`) instead of `FakePower`.
    init(known: [TVDeviceInfo] = [], selected: TVID? = nil, wifi: Bool = true,
         power: PowerOutcome? = .turnedOn, powerPlan: PowerAction? = nil, fetchable: [TVDeviceInfo] = [],
         realPower: Bool = false, powerFetchable: [TVDeviceInfo] = [], multicast: Bool = true) {
        store = FakeKnownTVStore(known.map(knownTV))
        self.wifi = WiFiSwitch(wifi)
        self.power = FakePower(power, plan: powerPlan)
        fetcher = FakeFetcher(fetchable)
        powerFetcher = FakeFetcher(powerFetchable)
        defaults = UserDefaults(suiteName: "AppModelTests.\(UUID().uuidString)")!
        if let selected { defaults.set(selected.rawValue, forKey: "selectedTV") }
        let discovery = discovery, sessions = sessions, powerFake = self.power
        let powerFetcher = powerFetcher, clock = clock
        let iface = IPv4Interface(name: "en0", address: 0xC0A8_0102, netmask: 0xFFFF_FF00)
        let env = AppEnvironment(
            makeDiscovery: { discovery.make($0) },
            makeSession: { sessions.make($0, $1) },
            makePowerController: {
                guard realPower else { return powerFake }
                return PowerController(fetcher: powerFetcher, wake: { _, _, _ in }, interface: { nil }, clock: clock)
            },
            fetcher: fetcher,
            credentials: credentials,
            labels: labels,
            knownTVStore: store,
            wifiInterface: { [wifi = self.wifi] in wifi.isOn ? iface : nil },
            clock: clock,
            userDefaults: defaults,
            multicastEnabled: multicast
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
    @Test func powerTipShownOnceAfterFirstConnection() async {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        #expect(h.model.powerTipTV == nil)
        await h.connectCurrent()
        #expect(h.model.powerTipTV == tvA.id)
        h.model.dismissPowerTip()
        #expect(h.model.powerTipTV == nil)
        #expect(h.defaults.stringArray(forKey: AppModel.powerTipShownKey) == [tvA.id.rawValue])
        // Reconnecting the same TV does not show it again.
        h.sessions.last?.emit(.connecting)
        h.sessions.last?.emit(.connected)
        await drain()
        #expect(h.model.powerTipTV == nil)
    }

    @Test func powerTipSkippedForTVsAlreadyShown() async {
        let h = Harness(known: [tvA], selected: tvA.id)
        h.defaults.set([tvA.id.rawValue], forKey: AppModel.powerTipShownKey)
        await h.appear()
        await h.connectCurrent()
        #expect(h.model.powerTipTV == nil)
    }

    @Test func powerTipMessageNamesTheSettingAndPath() {
        #expect(AppModel.powerTipMessage
            == "To turn this TV on from your iPhone, the TV's “Power On with Mobile” setting must be on: "
            + "Settings → Connection → Network → Expert Settings → Power On with Mobile "
            + "(on some TVs: Settings → General → Network → Expert Settings).")
    }

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
            == "Couldn't turn on the TV. On the TV, turn on “Power On with Mobile”: Settings → Connection → Network → "
            + "Expert Settings → Power On with Mobile (on some TVs: Settings → General → Network → Expert Settings). "
            + "Then turn the TV off and try again.")
    }

    @Test func powerFailureWithoutMulticastSuggestsTheTVRemote() async {
        let h = Harness(known: [tvA], selected: tvA.id, power: .failedToWake, multicast: false)
        await h.appear()
        await settle { h.sessions.last?.snapshot.connects == 1 }
        h.model.togglePower()
        await settle { !h.model.powerBusy }
        #expect(h.model.statusMessage
            == "Couldn't turn on the TV. Check that “Power On with Mobile” is on: Settings → Connection → Network → "
            + "Expert Settings → Power On with Mobile (on some TVs: Settings → General → Network → Expert Settings). "
            + "If it is and the TV has been off for a long time, turn it on with its own remote.")
    }

    @Test func infoPlistMulticastFlagIsExpanded() {
        // FRMulticastEnabled must be the expanded FREE_REMOTE_MULTICAST build setting (YES or NO);
        // whether it matches the entitlements is enforced by the "Check entitlements" build phase.
        let raw = Bundle.main.object(forInfoDictionaryKey: "FRMulticastEnabled") as? String
        #expect(raw == "YES" || raw == "NO")
        #expect(AppEnvironment.buildHasMulticastEntitlement == (raw == "YES"))
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

    // MARK: Launch

    @Test func firstFrameShowsRememberedTVs() {
        // Before onAppear (the first frame), the remembered TVs and selection are already loaded, so the
        // screen never flashes "No TVs found".
        let h = Harness(known: [tvA, tvB], selected: tvA.id)
        #expect(h.model.selectedID == tvA.id)
        #expect(h.model.tvs.map(\.id).sorted { $0.rawValue < $1.rawValue } == [tvA.id, tvB.id])
        #expect(h.model.screen == .ready)
        #expect(h.discovery.scans.isEmpty) // no network work until onAppear
        #expect(h.sessions.list.isEmpty)
    }

    @Test func firstFrameWithoutSelectionShowsChooseTV() {
        let h = Harness(known: [tvA, tvB])
        #expect(h.model.screen == .chooseTV)
    }

    // MARK: TV details

    @Test func detailsUnknownTVIsNil() async {
        let h = Harness(known: [tvA])
        await h.appear()
        #expect(h.model.details(for: tvB.id) == nil)
        #expect(await h.model.liveDetails(for: tvB.id) == nil)
    }

    @Test func detailsFromRecordsBeforeTheTVAnswers() async throws {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        let details = try #require(h.model.details(for: tvA.id))
        #expect(details.known.lastHost == tvA.host)
        #expect(details.info == nil) // not seen by a scan yet
        #expect(!details.isLive)
        #expect(!details.paired)
    }

    @Test func liveDetailsAskTheTV() async throws {
        var fresh = tvA
        fresh.details.resolution = "3840x2160"
        let h = Harness(known: [tvA], fetchable: [fresh])
        h.credentials.paired.withLock { _ = $0.insert(tvA.id) }
        await h.appear()
        let details = try #require(await h.model.liveDetails(for: tvA.id))
        #expect(details.isLive)
        #expect(details.info?.details.resolution == "3840x2160")
        #expect(details.paired)
        #expect(h.fetcher.requested.withLock { $0 }.contains(tvA.host))
    }

    @Test func liveDetailsFallBackWhenTheTVDoesNotAnswer() async throws {
        let h = Harness(known: [tvA])
        await h.appear()
        h.discovery.yield(.found(tvA))
        await settle { h.model.tvs.first?.status == .on }
        let details = try #require(await h.model.liveDetails(for: tvA.id))
        #expect(!details.isLive)
        #expect(details.info == tvA) // from the scan
    }

    @Test func liveDetailsIgnoreADifferentTVAtTheAddress() async throws {
        let impostor = info("uuid:other", host: tvA.host, name: "Other")
        let h = Harness(known: [tvA], fetchable: [impostor])
        await h.appear()
        let details = try #require(await h.model.liveDetails(for: tvA.id))
        #expect(!details.isLive)
        #expect(details.info == nil)
    }

    @Test func liveDetailsUpdateTheTVsStatus() async throws {
        let h = Harness(known: [tvA], fetchable: [tvA])
        await h.appear()
        h.discovery.finish() // the scan missed the TV
        await drain()
        #expect(h.model.tvs.first?.status == .unreachable)
        let details = try #require(await h.model.liveDetails(for: tvA.id))
        #expect(details.status == .on)
        #expect(h.model.tvs.first?.status == .on)
    }

    @Test func liveDetailsOffWiFiDoNotAskTheTV() async throws {
        let h = Harness(known: [tvA], fetchable: [tvA])
        await h.appear()
        h.discovery.finish()
        await drain()
        let before = h.fetcher.requested.withLock { $0.count }
        h.wifi.isOn = false
        h.model.rescan()
        let details = try #require(await h.model.liveDetails(for: tvA.id))
        #expect(!details.isLive)
        #expect(h.fetcher.requested.withLock { $0.count } == before)
    }

    @Test func liveDetailsForATVForgottenMeanwhileIsNil() async {
        let h = Harness(known: [tvA], fetchable: [tvA])
        await h.appear()
        h.discovery.finish()
        await drain()
        h.fetcher.gate.close()
        let task = Task { await h.model.liveDetails(for: tvA.id) }
        await settle { h.fetcher.gate.waiting == 1 }
        h.model.forget(tvA.id)
        h.fetcher.gate.open()
        #expect(await task.value == nil)
        #expect(h.model.tvs.isEmpty) // not resurrected by the late answer
    }

    // MARK: Scan Again feedback

    @Test func automaticScansShowNoFeedback() async {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        #expect(h.model.scanFeedback == nil)
        h.discovery.finish()
        await drain()
        #expect(h.model.scanFeedback == nil)
    }

    @Test func scanAgainShowsProgressThenNewTVCount() async {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        h.discovery.finish()
        await drain()

        h.model.scanAgain()
        #expect(h.model.scanFeedback == .scanning)
        await settle { h.discovery.scans.count == 2 }
        h.discovery.yield(.found(tvA)) // already known: not new
        h.discovery.yield(.found(tvB))
        h.discovery.yield(.found(tvC))
        h.discovery.finish()
        await settle { h.model.scanFeedback != .scanning }
        #expect(h.model.scanFeedback == .found(newTVs: 2))

        await settle { h.clock.sleeperCount > 0 }
        h.clock.advance(by: AppModel.scanResultDuration)
        await settle { h.model.scanFeedback == nil }
        #expect(h.model.scanFeedback == nil)
    }

    @Test func scanAgainReportsNoNewTVs() async {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        h.discovery.finish()
        await drain()

        h.model.scanAgain()
        await settle { h.discovery.scans.count == 2 }
        h.discovery.yield(.found(tvA))
        h.discovery.finish()
        await settle { h.model.scanFeedback != .scanning }
        #expect(h.model.scanFeedback == .found(newTVs: 0))
    }

    @Test func scanAgainJoinsScanAlreadyRunning() async {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear() // the launch scan is still running
        h.model.scanAgain()
        #expect(h.model.scanFeedback == .scanning)
        h.model.scanAgain() // a second tap does nothing more
        await drain()
        #expect(h.discovery.scans.count == 1)
        h.discovery.yield(.found(tvB))
        h.discovery.finish()
        await settle { h.model.scanFeedback != .scanning }
        #expect(h.model.scanFeedback == .found(newTVs: 1))
    }

    @Test func scanAgainDuringResultStartsFreshScan() async {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        h.discovery.finish()
        await drain()
        h.model.scanAgain()
        await settle { h.discovery.scans.count == 2 }
        h.discovery.finish()
        await settle { h.model.scanFeedback == .found(newTVs: 0) }

        h.model.scanAgain()
        #expect(h.model.scanFeedback == .scanning)
        await settle { h.discovery.scans.count == 3 }
        // The first result's timer must not clear the new scan's spinner.
        h.clock.advance(by: AppModel.scanResultDuration)
        await drain()
        #expect(h.model.scanFeedback == .scanning)
    }

    @Test func scanAgainOffWiFiShowsNoSpinner() async {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        h.discovery.finish()
        await drain()
        h.wifi.isOn = false
        h.model.scanAgain()
        #expect(h.model.scanFeedback == nil)
        #expect(h.model.screen == .noWiFi)
    }

    @Test func backgroundCancelsScanFeedback() async {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        h.discovery.finish()
        await drain()
        h.model.scanAgain()
        #expect(h.model.scanFeedback == .scanning)
        h.model.scenePhaseChanged(.background)
        #expect(h.model.scanFeedback == nil)
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

        // The TV was turned off on purpose: its session giving up is not an error, and the status
        // line says the TV is off rather than "Connecting…".
        session.emit(.failed(.unreachable))
        await settle { h.model.tvs.first?.status != .on }
        #expect(h.model.statusMessage == AppModel.turnedOffMessage)
        #expect(h.model.statusText == AppModel.turnedOffMessage)
        #expect(h.model.tvs.first { $0.id == tvA.id }?.status == .asleep)
        session.emit(.failed(.approvalTimedOut))
        await drain()
        #expect(h.model.statusMessage == AppModel.turnedOffMessage)
        h.model.statusMessage = nil
        #expect(h.model.statusText == AppModel.turnedOffMessage)
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

    // MARK: - Power never revives a closed session

    @Test func powerAfterSwitchingTVDoesNotReviveOldSession() async throws {
        let h = Harness(known: [tvA, tvB], selected: tvA.id, realPower: true, powerFetchable: [tvA])
        await h.appear()
        await h.connectCurrent()
        let old = try #require(h.sessions.last)
        h.powerFetcher.gate.close()
        h.model.togglePower()
        await settle { h.powerFetcher.gate.waiting == 1 }

        h.model.select(tvB.id)
        await settle { old.snapshot.disconnects == 1 }
        h.powerFetcher.gate.open() // the TV reports on: the controller sends KEY_POWER
        await settle { h.powerFetcher.answered.withLock { $0 } == 1 }
        await drain()
        #expect(old.snapshot.connects == 1)
        #expect(old.snapshot.ensured.isEmpty)
        #expect(old.snapshot.sent.isEmpty)
        #expect(h.sessions.last?.snapshot.ensured.isEmpty == true)
    }

    @Test func powerAfterForgettingTVDoesNotReviveOldSession() async throws {
        let h = Harness(known: [tvA, tvB], selected: tvA.id, realPower: true, powerFetchable: [tvA])
        await h.appear()
        await h.connectCurrent()
        let old = try #require(h.sessions.last)
        h.powerFetcher.gate.close()
        h.model.togglePower()
        await settle { h.powerFetcher.gate.waiting == 1 }

        h.model.forget(tvA.id)
        await settle { old.snapshot.disconnects == 1 && h.credentials.deleted.withLock { $0 } == [tvA.id] }
        h.powerFetcher.gate.open()
        await settle { h.powerFetcher.answered.withLock { $0 } == 1 }
        await drain()
        #expect(old.snapshot.connects == 1)
        #expect(old.snapshot.ensured.isEmpty)
        #expect(old.snapshot.sent.isEmpty)
        #expect(h.sessions.list.count == 1)
    }

    @Test func powerKeyWaitsForEarlierTeardown() async throws {
        let h = Harness(known: [tvA], selected: tvA.id, realPower: true, powerFetchable: [tvA])
        await h.appear()
        await h.connectCurrent()
        h.sessions.disconnectGate.close()
        h.model.scenePhaseChanged(.background)
        h.model.scenePhaseChanged(.active)
        await settle { h.sessions.list.count == 2 }
        let second = try #require(h.sessions.last)

        h.model.togglePower()
        await settle { h.powerFetcher.answered.withLock { $0 } == 1 }
        await drain()
        #expect(second.snapshot.ensured.isEmpty) // still queued behind the old disconnect
        h.sessions.disconnectGate.open()
        await settle { second.snapshot.ensured == ["KEY_POWER"] }
        #expect(second.snapshot.connects >= 1)
        #expect(second.snapshot.ensured == ["KEY_POWER"])
    }

    // MARK: - Status line

    @Test func statusTextDescribesTheSelectedSession() async throws {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        await settle { h.sessions.last?.snapshot.connects == 1 }
        let session = try #require(h.sessions.last)

        session.emit(.connecting)
        await settle { h.model.statusText == "Connecting…" }
        #expect(h.model.statusText == "Connecting…")

        session.emit(.awaitingApproval)
        await settle { h.model.screen == .pairing }
        #expect(h.model.statusText == "Pairing with the TV…")

        session.emit(.failed(.unreachable))
        await settle { h.model.statusMessage != nil }
        #expect(h.model.statusText == AppModel.unreachableMessage)
        // Even with the message gone, a session that gave up is never shown as connecting.
        h.model.statusMessage = nil
        #expect(h.model.statusText == AppModel.unreachableMessage)
        session.emit(.failed(.approvalTimedOut))
        await settle { h.model.statusMessage != nil }
        h.model.statusMessage = nil
        #expect(h.model.statusText == AppModel.approvalTimedOutMessage)

        session.emit(.connected)
        await settle { h.model.isConnected }
        #expect(h.model.statusText == nil)
    }

    @Test func statusShowsPowerDirectionWhileRunning() async {
        let off = Harness(known: [tvA], selected: tvA.id, power: .turnedOff, powerPlan: .turnOff)
        await off.appear()
        await off.connectCurrent()
        off.power.gate.close()
        off.model.togglePower()
        await settle { off.power.gate.waiting == 1 }
        #expect(off.model.powerDirection == .turningOff)
        #expect(off.model.statusText == "Turning off…")
        off.power.gate.open()
        await settle { !off.model.powerBusy }
        #expect(off.model.powerDirection == nil)
        #expect(off.model.statusText != "Turning off…")

        let on = Harness(known: [tvA], selected: tvA.id, power: .turnedOn, powerPlan: .wakeOnLAN)
        await on.appear()
        await settle { on.sessions.last?.snapshot.connects == 1 }
        on.power.gate.close()
        on.model.togglePower()
        await settle { on.power.gate.waiting == 1 }
        #expect(on.model.statusText == "Turning on…")
        on.power.gate.open()
        await settle { !on.model.powerBusy }
        #expect(on.model.powerDirection == nil)
    }

    // MARK: - Local Network prompt

    @Test func returningFromPromptRescansWhenNothingWasFound() async {
        let h = Harness()
        await h.appear()
        h.discovery.finish()
        await settle { h.model.screen == .noTVs }

        // The Local Network prompt was answered after the scan gave up.
        h.model.scenePhaseChanged(.inactive)
        h.model.scenePhaseChanged(.active)
        await settle { h.discovery.scans.count == 2 }
        #expect(h.discovery.scans.count == 2)

        h.discovery.yield(.found(tvA))
        h.discovery.finish()
        await settle { h.model.selectedID == tvA.id }
        // With a TV found, coming back from an alert does not scan again.
        h.model.scenePhaseChanged(.inactive)
        h.model.scenePhaseChanged(.active)
        await drain()
        #expect(h.discovery.scans.count == 2)
    }

    @Test func returningFromPromptRescansAfterDenial() async {
        let h = Harness()
        await h.appear()
        h.discovery.yield(.localNetworkDenied)
        await settle { h.model.screen == .localNetworkDenied }
        h.model.scenePhaseChanged(.inactive)
        h.model.scenePhaseChanged(.active)
        await settle { h.discovery.scans.count == 2 }
        #expect(h.discovery.scans.count == 2)
        h.discovery.yield(.found(tvA))
        await settle { h.model.screen != .localNetworkDenied }
        #expect(h.model.screen == .chooseTV)
    }

    @Test func deniedRetriesScanEveryThreeSecondsUntilFound() async {
        let h = Harness()
        await h.appear()
        h.discovery.yield(.localNetworkDenied)
        await h.clock.waitForSleepers(1)
        #expect(h.clock.requestedSleeps == [AppModel.deniedRetryInterval])
        #expect(AppModel.deniedRetryInterval == .seconds(3))

        // A scan still running is not interrupted.
        h.clock.advance(by: .seconds(3))
        await h.clock.waitForSleepers(1)
        #expect(h.discovery.scans.count == 1)

        h.discovery.finish()
        await drain()
        h.clock.advance(by: .seconds(3))
        await settle { h.discovery.scans.count == 2 }
        #expect(h.discovery.scans.count == 2)

        h.discovery.yield(.found(tvA))
        await h.clock.waitForSleepers(0)
        h.clock.advance(by: .seconds(30))
        await drain()
        #expect(h.discovery.scans.count == 2)
        #expect(h.model.screen == .chooseTV)
    }

    @Test func deniedRetriesAreBoundedAndStopInBackground() async {
        let h = Harness()
        await h.appear()
        h.discovery.yield(.localNetworkDenied)
        h.discovery.finish()
        await drain() // the scan has ended, so a retry may start one
        for retry in 1...AppModel.deniedRetryLimit {
            await h.clock.waitForSleepers(1)
            h.clock.advance(by: .seconds(3))
            await settle { h.discovery.scans.count == retry + 1 }
            #expect(h.discovery.scans.count == retry + 1)
            h.discovery.finish()
            await drain()
        }
        await h.clock.waitForSleepers(0)
        h.clock.advance(by: .seconds(30))
        await drain()
        #expect(h.discovery.scans.count == AppModel.deniedRetryLimit + 1)

        // Retries start again with the next denial, and background cancels them.
        h.model.scenePhaseChanged(.background)
        h.model.scenePhaseChanged(.active)
        await settle { h.discovery.scans.count == AppModel.deniedRetryLimit + 2 }
        h.discovery.yield(.localNetworkDenied)
        await h.clock.waitForSleepers(1)
        h.model.scenePhaseChanged(.background)
        await h.clock.waitForSleepers(0)
        h.clock.advance(by: .seconds(30))
        await drain()
        #expect(h.discovery.scans.count == AppModel.deniedRetryLimit + 2)
    }

    // MARK: - Recovery and manual add

    @Test func scanRecoversApprovalTimedOutSession() async throws {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        await settle { h.sessions.last?.snapshot.connects == 1 }
        let first = try #require(h.sessions.last)
        first.emit(.failed(.approvalTimedOut))
        await settle { h.model.statusMessage == AppModel.approvalTimedOutMessage }

        h.discovery.yield(.found(tvA))
        await settle { h.sessions.list.count == 2 && h.sessions.last?.snapshot.connects == 1 }
        #expect(h.sessions.list.count == 2)
        #expect(first.snapshot.disconnects == 1)
        #expect(h.sessions.last?.snapshot.connects == 1)
    }

    @Test func cancelledManualAddSelectsNothing() async {
        let h = Harness(fetchable: [tvA])
        h.fetcher.gate.close()
        let add = Task { await h.model.addManually(host: tvA.host) }
        await settle { h.fetcher.gate.waiting == 1 }
        add.cancel()
        h.fetcher.gate.open()
        #expect(await add.value == false)
        #expect(h.model.selectedID == nil)
        #expect(h.model.tvs.isEmpty)
        #expect(h.store.load().tvs.isEmpty)
        #expect(h.sessions.list.isEmpty)
    }
}

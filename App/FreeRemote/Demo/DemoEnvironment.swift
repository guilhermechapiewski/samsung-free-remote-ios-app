import Foundation
import Observation
import SamsungTVKit
import Synchronization
import SwiftUI

/// Demo mode (launch argument `-demo`) and SwiftUI previews: three fictional TVs on an in-memory
/// network where every command succeeds at once. Never touches the network, Keychain or iCloud.
@MainActor
enum DemoEnvironment {
    static let launchArgument = "-demo"

    /// What the demo shows. `-demo` alone is `.remote`; add one more argument for another state.
    enum Scenario: String, CaseIterable {
        /// Connected to the living room TV.
        case remote = "-demo"
        /// No TVs found.
        case empty = "-demo-empty"
        /// Three TVs and none selected yet.
        case chooseTV = "-demo-choose"
        /// The living room TV is waiting for Allow on the TV.
        case pairing = "-demo-pairing"
    }

    /// The scenario named by the launch arguments, or nil when demo mode was not requested.
    static var requestedScenario: Scenario? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains(launchArgument) else { return nil }
        return Scenario.allCases.last { arguments.contains($0.rawValue) }
    }

    static let livingRoom = TVID(rawValue: "demo:living-room")
    static let bedroom = TVID(rawValue: "demo:bedroom")
    static let patio = TVID(rawValue: "demo:patio")

    private static let defaultsSuite = "FreeRemote.demo"

    /// `keyLog`, when given, records every key the demo sessions send.
    static func make(_ scenario: Scenario = .remote, keyLog: DemoKeyLog? = nil) -> AppEnvironment {
        let livingRoomTV = tv(livingRoom, "Living Room", model: "65\" 4K TV", host: "10.0.0.21", mac: "02:00:00:00:00:21")
        let bedroomTV = tv(bedroom, "Bedroom", model: "43\" 4K TV", host: "10.0.0.22", mac: "02:00:00:00:00:22",
                           power: .standby)
        let patioTV = tv(patio, "Patio", model: "55\" Outdoor TV", host: "10.0.0.23", mac: "02:00:00:00:00:23")

        var registry = KnownTVRegistry()
        for info in [livingRoomTV, bedroomTV, patioTV] { registry.record(info, at: .now) }
        // The patio TV is known but never answers a scan, so it shows as unreachable.
        let found = scenario == .empty ? [] : [livingRoomTV, bedroomTV]
        if scenario == .empty { registry = KnownTVRegistry() }

        // A fresh, demo-only defaults domain that starts with the living room TV selected.
        let defaults = UserDefaults(suiteName: defaultsSuite) ?? .standard
        defaults.removePersistentDomain(forName: defaultsSuite)
        if scenario == .remote || scenario == .pairing {
            defaults.set(livingRoom.rawValue, forKey: AppModel.selectedTVKey)
        }
        let connectsTo: SessionState = scenario == .pairing ? .awaitingApproval : .connected

        let interface = IPv4Interface(name: "en0", address: 0x0A00_0002, netmask: 0xFFFF_FF00)
        let fetcher = DemoFetcher()
        return AppEnvironment(
            makeDiscovery: { _ in
                AsyncStream { continuation in
                    for info in found { continuation.yield(.found(info)) }
                    continuation.finish()
                }
            },
            makeSession: { _, _ in DemoSession(connectsTo: connectsTo, keyLog: keyLog) },
            makePowerController: { DemoPower() },
            fetcher: fetcher,
            credentials: DemoCredentials(),
            labels: DemoLabels(),
            knownTVStore: DemoKnownTVStore(registry),
            wifiInterface: { interface },
            clock: ContinuousClock(),
            userDefaults: defaults
        )
    }

    private static func tv(_ id: TVID, _ name: String, model: String, host: String, mac: String,
                           power: TVPowerState = .on) -> TVDeviceInfo {
        TVDeviceInfo(id: id, host: host, name: name, modelName: model, modelCode: "DEMO",
                     wifiMAC: MACAddress(mac), networkType: "wireless", powerState: power, tokenAuthSupported: true)
    }
}

/// The keys demo sessions sent, so UI tests can check what a button sends (demo mode only).
@MainActor
@Observable
final class DemoKeyLog {
    /// The raw value of the last key sent, e.g. `KEY_VOLUP`.
    private(set) var lastKey: String?
    /// How many keys were sent.
    private(set) var count = 0

    func record(_ key: RemoteKey) {
        lastKey = key.rawValue
        count += 1
    }
}

/// A session that connects at once (or waits for approval forever) and accepts every key and text.
private final class DemoSession: RemoteSessionProtocol {
    let states: AsyncStream<SessionState>
    let keyboardEvents: AsyncStream<Bool>
    private let stateContinuation: AsyncStream<SessionState>.Continuation
    private let keyboardContinuation: AsyncStream<Bool>.Continuation
    private let state = Mutex<SessionState>(.idle)
    private let connectsTo: SessionState
    private let keyLog: DemoKeyLog?

    init(connectsTo: SessionState, keyLog: DemoKeyLog?) {
        self.connectsTo = connectsTo
        self.keyLog = keyLog
        (states, stateContinuation) = AsyncStream.makeStream()
        (keyboardEvents, keyboardContinuation) = AsyncStream.makeStream()
    }

    var currentState: SessionState { state.withLock { $0 } }

    func connect() async {
        state.withLock { $0 = connectsTo }
        stateContinuation.yield(connectsTo)
    }

    func disconnect() async {
        state.withLock { $0 = .idle }
        stateContinuation.finish()
        keyboardContinuation.finish()
    }

    func send(_ key: RemoteKey, _ action: KeyAction) async throws(SessionError) {
        // A hold's release is not a key of its own.
        guard action != .release, let keyLog else { return }
        await keyLog.record(key)
    }
    func sendText(_ s: String) async throws(SessionError) {}
    func sendTextEnd() async throws(SessionError) {}
    func sendEnsuringConnection(_ key: RemoteKey, timeout: Duration) async throws(SessionError) {}
}

private struct DemoPower: PowerToggling {
    func togglePower(tv: KnownTV, sender: any PowerKeySending) async -> PowerOutcome? { .turnedOff }
}

/// No TV answers at a typed-in address in demo mode.
private struct DemoFetcher: TVInfoFetching {
    func fetchInfo(host: String) async throws(TVInfoError) -> TVDeviceInfo { throw .unreachable }
}

private struct DemoCredentials: CredentialStore {
    func load(_ id: TVID) -> TVCredentials? { nil }
    func save(_ c: TVCredentials, for id: TVID) throws {}
    func delete(_ id: TVID) {}
}

private final class DemoLabels: LabelStore {
    private let labels = Mutex<[TVID: String]>([:])
    let changes: AsyncStream<Void>
    private let changesContinuation: AsyncStream<Void>.Continuation

    init() { (changes, changesContinuation) = AsyncStream.makeStream() }

    func label(for id: TVID) -> String? { labels.withLock { $0[id] } }
    func setLabel(_ s: String?, for id: TVID) { labels.withLock { $0[id] = s } }
}

private final class DemoKnownTVStore: KnownTVPersisting {
    private let registry: Mutex<KnownTVRegistry>
    init(_ registry: KnownTVRegistry) { self.registry = Mutex(registry) }
    func load() -> KnownTVRegistry { registry.withLock { $0 } }
    func save(_ r: KnownTVRegistry) throws { registry.withLock { $0 = r } }
}

/// An invisible element (identifier "demo-last-key") exposing the demo key log to UI tests: its label is the
/// last key's raw value and its value the number of keys sent.
struct DemoKeyLogView: View {
    let log: DemoKeyLog

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(log.lastKey ?? "none")
            .accessibilityValue(String(log.count))
            .accessibilityIdentifier("demo-last-key")
    }
}

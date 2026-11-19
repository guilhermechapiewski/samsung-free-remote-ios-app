import Foundation
import SamsungTVKit
import Synchronization

/// Demo mode (launch argument `-demo`) and SwiftUI previews: three fictional TVs on an in-memory
/// network where every command succeeds at once. Never touches the network, Keychain or iCloud.
@MainActor
enum DemoEnvironment {
    static let launchArgument = "-demo"

    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains(launchArgument) }

    static let livingRoom = TVID(rawValue: "demo:living-room")
    static let bedroom = TVID(rawValue: "demo:bedroom")
    static let patio = TVID(rawValue: "demo:patio")

    private static let defaultsSuite = "FreeRemote.demo"

    static func make() -> AppEnvironment {
        let livingRoomTV = tv(livingRoom, "Living Room", model: "65\" 4K TV", host: "10.0.0.21", mac: "02:00:00:00:00:21")
        let bedroomTV = tv(bedroom, "Bedroom", model: "43\" 4K TV", host: "10.0.0.22", mac: "02:00:00:00:00:22",
                           power: .standby)
        let patioTV = tv(patio, "Patio", model: "55\" Outdoor TV", host: "10.0.0.23", mac: "02:00:00:00:00:23")

        var registry = KnownTVRegistry()
        for info in [livingRoomTV, bedroomTV, patioTV] { registry.record(info, at: .now) }
        // The patio TV is known but never answers a scan, so it shows as unreachable.
        let found = [livingRoomTV, bedroomTV]

        // A fresh, demo-only defaults domain that starts with the living room TV selected.
        let defaults = UserDefaults(suiteName: defaultsSuite) ?? .standard
        defaults.removePersistentDomain(forName: defaultsSuite)
        defaults.set(livingRoom.rawValue, forKey: AppModel.selectedTVKey)

        let interface = IPv4Interface(name: "en0", address: 0x0A00_0002, netmask: 0xFFFF_FF00)
        let fetcher = DemoFetcher()
        return AppEnvironment(
            makeDiscovery: { _ in
                AsyncStream { continuation in
                    for info in found { continuation.yield(.found(info)) }
                    continuation.finish()
                }
            },
            makeSession: { _, _ in DemoSession() },
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

/// A session that connects at once and accepts every key and text.
private final class DemoSession: RemoteSessionProtocol {
    let states: AsyncStream<SessionState>
    let keyboardEvents: AsyncStream<Bool>
    private let stateContinuation: AsyncStream<SessionState>.Continuation
    private let keyboardContinuation: AsyncStream<Bool>.Continuation
    private let state = Mutex<SessionState>(.idle)

    init() {
        (states, stateContinuation) = AsyncStream.makeStream()
        (keyboardEvents, keyboardContinuation) = AsyncStream.makeStream()
    }

    var currentState: SessionState { state.withLock { $0 } }

    func connect() async {
        state.withLock { $0 = .connected }
        stateContinuation.yield(.connected)
    }

    func disconnect() async {
        state.withLock { $0 = .idle }
        stateContinuation.finish()
        keyboardContinuation.finish()
    }

    func send(_ key: RemoteKey, _ action: KeyAction) async throws(SessionError) {}
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

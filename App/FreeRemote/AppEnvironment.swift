import Foundation
import SamsungTVKit

/// The part of `RemoteSession` the app uses, so tests and demo mode can substitute a fake.
protocol RemoteSessionProtocol: PowerKeySending {
    /// State changes (single consumer).
    var states: AsyncStream<SessionState> { get }
    /// `true` when the TV shows its on-screen keyboard, `false` when it hides it (single consumer).
    var keyboardEvents: AsyncStream<Bool> { get }
    var currentState: SessionState { get async }
    func connect() async
    func disconnect() async
    func send(_ key: RemoteKey, _ action: KeyAction) async throws(SessionError)
    func sendText(_ s: String) async throws(SessionError)
    func sendTextEnd() async throws(SessionError)
}

extension RemoteSession: RemoteSessionProtocol {}

/// The state-aware power toggle (`PowerController` conforms). `onPlan` is told what the toggle
/// will do once the TV's power state is known.
protocol PowerToggling: Sendable {
    func togglePower(
        tv: KnownTV, sender: any PowerKeySending, onPlan: @Sendable (PowerAction) async -> Void
    ) async -> PowerOutcome?
}

extension PowerController: PowerToggling {}

/// Where the known-TV registry is persisted (`FileKnownTVStore` conforms).
protocol KnownTVPersisting: Sendable {
    func load() -> KnownTVRegistry
    func save(_ r: KnownTVRegistry) throws
}

extension FileKnownTVStore: KnownTVPersisting {}

/// Every dependency of `AppModel`: real objects in the app, fakes in tests and demo mode.
struct AppEnvironment {
    /// Starts one scan that also probes `knownHosts`; the stream ends when the scan is complete.
    var makeDiscovery: @Sendable (_ knownHosts: [String]) async -> AsyncStream<DiscoveryEvent>
    var makeSession: @Sendable (_ id: TVID, _ host: String) -> any RemoteSessionProtocol
    var makePowerController: @Sendable () -> any PowerToggling
    /// Used by "Add TV by IP address".
    var fetcher: any TVInfoFetching
    var credentials: any CredentialStore
    var labels: any LabelStore
    var knownTVStore: any KnownTVPersisting
    /// The current Wi-Fi interface, or nil when not on Wi-Fi.
    var wifiInterface: @Sendable () -> IPv4Interface?
    var clock: any Clock<Duration>
    var userDefaults: UserDefaults
}

extension AppEnvironment {
    /// The real network, Keychain, iCloud and file-backed dependencies.
    static func live() -> AppEnvironment {
        let credentials = KeychainCredentialStore()
        let discoveryFetcher = HTTPTVInfoFetcher()
        let wifiInterface: @Sendable () -> IPv4Interface? = {
            NetworkInterfaces.wifiIPv4(from: NetworkInterfaces.current())
        }
        return AppEnvironment(
            makeDiscovery: { knownHosts in
                await DiscoveryCoordinator(
                    sources: [BonjourSamsungBrowser(), SSDPSearcher()],
                    fetcher: discoveryFetcher,
                    knownHosts: knownHosts
                ).scan()
            },
            makeSession: { id, host in
                RemoteSession(id: id, host: host, credentials: credentials, transport: { URLSessionWebSocketTransport() })
            },
            makePowerController: {
                PowerController(
                    fetcher: HTTPTVInfoFetcher(timeout: .seconds(1)),
                    wake: { mac, interface in await WakeOnLAN.send(to: mac, via: interface) },
                    interface: wifiInterface
                )
            },
            fetcher: discoveryFetcher,
            credentials: credentials,
            labels: ICloudLabelStore(),
            knownTVStore: FileKnownTVStore(),
            wifiInterface: wifiInterface,
            clock: ContinuousClock(),
            userDefaults: .standard
        )
    }
}

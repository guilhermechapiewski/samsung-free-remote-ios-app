import os

public enum PowerOutcome: Equatable, Sendable {
    case turnedOff, turnedOn, failedToWake, noMACKnown, notOnWiFi
    /// The TV was on but the power key could not be delivered.
    case failed
}

/// Sends one key, connecting first if needed. `RemoteSession` conforms.
public protocol PowerKeySending: Sendable {
    func sendEnsuringConnection(_ key: RemoteKey, timeout: Duration) async throws(SessionError)
}

extension RemoteSession: PowerKeySending {}

/// State-aware power toggle: checks the TV's power state, then turns it off, wakes it from network
/// standby with the power key, or wakes it with a magic packet.
public actor PowerController {
    private static let log = Logger(subsystem: "SamsungTVKit", category: "PowerController")
    static let keyTimeout: Duration = .seconds(3)
    static let pollInterval: Duration = .seconds(1)

    private let fetcher: any TVInfoFetching
    private let wake: @Sendable (MACAddress, IPv4Interface) async -> Void
    private let interface: @Sendable () -> IPv4Interface?
    private let clock: any Clock<Duration>
    private let wakeTimeout: Duration
    private var inFlight = false

    /// `fetcher` should use a short timeout (the app passes 1 s); `wake` sends the magic packet;
    /// `interface` returns the current Wi-Fi interface, or nil when not on Wi-Fi.
    public init(
        fetcher: any TVInfoFetching,
        wake: @escaping @Sendable (MACAddress, IPv4Interface) async -> Void,
        interface: @escaping @Sendable () -> IPv4Interface?,
        clock: any Clock<Duration> = ContinuousClock(),
        wakeTimeout: Duration = .seconds(20)
    ) {
        self.fetcher = fetcher
        self.wake = wake
        self.interface = interface
        self.clock = clock
        self.wakeTimeout = wakeTimeout
    }

    /// Toggles the TV's power. Returns nil (ignored) while a previous toggle is still in flight.
    public func togglePower(tv: KnownTV, sender: any PowerKeySending) async -> PowerOutcome? {
        guard !inFlight else { return nil }
        inFlight = true
        defer { inFlight = false }

        switch PowerPlanner.action(for: await fetchPower(tv.lastHost)) {
        case .turnOff:
            do {
                try await sender.sendEnsuringConnection(.power, timeout: Self.keyTimeout)
                return .turnedOff
            } catch {
                Self.log.error("Power key to \(tv.lastHost, privacy: .private) failed: \(String(describing: error), privacy: .public)")
                return .failed
            }
        case .wakeFromStandby:
            do {
                try await sender.sendEnsuringConnection(.power, timeout: Self.keyTimeout)
                return await pollUntilOn(tv.lastHost) ? .turnedOn : .failedToWake
            } catch {
                Self.log.info("Standby TV refused the connection; falling back to wake-on-LAN")
                return await wakeOnLAN(tv)
            }
        case .wakeOnLAN:
            return await wakeOnLAN(tv)
        }
    }

    private func wakeOnLAN(_ tv: KnownTV) async -> PowerOutcome {
        guard let mac = tv.wifiMAC else { return .noMACKnown }
        guard let iface = interface() else { return .notOnWiFi }
        await wake(mac, iface)
        return await pollUntilOn(tv.lastHost) ? .turnedOn : .failedToWake
    }

    private func fetchPower(_ host: String) async -> Result<TVPowerState, TVInfoError> {
        do {
            return .success(try await fetcher.fetchInfo(host: host).powerState)
        } catch {
            return .failure(error)
        }
    }

    /// Polls every second until the TV reports `.on` (true) or `wakeTimeout` elapses (false).
    private func pollUntilOn(_ host: String) async -> Bool {
        let clock = clock // a local: opening the stored existential directly fails to type-check
        let elapsed = stopwatch(clock)
        while elapsed() < wakeTimeout {
            do {
                try await clock.sleep(for: Self.pollInterval)
            } catch {
                return false // cancelled
            }
            if case .success(.on) = await fetchPower(host) { return true }
        }
        return false
    }
}

/// Returns a closure measuring the time elapsed on `clock` since this call.
private func stopwatch<C: Clock<Duration>>(_ clock: C) -> @Sendable () -> Duration {
    let start = clock.now
    return { start.duration(to: clock.now) }
}

import os

public enum PowerOutcome: Equatable, Sendable {
    case turnedOff, turnedOn, failedToWake, noMACKnown, notOnWiFi
    /// The power key could not be delivered (and wake-on-LAN was not an appropriate fallback).
    case failed(SessionError)
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
    /// How long a power-on waits for the TV to report on. Some TVs take well over 20 s to boot from
    /// network standby (a 2022 model in testing); the app keeps watching afterwards anyway.
    public static let defaultWakeTimeout: Duration = .seconds(45)

    private let fetcher: any TVInfoFetching
    private let wake: @Sendable (MACAddress, IPv4Interface, String) async -> Void
    private let interface: @Sendable () -> IPv4Interface?
    private let clock: any Clock<Duration>
    private let wakeTimeout: Duration
    private let offConfirmTimeout: Duration
    private var inFlight = false

    /// `fetcher` should use a short timeout (the app passes 1 s); `wake` sends the magic packet for the
    /// MAC via the interface (the third argument is the TV's last known host, for a unicast packet);
    /// `interface` returns the current Wi-Fi interface, or nil when not on Wi-Fi.
    public init(
        fetcher: any TVInfoFetching,
        wake: @escaping @Sendable (MACAddress, IPv4Interface, String) async -> Void,
        interface: @escaping @Sendable () -> IPv4Interface?,
        clock: any Clock<Duration> = ContinuousClock(),
        wakeTimeout: Duration = PowerController.defaultWakeTimeout,
        offConfirmTimeout: Duration = .seconds(5)
    ) {
        self.fetcher = fetcher
        self.wake = wake
        self.interface = interface
        self.clock = clock
        self.wakeTimeout = wakeTimeout
        self.offConfirmTimeout = offConfirmTimeout
    }

    /// Toggles the TV's power. Returns nil (ignored) while a previous toggle is still in flight,
    /// including while a turn-off is being confirmed, so a stale `.on` cannot trigger a second key.
    /// `onPlan` is told what the toggle will do (e.g. to show "Turning off…") once the TV's state is
    /// known, before acting on it.
    public func togglePower(
        tv: KnownTV, sender: any PowerKeySending, onPlan: @Sendable (PowerAction) async -> Void = { _ in }
    ) async -> PowerOutcome? {
        guard !inFlight else { return nil }
        inFlight = true
        defer { inFlight = false }

        let action = PowerPlanner.action(for: await fetchPower(tv.lastHost))
        await onPlan(action)
        switch action {
        case .turnOff:
            do {
                try await sender.sendEnsuringConnection(.power, timeout: Self.keyTimeout)
            } catch {
                Self.log.error("Power key to \(tv.lastHost, privacy: .private) failed: \(String(describing: error), privacy: .public)")
                return .failed(error)
            }
            // The key was accepted; stay in flight until the TV stops reporting on (or we give up).
            _ = await poll(tv.lastHost, timeout: offConfirmTimeout) { $0 != .success(.on) }
            return .turnedOff
        case .wakeFromStandby:
            do {
                try await sender.sendEnsuringConnection(.power, timeout: Self.keyTimeout)
                return await pollUntilOn(tv.lastHost) ? .turnedOn : .failedToWake
            } catch {
                switch error {
                case .identityChanged, .denied:
                    return .failed(error) // needs re-pairing; waking would not help
                case .unreachable, .approvalTimedOut:
                    Self.log.info("Standby TV did not accept the power key; falling back to wake-on-LAN")
                    return await wakeOnLAN(tv)
                }
            }
        case .wakeOnLAN:
            return await wakeOnLAN(tv)
        }
    }

    private func wakeOnLAN(_ tv: KnownTV) async -> PowerOutcome {
        guard let mac = tv.wifiMAC else { return .noMACKnown }
        guard let iface = interface() else { return .notOnWiFi }
        await wake(mac, iface, tv.lastHost)
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
        await poll(host, timeout: wakeTimeout) { $0 == .success(.on) }
    }

    /// Fetches every second until `done` holds for a result (true) or `timeout` elapses (false).
    private func poll(
        _ host: String, timeout: Duration, until done: (Result<TVPowerState, TVInfoError>) -> Bool
    ) async -> Bool {
        let clock = clock // a local: opening the stored existential directly fails to type-check
        let elapsed = stopwatch(clock)
        while elapsed() < timeout {
            do {
                try await clock.sleep(for: Self.pollInterval)
            } catch {
                return false // cancelled
            }
            if done(await fetchPower(host)) { return true }
        }
        return false
    }
}

/// Returns a closure measuring the time elapsed on `clock` since this call.
private func stopwatch<C: Clock<Duration>>(_ clock: C) -> @Sendable () -> Duration {
    let start = clock.now
    return { start.duration(to: clock.now) }
}

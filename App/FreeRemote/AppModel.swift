import Foundation
import Observation
import os
import SamsungTVKit
import SwiftUI

struct TVListItem: Identifiable, Equatable {
    let id: TVID
    /// The user's label, else the name the TV reports.
    var title: String
    /// The model name.
    var subtitle: String
    var status: TVStatus
}

enum TVStatus: Equatable {
    case on, asleep, unreachable, pairing
}

enum ScreenState: Equatable {
    case noWiFi, localNetworkDenied, searching, noTVs, chooseTV, ready, pairing, pairingDenied, identityChanged
}

/// The app's state and actions: discovery, the known TVs, the selected TV's session, power and
/// hold-to-repeat. Every dependency comes from the `AppEnvironment`.
@MainActor
@Observable
final class AppModel {
    static let selectedTVKey = "selectedTV"

    static let failedToWakeMessage =
        "Couldn't turn on the TV. Turn on “Power On with Mobile” in the TV's network settings, then try again."
    static let unreachableMessage = "Couldn't reach the TV. If it's off, press Power to turn it on."
    static let approvalTimedOutMessage =
        "The TV didn't confirm the connection in time. Try again and choose Allow if your TV asks."
    static let noMACKnownMessage =
        "Couldn't turn on the TV because its network address for waking isn't known yet. "
        + "Turn the TV on with its own remote once while this app is open, then try again."
    static let notOnWiFiMessage = "Connect your iPhone to the same Wi-Fi network as the TV, then try again."
    static let powerUnreachableMessage =
        "Couldn't reach the TV to change its power. Make sure it's on the same Wi-Fi network, then try again."
    static let sendFailedMessage = "The TV didn't receive that. Reconnecting…"

    private static let log = Logger(subsystem: "FreeRemote", category: "AppModel")

    private(set) var tvs: [TVListItem] = []
    private(set) var selectedID: TVID?
    /// A power toggle is in flight for the selected TV.
    var powerBusy: Bool { selectedID.map(powerBusyTVs.contains) ?? false }
    /// The TV is showing its on-screen keyboard and wants text.
    private(set) var keyboardRequested = false
    /// A transient explanation for the user (why a press did nothing, why power failed, …).
    var statusMessage: String?

    private var onWiFi = true
    private var localNetworkDenied = false
    private var scanning = false
    /// State of the selected TV's session (`.idle` when there is none).
    private var sessionState: SessionState = .idle
    private var registry = KnownTVRegistry()
    /// Latest info per TV found in the current or last completed scan.
    private var seen: [TVID: TVDeviceInfo] = [:]
    /// TVs with a power toggle in flight.
    private var powerBusyTVs: Set<TVID> = []

    @ObservationIgnored private let env: AppEnvironment
    /// One power controller per TV, so each TV has its own in-flight guard.
    @ObservationIgnored private var powerControllers: [TVID: any PowerToggling] = [:]
    @ObservationIgnored private var repeater: RepeatController!
    @ObservationIgnored private var current: SessionHandle?
    /// Disconnects of closed sessions (and credential deletes after them), chained in order; every
    /// new session waits for this before its first operation.
    @ObservationIgnored private var teardown: Task<Void, Never>?
    @ObservationIgnored private var foundThisScan: Set<TVID> = []
    /// TVs forgotten during the current scan; its in-flight results for them are ignored.
    @ObservationIgnored private var forgottenThisScan: Set<TVID> = []
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanGeneration = 0
    @ObservationIgnored private var labelTask: Task<Void, Never>?
    @ObservationIgnored private var appeared = false
    @ObservationIgnored private var inBackground = false
    @ObservationIgnored private var nextPlayPauseIsPause = true

    init(env: AppEnvironment) {
        self.env = env
        repeater = RepeatController(clock: env.clock, strategy: .default) { [weak self] key, action in
            await self?.sendFromHold(key, action)
        }
    }

    var screen: ScreenState {
        if !onWiFi { return .noWiFi }
        if localNetworkDenied { return .localNetworkDenied }
        if selectedID != nil {
            switch sessionState {
            case .awaitingApproval: return .pairing
            case .failed(.denied): return .pairingDenied
            case .failed(.identityChanged): return .identityChanged
            case .idle, .connecting, .connected, .failed(.unreachable), .failed(.approvalTimedOut): return .ready
            }
        }
        if tvs.isEmpty { return scanning ? .searching : .noTVs }
        return .chooseTV
    }

    /// The selected TV's session is connected, so keys can be sent.
    var isConnected: Bool { current != nil && sessionState == .connected }

    private var sessionFailed: Bool {
        if case .failed = sessionState { return true }
        return false
    }

    // MARK: - Lifecycle

    func onAppear() {
        guard !appeared else { return }
        appeared = true
        registry = env.knownTVStore.load()
        if let raw = env.userDefaults.string(forKey: Self.selectedTVKey) {
            let id = TVID(rawValue: raw)
            if registry.tvs[id] != nil {
                selectedID = id
            } else {
                env.userDefaults.removeObject(forKey: Self.selectedTVKey)
            }
        }
        let changes = env.labels.changes
        labelTask = Task { [weak self] in
            for await _ in changes { self?.rebuildTVs() }
        }
        rebuildTVs()
        refresh()
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            inBackground = true
            repeater.end()
            cancelScan()
            closeSession()
            rebuildTVs()
        case .active:
            guard inBackground else { return }
            inBackground = false
            refresh()
        default:
            break
        }
    }

    /// Re-checks Wi-Fi, reconnects the selected TV if it has no session or its session failed
    /// (this is also "Try Again"), and scans again.
    func rescan() {
        refresh()
    }

    private func refresh() {
        onWiFi = env.wifiInterface() != nil
        guard onWiFi else {
            repeater.end()
            cancelScan()
            closeSession()
            rebuildTVs()
            return
        }
        if let id = selectedID, current == nil || sessionFailed { openSession(id) }
        startScan()
    }

    // MARK: - Discovery

    private func startScan() {
        scanTask?.cancel()
        scanGeneration += 1
        let generation = scanGeneration
        scanning = true
        foundThisScan = []
        forgottenThisScan = []
        let hosts = registry.tvs.values.map(\.lastHost).sorted()
        let makeDiscovery = env.makeDiscovery
        scanTask = Task { [weak self] in
            let events = await makeDiscovery(hosts)
            for await event in events {
                guard let self, generation == self.scanGeneration else { return }
                self.handle(event)
            }
            guard let self, !Task.isCancelled, generation == self.scanGeneration else { return }
            self.finishScan()
        }
    }

    /// Stops the current scan; results still in flight are dropped.
    private func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        scanGeneration += 1
        scanning = false
    }

    private func handle(_ event: DiscoveryEvent) {
        switch event {
        case .localNetworkDenied:
            localNetworkDenied = true
        case .found(let info):
            guard !forgottenThisScan.contains(info.id) else { return }
            localNetworkDenied = false // evidently granted
            foundThisScan.insert(info.id)
            seen[info.id] = info
            registry.record(info, at: .now)
            saveRegistry()
            if info.id == selectedID, needsNewSession(for: info) {
                openSession(info.id)
            }
            rebuildTVs()
        }
    }

    /// The selected TV moved to another address, or is now on after the session gave up on it.
    private func needsNewSession(for info: TVDeviceInfo) -> Bool {
        guard let current else { return true }
        if current.host != info.host { return true }
        return sessionState == .failed(.unreachable) && info.powerState == .on
    }

    private func finishScan() {
        scanning = false
        seen = seen.filter { foundThisScan.contains($0.key) }
        // With no selection, pick the TV only when there is no choice to make.
        if selectedID == nil, registry.tvs.count == 1, let only = registry.tvs.keys.first {
            select(only)
        }
        rebuildTVs()
    }

    // MARK: - Selection and sessions

    func select(_ id: TVID) {
        guard registry.tvs[id] != nil else { return }
        if id == selectedID, let current, current.host == registry.tvs[id]?.lastHost, !sessionFailed { return }
        repeater.end()
        selectedID = id
        env.userDefaults.set(id.rawValue, forKey: Self.selectedTVKey)
        statusMessage = nil
        if onWiFi {
            openSession(id)
        } else {
            closeSession()
        }
        rebuildTVs()
    }

    /// Replaces the current session with a new one for `id` at its last known host and connects it
    /// once every earlier teardown has finished.
    private func openSession(_ id: TVID) {
        guard let tv = registry.tvs[id] else { return }
        closeSession()
        let handle = SessionHandle(host: tv.lastHost, session: env.makeSession(id, tv.lastHost), after: teardown)
        current = handle
        nextPlayPauseIsPause = true
        let session = handle.session
        handle.observers = [
            Task { [weak self] in
                for await state in session.states { self?.sessionStateChanged(state, on: handle) }
            },
            Task { [weak self] in
                for await shown in session.keyboardEvents { self?.keyboardChanged(shown, on: handle) }
            },
        ]
        handle.enqueue { await $0.connect() }
    }

    /// Stops observing and disconnects the current session, chaining the disconnect onto `teardown`.
    private func closeSession() {
        guard let handle = current else { return }
        current = nil
        sessionState = .idle
        keyboardRequested = false
        let disconnect = handle.close()
        afterTeardown { await disconnect.value }
    }

    /// Appends `work` to `teardown`, after every earlier disconnect.
    private func afterTeardown(_ work: @escaping @MainActor () async -> Void) {
        let previous = teardown
        teardown = Task {
            await previous?.value
            await work()
        }
    }

    private func sessionStateChanged(_ state: SessionState, on handle: SessionHandle) {
        guard handle === current else { return }
        sessionState = state
        switch state {
        case .connecting, .awaitingApproval, .connected, .failed(.denied), .failed(.identityChanged):
            // Progress makes older explanations stale; failure screens explain themselves.
            statusMessage = nil
        case .failed(.unreachable), .failed(.approvalTimedOut):
            // While a power toggle runs, its outcome explains what happened.
            if !powerBusy {
                statusMessage = state == .failed(.unreachable) ? Self.unreachableMessage : Self.approvalTimedOutMessage
            }
        case .idle:
            break
        }
        if state != .connected { repeater.end() }
        rebuildTVs()
    }

    private func keyboardChanged(_ shown: Bool, on handle: SessionHandle) {
        guard handle === current else { return }
        keyboardRequested = shown
    }

    // MARK: - Keys

    func press(_ key: RemoteKey) {
        send(key, .click)
    }

    /// Alternates KEY_PAUSE and KEY_PLAY, starting with KEY_PAUSE.
    func playPause() {
        guard send(nextPlayPauseIsPause ? .pause : .play, .click) != nil else { return }
        nextPlayPauseIsPause.toggle()
    }

    func beginHold(_ key: RemoteKey) {
        guard isConnected else {
            statusMessage = notConnectedReason
            return
        }
        repeater.begin(key)
    }

    func endHold() {
        repeater.end()
    }

    func sendText(_ text: String) {
        enqueueIfConnected { session throws(SessionError) in try await session.sendText(text) }
    }

    /// Tells the TV text entry is done.
    func endText() {
        enqueueIfConnected { session throws(SessionError) in try await session.sendTextEnd() }
    }

    @discardableResult
    private func send(_ key: RemoteKey, _ action: KeyAction) -> Task<Void, Never>? {
        enqueueIfConnected { session throws(SessionError) in try await session.send(key, action) }
    }

    private func sendFromHold(_ key: RemoteKey, _ action: KeyAction) async {
        // A release after the session closed (e.g. on background) has nothing to release.
        if action == .release, !isConnected { return }
        await send(key, action)?.value
    }

    /// Runs `operation` on the selected session after its earlier work, or explains why it cannot.
    @discardableResult
    private func enqueueIfConnected(
        _ operation: @escaping @MainActor (any RemoteSessionProtocol) async throws(SessionError) -> Void
    ) -> Task<Void, Never>? {
        guard let handle = current, isConnected else {
            statusMessage = notConnectedReason
            return nil
        }
        return handle.enqueue { [weak self] session in
            do {
                try await operation(session)
            } catch {
                guard let self, handle === self.current else { return }
                Self.log.error("Send failed: \(String(describing: error), privacy: .public)")
                self.statusMessage = Self.sendFailedMessage
            }
        }
    }

    private var notConnectedReason: String {
        if !onWiFi { return "Connect to Wi-Fi to control your TV." }
        guard selectedID != nil, current != nil else { return "Choose a TV first." }
        switch sessionState {
        case .awaitingApproval:
            return "Look at your TV and choose Allow."
        case .failed(.denied):
            return "Your TV blocked this iPhone. Allow Free Remote in the TV's Device Connection Manager."
        case .failed(.identityChanged):
            return "This TV's security identity changed. Pair again to continue."
        case .failed(.unreachable):
            return Self.unreachableMessage
        case .failed(.approvalTimedOut):
            return Self.approvalTimedOutMessage
        case .idle, .connecting, .connected:
            return "Connecting to the TV…"
        }
    }

    // MARK: - Power

    func togglePower() {
        guard !powerBusy else { return }
        guard let id = selectedID, let tv = registry.tvs[id], let handle = current else {
            statusMessage = onWiFi ? "Choose a TV first." : Self.notOnWiFiMessage
            return
        }
        powerBusyTVs.insert(id)
        statusMessage = nil
        let power = powerController(for: id), session = handle.session
        Task { [weak self] in
            let outcome = await power.togglePower(tv: tv, sender: session)
            guard let self else { return }
            self.powerBusyTVs.remove(id)
            // Only report on the TV still selected.
            guard let outcome, id == self.selectedID, let current = self.current else { return }
            self.powerFinished(outcome, tv: id, on: current)
        }
    }

    private func powerController(for id: TVID) -> any PowerToggling {
        if let existing = powerControllers[id] { return existing }
        let controller = env.makePowerController()
        powerControllers[id] = controller
        return controller
    }

    private func powerFinished(_ outcome: PowerOutcome, tv id: TVID, on handle: SessionHandle) {
        switch outcome {
        case .turnedOff:
            rescan()
        case .turnedOn:
            if sessionState != .connected { openSession(id) }
            rescan()
        case .failedToWake:
            statusMessage = Self.failedToWakeMessage
        case .noMACKnown:
            statusMessage = Self.noMACKnownMessage
        case .notOnWiFi:
            statusMessage = Self.notOnWiFiMessage
        case .failed(.identityChanged):
            sessionStateChanged(.failed(.identityChanged), on: handle)
        case .failed(.denied):
            sessionStateChanged(.failed(.denied), on: handle)
        case .failed(.unreachable), .failed(.approvalTimedOut):
            statusMessage = Self.powerUnreachableMessage
        }
    }

    // MARK: - Managing TVs

    /// Sets the TV's label; nil, empty or whitespace-only clears it.
    func rename(_ id: TVID, to label: String?) {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        env.labels.setLabel(trimmed.isEmpty ? nil : trimmed, for: id)
        rebuildTVs()
    }

    /// Removes the TV's registry entry, label and credentials, disconnecting it if selected.
    /// Never selects another TV; a later scan may, if exactly one TV remains.
    func forget(_ id: TVID) {
        // In-flight scan results must not record the TV again.
        if scanning { cancelScan() }
        forgottenThisScan.insert(id)
        if id == selectedID {
            repeater.end()
            closeSession()
            selectedID = nil
            env.userDefaults.removeObject(forKey: Self.selectedTVKey)
            statusMessage = nil
        }
        registry.forget(id)
        saveRegistry()
        seen[id] = nil
        env.labels.setLabel(nil, for: id)
        // After the disconnect, so a session mid-pairing cannot store credentials again, and before
        // any new session (which waits for `teardown`) could store fresh ones.
        let credentials = env.credentials
        afterTeardown { credentials.delete(id) }
        rebuildTVs()
    }

    /// Adds the TV at `host` (a private or link-local IPv4 address) and selects it.
    func addManually(host: String) async -> Bool {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard LocalAddress.isAllowed(host) else { return false }
        let info: TVDeviceInfo
        do {
            info = try await env.fetcher.fetchInfo(host: host)
        } catch {
            Self.log.info("No Samsung TV at manual address: \(String(describing: error), privacy: .public)")
            return false
        }
        forgottenThisScan.remove(info.id) // explicitly added again
        seen[info.id] = info
        registry.record(info, at: .now)
        saveRegistry()
        select(info.id)
        rebuildTVs()
        return true
    }

    /// Forgets the selected TV's pairing and connects again, so the TV asks to Allow once more.
    func repair() {
        guard let id = selectedID else { return }
        statusMessage = nil
        closeSession()
        let credentials = env.credentials
        afterTeardown { credentials.delete(id) }
        openSession(id)
        rebuildTVs()
    }

    // MARK: - Derived state

    private func rebuildTVs() {
        tvs = registry.tvs.values
            .map { tv in
                TVListItem(id: tv.id, title: env.labels.label(for: tv.id) ?? tv.reportedName,
                           subtitle: tv.modelName, status: status(of: tv.id))
            }
            .sorted { lhs, rhs in
                let (l, r) = (lhs.status != .unreachable, rhs.status != .unreachable)
                if l != r { return l }
                let order = lhs.title.localizedStandardCompare(rhs.title)
                return order == .orderedSame ? lhs.id.rawValue < rhs.id.rawValue : order == .orderedAscending
            }
    }

    private func status(of id: TVID) -> TVStatus {
        if id == selectedID, current != nil {
            switch sessionState {
            case .awaitingApproval: return .pairing
            case .connected: return .on
            case .failed(.unreachable), .failed(.approvalTimedOut): return .unreachable
            case .idle, .connecting, .failed(.denied), .failed(.identityChanged): break
            }
        }
        guard let info = seen[id] else { return .unreachable }
        return info.powerState == .on ? .on : .asleep
    }

    private func saveRegistry() {
        do {
            try env.knownTVStore.save(registry)
        } catch {
            Self.log.error("Saving known TVs failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// One session to one TV address, with its observers and a serial queue of work, so a connect,
/// key presses and the final disconnect reach the session in the order they were issued.
@MainActor
private final class SessionHandle {
    let host: String
    let session: any RemoteSessionProtocol
    var observers: [Task<Void, Never>] = []
    private var tail: Task<Void, Never>?

    /// `after` is work that must finish before this session's first operation (the previous
    /// session's disconnect).
    init(host: String, session: any RemoteSessionProtocol, after: Task<Void, Never>?) {
        self.host = host
        self.session = session
        tail = after
    }

    @discardableResult
    func enqueue(_ operation: @escaping @MainActor (any RemoteSessionProtocol) async -> Void) -> Task<Void, Never> {
        let previous = tail, session = session
        let task = Task {
            await previous?.value
            await operation(session)
        }
        tail = task
        return task
    }

    /// Stops observing and disconnects after any queued work. Returns the disconnect task.
    func close() -> Task<Void, Never> {
        for observer in observers { observer.cancel() }
        observers = []
        return enqueue { await $0.disconnect() }
    }
}

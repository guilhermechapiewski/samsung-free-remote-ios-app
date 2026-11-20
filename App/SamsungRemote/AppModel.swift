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

/// What the TV Details screen shows about one TV.
struct TVDetailsSnapshot: Equatable {
    let id: TVID
    let title: String
    let status: TVStatus
    /// The app's own record of the TV.
    let known: KnownTV
    /// The TV's latest answer: just now when `isLive`, else from the last scan; nil when the TV has
    /// not answered since the app started.
    let info: TVDeviceInfo?
    let isLive: Bool
    /// This iPhone holds a pairing token for the TV.
    let paired: Bool
}

enum TVStatus: Equatable {
    case on, asleep, unreachable, pairing
}

enum ScreenState: Equatable {
    case noWiFi, localNetworkDenied, searching, noTVs, chooseTV, ready, pairing, pairingDenied, identityChanged
}

/// What a running power toggle is doing, as decided by the power planner.
/// Feedback for a scan the user started with Scan Again. Automatic scans show none.
enum ScanFeedback: Equatable {
    case scanning
    /// The scan finished; `newTVs` is how many TVs it found that the app did not know before.
    case found(newTVs: Int)
}

enum PowerDirection: Equatable {
    case turningOn, turningOff
}

/// The app's state and actions: discovery, the known TVs, the selected TV's session, power and
/// hold-to-repeat. Every dependency comes from the `AppEnvironment`.
@MainActor
@Observable
final class AppModel {
    static let selectedTVKey = "selectedTV"

    /// Shown once per TV, after its first successful connection.
    static let powerTipTitle = "Turn On “Power On with Mobile”"
    static let powerTipMessage =
        "To turn this TV on from your iPhone, the TV's “Power On with Mobile” setting must be on: "
        + "\(StatusLine.powerOnWithMobilePath)."
    /// TV ids that have already been shown the power tip.
    static let powerTipShownKey = "powerTipShownTVs"
    /// How long "Connected to …" stays up after a connection.
    static let connectedConfirmationDuration: Duration = .seconds(2)
    /// While Local Network access looks denied, scan again this often (e.g. the user is still
    /// answering the permission prompt), up to `deniedRetryLimit` times.
    static let deniedRetryInterval: Duration = .seconds(3)
    static let deniedRetryLimit = 20
    /// While the selected TV is not connected (unreachable, or its session retrying after a drop) and the
    /// app is in front, its info is checked this often, so a TV that finishes booting late, or is turned
    /// on with its own remote, connects within seconds.
    static let watchInterval: Duration = .seconds(2)
    /// A connection attempt still running after this many watch ticks while the TV answers as on is
    /// stalled (the session is waiting out its reconnect backoff), so a fresh attempt starts at once.
    /// Longer than one connect attempt (5 s), so a normal attempt is never interrupted.
    static let stalledConnectTicks = 4
    /// How long a Scan Again result stays on screen.
    static let scanResultDuration: Duration = .seconds(3)

    private static let log = Logger(subsystem: "SamsungRemote", category: "AppModel")

    private(set) var tvs: [TVListItem] = []
    private(set) var selectedID: TVID?
    /// A power toggle is in flight for the selected TV.
    var powerBusy: Bool { selectedID.map(powerBusyTVs.contains) ?? false }
    /// What the selected TV's power toggle is doing, once the TV's state has been checked.
    var powerDirection: PowerDirection? { selectedID.flatMap { powerDirections[$0] } }
    /// The TV is showing its on-screen keyboard and wants text.
    private(set) var keyboardRequested = false
    /// A transient explanation for the user (why a press did nothing, why power failed, …).
    /// The last event worth telling the user about (a failure, a key that didn't arrive); cleared when the
    /// session makes progress or another TV is chosen.
    var statusEvent: StatusLine?
    /// The TV to show the one-time "Power On with Mobile" tip for, or nil.
    var powerTipTV: TVID?
    /// "Connected to …" is showing (briefly, after a connection).
    private var showsConnected = false
    @ObservationIgnored private var connectedConfirmationTask: Task<Void, Never>?
    /// Progress and result of a user-started scan, or nil.
    private(set) var scanFeedback: ScanFeedback?

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
    /// Direction of each in-flight power toggle whose plan is known.
    private var powerDirections: [TVID: PowerDirection] = [:]
    /// TVs this app just turned off: their sessions failing is expected, so it is not reported, and
    /// they show as asleep until seen on again.
    private var turnedOffTVs: Set<TVID> = []

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
    /// The last completed scan found no TV (e.g. it ran while the Local Network prompt was up).
    @ObservationIgnored private var lastScanFoundNothing = false
    @ObservationIgnored private var deniedRetryTask: Task<Void, Never>?
    /// The TVs known when the user started a scan; nil while no user-started scan is running.
    @ObservationIgnored private var scanAgainBaseline: Set<TVID>?
    @ObservationIgnored private var scanResultTask: Task<Void, Never>?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    /// Watch ticks since the session last changed state while it is connecting.
    @ObservationIgnored private var connectingTicks = 0
    /// Consecutive watch checks the connected TV did not answer.
    @ObservationIgnored private var missedWhileConnected = 0
    /// A connected TV that misses this many checks in a row is treated as gone (an open connection to a TV
    /// that lost power can take the transport's 15-30 s ping cycle to notice).
    static let missedChecksBeforeReconnect = 2
    /// The last watch check found the selected TV not answering while its session was retrying.
    private var watchFoundNoAnswer = false
    @ObservationIgnored private var labelTask: Task<Void, Never>?
    @ObservationIgnored private var appeared = false
    @ObservationIgnored private var inBackground = false
    @ObservationIgnored private var nextPlayPauseIsPause = true

    init(env: AppEnvironment) {
        self.env = env
        repeater = RepeatController(clock: env.clock, strategy: .default) { [weak self] key, action in
            await self?.sendFromHold(key, action)
        }
        loadRemembered()
    }

    /// Loads the remembered TVs and selection (a small local file and defaults), so the very first frame
    /// shows them instead of an empty "No TVs found" state. Network work waits for `onAppear()`.
    private func loadRemembered() {
        registry = env.knownTVStore.load()
        if let raw = env.userDefaults.string(forKey: Self.selectedTVKey) {
            let id = TVID(rawValue: raw)
            if registry.tvs[id] != nil {
                selectedID = id
            } else {
                env.userDefaults.removeObject(forKey: Self.selectedTVKey)
            }
        }
        rebuildTVs()
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

    /// The remote's keys (other than Power) can be used: connected, and the TV isn't off. A TV in network
    /// standby can keep its connection open, so being connected is not enough.
    var controlsAvailable: Bool { isConnected && !selectedTurnedOff }

    private var selectedTurnedOff: Bool { selectedID.map(turnedOffTVs.contains) ?? false }

    private var sessionFailed: Bool {
        if case .failed = sessionState { return true }
        return false
    }

    // MARK: - Lifecycle

    func onAppear() {
        guard !appeared else { return }
        appeared = true
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
            cancelDeniedRetries()
            closeSession()
            rebuildTVs()
            updateWatch()
        case .active:
            if inBackground {
                inBackground = false
                refresh()
            } else if appeared, localNetworkDenied || (!scanning && lastScanFoundNothing) {
                // Back from a system alert (such as the Local Network prompt, answered after the
                // scan gave up): look again.
                refresh()
            }
        default:
            break
        }
    }

    /// Re-checks Wi-Fi, reconnects the selected TV if it has no session or its session failed
    /// (this is also "Try Again"), and scans again.
    func rescan() {
        refresh()
    }

    /// The user's Scan Again: like `rescan()`, but shows progress and then how many new TVs were
    /// found. Joins a scan that is already running instead of restarting it.
    func scanAgain() {
        guard scanFeedback != .scanning else { return }
        guard env.wifiInterface() != nil else {
            refresh() // shows the no-Wi-Fi state; no progress to show
            return
        }
        clearScanFeedback()
        scanAgainBaseline = Set(registry.tvs.keys)
        scanFeedback = .scanning
        refresh(restartScan: !scanning)
    }

    private func refresh(restartScan: Bool = true) {
        onWiFi = env.wifiInterface() != nil
        guard onWiFi else {
            repeater.end()
            cancelScan()
            closeSession()
            rebuildTVs()
            return
        }
        if let id = selectedID, current == nil || sessionFailed { openSession(id) }
        if restartScan { startScan() }
    }

    private func clearScanFeedback() {
        scanResultTask?.cancel()
        scanResultTask = nil
        scanAgainBaseline = nil
        scanFeedback = nil
    }

    /// Shows the result of a user-started scan for `scanResultDuration`.
    private func finishScanAgain(baseline: Set<TVID>) {
        scanAgainBaseline = nil
        scanFeedback = .found(newTVs: foundThisScan.subtracting(baseline).count)
        let clock = env.clock
        scanResultTask = Task { [weak self] in
            do {
                try await clock.sleep(for: Self.scanResultDuration)
            } catch {
                return // cancelled: a newer scan or the background took over
            }
            self?.scanResultTask = nil
            self?.scanFeedback = nil
        }
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
        clearScanFeedback()
    }

    private func handle(_ event: DiscoveryEvent) {
        switch event {
        case .localNetworkDenied:
            localNetworkDenied = true
            startDeniedRetries()
        case .found(let info):
            guard !forgottenThisScan.contains(info.id) else { return }
            localNetworkDenied = false // evidently granted
            cancelDeniedRetries()
            foundThisScan.insert(info.id)
            seen[info.id] = info
            if info.powerState == .on { turnedOffTVs.remove(info.id) }
            registry.record(info, at: .now)
            saveRegistry()
            if info.id == selectedID, needsNewSession(for: info) {
                openSession(info.id)
            }
            rebuildTVs()
        }
    }

    /// The selected TV moved to another address, is now on after the session gave up on it, or
    /// answers again after its approval timed out (unless this app just turned it off).
    private func needsNewSession(for info: TVDeviceInfo) -> Bool {
        guard let current else { return true }
        if current.host != info.host { return true }
        switch sessionState {
        case .failed(.unreachable): return info.powerState == .on
        case .failed(.approvalTimedOut): return !turnedOffTVs.contains(info.id)
        default: return false
        }
    }

    /// While Local Network access looks denied and the app is active, scans again every
    /// `deniedRetryInterval` (bounded) until a TV is found.
    private func startDeniedRetries() {
        guard deniedRetryTask == nil, !inBackground else { return }
        let clock = env.clock
        deniedRetryTask = Task { [weak self] in
            for _ in 0..<Self.deniedRetryLimit {
                do {
                    try await clock.sleep(for: Self.deniedRetryInterval)
                } catch {
                    return // cancelled
                }
                if Task.isCancelled { return }
                guard let self, self.localNetworkDenied, !self.inBackground, self.onWiFi else { break }
                if !self.scanning { self.startScan() }
            }
            self?.deniedRetryTask = nil
        }
    }

    private func cancelDeniedRetries() {
        deniedRetryTask?.cancel()
        deniedRetryTask = nil
    }

    private func finishScan() {
        scanning = false
        lastScanFoundNothing = foundThisScan.isEmpty
        seen = seen.filter { foundThisScan.contains($0.key) }
        if let baseline = scanAgainBaseline { finishScanAgain(baseline: baseline) }
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
        statusEvent = nil
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
        endConnectedConfirmation()
        updateWatch()
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
        connectingTicks = 0
        missedWhileConnected = 0
        watchFoundNoAnswer = false
        let wasConnected = sessionState == .connected
        sessionState = state
        if state == .connected, !wasConnected {
            confirmConnected()
        } else if state != .connected {
            endConnectedConfirmation()
        }
        if state == .connected, let id = selectedID {
            turnedOffTVs.remove(id)
            if !powerTipShown.contains(id.rawValue) { powerTipTV = id }
        }
        switch state {
        case .connecting, .awaitingApproval, .connected, .failed(.denied), .failed(.identityChanged):
            // Progress makes older explanations stale; failure screens explain themselves.
            statusEvent = nil
        case .failed(.unreachable), .failed(.approvalTimedOut):
            // While a power toggle runs, its outcome explains what happened; a TV just turned off
            // is expected to go away.
            if powerBusy {
                break
            } else if selectedTurnedOff {
                statusEvent = .tvOff
            } else {
                statusEvent = state == .failed(.unreachable) ? .unreachable : .approvalTimedOut
            }
        case .idle:
            break
        }
        if state != .connected { repeater.end() }
        rebuildTVs()
        updateWatch()
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
            statusEvent = notConnectedReason
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
        // The TV is no longer asked for text, so a later request from it shows the sheet again.
        keyboardRequested = false
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
            statusEvent = notConnectedReason
            return nil
        }
        return handle.enqueue { [weak self] session in
            do {
                try await operation(session)
            } catch {
                guard let self, handle === self.current else { return }
                Self.log.error("Send failed: \(String(describing: error), privacy: .public)")
                self.statusEvent = .reconnecting
            }
        }
    }

    /// Why a key press did nothing.
    private var notConnectedReason: StatusLine {
        if !onWiFi { return .notOnWiFi }
        guard selectedID != nil, current != nil else { return .chooseTVFirst }
        switch sessionState {
        case .awaitingApproval: return .chooseAllow
        case .failed(.denied): return .blocked
        case .failed(.identityChanged): return .identityChanged
        case .failed(.unreachable) where selectedTurnedOff, .failed(.approvalTimedOut) where selectedTurnedOff:
            return .tvOff
        case .failed(.unreachable): return .unreachable
        case .failed(.approvalTimedOut): return .approvalTimedOut
        case .idle, .connecting, .connected: return .connecting(to: selectedTitle)
        }
    }

    // MARK: - Power

    func togglePower() {
        guard !powerBusy else { return }
        guard let id = selectedID, let tv = registry.tvs[id] else {
            statusEvent = .chooseTVFirst
            return
        }
        if current == nil {
            // No session, e.g. Wi-Fi was lost: check again, reconnecting if Wi-Fi is back.
            refresh()
        }
        guard let handle = current else {
            statusEvent = onWiFi ? .unreachable : .notOnWiFi
            return
        }
        powerBusyTVs.insert(id)
        statusEvent = nil
        // Show the likely direction at once (the plan, after checking the TV, may correct it), so the line
        // never shows a stale message in between.
        powerDirections[id] = isConnected && !selectedTurnedOff ? .turningOff : .turningOn
        let power = powerController(for: id), sender = powerSender(for: handle)
        let onPlan: @Sendable (PowerAction) async -> Void = { [weak self] action in
            await self?.powerPlanned(action, for: id)
        }
        Task { [weak self] in
            let outcome = await power.togglePower(tv: tv, sender: sender, onPlan: onPlan)
            guard let self else { return }
            self.powerBusyTVs.remove(id)
            self.powerDirections[id] = nil
            // Only report on the TV still selected.
            guard let outcome, id == self.selectedID, let current = self.current else { return }
            self.powerFinished(outcome, tv: id, on: current)
        }
    }

    private func powerPlanned(_ action: PowerAction, for id: TVID) {
        guard powerBusyTVs.contains(id) else { return }
        powerDirections[id] = action == .turnOff ? .turningOff : .turningOn
    }

    /// Sends the power controller's key through `handle`'s queue (after its earlier work and every
    /// earlier teardown), and refuses with `.unreachable` once `handle` is closed or replaced, so a
    /// late toggle never revives a session the app already closed.
    private func powerSender(for handle: SessionHandle) -> HandlePowerSender {
        HandlePowerSender { [weak self, weak handle] (key: RemoteKey, timeout: Duration) throws(SessionError) in
            guard let self, let handle else { throw .unreachable }
            try await self.sendPowerKey(key, timeout: timeout, on: handle)
        }
    }

    private func sendPowerKey(_ key: RemoteKey, timeout: Duration, on handle: SessionHandle) async throws(SessionError) {
        guard handle === current else { throw .unreachable }
        let result = await handle.enqueue { [weak self] session -> Result<Void, SessionError> in
            // Checked again once the queue reaches this work: the session may have closed meanwhile.
            guard let self, handle === self.current else { return .failure(.unreachable) }
            do throws(SessionError) {
                try await session.sendEnsuringConnection(key, timeout: timeout)
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value
        try result.get()
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
            turnedOffTVs.insert(id)
            rebuildTVs()
            rescan()
        case .turnedOn:
            turnedOffTVs.remove(id)
            if sessionState != .connected { openSession(id) }
            rescan()
        case .failedToWake:
            statusEvent = .notTurnedOn
        case .noMACKnown:
            statusEvent = .wakeAddressUnknown
        case .notOnWiFi:
            statusEvent = .notOnWiFi
        case .failed(.identityChanged):
            sessionStateChanged(.failed(.identityChanged), on: handle)
        case .failed(.denied):
            sessionStateChanged(.failed(.denied), on: handle)
        case .failed(.unreachable), .failed(.approvalTimedOut):
            statusEvent = .unreachable
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
            statusEvent = nil
        }
        registry.forget(id)
        saveRegistry()
        seen[id] = nil
        turnedOffTVs.remove(id)
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
        // The user cancelled the sheet while the TV was being asked.
        guard !Task.isCancelled else { return false }
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
        statusEvent = nil
        closeSession()
        let credentials = env.credentials
        afterTeardown { credentials.delete(id) }
        openSession(id)
        rebuildTVs()
    }

    // MARK: - Derived state

    /// The title of `status`.
    var statusText: String? { status?.title }

    /// The status line above the D-pad: power progress, else the last event, else what the selected TV's
    /// session is doing. Nil when connected with nothing to say.
    var status: StatusLine? {
        if let powerDirection { return powerDirection == .turningOn ? .turningOn : .turningOff }
        if let statusEvent { return statusEvent }
        guard screen == .ready else { return Self.screenStatusText(screen).map { StatusLine($0, tone: .info) } }
        if selectedTurnedOff, sessionState != .awaitingApproval { return .tvOff }
        switch sessionState {
        case .connected:
            return showsConnected ? .connected(to: selectedTitle) : nil
        case .failed(.unreachable):
            return .unreachable
        case .failed(.approvalTimedOut):
            return .approvalTimedOut
        case .connecting where watchFoundNoAnswer:
            // Still retrying, but the TV isn't answering: say so rather than "Connecting…".
            return .unreachable
        case .idle, .connecting, .awaitingApproval, .failed(.denied), .failed(.identityChanged):
            return .connecting(to: selectedTitle)
        }
    }

    private var selectedTitle: String? { tvs.first { $0.id == selectedID }?.title }

    private func confirmConnected() {
        connectedConfirmationTask?.cancel()
        showsConnected = true
        let clock = env.clock
        connectedConfirmationTask = Task { [weak self] in
            do {
                try await clock.sleep(for: Self.connectedConfirmationDuration)
            } catch {
                return // cancelled
            }
            self?.showsConnected = false
            self?.connectedConfirmationTask = nil
        }
    }

    private func endConnectedConfirmation() {
        connectedConfirmationTask?.cancel()
        connectedConfirmationTask = nil
        showsConnected = false
    }

    private var powerTipShown: [String] {
        env.userDefaults.stringArray(forKey: Self.powerTipShownKey) ?? []
    }

    /// The user acknowledged the power tip; it is not shown again for that TV.
    func dismissPowerTip() {
        guard let id = powerTipTV else { return }
        powerTipTV = nil
        var shown = powerTipShown
        if !shown.contains(id.rawValue) { shown.append(id.rawValue) }
        env.userDefaults.set(shown, forKey: Self.powerTipShownKey)
    }

    /// The status line's explanation of each screen state other than `.ready`.
    static func screenStatusText(_ screen: ScreenState) -> String? {
        switch screen {
        case .ready: nil
        case .noWiFi: "Not connected to Wi-Fi"
        case .localNetworkDenied: "Local Network access is turned off"
        case .searching: "Searching for TVs…"
        case .noTVs: "No TVs found"
        case .chooseTV: "Choose a TV"
        case .pairing: "Pairing with the TV…"
        case .pairingDenied: "The TV blocked this iPhone"
        case .identityChanged: "The TV's security identity changed"
        }
    }

    // MARK: - Watching a TV that isn't connected

    /// The app is in front on Wi-Fi and the selected TV's session is connected (to notice the TV turning
    /// off), has failed as unreachable (off, or still booting after Power) or is retrying after a drop.
    /// Pairing, denials and approval timeouts are excluded: reconnecting would prompt on the TV again.
    private var shouldWatchSelected: Bool {
        guard appeared, !inBackground, onWiFi, selectedID != nil else { return false }
        switch sessionState {
        case .connected, .connecting, .failed(.unreachable): return true
        case .idle, .awaitingApproval, .failed(.approvalTimedOut), .failed(.denied), .failed(.identityChanged):
            return false
        }
    }

    private func updateWatch() {
        if shouldWatchSelected {
            if watchTask == nil { startWatch() }
        } else {
            watchTask?.cancel()
            watchTask = nil
            watchFoundNoAnswer = false
        }
    }

    /// Every `watchInterval`, asks the selected TV for its info (one small local HTTP request) and
    /// `watchChecked`s the answer. Ends once there is nothing to watch.
    private func startWatch() {
        let clock = env.clock
        let fetcher = env.fetcher
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: Self.watchInterval)
                } catch {
                    return // cancelled
                }
                guard let self, self.shouldWatchSelected, let id = self.selectedID,
                      let host = self.registry.tvs[id]?.lastHost else {
                    self?.watchTask = nil
                    return
                }
                if self.powerBusy { continue } // the power toggle is already checking
                if self.sessionState == .connecting { self.connectingTicks += 1 }
                let info = try? await fetcher.fetchInfo(host: host)
                guard !Task.isCancelled, self.selectedID == id, self.shouldWatchSelected else { continue }
                self.watchChecked(info, for: id)
            }
        }
    }

    /// Acts on one watch check of the selected TV. An answer updates its status (as a scan would); when it
    /// is on, a failed session reconnects and a stalled attempt restarts; standby while connected marks it
    /// off. No answer while retrying is shown instead of an endless "Connecting…", and a connected TV that
    /// stops answering gets a fresh connection, which fails fast if it is really gone.
    private func watchChecked(_ info: TVDeviceInfo?, for id: TVID) {
        guard let info, info.id == id else {
            switch sessionState {
            case .connecting:
                watchFoundNoAnswer = true
            case .connected:
                missedWhileConnected += 1
                if missedWhileConnected >= Self.missedChecksBeforeReconnect {
                    missedWhileConnected = 0
                    openSession(id)
                }
            default:
                break
            }
            return
        }
        watchFoundNoAnswer = false
        missedWhileConnected = 0
        handle(.found(info)) // reconnects a failed session when the TV is on; clears "off" when on
        if info.powerState != .on, sessionState == .connected, !selectedTurnedOff {
            // Turned off with its own remote into network standby: the connection may stay open.
            turnedOffTVs.insert(id)
            rebuildTVs()
        }
        if info.powerState == .on, sessionState == .connecting, connectingTicks >= Self.stalledConnectTicks {
            connectingTicks = 0
            openSession(id)
        }
    }

    // MARK: - TV details

    /// What is known about a TV without asking it; nil for a TV the app does not know.
    func details(for id: TVID) -> TVDetailsSnapshot? {
        snapshot(id, live: nil)
    }

    /// Asks the TV for its current details, falling back to `details(for:)` when it does not answer
    /// (or a different TV answers at its address). A live answer also updates the TV's status, as a
    /// scan would. Nil when the TV is not (or no longer) known.
    func liveDetails(for id: TVID) async -> TVDetailsSnapshot? {
        guard let known = registry.tvs[id] else { return nil }
        guard onWiFi, let info = try? await env.fetcher.fetchInfo(host: known.lastHost), info.id == id,
              registry.tvs[id] != nil else {
            return details(for: id)
        }
        seen[info.id] = info
        if info.powerState == .on { turnedOffTVs.remove(info.id) }
        registry.record(info, at: .now)
        saveRegistry()
        rebuildTVs()
        return snapshot(id, live: info)
    }

    private func snapshot(_ id: TVID, live: TVDeviceInfo?) -> TVDetailsSnapshot? {
        guard let known = registry.tvs[id] else { return nil }
        return TVDetailsSnapshot(
            id: id,
            title: env.labels.label(for: id) ?? known.reportedName,
            status: status(of: id),
            known: known,
            info: live ?? seen[id],
            isLive: live != nil,
            paired: env.credentials.load(id)?.token != nil
        )
    }

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
            case .connected: return turnedOffTVs.contains(id) ? .asleep : .on
            case .failed(.unreachable), .failed(.approvalTimedOut):
                return turnedOffTVs.contains(id) ? .asleep : .unreachable
            case .idle, .connecting, .failed(.denied), .failed(.identityChanged): break
            }
        }
        // Cleared as soon as the TV is seen on again, so it outranks an older scan result.
        if turnedOffTVs.contains(id) { return .asleep }
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
    func enqueue<T: Sendable>(
        _ operation: @escaping @MainActor (any RemoteSessionProtocol) async -> T
    ) -> Task<T, Never> {
        let previous = tail, session = session
        let task = Task {
            await previous?.value
            return await operation(session)
        }
        tail = Task { _ = await task.value }
        return task
    }

    /// Stops observing and disconnects after any queued work. Returns the disconnect task.
    func close() -> Task<Void, Never> {
        for observer in observers { observer.cancel() }
        observers = []
        return enqueue { await $0.disconnect() }
    }
}

/// The `PowerKeySending` the power controller gets: routes its key through the app's session
/// handle instead of touching the session directly.
private struct HandlePowerSender: PowerKeySending {
    let send: @MainActor @Sendable (RemoteKey, Duration) async throws(SessionError) -> Void

    func sendEnsuringConnection(_ key: RemoteKey, timeout: Duration) async throws(SessionError) {
        try await send(key, timeout)
    }
}

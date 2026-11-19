import Foundation
import os

public enum SessionState: Equatable, Sendable {
    case idle, connecting, awaitingApproval, connected, failed(SessionError)
}

public enum SessionError: Error, Equatable, Sendable {
    case denied, approvalTimedOut, identityChanged, unreachable
}

/// One remote-control connection to one TV: pairing (approval on the TV), trust-on-first-use
/// pinning, and automatic reconnect after an established connection drops.
///
/// `states` and `keyboardEvents` are single-consumer streams created once at init (unbounded
/// buffering, a value is emitted only when it changes). They are finished when the session is
/// deallocated. A running connection keeps the session alive; call `disconnect()` to stop it.
public actor RemoteSession {
    static let maxReconnectFailures = 5
    private static let log = Logger(subsystem: "SamsungTVKit", category: "RemoteSession")

    private enum AttemptOutcome {
        /// The connection failed or dropped; `reachedConnected` tells whether the TV accepted it first.
        case dropped(reachedConnected: Bool)
        /// Stop for good with this error (no reconnect).
        case failed(SessionError)
    }

    private let id: TVID
    private let host: String
    private let credentials: any CredentialStore
    private let makeTransport: @Sendable () -> any WebSocketTransport
    private let clock: any Clock<Duration>
    private let approvalTimeout: Duration
    private let backoff = Backoff()

    private let stateContinuation: AsyncStream<SessionState>.Continuation
    private let keyboardContinuation: AsyncStream<Bool>.Continuation
    private let stateStream: AsyncStream<SessionState>
    private let keyboardStream: AsyncStream<Bool>

    public private(set) var currentState: SessionState = .idle
    private var keyboardShown = false

    /// Bumped whenever the session is stopped (disconnect or terminal failure); work started under an
    /// older generation must not touch state after an `await`.
    private var generation = 0
    /// Bumped per connection attempt, so a stale approval timer cannot fire on a newer attempt.
    private var attemptID = 0
    private var runner: Task<Void, Never>?
    private var approvalTimer: Task<Void, Never>?
    private var transport: (any WebSocketTransport)?

    /// Callers of `sendEnsuringConnection` suspended until the state settles; resumed on every
    /// state change, on every stop, and when their timeout fires.
    private var stateWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var expiredWaiters: Set<Int> = []
    private var nextWaiterID = 0

    public init(
        id: TVID,
        host: String,
        credentials: any CredentialStore,
        transport: @escaping @Sendable () -> any WebSocketTransport,
        clock: any Clock<Duration> = ContinuousClock(),
        approvalTimeout: Duration = .seconds(30)
    ) {
        self.id = id
        self.host = host
        self.credentials = credentials
        self.makeTransport = transport
        self.clock = clock
        self.approvalTimeout = approvalTimeout
        (stateStream, stateContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (keyboardStream, keyboardContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    deinit {
        approvalTimer?.cancel()
        stateContinuation.finish()
        keyboardContinuation.finish()
    }

    /// State changes (single consumer).
    public nonisolated var states: AsyncStream<SessionState> { stateStream }

    /// `true` when the TV shows its on-screen keyboard, `false` when it hides it (single consumer).
    public nonisolated var keyboardEvents: AsyncStream<Bool> { keyboardStream }

    /// Starts connecting. No-op while connecting or connected; from `.idle` or `.failed` it starts
    /// afresh. Returns once the attempt is under way; follow progress through `states`.
    public func connect() async {
        guard runner == nil else { return }
        generation += 1
        let gen = generation
        runner = Task { await self.run(gen) }
    }

    /// Stops the connection and any pending reconnect; emits `.idle`.
    public func disconnect() async {
        await stop(.idle)
    }

    public func send(_ key: RemoteKey, _ action: KeyAction = .click) async throws(SessionError) {
        try await write(RemoteProtocol.key(key, action))
    }

    /// Sends `key`, first connecting if the session is idle or failed and waiting (up to `timeout`)
    /// for `.connected`. Throws the session's failure, or `.unreachable` on timeout or disconnect.
    public func sendEnsuringConnection(_ key: RemoteKey, timeout: Duration) async throws(SessionError) {
        if currentState != .connected {
            try await waitUntilConnected(timeout: timeout)
        }
        try await send(key)
    }

    public func sendText(_ s: String) async throws(SessionError) {
        try await write(RemoteProtocol.text(s))
    }

    public func sendTextEnd() async throws(SessionError) {
        try await write(RemoteProtocol.textEnd())
    }

    // MARK: - Connection loop

    private func run(_ gen: Int) async {
        var hasConnected = false
        var failures = 0
        while gen == generation {
            let outcome = await attempt(gen)
            guard gen == generation else { return }
            switch outcome {
            case .failed(let error):
                await stop(.failed(error))
                return
            case .dropped(let reachedConnected):
                if reachedConnected {
                    hasConnected = true
                    failures = 0
                } else if hasConnected {
                    failures += 1
                }
                // Never connected: report and let the app decide whether to retry.
                guard hasConnected, failures < Self.maxReconnectFailures else {
                    await stop(.failed(.unreachable))
                    return
                }
                setState(.connecting)
                do {
                    try await clock.sleep(for: backoff.delay(attempt: failures))
                } catch {
                    return // cancelled by disconnect()
                }
            }
        }
    }

    /// One connection attempt with a fresh transport, running until it drops or fails for good.
    private func attempt(_ gen: Int) async -> AttemptOutcome {
        let stored = credentials.load(id)
        guard let url = RemoteProtocol.channelURL(host: host, token: stored?.token) else {
            Self.log.error("Refusing to connect to disallowed host \(self.host, privacy: .private)")
            return .failed(.unreachable)
        }
        let policy: PinPolicy = stored.map { .require($0.pin) } ?? .recordFirstUse

        setState(.connecting)
        let transport = makeTransport()
        self.transport = transport

        let pin: CertificatePin
        do {
            pin = try await transport.connect(url, policy: policy)
        } catch {
            await transport.close()
            guard gen == generation else { return .dropped(reachedConnected: false) }
            if error == .pinMismatch {
                Self.log.error("Certificate of \(self.host, privacy: .private) no longer matches its pin")
                return .failed(.identityChanged)
            }
            return .dropped(reachedConnected: false)
        }
        guard gen == generation else {
            await transport.close()
            return .dropped(reachedConnected: false)
        }

        if stored?.token == nil { setState(.awaitingApproval) }
        attemptID += 1
        startApprovalTimer(gen: gen, attempt: attemptID)

        var token = stored?.token
        var reachedConnected = false
        while true {
            let data: Data
            do {
                data = try await transport.receive()
            } catch {
                await transport.close()
                guard gen == generation else { return .dropped(reachedConnected: false) }
                cancelApprovalTimer()
                return .dropped(reachedConnected: reachedConnected)
            }
            guard gen == generation else {
                await transport.close()
                return .dropped(reachedConnected: false)
            }

            switch RemoteProtocol.decodeEvent(data) {
            case .connected(let newToken):
                guard !reachedConnected else { continue }
                cancelApprovalTimer()
                if let newToken { token = newToken }
                do {
                    try credentials.save(TVCredentials(token: token, pin: pin), for: id)
                } catch {
                    Self.log.error("Saving credentials failed: \(error.localizedDescription, privacy: .public)")
                }
                reachedConnected = true
                setState(.connected)
            case .unauthorized:
                credentials.delete(id)
                return .failed(.denied)
            case .timedOut:
                return .failed(.approvalTimedOut)
            case .keyboardShown:
                setKeyboard(true)
            case .keyboardHidden:
                setKeyboard(false)
            case .other:
                break
            }
        }
    }

    /// Ends the session (closing the transport, cancelling reconnect and timers) in `final` state.
    private func stop(_ final: SessionState) async {
        generation += 1
        runner?.cancel()
        runner = nil
        cancelApprovalTimer()
        let transport = self.transport
        self.transport = nil
        setState(final)
        // Wake waiters even when the state did not change (e.g. failed again with the same error).
        resumeStateWaiters()
        await transport?.close()
    }

    private func write(_ data: Data) async throws(SessionError) {
        guard currentState == .connected, let transport else { throw .unreachable }
        do {
            try await transport.send(data)
        } catch {
            // Treat as a drop: closing makes the receive loop fail, which triggers reconnect.
            await transport.close()
            throw .unreachable
        }
    }

    // MARK: - Waiting for a connection

    private func waitUntilConnected(timeout: Duration) async throws(SessionError) {
        // A failure or idle state from before this call is stale until the new attempt settles.
        var stale = false
        switch currentState {
        case .idle, .failed:
            await connect()
            stale = true
        default:
            break
        }

        nextWaiterID += 1
        let id = nextWaiterID
        let clock = clock
        let timer = Task { [weak self] in
            do {
                try await clock.sleep(for: timeout)
            } catch {
                return
            }
            await self?.expireWaiter(id)
        }
        defer {
            timer.cancel()
            expiredWaiters.remove(id)
        }

        while true {
            if currentState == .connected { return }
            if !stale {
                if case .failed(let error) = currentState { throw error }
                if currentState == .idle { throw .unreachable }
            }
            if expiredWaiters.contains(id) { throw .unreachable }
            await withCheckedContinuation { stateWaiters[id] = $0 }
            stale = false
        }
    }

    private func expireWaiter(_ id: Int) {
        expiredWaiters.insert(id)
        stateWaiters.removeValue(forKey: id)?.resume()
    }

    private func resumeStateWaiters() {
        let waiters = stateWaiters
        stateWaiters.removeAll()
        for waiter in waiters.values { waiter.resume() }
    }

    // MARK: - Approval timer

    /// Fails the attempt if the TV has not accepted the connection within `approvalTimeout` of the
    /// transport opening (both first pairing and token reconnects).
    private func startApprovalTimer(gen: Int, attempt: Int) {
        approvalTimer?.cancel()
        let clock = clock, timeout = approvalTimeout
        approvalTimer = Task { [weak self] in
            do {
                try await clock.sleep(for: timeout)
            } catch {
                return
            }
            await self?.approvalTimerFired(gen: gen, attempt: attempt)
        }
    }

    private func approvalTimerFired(gen: Int, attempt: Int) async {
        guard gen == generation, attempt == attemptID, currentState != .connected else { return }
        await stop(.failed(.approvalTimedOut))
    }

    private func cancelApprovalTimer() {
        approvalTimer?.cancel()
        approvalTimer = nil
    }

    // MARK: - Emission

    private func setState(_ new: SessionState) {
        guard new != currentState else { return }
        currentState = new
        stateContinuation.yield(new)
        resumeStateWaiters()
        if new != .connected { setKeyboard(false) }
    }

    private func setKeyboard(_ shown: Bool) {
        guard shown != keyboardShown else { return }
        keyboardShown = shown
        keyboardContinuation.yield(shown)
    }
}

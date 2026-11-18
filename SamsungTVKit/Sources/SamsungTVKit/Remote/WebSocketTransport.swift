import Foundation
import Synchronization

public enum TransportError: Error, Equatable {
    case pinMismatch, unreachable, closed
}

public protocol WebSocketTransport: Sendable {
    func connect(_ url: URL, policy: PinPolicy) async throws(TransportError) -> CertificatePin
    func send(_ data: Data) async throws(TransportError)
    func receive() async throws(TransportError) -> Data
    func close() async
}

/// Single-use, pinned WebSocket connection over `URLSessionWebSocketTask`. Create one per
/// connection attempt; after `close()` (or a failed `connect`) it cannot be reused.
public final class URLSessionWebSocketTransport: WebSocketTransport {
    static let maxMessageBytes = 256 * 1024
    static let connectTimeout: Duration = .seconds(5)
    static let pingInterval: Duration = .seconds(15)

    private struct State {
        var task: URLSessionWebSocketTask?
        var pinger: Task<Void, Never>?
        var awaitingPong = false
        var closed = false
    }

    private let delegate = PinningDelegate()
    private let session: URLSession
    private let state = Mutex(State())

    public init() {
        session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        // Safety net if close() was never called: break the session -> delegate retention.
        session.invalidateAndCancel()
    }

    public func connect(_ url: URL, policy: PinPolicy) async throws(TransportError) -> CertificatePin {
        let task: URLSessionWebSocketTask? = state.withLock { s in
            guard !s.closed, s.task == nil else { return nil }
            let task = session.webSocketTask(with: url)
            task.maximumMessageSize = Self.maxMessageBytes
            s.task = task
            return task
        }
        guard let task else { throw .closed }

        let delegate = self.delegate
        let timeout = Task {
            try? await Task.sleep(for: Self.connectTimeout)
            delegate.finish(.failure(.unreachable))
        }
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                delegate.begin(policy: policy, url: url, waiter: continuation)
                task.resume()
            }
        } onCancel: {
            delegate.finish(.failure(.unreachable))
        }
        timeout.cancel()

        switch result {
        case .success(let pin):
            startPinging()
            return pin
        case .failure(let error):
            await close()
            throw error
        }
    }

    public func send(_ data: Data) async throws(TransportError) {
        guard let task = currentTask() else { throw .closed }
        do {
            try await task.send(.string(String(decoding: data, as: UTF8.self)))
        } catch {
            throw .closed
        }
    }

    public func receive() async throws(TransportError) -> Data {
        guard let task = currentTask() else { throw .closed }
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await task.receive()
        } catch {
            throw .closed
        }
        switch message {
        case .string(let string): return Data(string.utf8)
        case .data(let data): return data
        @unknown default: throw .closed
        }
    }

    public func close() async {
        let (task, pinger) = state.withLock { s -> (URLSessionWebSocketTask?, Task<Void, Never>?) in
            guard !s.closed else { return (nil, nil) }
            s.closed = true
            defer { s.task = nil; s.pinger = nil }
            return (s.task, s.pinger)
        }
        pinger?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        delegate.finish(.failure(.closed))
        session.finishTasksAndInvalidate()
    }

    private func currentTask() -> URLSessionWebSocketTask? {
        state.withLock { $0.closed ? nil : $0.task }
    }

    private func startPinging() {
        let pinger = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pingInterval)
                guard !Task.isCancelled, let self else { return }
                if await !self.ping() { return }
            }
        }
        let alreadyClosed = state.withLock { s -> Bool in
            if s.closed { return true }
            s.pinger = pinger
            return false
        }
        if alreadyClosed { pinger.cancel() }
    }

    /// Sends a ping. Returns false (after closing) if the previous ping never got a pong or the
    /// connection is gone.
    private func ping() async -> Bool {
        let task: URLSessionWebSocketTask? = state.withLock { s in
            guard !s.closed, let task = s.task, !s.awaitingPong else { return nil }
            s.awaitingPong = true
            return task
        }
        guard let task else {
            await close()
            return false
        }
        task.sendPing { [weak self] error in
            guard let self else { return }
            if error != nil {
                Task { await self.close() }
            } else {
                self.state.withLock { $0.awaitingPong = false }
            }
        }
        return true
    }
}

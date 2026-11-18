import Foundation
import Synchronization
@testable import SamsungTVKit

/// Scripted `WebSocketTransport`: `connect` returns a preset result; `receive` delivers messages
/// pushed by the test, or throws once the test drops the connection or the transport is closed.
final class FakeTransport: WebSocketTransport {
    private struct State {
        var url: URL?
        var policy: PinPolicy?
        var sent: [Data] = []
        var inbox: [Result<Data, TransportError>] = []
        var waiter: CheckedContinuation<Result<Data, TransportError>, Never>?
        var closed = false
        var failSends = false
    }

    private let connectResult: Result<CertificatePin, TransportError>
    private let state = Mutex(State())

    init(connectResult: Result<CertificatePin, TransportError>) {
        self.connectResult = connectResult
    }

    var url: URL? { state.withLock { $0.url } }
    var policy: PinPolicy? { state.withLock { $0.policy } }
    var sent: [Data] { state.withLock { $0.sent } }
    var isClosed: Bool { state.withLock { $0.closed } }

    func connect(_ url: URL, policy: PinPolicy) async throws(TransportError) -> CertificatePin {
        state.withLock { $0.url = url; $0.policy = policy }
        return try connectResult.get()
    }

    func send(_ data: Data) async throws(TransportError) {
        try state.withLock { s throws(TransportError) in
            if s.closed || s.failSends { throw .closed }
            s.sent.append(data)
        }
    }

    func receive() async throws(TransportError) -> Data {
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<Data, TransportError>, Never>) in
            let immediate = state.withLock { s -> Result<Data, TransportError>? in
                if s.closed { return .failure(.closed) }
                if !s.inbox.isEmpty { return s.inbox.removeFirst() }
                s.waiter = continuation
                return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
        return try result.get()
    }

    func close() async {
        let waiter = state.withLock { s in
            s.closed = true
            defer { s.waiter = nil }
            return s.waiter
        }
        waiter?.resume(returning: .failure(.closed))
    }

    /// Delivers a raw JSON event to the session.
    func push(_ json: String) { deliver(.success(Data(json.utf8))) }

    /// Simulates the TV/network dropping the connection.
    func drop() { deliver(.failure(.closed)) }

    /// Suspends (yielding) until `close()` has been called. A session may emit its final state
    /// just before it finishes closing the transport.
    func waitUntilClosed() async {
        while !isClosed { await Task.yield() }
    }

    func failSubsequentSends() { state.withLock { $0.failSends = true } }

    private func deliver(_ result: Result<Data, TransportError>) {
        let waiter = state.withLock { s -> CheckedContinuation<Result<Data, TransportError>, Never>? in
            if let waiter = s.waiter {
                s.waiter = nil
                return waiter
            }
            s.inbox.append(result)
            return nil
        }
        waiter?.resume(returning: result)
    }
}

/// Hands out one new `FakeTransport` per connection attempt; connect results are scripted by
/// attempt index (default: success with `pin`).
final class FakeTransportFactory: Sendable {
    let pin: CertificatePin
    private let scripted: [Int: Result<CertificatePin, TransportError>]
    private let made = Mutex<[FakeTransport]>([])

    init(pin: CertificatePin, connectResults: [Int: Result<CertificatePin, TransportError>] = [:]) {
        self.pin = pin
        self.scripted = connectResults
    }

    var count: Int { made.withLock { $0.count } }

    func make() -> any WebSocketTransport {
        made.withLock { list in
            let transport = FakeTransport(connectResult: scripted[list.count] ?? .success(pin))
            list.append(transport)
            return transport
        }
    }

    /// Suspends (yielding) until the transport for attempt `index` exists and the session has called
    /// `connect` on it, then returns it.
    func transport(_ index: Int) async -> FakeTransport {
        while true {
            if let t = made.withLock({ index < $0.count ? $0[index] : nil }), t.url != nil { return t }
            await Task.yield()
        }
    }
}

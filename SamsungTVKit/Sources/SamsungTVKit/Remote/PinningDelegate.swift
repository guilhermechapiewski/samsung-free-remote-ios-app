import Foundation
import Synchronization

enum PinDecision: Equatable, Sendable {
    /// Accept the server trust; this is the pin of the accepted certificate.
    case accept(CertificatePin)
    /// Cancel the challenge. `mismatch` is true when a pin was computed but differs from the
    /// required one (surfaced as `TransportError.pinMismatch`).
    case reject(mismatch: Bool)
}

/// URLSession delegate for one `URLSessionWebSocketTransport` connection. Decides server trust
/// purely by certificate pin and reports the connection outcome to a single waiter.
final class PinningDelegate: NSObject, URLSessionWebSocketDelegate, Sendable {
    private struct State {
        var policy: PinPolicy = .require(CertificatePin(sha256: Data())) // fail closed until begin()
        var requestedURL: URL?
        var acceptedPin: CertificatePin?
        var mismatch = false
        var waiter: CheckedContinuation<Result<CertificatePin, TransportError>, Never>?
        var finished = false
    }

    private let state = Mutex(State())

    static func decide(policy: PinPolicy, presented: CertificatePin?) -> PinDecision {
        guard let presented else { return .reject(mismatch: false) }
        switch policy {
        case .recordFirstUse:
            return .accept(presented)
        case .require(let required):
            return presented == required ? .accept(presented) : .reject(mismatch: true)
        }
    }

    /// True only when the socket actually opened on the endpoint that was requested (same scheme,
    /// host, port and path), so a redirected upgrade can never be trusted on another endpoint's pin.
    /// URLSession reports an opened WebSocket task's request with an http(s) scheme, so `ws` is
    /// treated as `http` and `wss` as `https` (never `wss` as `http`).
    static func openedURLMatches(requested: URL, opened: URL?) -> Bool {
        guard let opened,
              let scheme = requested.scheme.map(httpEquivalentScheme),
              let host = requested.host()?.lowercased()
        else { return false }
        return opened.scheme.map(httpEquivalentScheme) == scheme
            && opened.host()?.lowercased() == host
            && opened.port == requested.port
            && opened.path() == requested.path()
    }

    private static func httpEquivalentScheme(_ scheme: String) -> String {
        switch scheme.lowercased() {
        case "ws": "http"
        case "wss": "https"
        case let other: other
        }
    }

    /// Registers the policy, the requested URL and the waiter for the connection outcome. Must be
    /// called before the WebSocket task is resumed.
    func begin(
        policy: PinPolicy,
        url: URL,
        waiter: CheckedContinuation<Result<CertificatePin, TransportError>, Never>
    ) {
        let alreadyFinished = state.withLock { s -> Bool in
            if s.finished { return true }
            s.policy = policy
            s.requestedURL = url
            s.waiter = waiter
            return false
        }
        if alreadyFinished { waiter.resume(returning: .failure(.closed)) }
    }

    /// Resolves the waiter (first call wins; later calls are ignored).
    func finish(_ result: Result<CertificatePin, TransportError>) {
        let waiter = state.withLock { s -> CheckedContinuation<Result<CertificatePin, TransportError>, Never>? in
            s.finished = true
            defer { s.waiter = nil }
            return s.waiter
        }
        waiter?.resume(returning: result)
    }

    private func failure() -> Result<CertificatePin, TransportError> {
        .failure(state.withLock { $0.mismatch } ? .pinMismatch : .unreachable)
    }

    // MARK: URLSessionTaskDelegate

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let presented = CertificatePin.of(trust)
        let decision = state.withLock { s -> PinDecision in
            let decision = Self.decide(policy: s.policy, presented: presented)
            switch decision {
            case .accept(let pin): s.acceptedPin = pin
            case .reject(let mismatch): s.mismatch = s.mismatch || mismatch
            }
            return decision
        }
        switch decision {
        case .accept:
            completionHandler(.useCredential, URLCredential(trust: trust))
        case .reject:
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    /// Redirects are never followed: the pinned endpoint must be the one that opens.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        finish(failure())
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        // An open without a pin accepted by the challenge above, or on any endpoint other than
        // the requested one, is never trusted.
        // Falling back to `originalRequest` when `currentRequest` is nil is safe: redirects are
        // refused, so the two can only differ if the task was redirected (which it cannot be), and
        // an accepted pin from the challenge is still required below before the open is trusted.
        let (pin, requested) = state.withLock { ($0.acceptedPin, $0.requestedURL) }
        guard let requested,
              Self.openedURLMatches(
                  requested: requested,
                  opened: webSocketTask.currentRequest?.url ?? webSocketTask.originalRequest?.url
              )
        else {
            finish(.failure(.unreachable))
            webSocketTask.cancel(with: .goingAway, reason: nil)
            return
        }
        if let pin {
            finish(.success(pin))
        } else {
            finish(failure())
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        finish(failure())
    }
}

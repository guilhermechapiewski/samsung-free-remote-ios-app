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

    /// Registers the policy and the waiter for the connection outcome. Must be called before
    /// the WebSocket task is resumed.
    func begin(policy: PinPolicy, waiter: CheckedContinuation<Result<CertificatePin, TransportError>, Never>) {
        let alreadyFinished = state.withLock { s -> Bool in
            if s.finished { return true }
            s.policy = policy
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

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        finish(failure())
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        // An open without a pin accepted by the challenge above is never trusted.
        if let pin = state.withLock({ $0.acceptedPin }) {
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

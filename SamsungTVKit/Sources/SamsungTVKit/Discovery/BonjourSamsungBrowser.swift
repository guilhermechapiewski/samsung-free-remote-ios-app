import Foundation
import Network
import os
import Synchronization

/// Decides whether an AirPlay Bonjour TXT record belongs to a Samsung device.
public enum BonjourTXT {
    public static func isSamsung(_ txt: [String: String]) -> Bool {
        guard let manufacturer = txt["manufacturer"] else { return false }
        return manufacturer.caseInsensitiveCompare("Samsung") == .orderedSame
    }
}

/// Browses `_airplay._tcp`, keeps Samsung results and resolves each to an IPv4 host.
/// Failures (e.g. Local Network permission denied) are logged and end the stream.
public struct BonjourSamsungBrowser: CandidateSource {
    private static let log = Logger(subsystem: "SamsungTVKit", category: "Bonjour")
    let duration: Duration
    let allowLoopback: Bool

    public init(duration: Duration = .seconds(4)) {
        self.init(duration: duration, allowLoopback: false)
    }

    init(duration: Duration, allowLoopback: Bool) {
        self.duration = duration
        self.allowLoopback = allowLoopback
    }

    public func candidates() -> AsyncStream<String> {
        let duration = duration, allowLoopback = allowLoopback
        return AsyncStream { continuation in
            let log = Self.log
            let queue = DispatchQueue(label: "SamsungTVKit.Bonjour")
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_airplay._tcp", domain: nil), using: .tcp)
            let state = Shared()

            browser.browseResultsChangedHandler = { _, changes in
                for change in changes {
                    guard case .added(let result) = change,
                          case .bonjour(let record) = result.metadata,
                          BonjourTXT.isSamsung(record.dictionary) else { continue }
                    let key = "\(result.endpoint)"
                    let isNew = state.lock.withLock { s in
                        guard !s.finished, s.resolving.insert(key).inserted else { return false }
                        return true
                    }
                    guard isNew else { continue }
                    Self.resolve(result.endpoint, queue: queue, state: state) { host in
                        guard LocalAddress.isAllowed(host, allowLoopback: allowLoopback),
                              state.lock.withLock({ $0.yielded.insert(host).inserted }) else { return }
                        continuation.yield(host)
                    }
                }
            }
            browser.stateUpdateHandler = { s in
                switch s {
                case .failed(let error):
                    log.error("Bonjour browser failed: \(error.localizedDescription, privacy: .public)")
                    continuation.finish()
                case .cancelled:
                    continuation.finish()
                default: break
                }
            }
            let timer = Task {
                try? await Task.sleep(for: duration)
                continuation.finish()
            }
            continuation.onTermination = { _ in
                timer.cancel()
                browser.cancel()
                let pending = state.lock.withLock { s in
                    s.finished = true
                    defer { s.connections.removeAll() }
                    return s.connections
                }
                pending.forEach { $0.cancel() }
            }
            browser.start(queue: queue)
        }
    }

    /// Mutex-guarded browse state (a class because `Mutex` is noncopyable).
    private final class Shared: Sendable {
        let lock = Mutex(State())
    }

    private struct State {
        var finished = false
        var resolving: Set<String> = []
        var yielded: Set<String> = []
        var connections: [NWConnection] = []
    }

    /// Opens a short-lived IPv4 TCP connection to learn the service's address.
    private static func resolve(_ endpoint: NWEndpoint, queue: DispatchQueue, state: Shared,
                                completion: @escaping @Sendable (String) -> Void) {
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let connection = NWConnection(to: endpoint, using: params)
        let registered = state.lock.withLock { s in
            guard !s.finished else { return false }
            s.connections.append(connection)
            return true
        }
        guard registered else { connection.cancel(); return }
        let done = Mutex(false)
        let finish: @Sendable (String?) -> Void = { host in
            guard done.withLock({ let was = $0; $0 = true; return !was }) else { return }
            connection.cancel()
            state.lock.withLock { s in s.connections.removeAll { $0 === connection } }
            if let host { completion(host) }
        }
        connection.stateUpdateHandler = { s in
            switch s {
            case .ready:
                if case .hostPort(let host, _)? = connection.currentPath?.remoteEndpoint, case .ipv4(let address) = host {
                    finish(address.rawValue.map(String.init).joined(separator: "."))
                } else {
                    finish(nil)
                }
            case .failed(let error):
                log.debug("Bonjour resolve failed: \(error.localizedDescription, privacy: .public)")
                finish(nil)
            case .cancelled:
                finish(nil)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 2) { finish(nil) }
    }
}

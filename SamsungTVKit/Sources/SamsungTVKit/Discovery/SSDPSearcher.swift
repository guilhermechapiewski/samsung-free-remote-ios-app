import Foundation
import Network
import os
import Synchronization

/// Multicast SSDP search. Failures (e.g. missing multicast entitlement on iOS) are logged and end the stream.
public struct SSDPSearcher: CandidateSource {
    private static let log = Logger(subsystem: "SamsungTVKit", category: "SSDP")
    let duration: Duration
    let repeats: Int

    public init(duration: Duration = .seconds(4), repeats: Int = 3) {
        self.duration = duration
        self.repeats = max(1, repeats)
    }

    public func candidates() -> AsyncStream<CandidateEvent> {
        let duration = duration, repeats = repeats
        return AsyncStream { continuation in
            let log = Self.log
            let group: NWConnectionGroup
            do {
                let multicast = try NWMulticastGroup(for: [.hostPort(host: "239.255.255.250", port: 1900)])
                group = NWConnectionGroup(with: multicast, using: .udp)
            } catch {
                log.error("SSDP group creation failed: \(error.localizedDescription, privacy: .public)")
                continuation.finish()
                return
            }
            let seen = Mutex<Set<String>>([])
            group.setReceiveHandler(maximumMessageSize: 16 * 1024, rejectOversizedMessages: true) { message, content, _ in
                guard let content, let source = Self.ipv4String(message.remoteEndpoint),
                      let host = SSDP.host(fromResponse: content), host == source,
                      seen.withLock({ $0.insert(host).inserted }) else { return }
                continuation.yield(.host(host))
            }
            let sent = Mutex(false)
            group.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard sent.withLock({ let was = $0; $0 = true; return was }) == false else { return }
                    Task {
                        for round in 0..<repeats {
                            for target in SSDP.targets {
                                group.send(content: SSDP.searchRequest(target: target)) { error in
                                    if let error { log.error("SSDP send failed: \(error.localizedDescription, privacy: .public)") }
                                }
                            }
                            if round < repeats - 1 { try? await Task.sleep(for: duration / repeats) }
                        }
                    }
                case .failed(let error):
                    log.error("SSDP group failed: \(error.localizedDescription, privacy: .public)")
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
                group.cancel()
            }
            group.start(queue: DispatchQueue(label: "SamsungTVKit.SSDP"))
        }
    }

    private static func ipv4String(_ endpoint: NWEndpoint?) -> String? {
        guard case .hostPort(let host, _)? = endpoint, case .ipv4(let address) = host else { return nil }
        return address.rawValue.map(String.init).joined(separator: ".")
    }
}

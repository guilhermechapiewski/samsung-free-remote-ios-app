import Foundation
import Synchronization
@testable import SamsungTVKit

/// Builds an `IPv4Interface` from dotted strings (test literals only).
func iface(_ name: String, _ address: String, _ netmask: String) -> IPv4Interface {
    func value(_ s: String) -> UInt32 {
        s.split(separator: ".").reduce(0) { ($0 << 8) | UInt32($1)! }
    }
    return IPv4Interface(name: name, address: value(address), netmask: value(netmask))
}

/// A `PortProbing` double: reports `open` hosts as open after an optional delay, honours task
/// cancellation, and records every call, the peak number of concurrent probes and cancellations.
final class FakeProber: PortProbing {
    struct Call: Equatable, Sendable {
        let host: String
        let port: UInt16
        let timeout: Duration
    }

    private struct State {
        var calls: [Call] = []
        var active = 0
        var maxActive = 0
        var cancellations = 0
    }

    private let open: Set<String>
    private let delay: Duration?
    private let state = Mutex(State())

    init(open: Set<String>, delay: Duration? = nil) {
        self.open = open
        self.delay = delay
    }

    var calls: [Call] { state.withLock { $0.calls } }
    var maxActive: Int { state.withLock { $0.maxActive } }
    var cancellations: Int { state.withLock { $0.cancellations } }

    func isOpen(host: String, port: UInt16, timeout: Duration) async -> Bool {
        state.withLock { s in
            s.calls.append(Call(host: host, port: port, timeout: timeout))
            s.active += 1
            s.maxActive = max(s.maxActive, s.active)
        }
        defer { state.withLock { $0.active -= 1 } }
        if let delay { try? await Task.sleep(for: delay) }
        if Task.isCancelled {
            state.withLock { $0.cancellations += 1 }
            return false
        }
        return open.contains(host)
    }
}

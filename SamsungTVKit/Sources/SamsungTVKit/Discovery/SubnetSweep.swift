import Foundation
import Network
import os
import Synchronization

/// Checks whether a TCP port accepts connections.
public protocol PortProbing: Sendable {
    func isOpen(host: String, port: UInt16, timeout: Duration) async -> Bool
}

/// Probes with an IPv4 `NWConnection`: open only when the connection reaches `.ready`; closed on
/// failure, `.waiting` (e.g. refused), timeout or task cancellation. The connection is always cancelled.
/// Hosts failing `LocalAddress.isAllowed` are refused without any traffic.
public struct NWPortProber: PortProbing {
    let allowLoopback: Bool
    private let queue = DispatchQueue(label: "SamsungTVKit.PortProbe")

    public init() {
        self.init(allowLoopback: false)
    }

    init(allowLoopback: Bool) {
        self.allowLoopback = allowLoopback
    }

    public func isOpen(host: String, port: UInt16, timeout: Duration) async -> Bool {
        guard LocalAddress.isAllowed(host, allowLoopback: allowLoopback),
              let nwPort = NWEndpoint.Port(rawValue: port), port != 0 else { return false }
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let probe = Probe(connection: NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params))
        let queue = queue
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard probe.install(continuation) else { return }
                probe.connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: probe.finish(true)
                    case .waiting, .failed, .cancelled: probe.finish(false)
                    default: break
                    }
                }
                probe.connection.start(queue: queue)
                // Cancelled between install and start: finish already cancelled the connection, but
                // start may have revived it, so cancel it again.
                if probe.isDone {
                    probe.connection.cancel()
                    return
                }
                probe.scheduleTimeout(on: queue, after: Self.seconds(timeout))
            }
        } onCancel: {
            probe.finish(false)
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return max(0, Double(seconds) + Double(attoseconds) / 1e18)
    }

    /// One probe's connection and its one-shot completion.
    private final class Probe: Sendable {
        private enum Phase {
            case idle
            /// `timeout` is the pending deadline, cancelled when the probe finishes early.
            case waiting(CheckedContinuation<Bool, Never>, timeout: DispatchWorkItem?)
            case done
        }

        let connection: NWConnection
        private let phase = Mutex(Phase.idle)

        init(connection: NWConnection) {
            self.connection = connection
        }

        /// Stores the continuation. Returns false (after resuming it with false) if the probe has
        /// already finished, i.e. the task was cancelled before the continuation existed.
        func install(_ continuation: CheckedContinuation<Bool, Never>) -> Bool {
            let installed = phase.withLock { p in
                guard case .idle = p else { return false }
                p = .waiting(continuation, timeout: nil)
                return true
            }
            if !installed { continuation.resume(returning: false) }
            return installed
        }

        var isDone: Bool {
            phase.withLock { p in
                if case .done = p { return true }
                return false
            }
        }

        /// Finishes the probe as closed after `seconds`, unless it finishes first. Does nothing once
        /// the probe is done. The work item holds the probe weakly: a cancelled item keeps its
        /// captures until its deadline comes round, and the probe should not live that long.
        func scheduleTimeout(on queue: DispatchQueue, after seconds: Double) {
            phase.withLock { p in
                guard case .waiting(let continuation, timeout: nil) = p else { return }
                let item = DispatchWorkItem { [weak self] in self?.finish(false) }
                p = .waiting(continuation, timeout: item)
                queue.asyncAfter(deadline: .now() + seconds, execute: item)
            }
        }

        /// Ends the probe once: cancels the connection and any pending deadline, and resumes the
        /// caller, if it is waiting.
        func finish(_ open: Bool) {
            let continuation: CheckedContinuation<Bool, Never>?? = phase.withLock { p in
                switch p {
                case .done: return .none
                case .idle: p = .done; return .some(nil)
                case .waiting(let c, let timeout):
                    p = .done
                    timeout?.cancel()
                    return .some(c)
                }
            }
            guard case .some(let waiting) = continuation else { return }
            connection.cancel()
            waiting?.resume(returning: open)
        }
    }
}

/// Finds hosts on the iPhone's own Wi-Fi subnet that accept TCP on `port` (8001: the TV's HTTP API),
/// nearest addresses first, with at most `concurrency` probes in flight. Hits still need confirming
/// (a device-info request) by the consumer. It never yields `.localNetworkDenied`: connection errors
/// do not reliably tell denial apart, and the Bonjour source reports it.
public struct SubnetSweep: CandidateSource {
    private static let log = Logger(subsystem: "SamsungTVKit", category: "Sweep")
    let interface: @Sendable () -> IPv4Interface?
    let prober: any PortProbing
    let port: UInt16
    let concurrency: Int
    let timeout: Duration
    let maxAddresses: Int

    public init(interface: @escaping @Sendable () -> IPv4Interface?, prober: any PortProbing = NWPortProber(),
                port: UInt16 = 8001, concurrency: Int = 64, timeout: Duration = .milliseconds(500),
                maxAddresses: Int = SweepRange.maxAddresses) {
        self.interface = interface
        self.prober = prober
        self.port = port
        self.concurrency = max(1, concurrency)
        self.timeout = timeout
        self.maxAddresses = maxAddresses
    }

    public func candidates() -> AsyncStream<CandidateEvent> {
        let interface = interface, prober = prober, port = port, concurrency = concurrency
        let timeout = timeout, maxAddresses = maxAddresses
        return AsyncStream { continuation in
            let task = Task {
                let wifi = interface()
                let hosts = wifi.map { SweepRange.hosts(around: $0, maxAddresses: maxAddresses) } ?? []
                if let wifi {
                    let size = SweepRange.addressCount(netmask: wifi.netmask)
                    if size > UInt64(max(maxAddresses, 0)) {
                        Self.log.info(
                            "Subnet has \(size, privacy: .public) addresses, over the limit of \(maxAddresses, privacy: .public); not sweeping"
                        )
                    } else if size & (size - 1) != 0 {
                        Self.log.info("Netmask is not contiguous; not sweeping")
                    }
                }
                let start = ContinuousClock.now
                var probed = 0, openCount = 0
                await withTaskGroup(of: (String, Bool).self) { group in
                    var pending = hosts.makeIterator()
                    func startNext() {
                        guard !Task.isCancelled, let host = pending.next() else { return }
                        probed += 1
                        group.addTask { (host, await prober.isOpen(host: host, port: port, timeout: timeout)) }
                    }
                    for _ in 0..<concurrency { startNext() }
                    while let (host, open) = await group.next() {
                        if open {
                            openCount += 1
                            Self.log.debug("Port \(port, privacy: .public) open on \(host, privacy: .private)")
                            continuation.yield(.host(host))
                        }
                        startNext()
                    }
                }
                let elapsed = String(describing: ContinuousClock.now - start)
                Self.log.info(
                    "Swept \(probed, privacy: .public) of \(hosts.count, privacy: .public) addresses, \(openCount, privacy: .public) open, in \(elapsed, privacy: .public)"
                )
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

import Foundation
import Network
import Synchronization

/// Signals when the Wi-Fi path's status changes (Wi-Fi turned on or off, joined or left). Only a
/// trigger: whether the device is on Wi-Fi is still decided from its interfaces (`NetworkInterfaces`).
public struct WiFiPathMonitor: Sendable {
    public init() {}

    /// Yields once for the first path update (so a change between the caller's own check and the
    /// monitor starting is not missed) and then whenever the status differs from the previous update.
    /// Each call starts its own monitor, which is cancelled when the stream terminates.
    public func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
            let last = StatusBox()
            monitor.pathUpdateHandler = { path in
                if last.swap(path.status) != path.status { continuation.yield() }
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "SamsungTVKit.WiFiPathMonitor"))
        }
    }
}

/// The last path status seen.
private final class StatusBox: Sendable {
    private let status = Mutex<NWPath.Status?>(nil)

    /// Stores `new` and returns the previous status.
    func swap(_ new: NWPath.Status) -> NWPath.Status? {
        status.withLock { s in
            defer { s = new }
            return s
        }
    }
}

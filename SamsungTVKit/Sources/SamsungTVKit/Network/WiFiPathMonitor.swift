import Foundation
import Network

/// Signals when the Wi-Fi path may have changed (Wi-Fi turned on or off, joined or left, addresses
/// assigned). Only a trigger: whether the device is on Wi-Fi is still decided from its interfaces
/// (`NetworkInterfaces`), and the caller ignores updates that change nothing.
public struct WiFiPathMonitor: Sendable {
    public init() {}

    /// Yields on every path update, including the first. Updates are not filtered by status: the path can
    /// turn satisfied before the interface has its IPv4 address, and a later update with the same status is
    /// then the one that matters. Unread updates coalesce into one (`bufferingNewest(1)`), so a burst never
    /// queues up. Each call starts its own monitor, which is cancelled when the stream terminates.
    public func changes() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
            monitor.pathUpdateHandler = { _ in continuation.yield() }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "SamsungTVKit.WiFiPathMonitor"))
        }
    }
}

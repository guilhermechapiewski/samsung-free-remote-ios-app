import Foundation
import OSLog
#if canImport(Darwin)
import Darwin
#endif

public enum WakeOnLAN {
    private static let log = Logger(subsystem: "SamsungTVKit", category: "WakeOnLAN")

    /// 6 x 0xFF followed by the MAC repeated 16 times (102 bytes).
    public static func magicPacket(for mac: MACAddress) -> Data {
        var data = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { data.append(contentsOf: mac.bytes) }
        return data
    }

    /// Destinations, deduplicated: `host` (unicast; only if it is a private/link-local address),
    /// then, when `broadcast` is true, the interface's directed broadcast and the limited broadcast.
    ///
    /// Broadcasts need the multicast networking entitlement on iOS. Without it they fail with
    /// EHOSTUNREACH, and only the unicast packet can reach the TV: that works while the iPhone (or the
    /// router) still has the TV's hardware address cached, typically for a while after the TV was on.
    public static func targets(via: IPv4Interface, host: String?, broadcast: Bool) -> [String] {
        targets(via: via, host: host, broadcast: broadcast, allowLoopback: false)
    }

    static func targets(via: IPv4Interface, host: String?, broadcast: Bool, allowLoopback: Bool) -> [String] {
        var list: [String] = []
        if let host, LocalAddress.isAllowed(host, allowLoopback: allowLoopback) { list.append(host) }
        if broadcast {
            for b in [via.broadcast, "255.255.255.255"] where !list.contains(b) { list.append(b) }
        }
        return list
    }

    /// Sends the magic packet to UDP port 9 on each of `targets(via:host:broadcast:)`, `repeats` times
    /// (~100 ms apart). Errors are logged, never thrown.
    public static func send(
        to mac: MACAddress, via: IPv4Interface, host: String? = nil, broadcast: Bool = true, repeats: Int = 3
    ) async {
        let packet = magicPacket(for: mac)
        let destinations = targets(via: via, host: host, broadcast: broadcast)
        guard !destinations.isEmpty else {
            log.error("Wake-on-LAN has no destination (no valid host and broadcast disabled)")
            return
        }
        for attempt in 0..<max(repeats, 1) {
            if Task.isCancelled { return }
            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return }
            }
            let errno = sendOnce(packet, to: destinations, interfaceName: via.name)
            if errno != 0 {
                log.error("Wake-on-LAN send failed (errno \(errno, privacy: .public))")
            }
        }
    }

    /// Sends one round on a fresh BSD UDP socket. Returns 0 or the first errno encountered.
    private static func sendOnce(_ packet: Data, to destinations: [String], interfaceName: String) -> Int32 {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return Darwin.errno }
        defer { close(fd) }

        var on: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            return Darwin.errno
        }
        var index = if_nametoindex(interfaceName)
        if index != 0 {
            // Best effort: keep the packet on the Wi-Fi interface.
            _ = setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
        }

        var firstError: Int32 = 0
        for host in destinations {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(9).bigEndian
            guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
                if firstError == 0 { firstError = EINVAL }
                continue
            }
            let sent = packet.withUnsafeBytes { buf in
                withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if sent < 0, firstError == 0 { firstError = Darwin.errno }
        }
        return firstError
    }
}

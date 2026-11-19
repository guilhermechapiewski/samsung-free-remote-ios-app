import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// An IPv4 interface. `address` and `netmask` are in host byte order
/// (192.168.1.100 == 0xC0A80164).
public struct IPv4Interface: Equatable, Sendable {
    public let name: String
    public let address: UInt32
    public let netmask: UInt32

    public init(name: String, address: UInt32, netmask: UInt32) {
        self.name = name
        self.address = address
        self.netmask = netmask
    }

    /// Converts a network-byte-order `in_addr` to a host-order value.
    static func hostOrder(_ addr: in_addr) -> UInt32 {
        UInt32(bigEndian: addr.s_addr)
    }

    static func dotted(_ value: UInt32) -> String {
        "\(value >> 24).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
    }

    public var addressString: String { Self.dotted(address) }

    /// `(address & mask) | ~mask`, dotted.
    public var broadcast: String { Self.dotted((address & netmask) | ~netmask) }
}

public enum NetworkInterfaces {
    /// First interface named exactly `en0` with a private/link-local address and a non-zero netmask.
    public static func wifiIPv4(from list: [IPv4Interface]) -> IPv4Interface? {
        list.first { $0.name == "en0" && $0.netmask != 0 && LocalAddress.isAllowed($0.addressString) }
    }

    /// Up IPv4 interfaces with a netmask, via getifaddrs.
    public static func current() -> [IPv4Interface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result: [IPv4Interface] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0,
                  let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  let mask = entry.pointee.ifa_netmask else { continue }
            let address = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                IPv4Interface.hostOrder($0.pointee.sin_addr)
            }
            let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                IPv4Interface.hostOrder($0.pointee.sin_addr)
            }
            result.append(IPv4Interface(name: String(cString: entry.pointee.ifa_name), address: address, netmask: netmask))
        }
        return result
    }
}

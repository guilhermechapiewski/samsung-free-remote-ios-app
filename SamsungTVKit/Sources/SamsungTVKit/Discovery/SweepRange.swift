import Foundation

/// Which addresses of the iPhone's own subnet a sweep should probe.
public enum SweepRange {
    /// Largest subnet (in addresses) that is swept; a /22 fits, a /21 does not.
    public static let maxAddresses = 1024

    /// Dotted IPv4 hosts of the interface's subnet, nearest to its own address first (ties: lower
    /// address first). Excludes the own address and, for prefixes of /30 or shorter, the network and
    /// broadcast addresses. Empty when the subnet holds more than `maxAddresses` addresses.
    public static func hosts(around interface: IPv4Interface, maxAddresses: Int = maxAddresses) -> [String] {
        let size = UInt64(~interface.netmask) + 1
        guard size <= UInt64(max(maxAddresses, 0)) else { return [] }

        let network = UInt64(interface.address & interface.netmask)
        let own = UInt64(interface.address)
        let usable = size >= 4 ? (network + 1)...(network + size - 2) : network...(network + size - 1)

        let candidates = usable.filter { $0 != own }.sorted { a, b in
            let da = a > own ? a - own : own - a
            let db = b > own ? b - own : own - b
            return da != db ? da < db : a < b
        }
        return candidates
            .map { IPv4Interface.dotted(UInt32($0)) }
            .filter { LocalAddress.isAllowed($0) }
    }
}

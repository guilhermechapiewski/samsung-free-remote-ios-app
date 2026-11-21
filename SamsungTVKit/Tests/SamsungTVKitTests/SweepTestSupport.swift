import Foundation
@testable import SamsungTVKit

/// Builds an `IPv4Interface` from dotted strings (test literals only).
func iface(_ name: String, _ address: String, _ netmask: String) -> IPv4Interface {
    func value(_ s: String) -> UInt32 {
        s.split(separator: ".").reduce(0) { ($0 << 8) | UInt32($1)! }
    }
    return IPv4Interface(name: name, address: value(address), netmask: value(netmask))
}

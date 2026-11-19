import Foundation
import Testing
@testable import SamsungTVKit

@Suite struct NetworkInterfacesTests {
    static func iface(_ name: String, _ a: String, _ m: String) -> IPv4Interface {
        IPv4Interface(name: name, address: ip(a), netmask: ip(m))
    }
    static func ip(_ s: String) -> UInt32 {
        s.split(separator: ".").reduce(0) { ($0 << 8) | UInt32($1)! }
    }

    @Test func broadcastClassC() {
        #expect(Self.iface("en0", "192.168.1.100", "255.255.255.0").broadcast == "192.168.1.255")
    }
    @Test func broadcastSlash16() {
        #expect(Self.iface("en0", "10.1.2.3", "255.255.0.0").broadcast == "10.1.255.255")
    }
    @Test func broadcastSlash30() {
        #expect(Self.iface("en0", "172.16.5.4", "255.255.255.252").broadcast == "172.16.5.7")
    }
    @Test func broadcastOfSlash32() {
        #expect(Self.iface("en0", "10.0.0.9", "255.255.255.255").broadcast == "10.0.0.9")
    }
    @Test func addressString() {
        #expect(Self.iface("en0", "192.168.1.100", "255.255.255.0").addressString == "192.168.1.100")
    }
    @Test func inAddrRoundTrip() {
        var addr = in_addr()
        #expect(inet_pton(AF_INET, "192.168.7.42", &addr) == 1)
        #expect(IPv4Interface.hostOrder(addr) == 0xC0A8_072A)
    }
    @Test func wifiPicksEn0() {
        let list = [Self.iface("pdp_ip0", "10.9.9.9", "255.0.0.0"), Self.iface("en0", "192.168.0.5", "255.255.255.0")]
        #expect(NetworkInterfaces.wifiIPv4(from: list)?.name == "en0")
    }
    @Test func noWiFiReturnsNil() {
        let list = [Self.iface("pdp_ip0", "10.9.9.9", "255.0.0.0"), Self.iface("lo0", "127.0.0.1", "255.0.0.0")]
        #expect(NetworkInterfaces.wifiIPv4(from: list) == nil)
    }
    @Test func publicEn0ReturnsNil() {
        #expect(NetworkInterfaces.wifiIPv4(from: [Self.iface("en0", "8.8.8.8", "255.255.255.0")]) == nil)
    }
    @Test func wifiIgnoresLinkLocalLoopback() {
        // Loopback on en0 is rejected; zero netmask is rejected.
        #expect(NetworkInterfaces.wifiIPv4(from: [Self.iface("en0", "127.0.0.1", "255.0.0.0")]) == nil)
        #expect(NetworkInterfaces.wifiIPv4(from: [Self.iface("en0", "192.168.1.5", "0.0.0.0")]) == nil)
    }
    @Test func currentDoesNotCrash() {
        _ = NetworkInterfaces.current()
    }
}

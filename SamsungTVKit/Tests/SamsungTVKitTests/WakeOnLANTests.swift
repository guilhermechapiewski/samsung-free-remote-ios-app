import Foundation
import Testing
@testable import SamsungTVKit

@Suite struct WakeOnLANTests {
    @Test func magicPacketLayout() throws {
        let mac = try #require(MACAddress("02:00:00:00:00:aa"))
        let p = [UInt8](WakeOnLAN.magicPacket(for: mac))
        #expect(p.count == 102)
        #expect(p[0..<6].allSatisfy { $0 == 0xFF })
        for i in 0..<16 {
            #expect(Array(p[(6 + i * 6)..<(12 + i * 6)]) == mac.bytes)
        }
    }

    static let via = IPv4Interface(name: "en0", address: 0x0A01_0203, netmask: 0xFFFF_0000)

    @Test func targetsAreInterfaceBroadcastAndLimited() {
        #expect(WakeOnLAN.targets(via: Self.via, host: nil, broadcast: true) == ["10.1.255.255", "255.255.255.255"])
    }

    @Test func targetsDedupe() {
        let via = IPv4Interface(name: "en0", address: 0x0A01_0203, netmask: 0)
        #expect(WakeOnLAN.targets(via: via, host: nil, broadcast: true) == ["255.255.255.255"])
    }

    @Test func targetsPutUnicastHostFirst() {
        #expect(WakeOnLAN.targets(via: Self.via, host: "10.1.0.42", broadcast: true)
            == ["10.1.0.42", "10.1.255.255", "255.255.255.255"])
    }

    @Test func targetsUnicastOnlyWithoutBroadcast() {
        #expect(WakeOnLAN.targets(via: Self.via, host: "10.1.0.42", broadcast: false) == ["10.1.0.42"])
    }

    @Test(arguments: ["8.8.8.8", "127.0.0.1", "010.1.0.42", "tv.local", ""])
    func targetsDropNonLocalHost(host: String) {
        #expect(WakeOnLAN.targets(via: Self.via, host: host, broadcast: false).isEmpty)
        #expect(WakeOnLAN.targets(via: Self.via, host: host, broadcast: true) == ["10.1.255.255", "255.255.255.255"])
    }

    @Test func targetsDedupeHostEqualToBroadcast() {
        #expect(WakeOnLAN.targets(via: Self.via, host: "10.1.255.255", broadcast: true)
            == ["10.1.255.255", "255.255.255.255"])
    }

    @Test func loopbackHostOnlyWhenAllowed() {
        #expect(WakeOnLAN.targets(via: Self.via, host: "127.0.0.1", broadcast: false, allowLoopback: true) == ["127.0.0.1"])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TVKIT_LIVE"] == "1"))
    func liveSendFakeMAC() async throws {
        let all = NetworkInterfaces.current()
        // Wi-Fi is en0 on iPhone; on a Mac it may be another interface, so fall back to any private one.
        let wifi = try #require(NetworkInterfaces.wifiIPv4(from: all)
            ?? all.first { $0.netmask != 0 && LocalAddress.isAllowed($0.addressString) })
        await WakeOnLAN.send(to: try #require(MACAddress("02:00:00:00:00:aa")), via: wifi)
    }
}

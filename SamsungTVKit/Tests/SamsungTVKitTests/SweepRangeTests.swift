import Testing
@testable import SamsungTVKit

@Suite struct SweepRangeTests {
    @Test func slash24ExcludesSelfNetworkAndBroadcast() {
        let hosts = SweepRange.hosts(around: iface("en0", "10.0.0.20", "255.255.255.0"))
        #expect(hosts.count == 253)
        #expect(!hosts.contains("10.0.0.20") && !hosts.contains("10.0.0.0") && !hosts.contains("10.0.0.255"))
        #expect(Array(hosts.prefix(4)) == ["10.0.0.19", "10.0.0.21", "10.0.0.18", "10.0.0.22"])
    }
    @Test func slash22IsSwept() {
        #expect(SweepRange.hosts(around: iface("en0", "10.0.4.7", "255.255.252.0")).count == 1021)
    }
    @Test func slash21IsTooLarge() {
        #expect(SweepRange.hosts(around: iface("en0", "10.0.4.7", "255.255.248.0")).isEmpty)
    }
    @Test func slash16IsTooLarge() {
        #expect(SweepRange.hosts(around: iface("en0", "169.254.3.4", "255.255.0.0")).isEmpty)
    }
    @Test func hotspotSlash28() {
        let hosts = SweepRange.hosts(around: iface("en0", "172.20.10.2", "255.255.255.240"))
        #expect(hosts.count == 13 && hosts.first == "172.20.10.1" && !hosts.contains("172.20.10.15"))
    }
    @Test func slash30() {
        #expect(SweepRange.hosts(around: iface("en0", "10.0.0.5", "255.255.255.252")) == ["10.0.0.6"])
    }
    @Test func slash31HasNoNetworkOrBroadcast() {
        #expect(SweepRange.hosts(around: iface("en0", "10.0.0.4", "255.255.255.254")) == ["10.0.0.5"])
    }
    @Test func slash32IsEmpty() {
        #expect(SweepRange.hosts(around: iface("en0", "10.0.0.4", "255.255.255.255")).isEmpty)
    }
    @Test func lowerLimitApplies() {
        #expect(SweepRange.hosts(around: iface("en0", "10.0.4.7", "255.255.252.0"), maxAddresses: 512).isEmpty)
    }
    @Test func publicAddressYieldsNothing() {
        #expect(SweepRange.hosts(around: iface("en0", "8.8.8.8", "255.255.255.240")).isEmpty)
    }
    @Test func carrierGradeNatAddressYieldsNothing() {
        #expect(SweepRange.hosts(around: iface("en0", "100.64.1.5", "255.255.255.240")).isEmpty)
    }
}

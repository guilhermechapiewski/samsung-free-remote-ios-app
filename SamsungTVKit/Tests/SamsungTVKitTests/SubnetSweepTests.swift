import Testing
@testable import SamsungTVKit

@Suite struct SubnetSweepTests {
    private let wifi: @Sendable () -> IPv4Interface? = { iface("en0", "10.0.0.20", "255.255.255.0") }

    @Test func yieldsOnlyOpenHosts() async {
        let prober = FakeProber(open: ["10.0.0.7", "10.0.0.200"])
        let sweep = SubnetSweep(interface: wifi, prober: prober)
        var hosts: [String] = []
        for await case .host(let h) in sweep.candidates() { hosts.append(h) }
        #expect(Set(hosts) == ["10.0.0.7", "10.0.0.200"])
        #expect(prober.calls.count == 253)
        #expect(prober.calls.allSatisfy { $0.port == 8001 && $0.timeout == .milliseconds(500) })
    }

    @Test func respectsConcurrencyLimit() async {
        let prober = FakeProber(open: [], delay: .milliseconds(20))
        for await _ in SubnetSweep(interface: wifi, prober: prober, concurrency: 64).candidates() {}
        #expect(prober.maxActive <= 64 && prober.maxActive >= 32)
        #expect(prober.calls.count == 253)
    }

    @Test func sweepWithoutWiFiFinishesEmpty() async {
        let prober = FakeProber(open: [])
        var count = 0
        for await _ in SubnetSweep(interface: { nil }, prober: prober).candidates() { count += 1 }
        #expect(count == 0 && prober.calls.isEmpty)
    }

    @Test func tooLargeSubnetProbesNothing() async {
        let prober = FakeProber(open: [])
        for await _ in SubnetSweep(interface: { iface("en0", "10.1.2.3", "255.255.0.0") }, prober: prober).candidates() {}
        #expect(prober.calls.isEmpty)
    }

    @Test func cancellingStopsProbes() async throws {
        let prober = FakeProber(open: [], delay: .seconds(10))
        let sweep = SubnetSweep(interface: wifi, prober: prober)
        let task = Task { for await _ in sweep.candidates() {} }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let start = ContinuousClock.now
        await task.value
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(prober.calls.count <= 64) // no new batches after cancellation
        #expect(prober.cancellations > 0) // in-flight probes saw the cancellation
    }

    @Test func consumerStoppingEndsSweep() async {
        let prober = FakeProber(open: ["10.0.0.19"], delay: .milliseconds(20))
        for await event in SubnetSweep(interface: wifi, prober: prober, concurrency: 1).candidates() {
            if case .host = event { break }
        }
        let afterBreak = prober.calls.count
        try? await Task.sleep(for: .milliseconds(200))
        // The sweep may start one more probe before it sees the termination; uncancelled, it would
        // run about ten more in 200 ms.
        #expect(prober.calls.count <= afterBreak + 1)
    }

    @Test func nearestHostsProbedFirst() async {
        let prober = FakeProber(open: [])
        for await _ in SubnetSweep(interface: wifi, prober: prober, concurrency: 1).candidates() {}
        #expect(Array(prober.calls.prefix(2).map(\.host)) == ["10.0.0.19", "10.0.0.21"])
    }
}

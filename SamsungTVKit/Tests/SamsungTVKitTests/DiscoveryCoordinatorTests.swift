import Foundation
import Synchronization
import Testing
@testable import SamsungTVKit

private struct FakeSource: CandidateSource {
    let events: [CandidateEvent]
    var delay: Duration = .zero

    func candidates() -> AsyncStream<CandidateEvent> {
        let events = events, delay = delay
        return AsyncStream { continuation in
            let task = Task {
                for event in events {
                    if delay > .zero { try? await Task.sleep(for: delay) }
                    continuation.yield(event)
                }
                if delay > .zero { try? await Task.sleep(for: delay) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Never finishes on its own; records when its stream is terminated.
private final class EndlessSource: CandidateSource {
    let terminated = Mutex(false)

    func candidates() -> AsyncStream<CandidateEvent> {
        AsyncStream { continuation in
            continuation.yield(.host("10.0.0.5"))
            continuation.onTermination = { [self] _ in terminated.withLock { $0 = true } }
        }
    }
}

private final class FakeFetcher: TVInfoFetching {
    private struct State {
        var calls: [String] = []
        var active = 0
        var maxActive = 0
    }
    private let state = Mutex(State())
    let ids: [String: String]
    let delay: Duration

    /// `ids` maps host → TV id; hosts not in the map fail with `.unreachable`.
    init(ids: [String: String], delay: Duration = .zero) {
        self.ids = ids
        self.delay = delay
    }

    var calls: [String] { state.withLock { $0.calls } }
    var maxActive: Int { state.withLock { $0.maxActive } }

    func fetchInfo(host: String) async throws(TVInfoError) -> TVDeviceInfo {
        state.withLock { s in
            s.calls.append(host)
            s.active += 1
            s.maxActive = max(s.maxActive, s.active)
        }
        defer { state.withLock { $0.active -= 1 } }
        if delay > .zero { try? await Task.sleep(for: delay) }
        guard let id = ids[host] else { throw .unreachable }
        return TVDeviceInfo(id: TVID(rawValue: id), host: host, name: "TV", modelName: "M", modelCode: "C",
                            wifiMAC: nil, networkType: "wired", powerState: .on, tokenAuthSupported: true)
    }
}

private func collect(_ stream: AsyncStream<DiscoveryEvent>) async -> [DiscoveryEvent] {
    var events: [DiscoveryEvent] = []
    for await event in stream { events.append(event) }
    return events
}

private func foundIDs(_ events: [DiscoveryEvent]) -> [String] {
    events.compactMap { if case .found(let info) = $0 { info.id.rawValue } else { nil } }
}

@Test func fetchesEachDistinctHostOnce() async {
    let fetcher = FakeFetcher(ids: ["10.0.0.5": "uuid:a", "10.0.0.6": "uuid:b", "10.0.0.7": "uuid:c"])
    let coordinator = DiscoveryCoordinator(
        sources: [FakeSource(events: [.host("10.0.0.5"), .host("10.0.0.6")]),
                  FakeSource(events: [.host("10.0.0.5"), .host("10.0.0.7")], delay: .milliseconds(10))],
        fetcher: fetcher, knownHosts: ["10.0.0.7", "10.0.0.5"])
    let events = await collect(await coordinator.scan())
    #expect(fetcher.calls.sorted() == ["10.0.0.5", "10.0.0.6", "10.0.0.7"])
    #expect(foundIDs(events).sorted() == ["uuid:a", "uuid:b", "uuid:c"])
}

@Test func knownHostsFetchedWithoutSources() async {
    let fetcher = FakeFetcher(ids: ["10.0.0.9": "uuid:k"])
    let coordinator = DiscoveryCoordinator(sources: [], fetcher: fetcher, knownHosts: ["10.0.0.9"])
    #expect(foundIDs(await collect(await coordinator.scan())) == ["uuid:k"])
}

@Test func sameIDFromTwoHostsYieldedOnce() async {
    let fetcher = FakeFetcher(ids: ["10.0.0.5": "uuid:same", "10.0.0.6": "uuid:same"])
    let coordinator = DiscoveryCoordinator(
        sources: [FakeSource(events: [.host("10.0.0.5"), .host("10.0.0.6")])], fetcher: fetcher, knownHosts: [])
    let events = await collect(await coordinator.scan())
    #expect(fetcher.calls.count == 2)
    #expect(foundIDs(events) == ["uuid:same"])
}

@Test func fetchFailuresSkipped() async {
    let fetcher = FakeFetcher(ids: ["10.0.0.6": "uuid:ok"])
    let coordinator = DiscoveryCoordinator(
        sources: [FakeSource(events: [.host("10.0.0.5"), .host("10.0.0.6")])], fetcher: fetcher, knownHosts: ["10.0.0.7"])
    let events = await collect(await coordinator.scan())
    #expect(fetcher.calls.count == 3)
    #expect(events.count == 1)
    #expect(foundIDs(events) == ["uuid:ok"])
}

@Test func streamFinishesWhenSourcesAndFetchesFinish() async {
    let fetcher = FakeFetcher(ids: ["10.0.0.5": "uuid:a", "10.0.0.6": "uuid:b"], delay: .milliseconds(50))
    let coordinator = DiscoveryCoordinator(
        sources: [FakeSource(events: [.host("10.0.0.5")], delay: .milliseconds(20)),
                  FakeSource(events: [.host("10.0.0.6")], delay: .milliseconds(40))],
        fetcher: fetcher, knownHosts: [])
    // The last fetch starts after its source yields and completes after the source finishes; both must be included.
    #expect(foundIDs(await collect(await coordinator.scan())).sorted() == ["uuid:a", "uuid:b"])
}

@Test func atMostEightConcurrentFetches() async {
    let hosts = (1...20).map { "10.0.1.\($0)" }
    let fetcher = FakeFetcher(ids: Dictionary(uniqueKeysWithValues: hosts.map { ($0, "uuid:\($0)") }), delay: .milliseconds(20))
    let coordinator = DiscoveryCoordinator(
        sources: [FakeSource(events: hosts.map { .host($0) })], fetcher: fetcher, knownHosts: [])
    let events = await collect(await coordinator.scan())
    #expect(foundIDs(events).count == 20)
    #expect(fetcher.maxActive == 8)
}

@Test func localNetworkDeniedForwardedOnce() async {
    let fetcher = FakeFetcher(ids: ["10.0.0.5": "uuid:a"])
    let coordinator = DiscoveryCoordinator(
        sources: [FakeSource(events: [.localNetworkDenied, .localNetworkDenied]),
                  FakeSource(events: [.localNetworkDenied, .host("10.0.0.5")])],
        fetcher: fetcher, knownHosts: [])
    let events = await collect(await coordinator.scan())
    #expect(events.filter { $0 == .localNetworkDenied }.count == 1)
    #expect(foundIDs(events) == ["uuid:a"])
}

@Test func cancellingConsumerTerminatesSources() async throws {
    let source = EndlessSource()
    let coordinator = DiscoveryCoordinator(sources: [source], fetcher: FakeFetcher(ids: ["10.0.0.5": "uuid:a"]), knownHosts: [])
    let consumer = Task {
        for await event in await coordinator.scan() {
            if case .found = event { return true }
        }
        return false
    }
    #expect(await consumer.value)
    for _ in 0..<100 where !source.terminated.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(source.terminated.withLock { $0 })
}

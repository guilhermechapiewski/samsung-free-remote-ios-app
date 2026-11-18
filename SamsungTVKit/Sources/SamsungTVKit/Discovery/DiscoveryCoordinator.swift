import Foundation
import os
import Synchronization

/// What a scan reports.
public enum DiscoveryEvent: Equatable, Sendable {
    /// A TV, reported once per `TVID` per scan.
    case found(TVDeviceInfo)
    /// Local Network access was denied; reported at most once per scan.
    case localNetworkDenied
}

/// Merges candidate sources with previously known hosts, fetches each distinct host's info once per scan
/// (at most `maxConcurrentFetches` at a time) and reports each TV once.
public actor DiscoveryCoordinator {
    private static let log = Logger(subsystem: "SamsungTVKit", category: "Discovery")
    static let maxConcurrentFetches = 8

    private let sources: [any CandidateSource]
    private let fetcher: any TVInfoFetching
    private let knownHosts: [String]

    public init(sources: [any CandidateSource], fetcher: any TVInfoFetching, knownHosts: [String]) {
        self.sources = sources
        self.fetcher = fetcher
        self.knownHosts = knownHosts
    }

    /// Finishes when every source has finished and every fetch has completed.
    /// Ending iteration early cancels the sources and in-flight fetches.
    public func scan() -> AsyncStream<DiscoveryEvent> {
        let sources = sources, fetcher = fetcher, knownHosts = knownHosts
        return AsyncStream { continuation in
            let task = Task {
                await Self.run(sources: sources, fetcher: fetcher, knownHosts: knownHosts, output: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private enum ChildResult: Sendable {
        case sourcesFinished
        case fetchFinished
    }

    private static func run(sources: [any CandidateSource], fetcher: any TVInfoFetching, knownHosts: [String],
                            output: AsyncStream<DiscoveryEvent>.Continuation) async {
        let (merged, mergedContinuation) = AsyncStream.makeStream(of: CandidateEvent.self)
        let reportedIDs = Mutex<Set<TVID>>([])
        var requestedHosts: Set<String> = []
        var reportedDenial = false
        var inFlight = 0

        await withTaskGroup(of: ChildResult.self) { group in
            group.addTask {
                await withTaskGroup(of: Void.self) { feeders in
                    for source in sources {
                        feeders.addTask {
                            for await event in source.candidates() { mergedContinuation.yield(event) }
                        }
                    }
                }
                mergedContinuation.finish()
                return .sourcesFinished
            }

            func fetch(_ host: String) async {
                guard requestedHosts.insert(host).inserted else { return }
                while inFlight >= maxConcurrentFetches, let result = await group.next() {
                    if case .fetchFinished = result { inFlight -= 1 }
                }
                inFlight += 1
                group.addTask {
                    do {
                        let info = try await fetcher.fetchInfo(host: host)
                        if reportedIDs.withLock({ $0.insert(info.id).inserted }) { output.yield(.found(info)) }
                    } catch {
                        log.debug("Fetch failed for \(host, privacy: .private): \(String(describing: error), privacy: .public)")
                    }
                    return .fetchFinished
                }
            }

            for host in knownHosts { await fetch(host) }
            for await event in merged {
                switch event {
                case .host(let host):
                    await fetch(host)
                case .localNetworkDenied:
                    guard !reportedDenial else { continue }
                    reportedDenial = true
                    output.yield(.localNetworkDenied)
                }
            }
            await group.waitForAll()
        }
    }
}

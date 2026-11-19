import Foundation
import Testing
@testable import SamsungTVKit

private let tvID = TVID(rawValue: "uuid:00000000-0000-4000-8000-000000000001")
private let loopback = "127.0.0.1"

/// End-to-end tests over real loopback sockets: the production `URLSessionWebSocketTransport`,
/// `PinningDelegate`, `RemoteSession` and `HTTPTVInfoFetcher` against `FakeTV`. FakeTV binds the
/// production ports 8001/8002 on 127.0.0.1, so the suite is serialized.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct FakeTVTests {
    @Test func pairsThenReconnectsWithToken() async throws {
        try await withFakeTV { tv in
            let store = InMemoryCredentialStore()

            let first = makeSession(store)
            #expect(await connect(first) == .connected)
            #expect(store.load(tvID)?.token == "fake-token")
            await first.disconnect()

            // A second, independent session and transport: must present the token and pass the
            // pin check (which requires a fresh trust challenge on the new connection).
            let second = makeSession(store)
            #expect(await connect(second) == .connected)
            await second.disconnect()

            let targets = tv.requestTargets
            try #require(targets.count == 2)
            #expect(targets[0].hasPrefix("/api/v2/channels/samsung.remote.control?name="))
            #expect(!targets[0].contains("token="))
            #expect(targets[1].contains("token=fake-token"))
        }
    }

    @Test func rejectsDifferentCertificate() async throws {
        try await withFakeTV { tv in
            let store = InMemoryCredentialStore()
            let first = makeSession(store)
            #expect(await connect(first) == .connected)
            await first.disconnect()

            await tv.stop()
            try await tv.start(identity: .secondary)

            let second = makeSession(store)
            #expect(await connect(second) == .failed(.identityChanged))
            #expect(tv.requestTargets.count == 1) // the impostor never saw the upgrade request
        }
    }

    @Test func keyArrivesAtTV() async throws {
        try await withFakeTV { tv in
            let session = makeSession(InMemoryCredentialStore())
            #expect(await connect(session) == .connected)

            try await session.send(.volumeUp)

            let expected = #"{"method":"ms.remote.control","params":{"Cmd":"Click","DataOfCmd":"KEY_VOLUP","Option":"false","TypeOfRemote":"SendRemoteKey"}}"#
            #expect(await eventually { tv.receivedMessages == [expected] })
            await session.disconnect()
        }
    }

    @Test func deniedPairing() async throws {
        try await withFakeTV { tv in
            tv.denyPairing = true
            let store = InMemoryCredentialStore()
            let session = makeSession(store)
            #expect(await connect(session) == .failed(.denied))
            #expect(store.load(tvID) == nil)
        }
    }

    @Test func infoFetchOverLoopback() async throws {
        try await withFakeTV { _ in
            let urlSession = URLSession(configuration: .ephemeral)
            defer { urlSession.invalidateAndCancel() }
            let fetcher = HTTPTVInfoFetcher(
                session: urlSession, timeout: .seconds(2), maxBytes: 64 * 1024, allowLoopback: true
            )
            let info = try await fetcher.fetchInfo(host: loopback)
            #expect(info.id == tvID)
            #expect(info.host == loopback)
            #expect(info.name == "Fake TV")
            #expect(info.powerState == .on)
            #expect(info.tokenAuthSupported)
        }
    }
}

// MARK: - Helpers

private func makeSession(_ store: InMemoryCredentialStore) -> RemoteSession {
    RemoteSession(id: tvID, host: loopback, credentials: store, transport: { URLSessionWebSocketTransport() })
}

/// Connects and returns the first settled state (`.connected` or `.failed`).
private func connect(_ session: RemoteSession) async -> SessionState? {
    var states = session.states.makeAsyncIterator()
    await session.connect()
    while let state = await states.next() {
        switch state {
        case .connected, .failed: return state
        case .idle, .connecting, .awaitingApproval: continue
        }
    }
    return nil
}

/// Starts a FakeTV with the primary identity, runs `body`, and always stops it (ports are fixed).
private func withFakeTV(_ body: (FakeTV) async throws -> Void) async throws {
    let tv = FakeTV()
    try await tv.start(identity: .primary)
    do {
        try await body(tv)
    } catch {
        await tv.stop()
        throw error
    }
    await tv.stop()
}

private func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

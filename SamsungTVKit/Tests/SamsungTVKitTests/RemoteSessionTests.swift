import Foundation
import Testing
@testable import SamsungTVKit

private let tvID = TVID(rawValue: "tv-1")
private let host = "10.0.0.5"
private let pin = CertificatePin(sha256: Data(repeating: 0xA, count: 32))

private let connectEvent = #"{"event":"ms.channel.connect","data":{"token":"12345678"}}"#
private let connectEventNoToken = #"{"event":"ms.channel.connect","data":{}}"#

@Suite(.timeLimit(.minutes(1)))
struct RemoteSessionTests {
    let store: InMemoryCredentialStore
    let factory: FakeTransportFactory
    let clock = TestClock()
    let session: RemoteSession

    init() {
        self.init(stored: nil)
    }

    private init(stored: TVCredentials?, connectResults: [Int: Result<CertificatePin, TransportError>] = [:]) {
        store = InMemoryCredentialStore(stored.map { [tvID: $0] } ?? [:])
        factory = FakeTransportFactory(pin: pin, connectResults: connectResults)
        let factory = factory
        session = RemoteSession(
            id: tvID, host: host, credentials: store,
            transport: { factory.make() }, clock: clock
        )
    }

    private static func paired(connectResults: [Int: Result<CertificatePin, TransportError>] = [:]) -> RemoteSessionTests {
        RemoteSessionTests(stored: TVCredentials(token: "stored", pin: pin), connectResults: connectResults)
    }

    /// Connects with stored credentials and completes the handshake.
    private func connectPaired(_ states: inout AsyncStream<SessionState>.Iterator) async -> FakeTransport {
        await session.connect()
        #expect(await states.next() == .connecting)
        let transport = await factory.transport(0)
        transport.push(connectEventNoToken)
        #expect(await states.next() == .connected)
        return transport
    }

    @Test func firstPairingSavesTokenAndPin() async {
        var states = session.states.makeAsyncIterator()
        await session.connect()
        #expect(await states.next() == .connecting)
        #expect(await states.next() == .awaitingApproval)

        let transport = await factory.transport(0)
        guard case .recordFirstUse = transport.policy else {
            Issue.record("expected recordFirstUse, got \(String(describing: transport.policy))")
            return
        }
        #expect(transport.url?.query?.contains("token=") == false)

        transport.push(connectEvent)
        #expect(await states.next() == .connected)
        #expect(store.load(tvID) == TVCredentials(token: "12345678", pin: pin))
        #expect(await session.currentState == .connected)
    }

    @Test func storedCredentialsUseRequirePolicyAndToken() async {
        let t = Self.paired()
        var states = t.session.states.makeAsyncIterator()
        await t.session.connect()
        #expect(await states.next() == .connecting)

        let transport = await t.factory.transport(0)
        guard case .require(let required) = transport.policy else {
            Issue.record("expected require policy, got \(String(describing: transport.policy))")
            return
        }
        #expect(required == pin)
        #expect(transport.url?.query?.contains("token=stored") == true)

        // TV sends no new token: the stored one is kept.
        transport.push(connectEventNoToken)
        #expect(await states.next() == .connected)
        #expect(t.store.load(tvID) == TVCredentials(token: "stored", pin: pin))
    }

    @Test func newTokenReplacesStoredToken() async {
        let t = Self.paired()
        var states = t.session.states.makeAsyncIterator()
        await t.session.connect()
        #expect(await states.next() == .connecting)
        await t.factory.transport(0).push(connectEvent)
        #expect(await states.next() == .connected)
        #expect(t.store.load(tvID)?.token == "12345678")
    }

    @Test func deniedDeletesCredentials() async {
        let t = Self.paired()
        var states = t.session.states.makeAsyncIterator()
        await t.session.connect()
        #expect(await states.next() == .connecting)
        let transport = await t.factory.transport(0)
        transport.push(#"{"event":"ms.channel.unauthorized"}"#)
        #expect(await states.next() == .failed(.denied))
        #expect(t.store.load(tvID) == nil)
        await transport.waitUntilClosed()
    }

    @Test func approvalTimeout() async {
        var states = session.states.makeAsyncIterator()
        await session.connect()
        #expect(await states.next() == .connecting)
        #expect(await states.next() == .awaitingApproval)
        let transport = await factory.transport(0)

        await clock.waitForSleepers(1)
        #expect(clock.requestedSleeps == [.seconds(30)])
        clock.advance(by: .seconds(30))
        #expect(await states.next() == .failed(.approvalTimedOut))
        await transport.waitUntilClosed()
        #expect(store.load(tvID) == nil)
    }

    @Test func approvalTimeoutAppliesToTokenConnectAndStopsOnceConnected() async {
        let t = Self.paired()
        var states = t.session.states.makeAsyncIterator()
        await t.session.connect()
        #expect(await states.next() == .connecting)
        await t.clock.waitForSleepers(1)
        t.clock.advance(by: .seconds(30))
        #expect(await states.next() == .failed(.approvalTimedOut))
        #expect(t.store.load(tvID) == TVCredentials(token: "stored", pin: pin))

        await t.session.connect()
        #expect(await states.next() == .connecting)
        await t.factory.transport(1).push(connectEventNoToken)
        #expect(await states.next() == .connected)
        #expect(t.clock.sleeperCount == 0)
        t.clock.advance(by: .seconds(60))
        #expect(await t.session.currentState == .connected)
    }

    @Test func tvTimeOutEventReportsApprovalTimedOut() async {
        var states = session.states.makeAsyncIterator()
        await session.connect()
        #expect(await states.next() == .connecting)
        #expect(await states.next() == .awaitingApproval)
        await factory.transport(0).push(#"{"event":"ms.channel.timeOut"}"#)
        #expect(await states.next() == .failed(.approvalTimedOut))
    }

    @Test func pinMismatchReportsIdentityChanged() async {
        let t = Self.paired(connectResults: [0: .failure(.pinMismatch)])
        var states = t.session.states.makeAsyncIterator()
        await t.session.connect()
        #expect(await states.next() == .connecting)
        #expect(await states.next() == .failed(.identityChanged))
        #expect(t.store.load(tvID) == TVCredentials(token: "stored", pin: pin))
        #expect(t.factory.count == 1)
    }

    @Test func initialConnectFailureIsUnreachableWithoutRetry() async {
        let t = Self.paired(connectResults: [0: .failure(.unreachable)])
        var states = t.session.states.makeAsyncIterator()
        await t.session.connect()
        #expect(await states.next() == .connecting)
        #expect(await states.next() == .failed(.unreachable))
        #expect(t.factory.count == 1)
        #expect(t.clock.sleeperCount == 0)
    }

    @Test func disallowedHostFailsWithoutConnecting() async {
        let session = RemoteSession(
            id: tvID, host: "8.8.8.8", credentials: store,
            transport: { [factory] in factory.make() }, clock: clock
        )
        var states = session.states.makeAsyncIterator()
        await session.connect()
        #expect(await states.next() == .failed(.unreachable))
        #expect(factory.count == 0)
    }

    @Test func dropReconnectsWithBackoff() async {
        let t = Self.paired(connectResults: [1: .failure(.unreachable), 2: .failure(.unreachable)])
        var states = t.session.states.makeAsyncIterator()
        let first = await t.connectPaired(&states)

        first.drop()
        #expect(await states.next() == .connecting)
        #expect(first.isClosed)

        await t.clock.waitForSleepers(1)
        #expect(t.clock.requestedSleeps.last == .milliseconds(500))
        t.clock.advance(by: .milliseconds(499))
        #expect(t.factory.count == 1)
        t.clock.advance(by: .milliseconds(1))
        _ = await t.factory.transport(1) // fails to connect

        await t.clock.waitForSleepers(1)
        #expect(t.clock.requestedSleeps.last == .seconds(1))
        t.clock.advance(by: .seconds(1))
        _ = await t.factory.transport(2) // fails to connect

        await t.clock.waitForSleepers(1)
        #expect(t.clock.requestedSleeps.last == .seconds(2))
        t.clock.advance(by: .seconds(2))
        let fourth = await t.factory.transport(3)
        fourth.push(connectEventNoToken)
        #expect(await states.next() == .connected)
        #expect(await t.session.currentState == .connected)
    }

    @Test func reconnectGivesUpAfterFiveFailedAttempts() async {
        let failures = Dictionary(uniqueKeysWithValues: (1...5).map { ($0, Result<CertificatePin, TransportError>.failure(.unreachable)) })
        let t = Self.paired(connectResults: failures)
        var states = t.session.states.makeAsyncIterator()
        let first = await t.connectPaired(&states)

        first.drop()
        #expect(await states.next() == .connecting)
        for (attempt, delay) in [Duration.milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8)].enumerated() {
            await t.clock.waitForSleepers(1)
            #expect(t.clock.requestedSleeps.last == delay)
            t.clock.advance(by: delay)
            _ = await t.factory.transport(attempt + 1)
        }
        #expect(await states.next() == .failed(.unreachable))
        #expect(t.factory.count == 6)
        #expect(t.clock.sleeperCount == 0)
    }

    @Test func disconnectStopsReconnect() async {
        let t = Self.paired()
        var states = t.session.states.makeAsyncIterator()
        let first = await t.connectPaired(&states)

        first.drop()
        #expect(await states.next() == .connecting)
        await t.clock.waitForSleepers(1)

        await t.session.disconnect()
        #expect(await states.next() == .idle)
        #expect(t.clock.sleeperCount == 0)
        t.clock.advance(by: .seconds(60))
        #expect(t.factory.count == 1)
        #expect(await t.session.currentState == .idle)
    }

    @Test func disconnectWhileConnectedClosesTransport() async {
        let t = Self.paired()
        var states = t.session.states.makeAsyncIterator()
        let transport = await t.connectPaired(&states)
        await t.session.disconnect()
        #expect(await states.next() == .idle)
        #expect(transport.isClosed)
        #expect(t.factory.count == 1)
    }

    @Test func connectWhileConnectingIsNoOpAndFailedCanRestart() async {
        var states = session.states.makeAsyncIterator()
        await session.connect()
        await session.connect()
        #expect(await states.next() == .connecting)
        #expect(await states.next() == .awaitingApproval)
        #expect(factory.count == 1)

        await factory.transport(0).push(#"{"event":"ms.channel.timeOut"}"#)
        #expect(await states.next() == .failed(.approvalTimedOut))

        await session.connect()
        #expect(await states.next() == .connecting)
        #expect(await states.next() == .awaitingApproval)
        #expect(factory.count == 2)
    }

    @Test func sendWhileDisconnectedThrows() async {
        await #expect(throws: SessionError.unreachable) { try await session.send(.home) }
        await #expect(throws: SessionError.unreachable) { try await session.sendText("hi") }
        await #expect(throws: SessionError.unreachable) { try await session.sendTextEnd() }
    }

    @Test func sendWhileConnectedWritesProtocolMessages() async throws {
        let t = Self.paired()
        var states = t.session.states.makeAsyncIterator()
        let transport = await t.connectPaired(&states)

        try await t.session.send(.volumeUp)
        try await t.session.send(.enter, .press)
        try await t.session.sendText("hi")
        try await t.session.sendTextEnd()
        #expect(transport.sent == [
            RemoteProtocol.key(.volumeUp, .click),
            RemoteProtocol.key(.enter, .press),
            RemoteProtocol.text("hi"),
            RemoteProtocol.textEnd(),
        ])
    }

    @Test func sendFailureThrowsAndReconnects() async {
        let t = Self.paired()
        var states = t.session.states.makeAsyncIterator()
        let transport = await t.connectPaired(&states)
        transport.failSubsequentSends()

        await #expect(throws: SessionError.unreachable) { try await t.session.send(.home) }
        #expect(await states.next() == .connecting)
        await t.clock.waitForSleepers(1)
        t.clock.advance(by: .milliseconds(500))
        await t.factory.transport(1).push(connectEventNoToken)
        #expect(await states.next() == .connected)
    }

    @Test func keyboardEventsForwarded() async {
        let t = Self.paired()
        var states = t.session.states.makeAsyncIterator()
        var keyboard = t.session.keyboardEvents.makeAsyncIterator()
        let transport = await t.connectPaired(&states)

        transport.push(#"{"event":"ms.remote.imeStart"}"#)
        #expect(await keyboard.next() == true)
        transport.push(#"{"event":"ms.remote.imeEnd"}"#)
        #expect(await keyboard.next() == false)
    }

    // MARK: - sendEnsuringConnection

    @Test func ensuringConnectionSendsImmediatelyWhenConnected() async throws {
        let t = Self.paired()
        var states = t.session.states.makeAsyncIterator()
        let transport = await t.connectPaired(&states)

        try await t.session.sendEnsuringConnection(.power, timeout: .seconds(3))
        #expect(transport.sent == [RemoteProtocol.key(.power, .click)])
        #expect(t.factory.count == 1)
        #expect(t.clock.sleeperCount == 0)
    }

    @Test func ensuringConnectionConnectsFromIdleThenSends() async throws {
        let t = Self.paired()
        let send = Task { try await t.session.sendEnsuringConnection(.power, timeout: .seconds(3)) }
        let transport = await t.factory.transport(0)
        transport.push(connectEventNoToken)
        try await send.value
        #expect(transport.sent == [RemoteProtocol.key(.power, .click)])
        #expect(await t.session.currentState == .connected)
    }

    @Test func ensuringConnectionRestartsFromFailed() async throws {
        let t = Self.paired(connectResults: [0: .failure(.unreachable)])
        var states = t.session.states.makeAsyncIterator()
        await t.session.connect()
        #expect(await states.next() == .connecting)
        #expect(await states.next() == .failed(.unreachable))

        let send = Task { try await t.session.sendEnsuringConnection(.power, timeout: .seconds(3)) }
        let transport = await t.factory.transport(1)
        transport.push(connectEventNoToken)
        try await send.value
        #expect(transport.sent == [RemoteProtocol.key(.power, .click)])
    }

    @Test func ensuringConnectionPropagatesFailure() async {
        let t = Self.paired(connectResults: [0: .failure(.pinMismatch)])
        await #expect(throws: SessionError.identityChanged) {
            try await t.session.sendEnsuringConnection(.power, timeout: .seconds(3))
        }
    }

    @Test func ensuringConnectionReportsFailureEvenWhenStateRepeats() async {
        // Already failed with .unreachable; the new attempt fails the same way without a new state value.
        let session = RemoteSession(
            id: tvID, host: "8.8.8.8", credentials: store,
            transport: { [factory] in factory.make() }, clock: clock
        )
        await session.connect()
        while await session.currentState != .failed(.unreachable) { await Task.yield() }
        await #expect(throws: SessionError.unreachable) {
            try await session.sendEnsuringConnection(.power, timeout: .seconds(3))
        }
    }

    @Test func ensuringConnectionTimesOut() async {
        let t = Self.paired()
        let send = Task { try await t.session.sendEnsuringConnection(.power, timeout: .seconds(3)) }
        let transport = await t.factory.transport(0)
        await t.clock.waitForSleepers(2) // approval timer + send timeout
        #expect(t.clock.requestedSleeps.sorted() == [.seconds(3), .seconds(30)])
        t.clock.advance(by: .seconds(3))
        await #expect(throws: SessionError.unreachable) { try await send.value }
        #expect(transport.sent.isEmpty)
    }
}

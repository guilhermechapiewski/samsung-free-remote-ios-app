import Testing
@testable import SamsungTVKit

/// `NWPortProber` over real loopback sockets. Nested in `FakeTVTests` so its `.serialized` trait
/// also covers these tests: both bind or probe the fixed port 8001 on 127.0.0.1.
extension FakeTVTests {
    @Suite struct PortProberTests {
        @Test func openPortIsOpen() async throws {
            let tv = FakeTV()
            try await tv.start(identity: .primary)
            let open = await NWPortProber(allowLoopback: true)
                .isOpen(host: "127.0.0.1", port: 8001, timeout: .milliseconds(500))
            await tv.stop()
            #expect(open)
        }

        @Test func closedPortIsClosedQuickly() async throws {
            let tv = FakeTV()
            try await tv.start(identity: .primary)
            await tv.stop()
            let start = ContinuousClock.now
            let open = await NWPortProber(allowLoopback: true)
                .isOpen(host: "127.0.0.1", port: 8001, timeout: .seconds(5))
            #expect(!open)
            #expect(ContinuousClock.now - start < .seconds(1))
        }

        @Test func publicHostRefused() async {
            let start = ContinuousClock.now
            let open = await NWPortProber().isOpen(host: "8.8.8.8", port: 8001, timeout: .seconds(5))
            #expect(!open)
            #expect(ContinuousClock.now - start < .milliseconds(50))
        }

        @Test func loopbackRefusedByDefault() async {
            #expect(await NWPortProber().isOpen(host: "127.0.0.1", port: 8001, timeout: .seconds(5)) == false)
        }

        @Test func cancelledCallerGetsFalseEvenForOpenPort() async throws {
            let tv = FakeTV()
            try await tv.start(identity: .primary)
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return await NWPortProber(allowLoopback: true)
                    .isOpen(host: "127.0.0.1", port: 8001, timeout: .seconds(5))
            }
            let open = await task.value
            await tv.stop()
            #expect(!open)
        }
    }
}

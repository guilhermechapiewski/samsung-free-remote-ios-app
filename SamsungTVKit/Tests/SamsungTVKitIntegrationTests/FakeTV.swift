import CryptoKit
import Foundation
import Network
import Security
import Synchronization

/// A minimal stand-in for a Samsung Tizen TV on loopback, for integration tests only.
///
/// - `http://127.0.0.1:8001/api/v2/` serves `Fixtures/info.json`.
/// - `wss://127.0.0.1:8002/…` is a TLS server (identity from a fixture p12) speaking just enough
///   RFC 6455 to accept the upgrade, record the request target, reply `ms.channel.connect` with
///   token `fake-token` (or `ms.channel.unauthorized` when `denyPairing`), and record every text
///   message it receives.
///
/// The WebSocket layer is hand-rolled over TLS rather than `NWProtocolWebSocket` because the
/// server-side `NWProtocolWebSocket` API does not expose the request path and query, which the
/// tests must check. The ports are the production ones (they are hardcoded in the kit), so only
/// one FakeTV may run at a time.
final class FakeTV: Sendable {
    enum Identity: String {
        case primary = "fake-tv-identity"
        case secondary = "fake-tv-identity-2"
    }

    struct SetupError: Error, CustomStringConvertible {
        let description: String
    }

    static let httpPort: NWEndpoint.Port = 8001
    static let webSocketPort: NWEndpoint.Port = 8002
    static let token = "fake-token"

    private struct State {
        var listeners: [NWListener] = []
        var connections: [NWConnection] = []
        var denyPairing = false
        var requestTargets: [String] = []
        var receivedMessages: [String] = []
    }

    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "FakeTV")

    /// When true, WebSocket clients get `ms.channel.unauthorized` instead of a token.
    var denyPairing: Bool {
        get { state.withLock { $0.denyPairing } }
        set { state.withLock { $0.denyPairing = newValue } }
    }

    /// Request targets (path + query) of every accepted WebSocket upgrade, in order.
    var requestTargets: [String] { state.withLock { $0.requestTargets } }

    /// Every text message received from WebSocket clients, in order.
    var receivedMessages: [String] { state.withLock { $0.receivedMessages } }

    /// Binds both ports. Throws a descriptive error if either is busy.
    func start(identity: Identity) async throws {
        let infoBody = try Self.fixture("info", "json")
        let secIdentity = try Self.loadIdentity(identity)

        let tls = NWProtocolTLS.Options()
        guard let secProtocolIdentity = sec_identity_create(secIdentity) else {
            throw SetupError(description: "sec_identity_create failed for \(identity.rawValue)")
        }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secProtocolIdentity)

        let http = try makeListener(NWParameters.tcp, port: Self.httpPort) { [weak self] connection in
            self?.serveHTTP(connection, body: infoBody)
        }
        let ws = try makeListener(NWParameters(tls: tls), port: Self.webSocketPort) { [weak self] connection in
            self?.serveWebSocket(connection)
        }
        state.withLock { $0.listeners = [http, ws] }
        do {
            try await Self.waitUntilReady(http, port: Self.httpPort)
            try await Self.waitUntilReady(ws, port: Self.webSocketPort)
        } catch {
            await stop()
            throw error
        }
    }

    /// Closes all connections and unbinds both ports (waits until the listeners are cancelled).
    func stop() async {
        let (listeners, connections) = state.withLock { s in
            defer { s.listeners = []; s.connections = [] }
            return (s.listeners, s.connections)
        }
        for connection in connections { connection.cancel() }
        for listener in listeners {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let once = Once()
                let resumeOnce: @Sendable () -> Void = {
                    if once.claim() { continuation.resume() }
                }
                listener.stateUpdateHandler = { state in
                    if case .cancelled = state { resumeOnce() }
                }
                listener.cancel()
                if case .cancelled = listener.state { resumeOnce() }
            }
        }
    }

    // MARK: - Listeners

    private func makeListener(
        _ parameters: NWParameters,
        port: NWEndpoint.Port,
        onConnection: @escaping @Sendable (NWConnection) -> Void
    ) throws -> NWListener {
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw SetupError(description: "FakeTV cannot create a listener on 127.0.0.1:\(port): \(error)")
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.state.withLock { $0.connections.append(connection) }
            onConnection(connection)
        }
        return listener
    }

    private static func waitUntilReady(_ listener: NWListener, port: NWEndpoint.Port) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let once = Once()
            let resume: @Sendable (Result<Void, any Error>) -> Void = { result in
                if once.claim() { continuation.resume(with: result) }
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resume(.success(()))
                case .failed(let error), .waiting(let error):
                    resume(.failure(SetupError(description:
                        "FakeTV cannot bind 127.0.0.1:\(port) (is the port busy? another test run or a "
                        + "local service may be using it): \(error)")))
                case .cancelled:
                    resume(.failure(SetupError(description: "FakeTV listener on port \(port) was cancelled")))
                case .setup:
                    break
                @unknown default:
                    break
                }
            }
            listener.start(queue: DispatchQueue(label: "FakeTV.listener.\(port)"))
        }
    }

    // MARK: - HTTP (port 8001)

    private func serveHTTP(_ connection: NWConnection, body: Data) {
        connection.start(queue: queue)
        Self.readHead(connection, buffer: []) { head, _ in
            guard let head else { connection.cancel(); return }
            let found = head.requestTarget == "/api/v2/" && head.method == "GET"
            let payload = found ? body : Data()
            let status = found ? "200 OK" : "404 Not Found"
            var response = Data((
                "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\n"
                + "Content-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
            ).utf8)
            response.append(payload)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    // MARK: - WebSocket over TLS (port 8002)

    private func serveWebSocket(_ connection: NWConnection) {
        connection.start(queue: queue)
        Self.readHead(connection, buffer: []) { [weak self] head, rest in
            guard let self, let head, let key = head.headers["sec-websocket-key"] else {
                connection.cancel()
                return
            }
            let deny = state.withLock { s in
                s.requestTargets.append(head.requestTarget)
                return s.denyPairing
            }
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)))
                .base64EncodedString()
            var reply = Data((
                "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                + "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
            ).utf8)
            let event = deny
                ? #"{"event":"ms.channel.unauthorized"}"#
                : #"{"data":{"clients":[],"id":"fake-client","token":"\#(Self.token)"},"event":"ms.channel.connect"}"#
            reply.append(Self.frame(opcode: 0x1, payload: Data(event.utf8)))
            connection.send(content: reply, completion: .contentProcessed { _ in })
            readFrames(connection, buffer: rest)
        }
    }

    private func readFrames(_ connection: NWConnection, buffer: [UInt8]) {
        var buffer = buffer
        while let (opcode, payload, consumed) = Self.parseFrame(buffer) {
            buffer.removeFirst(consumed)
            switch opcode {
            case 0x1:
                let text = String(decoding: payload, as: UTF8.self)
                state.withLock { $0.receivedMessages.append(text) }
            case 0x8:
                connection.send(content: Self.frame(opcode: 0x8, payload: Data()),
                                completion: .contentProcessed { _ in connection.cancel() })
                return
            case 0x9:
                connection.send(content: Self.frame(opcode: 0xA, payload: Data(payload)),
                                completion: .contentProcessed { _ in })
            default:
                break
            }
        }
        let pending = buffer
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, error == nil, !isComplete || data != nil else {
                connection.cancel()
                return
            }
            readFrames(connection, buffer: pending + (data.map(Array.init) ?? []))
        }
    }

    /// Unmasked server frame (FIN set).
    private static func frame(opcode: UInt8, payload: Data) -> Data {
        var out = Data([0x80 | opcode])
        if payload.count < 126 {
            out.append(UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            out.append(126)
            out.append(contentsOf: [UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
        } else {
            out.append(127)
            out.append(contentsOf: (0..<8).reversed().map { UInt8((payload.count >> ($0 * 8)) & 0xFF) })
        }
        out.append(payload)
        return out
    }

    /// Parses one complete client frame from the start of `buffer` (fragmentation is not used by
    /// the kit's small control messages and is not supported).
    private static func parseFrame(_ buffer: [UInt8]) -> (opcode: UInt8, payload: [UInt8], consumed: Int)? {
        guard buffer.count >= 2 else { return nil }
        let opcode = buffer[0] & 0x0F
        let masked = buffer[1] & 0x80 != 0
        var length = Int(buffer[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard buffer.count >= 4 else { return nil }
            length = Int(buffer[2]) << 8 | Int(buffer[3])
            offset = 4
        } else if length == 127 {
            guard buffer.count >= 10 else { return nil }
            length = buffer[2..<10].reduce(0) { $0 << 8 | Int($1) }
            offset = 10
        }
        let maskKey: [UInt8]
        if masked {
            guard buffer.count >= offset + 4 else { return nil }
            maskKey = Array(buffer[offset..<offset + 4])
            offset += 4
        } else {
            maskKey = [0, 0, 0, 0]
        }
        guard buffer.count >= offset + length else { return nil }
        let payload = buffer[offset..<offset + length].enumerated().map { $0.element ^ maskKey[$0.offset % 4] }
        return (opcode, payload, offset + length)
    }

    // MARK: - HTTP request head

    private struct RequestHead {
        let method: String
        let requestTarget: String
        /// Lowercased names.
        let headers: [String: String]
    }

    /// Reads until the end of the request head; calls back with the parsed head (nil on error)
    /// and any bytes received after it.
    private static func readHead(
        _ connection: NWConnection,
        buffer: [UInt8],
        completion: @escaping @Sendable (RequestHead?, [UInt8]) -> Void
    ) {
        let terminator: [UInt8] = Array("\r\n\r\n".utf8)
        if let range = buffer.firstRange(of: terminator) {
            let text = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
            completion(parseHead(text), Array(buffer[range.upperBound...]))
            return
        }
        guard buffer.count < 16 * 1024 else { completion(nil, []); return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
            guard error == nil, let data, !data.isEmpty else { completion(nil, []); return }
            readHead(connection, buffer: buffer + Array(data), completion: completion)
        }
    }

    private static func parseHead(_ text: String) -> RequestHead? {
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        return RequestHead(method: String(requestLine[0]), requestTarget: String(requestLine[1]), headers: headers)
    }

    // MARK: - Fixtures

    private static func fixture(_ name: String, _ ext: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") else {
            throw SetupError(description: "Missing fixture \(name).\(ext)")
        }
        return try Data(contentsOf: url)
    }

    private static func loadIdentity(_ identity: Identity) throws -> SecIdentity {
        let p12 = try fixture(identity.rawValue, "p12")
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: "test",
            kSecImportToMemoryOnly as String: true,
        ]
        var items: CFArray?
        let status = SecPKCS12Import(p12 as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let value = first[kSecImportItemIdentity as String]
        else {
            throw SetupError(description: "SecPKCS12Import of \(identity.rawValue).p12 failed (OSStatus \(status))")
        }
        // CF type bridged from the import result dictionary; the key guarantees a SecIdentity.
        return value as! SecIdentity
    }
}

/// Lets exactly one of several racing callbacks resume a continuation.
private final class Once: Sendable {
    private let claimed = Mutex(false)

    /// True for the first caller only.
    func claim() -> Bool {
        claimed.withLock { c in
            defer { c = true }
            return !c
        }
    }
}

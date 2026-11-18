import Foundation
import Synchronization
import Testing
@testable import SamsungTVKit

private enum StubResult: Sendable {
    case response(status: Int, body: Data)
    case failure(URLError.Code)
    case redirect(to: URL)
}

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    // Safety: all shared state lives in Mutex-protected statics; instances only touch their own URLProtocol state.
    private static let state = Mutex<(result: StubResult, requests: [URL], timeouts: [TimeInterval])>((.failure(.unknown), [], []))

    static func configure(_ result: StubResult) {
        state.withLock { $0 = (result, [], []) }
    }
    static var timeouts: [TimeInterval] { state.withLock { $0.timeouts } }
    static var requests: [URL] { state.withLock { $0.requests } }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let result = Self.state.withLock { s -> StubResult in
            s.requests.append(url)
            s.timeouts.append(request.timeoutInterval)
            return s.result
        }
        switch result {
        case .response(let status, let body):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let target):
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }
}

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func makeFetcher(maxBytes: Int = 64 * 1024, timeout: Duration = .seconds(2)) -> HTTPTVInfoFetcher {
    HTTPTVInfoFetcher(session: StubProtocol.makeSession(), timeout: timeout, maxBytes: maxBytes, allowLoopback: false)
}

@Suite(.serialized)
struct HTTPTVInfoFetcherTests {
    @Test func fetchRejectsPublicHost() async throws {
        StubProtocol.configure(.response(status: 200, body: try fixture("info-on")))
        await #expect(throws: TVInfoError.notLocalAddress) {
            try await makeFetcher().fetchInfo(host: "8.8.8.8")
        }
        #expect(StubProtocol.requests.isEmpty)
    }

    @Test func rejectsLoopbackByDefault() async {
        StubProtocol.configure(.response(status: 200, body: Data()))
        await #expect(throws: TVInfoError.notLocalAddress) {
            try await makeFetcher().fetchInfo(host: "127.0.0.1")
        }
        #expect(StubProtocol.requests.isEmpty)
    }

    @Test func rejectsOversizedBody() async {
        StubProtocol.configure(.response(status: 200, body: Data(repeating: 0x20, count: 70 * 1024)))
        await #expect(throws: TVInfoError.tooLarge) {
            try await makeFetcher().fetchInfo(host: "10.0.0.5")
        }
    }

    @Test func timeoutMapsToUnreachable() async {
        StubProtocol.configure(.failure(.timedOut))
        await #expect(throws: TVInfoError.unreachable) {
            try await makeFetcher(timeout: .milliseconds(100)).fetchInfo(host: "10.0.0.5")
        }
    }

    @Test func nonOKStatusMapsToUnreachable() async {
        StubProtocol.configure(.response(status: 500, body: Data()))
        await #expect(throws: TVInfoError.unreachable) {
            try await makeFetcher().fetchInfo(host: "10.0.0.5")
        }
    }

    @Test func success() async throws {
        StubProtocol.configure(.response(status: 200, body: try fixture("info-on")))
        let info = try await makeFetcher().fetchInfo(host: "10.0.0.5")
        #expect(info.host == "10.0.0.5")
        #expect(info.powerState == .on)
        #expect(StubProtocol.requests.map(\.absoluteString) == ["http://10.0.0.5:8001/api/v2/"])
    }

    @Test func redirectIsNotFollowed() async {
        StubProtocol.configure(.redirect(to: URL(string: "http://8.8.8.8/")!))
        await #expect(throws: TVInfoError.unreachable) {
            try await makeFetcher().fetchInfo(host: "10.0.0.5")
        }
        #expect(StubProtocol.requests.map(\.absoluteString) == ["http://10.0.0.5:8001/api/v2/"])
    }

    @Test func timeoutIsAppliedToRequest() async throws {
        StubProtocol.configure(.response(status: 200, body: try fixture("info-on")))
        _ = try await makeFetcher(timeout: .milliseconds(100)).fetchInfo(host: "10.0.0.5")
        #expect(abs(StubProtocol.timeouts[0] - 0.1) < 0.001)
        StubProtocol.configure(.response(status: 200, body: try fixture("info-on")))
        let defaults = HTTPTVInfoFetcher(session: StubProtocol.makeSession())
        _ = try await defaults.fetchInfo(host: "10.0.0.5")
        #expect(StubProtocol.timeouts[0] == 2.0)
    }
}

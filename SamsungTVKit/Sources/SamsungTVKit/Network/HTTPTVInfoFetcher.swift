import Foundation

public protocol TVInfoFetching: Sendable {
    func fetchInfo(host: String) async throws(TVInfoError) -> TVDeviceInfo
}

public struct HTTPTVInfoFetcher: TVInfoFetching {
    private let session: URLSession
    private let timeout: Duration
    private let maxBytes: Int
    private let allowLoopback: Bool

    public init(session: URLSession = .shared, timeout: Duration = .seconds(2), maxBytes: Int = 64 * 1024) {
        self.init(session: session, timeout: timeout, maxBytes: maxBytes, allowLoopback: false)
    }

    init(session: URLSession, timeout: Duration, maxBytes: Int, allowLoopback: Bool) {
        self.session = session
        self.timeout = timeout
        self.maxBytes = maxBytes
        self.allowLoopback = allowLoopback
    }

    public func fetchInfo(host: String) async throws(TVInfoError) -> TVDeviceInfo {
        guard LocalAddress.isAllowed(host, allowLoopback: allowLoopback),
              let url = URL(string: "http://\(host):8001/api/v2/") else { throw .notLocalAddress }
        var request = URLRequest(url: url)
        let (seconds, attoseconds) = timeout.components
        request.timeoutInterval = Double(seconds) + Double(attoseconds) / 1e18

        var body = Data()
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: NoRedirectDelegate())
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw TVInfoError.unreachable }
            for try await byte in bytes {
                body.append(byte)
                if body.count > maxBytes { throw TVInfoError.tooLarge }
            }
        } catch let error as TVInfoError {
            throw error
        } catch {
            throw .unreachable
        }
        return try TVDeviceInfo.decode(body, host: host)
    }
}

/// Redirects could lead off the LAN; refuse them so a 3xx surfaces as a non-200 response.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? { nil }
}

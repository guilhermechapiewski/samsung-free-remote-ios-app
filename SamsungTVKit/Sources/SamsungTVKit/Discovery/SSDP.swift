import Foundation

/// A source of candidate TV hosts (IPv4 literals). The stream finishes when the source stops.
public protocol CandidateSource: Sendable {
    func candidates() -> AsyncStream<String>
}

/// SSDP request building and response parsing.
public enum SSDP {
    static let targets = ["urn:samsung.com:device:RemoteControlReceiver:1", "urn:dial-multiscreen-org:service:dial:1"]
    static let maxResponseSize = 8 * 1024

    static func searchRequest(target: String) -> Data {
        Data("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: \(target)\r\n\r\n".utf8)
    }

    /// The LOCATION host of a Samsung `200 OK` search response, if it is a private/link-local IPv4.
    static func host(fromResponse data: Data) -> String? {
        guard data.count <= maxResponseSize, let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let status = lines.first, status.hasPrefix("HTTP/1.1 200 OK") else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if headers[name] == nil { headers[name] = value }
        }
        guard let server = headers["server"], server.contains("Samsung"),
              let location = headers["location"],
              let host = URL(string: location)?.host,
              LocalAddress.isAllowed(host) else { return nil }
        return host
    }
}

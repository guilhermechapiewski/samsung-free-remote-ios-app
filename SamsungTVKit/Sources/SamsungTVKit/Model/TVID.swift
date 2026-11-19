import Foundation

/// Stable identifier of a TV (the `id` field of the `/api/v2/` response, e.g. `uuid:…`).
public struct TVID: Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Lets `[TVID: …]` dictionaries encode as JSON objects keyed by the raw id (instead of a flat array).
extension TVID: CodingKeyRepresentable {
    public var codingKey: any CodingKey { RawKey(stringValue: rawValue) }

    public init?<T: CodingKey>(codingKey: T) {
        self.init(rawValue: codingKey.stringValue)
    }

    private struct RawKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

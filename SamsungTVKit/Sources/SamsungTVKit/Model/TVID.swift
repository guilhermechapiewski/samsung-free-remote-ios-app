import Foundation

/// Stable identifier of a TV (the `id` field of the `/api/v2/` response, e.g. `uuid:…`).
public struct TVID: Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

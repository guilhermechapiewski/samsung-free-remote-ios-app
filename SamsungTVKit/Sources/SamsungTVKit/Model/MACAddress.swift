import Foundation

/// A 48-bit MAC address.
public struct MACAddress: Hashable, Codable, Sendable, CustomStringConvertible {
    /// Always 6 bytes.
    public let bytes: [UInt8]

    /// Parses `aa:bb:cc:dd:ee:ff` (colon or hyphen separated, any case).
    public init?(_ string: String) {
        let parts = string.split(omittingEmptySubsequences: false, whereSeparator: { $0 == ":" || $0 == "-" })
        guard parts.count == 6 else { return nil }
        var result: [UInt8] = []
        for part in parts {
            guard part.count == 2, part.allSatisfy(\.isHexDigit), let byte = UInt8(part, radix: 16) else { return nil }
            result.append(byte)
        }
        bytes = result
    }

    public var description: String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    public init(from decoder: any Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let mac = MACAddress(string) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid MAC address"))
        }
        self = mac
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

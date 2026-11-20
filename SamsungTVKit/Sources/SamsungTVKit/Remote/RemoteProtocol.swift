import Foundation

public enum ChannelEvent: Equatable, Sendable {
    case connected(token: String?)
    case unauthorized
    case timedOut
    case keyboardShown
    case keyboardHidden
    case other(String)
}

/// Pure encoding/decoding of the Samsung remote WebSocket protocol.
public enum RemoteProtocol {
    public static let pairingName = "TV Remote"

    static let maxEventBytes = 256 * 1024

    /// Returns nil unless `host` is an allowed local IPv4 address (loopback permitted at this layer;
    /// production callers are guarded upstream).
    public static func channelURL(host: String, token: String?) -> URL? {
        guard LocalAddress.isAllowed(host, allowLoopback: true) else { return nil }
        var components = URLComponents()
        components.scheme = "wss"
        components.host = host
        components.port = 8002
        components.path = "/api/v2/channels/samsung.remote.control"
        // Base64 alphabet characters (+ / =) are legal in a query; set percentEncodedQuery
        // so URLComponents leaves them verbatim for the fixed name.
        var query = "name=" + Data(pairingName.utf8).base64EncodedString()
        if let token, !token.isEmpty {
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "&=+/#?")
            if let encoded = token.addingPercentEncoding(withAllowedCharacters: allowed) {
                query += "&token=" + encoded
            }
        }
        components.percentEncodedQuery = query
        return components.url
    }

    public static func key(_ key: RemoteKey, _ action: KeyAction) -> Data {
        control([
            "Cmd": action.rawValue,
            "DataOfCmd": key.rawValue,
            "Option": "false",
            "TypeOfRemote": "SendRemoteKey",
        ])
    }

    public static func text(_ string: String) -> Data {
        control([
            "Cmd": Data(string.utf8).base64EncodedString(),
            "DataOfCmd": "base64",
            "Option": "false",
            "TypeOfRemote": "SendInputString",
        ])
    }

    public static func textEnd() -> Data {
        control(["TypeOfRemote": "SendInputEnd"])
    }

    public static func decodeEvent(_ data: Data) -> ChannelEvent {
        guard data.count <= maxEventBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = root["event"] as? String
        else { return .other("") }
        switch name {
        case "ms.channel.connect":
            let payload = root["data"] as? [String: Any]
            switch payload?["token"] {
            case let s as String: return .connected(token: s)
            case let n as NSNumber: return .connected(token: n.stringValue)
            default: return .connected(token: nil)
            }
        case "ms.channel.unauthorized": return .unauthorized
        case "ms.channel.timeOut", "ms.channel.timeout": return .timedOut
        case "ms.remote.imeStart": return .keyboardShown
        case "ms.remote.imeEnd": return .keyboardHidden
        default: return .other(name)
        }
    }

    private static func control(_ params: [String: String]) -> Data {
        let object: [String: Any] = ["method": "ms.remote.control", "params": params]
        // Dictionary of plain strings always serializes.
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}

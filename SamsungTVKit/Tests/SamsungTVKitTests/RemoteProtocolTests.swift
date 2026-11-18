import Testing
import Foundation
@testable import SamsungTVKit

@Suite struct RemoteProtocolTests {
    private func dict(_ data: Data) throws -> NSDictionary {
        try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    @Test func channelURLWithoutToken() throws {
        let url = try #require(RemoteProtocol.channelURL(host: "10.0.0.5", token: nil))
        #expect(url.absoluteString == "wss://10.0.0.5:8002/api/v2/channels/samsung.remote.control?name=RnJlZSBSZW1vdGU=")
    }

    @Test func channelURLWithToken() throws {
        let url = try #require(RemoteProtocol.channelURL(host: "10.0.0.5", token: "abc"))
        #expect(url.absoluteString == "wss://10.0.0.5:8002/api/v2/channels/samsung.remote.control?name=RnJlZSBSZW1vdGU=&token=abc")
    }

    @Test func channelURLPercentEncodesToken() throws {
        let url = try #require(RemoteProtocol.channelURL(host: "10.0.0.5", token: "a b&c=d+/"))
        #expect(url.absoluteString.hasSuffix("&token=a%20b%26c%3Dd%2B%2F"))
    }

    @Test func channelURLIgnoresEmptyToken() throws {
        let url = try #require(RemoteProtocol.channelURL(host: "10.0.0.5", token: ""))
        #expect(!url.absoluteString.contains("token"))
    }

    @Test func channelURLRejectsInvalidHosts() {
        for host in ["", "a b", "x/y", "10.0.0.5:80", "::1", "tv.local", "8.8.8.8"] {
            #expect(RemoteProtocol.channelURL(host: host, token: nil) == nil, "\(host)")
        }
        #expect(RemoteProtocol.channelURL(host: "127.0.0.1", token: nil) != nil)
    }

    @Test func pairingName() {
        #expect(RemoteProtocol.pairingName == "Free Remote")
    }

    @Test func keyMessage() throws {
        let expected: NSDictionary = ["method": "ms.remote.control", "params": [
            "Cmd": "Click", "DataOfCmd": "KEY_VOLUP", "Option": "false", "TypeOfRemote": "SendRemoteKey"]]
        #expect(try dict(RemoteProtocol.key(.volumeUp, .click)) == expected)
        let press = try dict(RemoteProtocol.key(.back, .press))
        let params = try #require(press["params"] as? NSDictionary)
        #expect(params["Cmd"] as? String == "Press")
        #expect(params["DataOfCmd"] as? String == "KEY_RETURN")
    }

    @Test func textMessage() throws {
        let expected: NSDictionary = ["method": "ms.remote.control", "params": [
            "Cmd": Data("hé".utf8).base64EncodedString(), "DataOfCmd": "base64",
            "Option": "false", "TypeOfRemote": "SendInputString"]]
        #expect(try dict(RemoteProtocol.text("hé")) == expected)
    }

    @Test func textEndMessage() throws {
        let expected: NSDictionary = ["method": "ms.remote.control", "params": ["TypeOfRemote": "SendInputEnd"]]
        #expect(try dict(RemoteProtocol.textEnd()) == expected)
    }

    @Test func remoteKeyValues() {
        #expect(RemoteKey.allCases.count == 30)
        #expect(RemoteKey.back.rawValue == "KEY_RETURN")
        #expect(RemoteKey.hdmi3.rawValue == "KEY_HDMI3")
        #expect(RemoteKey.digit7.rawValue == "KEY_7")
        #expect(RemoteKey.volumeDown.rawValue == "KEY_VOLDOWN")
        #expect(KeyAction.release.rawValue == "Release")
    }

    private func decode(_ s: String) -> ChannelEvent { RemoteProtocol.decodeEvent(Data(s.utf8)) }

    @Test func decodeEvents() {
        #expect(decode(#"{"event":"ms.channel.connect","data":{"token":"123"}}"#) == .connected(token: "123"))
        #expect(decode(#"{"event":"ms.channel.connect","data":{"token":123}}"#) == .connected(token: "123"))
        #expect(decode(#"{"event":"ms.channel.connect"}"#) == .connected(token: nil))
        #expect(decode(#"{"event":"ms.channel.connect","data":{}}"#) == .connected(token: nil))
        #expect(decode(#"{"event":"ms.channel.unauthorized"}"#) == .unauthorized)
        #expect(decode(#"{"event":"ms.channel.timeOut"}"#) == .timedOut)
        #expect(decode(#"{"event":"ms.channel.timeout"}"#) == .timedOut)
        #expect(decode(#"{"event":"ms.remote.imeStart"}"#) == .keyboardShown)
        #expect(decode(#"{"event":"ms.remote.imeEnd"}"#) == .keyboardHidden)
        #expect(decode(#"{"event":"ms.foo"}"#) == .other("ms.foo"))
    }

    @Test func decodeGarbage() {
        #expect(decode("garbage") == .other(""))
        #expect(decode("[1,2]") == .other(""))
        #expect(decode("{}") == .other(""))
        #expect(decode(#"{"event":5}"#) == .other(""))
        #expect(RemoteProtocol.decodeEvent(Data()) == .other(""))
    }

    @Test func decodeOversizedInput() {
        let big = #"{"event":"ms.channel.unauthorized","pad":""# + String(repeating: "a", count: 300_000) + #""}"#
        #expect(decode(big) == .other(""))
    }
}

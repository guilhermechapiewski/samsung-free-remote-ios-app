import Foundation
import Testing
@testable import SamsungTVKit

private func response(server: String, location: String = "http://10.0.0.5:7678/nservice/", status: String = "HTTP/1.1 200 OK") -> Data {
    Data("\(status)\r\nCACHE-CONTROL: max-age=1800\r\nDATE: Thu, 01 Jan 1970 00:00:00 GMT\r\nEXT:\r\nLOCATION: \(location)\r\nSERVER: \(server)\r\nST: urn:dial-multiscreen-org:service:dial:1\r\nUSN: uuid:00000000-0000-4000-8000-000000000001::urn:dial-multiscreen-org:service:dial:1\r\n\r\n".utf8)
}

private let samsungServer = "Samsung-Linux/4.1, UPnP/1.0, Samsung_UPnP_SDK/1.0"

@Test func searchRequestExactBytes() {
    let expected = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: urn:dial-multiscreen-org:service:dial:1\r\n\r\n"
    #expect(SSDP.searchRequest(target: "urn:dial-multiscreen-org:service:dial:1") == Data(expected.utf8))
}

@Test func targetsAreSamsungAndDial() {
    #expect(SSDP.targets == ["urn:samsung.com:device:RemoteControlReceiver:1", "urn:dial-multiscreen-org:service:dial:1"])
}

@Test func extractsHostFromSamsungResponse() {
    #expect(SSDP.host(fromResponse: response(server: samsungServer)) == "10.0.0.5")
}

@Test(arguments: ["Linux UPnP/1.0 Sonos/98.0-82170 (ZPS16)", "Hue/1.0 UPnP/1.0 IpBridge/1.78.0"])
func rejectsNonSamsung(server: String) {
    #expect(SSDP.host(fromResponse: response(server: server)) == nil)
}

@Test func ignoresPublicLocation() {
    #expect(SSDP.host(fromResponse: response(server: samsungServer, location: "http://8.8.8.8:7678/nservice/")) == nil)
}

@Test func headersAreCaseInsensitive() {
    let text = "HTTP/1.1 200 OK\r\nlocation: http://192.168.1.20:7678/x\r\nServer: samsung-linux\r\n\r\n"
    // SERVER value match is on "Samsung", compared case-insensitively on the header name only.
    #expect(SSDP.host(fromResponse: Data(text.utf8)) == nil)
    let ok = "HTTP/1.1 200 OK\r\nlocation: http://192.168.1.20:7678/x\r\nsErVeR: Samsung-Linux/4.1\r\n\r\n"
    #expect(SSDP.host(fromResponse: Data(ok.utf8)) == "192.168.1.20")
}

@Test func rejectsNon200Status() {
    #expect(SSDP.host(fromResponse: response(server: samsungServer, status: "NOTIFY * HTTP/1.1")) == nil)
}

@Test func rejectsOversizedJunk() {
    #expect(SSDP.host(fromResponse: Data(repeating: 0x41, count: 100 * 1024)) == nil)
    var big = response(server: samsungServer)
    big.append(Data(repeating: 0x20, count: 9 * 1024))
    #expect(SSDP.host(fromResponse: big) == nil)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["TVKIT_LIVE"] == "1"))
func liveSearch() async {
    var count = 0
    for await _ in SSDPSearcher(duration: .seconds(4)).candidates() { count += 1 }
    print("SSDP live: found \(count) host(s)")
}

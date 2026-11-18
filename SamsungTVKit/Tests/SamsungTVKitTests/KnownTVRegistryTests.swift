import Foundation
import Testing
@testable import SamsungTVKit

private func info(id: String = "uuid:tv-x", host: String, name: String = "Living Room", model: String = "QE55Q80",
                  mac: String? = "AA:BB:CC:DD:EE:01") -> TVDeviceInfo {
    TVDeviceInfo(id: TVID(rawValue: id), host: host, name: name, modelName: model, modelCode: "22_PONTUSM_QTV",
                 wifiMAC: mac.flatMap(MACAddress.init), networkType: "wireless", powerState: .on, tokenAuthSupported: true)
}

@Test func ipChangeKeepsIdentity() {
    var registry = KnownTVRegistry()
    let t0 = Date(timeIntervalSince1970: 1_000), t1 = Date(timeIntervalSince1970: 2_000)
    registry.record(info(host: "10.0.0.5"), at: t0)
    registry.record(info(host: "10.0.0.9", name: "Bedroom", model: "QE65S95", mac: "AA:BB:CC:DD:EE:02"), at: t1)

    #expect(registry.tvs.count == 1)
    let tv = registry.tvs[TVID(rawValue: "uuid:tv-x")]
    #expect(tv == KnownTV(id: TVID(rawValue: "uuid:tv-x"), lastHost: "10.0.0.9", wifiMAC: MACAddress("AA:BB:CC:DD:EE:02"),
                          modelName: "QE65S95", reportedName: "Bedroom", lastSeen: t1))
}

@Test func nilMACDoesNotOverwriteKnownMAC() {
    var registry = KnownTVRegistry()
    registry.record(info(host: "10.0.0.5"), at: Date(timeIntervalSince1970: 1))
    registry.record(info(host: "10.0.0.5", mac: nil), at: Date(timeIntervalSince1970: 2))
    #expect(registry.tvs[TVID(rawValue: "uuid:tv-x")]?.wifiMAC == MACAddress("AA:BB:CC:DD:EE:01"))
    #expect(registry.tvs[TVID(rawValue: "uuid:tv-x")]?.lastSeen == Date(timeIntervalSince1970: 2))
}

@Test func forgetRemoves() {
    var registry = KnownTVRegistry()
    registry.record(info(id: "uuid:a", host: "10.0.0.5"), at: Date(timeIntervalSince1970: 1))
    registry.record(info(id: "uuid:b", host: "10.0.0.6"), at: Date(timeIntervalSince1970: 1))
    registry.forget(TVID(rawValue: "uuid:a"))
    #expect(Set(registry.tvs.keys) == [TVID(rawValue: "uuid:b")])
}

@Test func codableRoundTrip() throws {
    var registry = KnownTVRegistry()
    registry.record(info(id: "uuid:a", host: "10.0.0.5"), at: Date(timeIntervalSince1970: 1_234))
    registry.record(info(id: "uuid:b", host: "192.168.1.20", mac: nil), at: Date(timeIntervalSince1970: 5_678))
    let data = try JSONEncoder().encode(registry)
    #expect(try JSONDecoder().decode(KnownTVRegistry.self, from: data) == registry)

    let tv = try #require(registry.tvs[TVID(rawValue: "uuid:a")])
    #expect(try JSONDecoder().decode(KnownTV.self, from: JSONEncoder().encode(tv)) == tv)
}

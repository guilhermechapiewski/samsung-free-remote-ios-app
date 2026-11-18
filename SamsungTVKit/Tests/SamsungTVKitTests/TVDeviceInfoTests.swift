import Foundation
import Testing
@testable import SamsungTVKit

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Test func decodesOnTV() throws {
    let info = try TVDeviceInfo.decode(fixture("info-on"), host: "10.0.0.5")
    #expect(info.id == TVID(rawValue: "uuid:00000000-0000-4000-8000-000000000001"))
    #expect(info.host == "10.0.0.5")
    #expect(info.name == "65\" Test TV")
    #expect(info.modelName == "QN00XX00XAFXZA")
    #expect(info.modelCode == "24_TEST_QTV")
    #expect(info.networkType == "wireless")
    #expect(info.powerState == .on)
    #expect(info.wifiMAC?.description == "02:00:00:00:00:01")
    #expect(info.tokenAuthSupported)
}

@Test func emptyPowerStateIsStandby() throws {
    #expect(try TVDeviceInfo.decode(fixture("info-asleep"), host: "10.0.0.5").powerState == .standby)
}

@Test func absentPowerStateIsUnknown() throws {
    var json = try #require(String(data: fixture("info-on"), encoding: .utf8))
    json = json.replacingOccurrences(of: "\"PowerState\":\"on\",", with: "")
    #expect(try TVDeviceInfo.decode(Data(json.utf8), host: "10.0.0.5").powerState == .unknown(""))
}

@Test func rejectsNonTizen() {
    #expect(throws: TVInfoError.notSamsungTizen) { try TVDeviceInfo.decode(fixture("info-non-tizen"), host: "10.0.0.5") }
}

@Test func rejectsGarbage() {
    #expect(throws: TVInfoError.malformed) { try TVDeviceInfo.decode(Data("<html>".utf8), host: "10.0.0.5") }
}

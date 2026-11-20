import Foundation
import SamsungTVKit
import Testing
@testable import FreeRemote

@MainActor
@Suite struct TVDetailsContentTests {
    private let us = Locale(identifier: "en_US")
    private let id = TVID(rawValue: "uuid:test")

    private var known: KnownTV {
        KnownTV(id: id, lastHost: "10.0.0.7", wifiMAC: MACAddress("02:00:00:00:00:01"), modelName: "QN00XX00XAFXZA",
                reportedName: "Test TV", lastSeen: Date(timeIntervalSince1970: 1_800_000_000))
    }

    private var fullInfo: TVDeviceInfo {
        TVDeviceInfo(
            id: id, host: "10.0.0.8", name: "Test TV", modelName: "QN00XX00XAFXZA", modelCode: "24_TEST_QTV",
            wifiMAC: MACAddress("02:00:00:00:00:01"), networkType: "wireless", powerState: .on,
            tokenAuthSupported: true,
            details: TVDeviceDetails(
                modelYear: 2024, resolution: "3840x2160", language: "en_US", countryCode: "US",
                accessPoint: MACAddress("02:00:00:00:00:99"), frameTV: false, voice: true, gamePad: true,
                keyboardSync: true, developerMode: false, firmwareVersion: nil, apiVersion: "2.0.25"
            )
        )
    }

    private func snapshot(info: TVDeviceInfo?, live: Bool, paired: Bool = true) -> TVDetailsSnapshot {
        TVDetailsSnapshot(id: id, title: "Den", status: live ? .on : .unreachable, known: known, info: info,
                          isLive: live, paired: paired)
    }

    private func value(_ content: TVDetailsContent, _ label: String) -> String? {
        content.sections.flatMap(\.rows).first { $0.label == label }?.value
    }

    @Test func liveTVShowsEverything() {
        let content = TVDetailsContent(snapshot(info: fullInfo, live: true), locale: us)
        #expect(content.sections.map(\.title) == ["TV", "Network", "Status", "Features", "Region", "Software"])
        #expect(value(content, "IP Address") == "10.0.0.8") // the live answer, not the record
        #expect(value(content, "Connection") == "Wi-Fi")
        #expect(value(content, "Wi-Fi Access Point") == "02:00:00:00:00:99")
        #expect(value(content, "Model Year") == "2024")
        #expect(value(content, "Resolution") == "3840 × 2160 (4K)")
        #expect(value(content, "Last Seen") == "Just now")
        #expect(value(content, "Paired with This iPhone") == "Yes")
        #expect(value(content, "Voice Control") == "Yes")
        #expect(value(content, "Developer Mode") == "Off")
        #expect(value(content, "Language") == "English (United States)")
        #expect(value(content, "Country") == "United States")
        #expect(value(content, "Firmware") == nil)
        #expect(value(content, "Remote API Version") == "2.0.25")
        #expect(content.footnote == nil)
    }

    @Test func unansweredTVShowsTheRecord() {
        let content = TVDetailsContent(snapshot(info: nil, live: false, paired: false), locale: us)
        #expect(content.sections.map(\.title) == ["TV", "Network", "Status"])
        #expect(value(content, "IP Address") == "10.0.0.7")
        #expect(value(content, "Wi-Fi MAC Address") == "02:00:00:00:00:01")
        #expect(value(content, "Connection") == nil)
        #expect(value(content, "Power") == "Unreachable")
        #expect(value(content, "Paired with This iPhone") == "No")
        #expect(value(content, "Last Seen")?.contains("2027") == true)
        #expect(content.footnote == TVDetailsContent.notLiveFootnote)
    }

    @Test func wiredTVHasNoAccessPoint() {
        var info = fullInfo
        info.networkType = "wired"
        let content = TVDetailsContent(snapshot(info: info, live: true), locale: us)
        #expect(value(content, "Connection") == "Ethernet")
        #expect(value(content, "Wi-Fi Access Point") == nil)
    }

    @Test func formatting() {
        #expect(TVDetailsContent.resolution("1920x1080") == "1920 × 1080 (Full HD)")
        #expect(TVDetailsContent.resolution("7680x4320") == "7680 × 4320 (8K)")
        #expect(TVDetailsContent.resolution("1024x768") == "1024 × 768")
        #expect(TVDetailsContent.resolution("weird") == "weird")
        #expect(TVDetailsContent.connection("") == nil)
        #expect(TVDetailsContent.connection("p2p") == "p2p")
    }

    @Test func plainTextListsEveryRow() {
        let content = TVDetailsContent(snapshot(info: nil, live: false), locale: us)
        #expect(content.plainText.hasPrefix("TV\nName on TV: Test TV\nModel: QN00XX00XAFXZA"))
        #expect(content.plainText.contains("\n\nNetwork\nIP Address: 10.0.0.7"))
    }
}

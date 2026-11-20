import Foundation
import SamsungTVKit

/// The rows of the TV Details screen, built from a snapshot. Rows the TV did not report are left out.
struct TVDetailsContent: Equatable {
    struct Row: Equatable, Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    struct Section: Equatable, Identifiable {
        let title: String
        let rows: [Row]
        var id: String { title }
    }

    let sections: [Section]
    /// Explains where the values come from when the TV did not answer just now.
    let footnote: String?

    static let notLiveFootnote = "The TV didn't answer just now, so these are the last known details. "
        + "Turn the TV on to see everything."

    init(_ snapshot: TVDetailsSnapshot, locale: Locale = .current) {
        let info = snapshot.info
        let details = info?.details
        var sections: [Section] = []

        sections.append(Section(title: "TV", rows: Self.compact([
            ("Name on TV", info?.name ?? snapshot.known.reportedName),
            ("Model", info?.modelName ?? snapshot.known.modelName),
            ("Model Code", info?.modelCode),
            ("Model Year", details?.modelYear.map(String.init)),
            ("Resolution", details?.resolution.map(Self.resolution)),
        ])))

        let wireless = info?.networkType == "wireless"
        sections.append(Section(title: "Network", rows: Self.compact([
            ("IP Address", info?.host ?? snapshot.known.lastHost),
            ("Connection", info.flatMap { Self.connection($0.networkType) }),
            ("Wi-Fi MAC Address", (info?.wifiMAC ?? snapshot.known.wifiMAC)?.description),
            ("Wi-Fi Access Point", wireless ? details?.accessPoint?.description : nil),
        ])))

        sections.append(Section(title: "Status", rows: Self.compact([
            ("Power", snapshot.status.displayName),
            ("Last Seen", snapshot.isLive ? "Just now" : Self.date(snapshot.known.lastSeen, locale: locale)),
            ("Paired with This iPhone", snapshot.paired ? "Yes" : "No"),
        ])))

        if let details {
            sections.append(Section(title: "Features", rows: Self.compact([
                ("Frame TV", details.frameTV.map(Self.yesNo)),
                ("Voice Control", details.voice.map(Self.yesNo)),
                ("Game Controllers", details.gamePad.map(Self.yesNo)),
                ("Keyboard Sync", details.keyboardSync.map(Self.yesNo)),
                ("Developer Mode", details.developerMode.map { $0 ? "On" : "Off" }),
            ])))
            sections.append(Section(title: "Region", rows: Self.compact([
                ("Language", details.language.map { Self.language($0, locale: locale) }),
                ("Country", details.countryCode.map { Self.country($0, locale: locale) }),
            ])))
            sections.append(Section(title: "Software", rows: Self.compact([
                ("Firmware", details.firmwareVersion),
                ("Remote API Version", details.apiVersion),
            ])))
        }

        self.sections = sections.filter { !$0.rows.isEmpty }
        footnote = snapshot.isLive ? nil : Self.notLiveFootnote
    }

    /// Every row as "Label: value" lines, for Copy All.
    var plainText: String {
        sections.map { section in
            ([section.title] + section.rows.map { "\($0.label): \($0.value)" }).joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    private static func compact(_ pairs: [(String, String?)]) -> [Row] {
        pairs.compactMap { label, value in
            guard let value, !value.isEmpty else { return nil }
            return Row(label: label, value: value)
        }
    }

    private static func yesNo(_ value: Bool) -> String { value ? "Yes" : "No" }

    static func connection(_ networkType: String) -> String? {
        switch networkType.lowercased() {
        case "wireless": "Wi-Fi"
        case "wired": "Ethernet"
        case "": nil
        default: networkType
        }
    }

    /// "3840x2160" → "3840 × 2160 (4K)".
    static func resolution(_ raw: String) -> String {
        let parts = raw.lowercased().split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2 else { return raw }
        let name: String? = switch parts[0] {
        case 7680: "8K"
        case 3840: "4K"
        case 1920: "Full HD"
        case 1280, 1366: "HD"
        default: nil
        }
        let size = "\(parts[0]) × \(parts[1])"
        return name.map { "\(size) (\($0))" } ?? size
    }

    static func language(_ identifier: String, locale: Locale) -> String {
        locale.localizedString(forIdentifier: identifier) ?? identifier
    }

    static func country(_ code: String, locale: Locale) -> String {
        locale.localizedString(forRegionCode: code) ?? code
    }

    private static func date(_ date: Date, locale: Locale) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
    }
}

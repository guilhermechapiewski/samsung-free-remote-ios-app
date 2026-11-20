import Foundation

/// How the status line above the D-pad looks.
enum StatusTone: Hashable {
    /// Something is happening (connecting, turning on or off).
    case progress
    /// It worked (connected).
    case success
    /// Something went wrong or needs the user.
    case warning
    /// Plain information.
    case info
}

/// One status: a short title that fits on one line, and optionally a longer explanation shown on tap.
struct StatusLine: Hashable {
    let title: String
    let tone: StatusTone
    let detail: String?
    /// The leading icon. Progress shows a spinner instead; nil shows no icon. Never an "info" glyph: ⓘ is
    /// reserved for statuses that open a detail when tapped.
    let symbol: String?

    init(_ title: String, tone: StatusTone, detail: String? = nil, symbol: String? = nil) {
        self.title = title
        self.tone = tone
        self.detail = detail
        self.symbol = symbol ?? tone.defaultSymbol
    }
}

extension StatusTone {
    /// Information has no default icon: a generic "i" would look like the tappable ⓘ.
    var defaultSymbol: String? {
        switch self {
        case .progress, .info: nil
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        }
    }
}

/// Every status the app shows. Titles stay short (one line at the default text size); anything longer
/// goes in `detail`.
extension StatusLine {
    /// Where Samsung TVs keep the setting that lets the app turn them on (2022 and newer under
    /// Connection; older models under General).
    static let powerOnWithMobilePath =
        "Settings → Connection → Network → Expert Settings → Power On with Mobile "
        + "(on some TVs: Settings → General → Network → Expert Settings)"

    static let turningOn = StatusLine("Turning on…", tone: .progress)
    static let turningOff = StatusLine("Turning off…", tone: .progress)
    /// A key didn't reach the TV; the session reconnects.
    static let reconnecting = StatusLine("Reconnecting…", tone: .progress)

    static func connecting(to name: String?) -> StatusLine {
        StatusLine(name.map { "Connecting to \($0)…" } ?? "Connecting…", tone: .progress)
    }

    static func connected(to name: String?) -> StatusLine {
        StatusLine(name.map { "Connected to \($0)" } ?? "Connected", tone: .success)
    }

    static let tvOff = StatusLine("The TV is off", tone: .info, symbol: "power")
    static let unreachable = StatusLine(
        "Can't reach the TV", tone: .warning,
        detail: "Make sure the TV is on and connected to the same Wi-Fi network as this iPhone. "
            + "If it's off, press Power to turn it on."
    )
    /// Power-on didn't show the TV as on within the power controller's wait. The app keeps watching, so a
    /// TV that is just slow to boot still connects. A TV off for hours may not wake at all, broadcast or
    /// not (2026-11-20 overnight test), hence the own-remote advice.
    static let notTurnedOn = StatusLine(
        "The TV hasn't turned on yet", tone: .warning,
        detail: "If it turns on, it connects here on its own. If it stays off, check that “Power On with "
            + "Mobile” is on: \(powerOnWithMobilePath). A TV that has been off for a long time may need "
            + "its own remote."
    )
    static let wakeAddressUnknown = StatusLine(
        "Can't turn this TV on yet", tone: .warning,
        detail: "Its network address for waking isn't known yet. Turn the TV on with its own remote once "
            + "while this app is open; after that, Power works from here."
    )
    static let notOnWiFi = StatusLine(
        "Not on Wi-Fi", tone: .warning,
        detail: "Connect your iPhone to the same Wi-Fi network as the TV, then try again."
    )
    static let approvalTimedOut = StatusLine(
        "Allow wasn't chosen in time", tone: .warning,
        detail: "The TV didn't confirm the connection in time. Choose the TV again in the menu, and choose "
            + "Allow when the TV asks."
    )
    static let chooseTVFirst = StatusLine("Choose a TV first", tone: .warning)
    static let chooseAllow = StatusLine("Choose Allow on the TV", tone: .info, symbol: "hand.tap.fill")
    static let blocked = StatusLine(
        "The TV blocked this iPhone", tone: .warning,
        detail: "On the TV, open Settings → General → External Device Manager → Device Connection Manager "
            + "→ Device List, and allow TV Remote."
    )
    static let identityChanged = StatusLine(
        "The TV's identity changed", tone: .warning,
        detail: "This can happen after a software update. Pair again to continue."
    )
}

import Foundation

/// Samsung remote key codes sent as `DataOfCmd`.
public enum RemoteKey: String, Sendable, CaseIterable {
    case power = "KEY_POWER"
    case up = "KEY_UP"
    case down = "KEY_DOWN"
    case left = "KEY_LEFT"
    case right = "KEY_RIGHT"
    case enter = "KEY_ENTER"
    case back = "KEY_RETURN"
    case home = "KEY_HOME"
    case volumeUp = "KEY_VOLUP"
    case volumeDown = "KEY_VOLDOWN"
    case mute = "KEY_MUTE"
    case channelUp = "KEY_CHUP"
    case channelDown = "KEY_CHDOWN"
    case source = "KEY_SOURCE"
    case hdmi1 = "KEY_HDMI1"
    case hdmi2 = "KEY_HDMI2"
    case hdmi3 = "KEY_HDMI3"
    case hdmi4 = "KEY_HDMI4"
    case play = "KEY_PLAY"
    case pause = "KEY_PAUSE"
    case digit0 = "KEY_0"
    case digit1 = "KEY_1"
    case digit2 = "KEY_2"
    case digit3 = "KEY_3"
    case digit4 = "KEY_4"
    case digit5 = "KEY_5"
    case digit6 = "KEY_6"
    case digit7 = "KEY_7"
    case digit8 = "KEY_8"
    case digit9 = "KEY_9"
}

public enum KeyAction: String, Sendable {
    case click = "Click"
    case press = "Press"
    case release = "Release"
}

/// How the app repeats a held key (volume, arrows): one Press then Release, or repeated Clicks.
/// The default is the conservative choice until verified on real TVs (see docs/protocol-notes.md).
public enum RepeatStrategy: Sendable, Equatable {
    case pressRelease
    case clickEvery(Duration)

    public static let `default`: RepeatStrategy = .clickEvery(.milliseconds(150))
}

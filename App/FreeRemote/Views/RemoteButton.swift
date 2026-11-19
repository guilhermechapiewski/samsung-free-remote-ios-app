import SwiftUI
import UIKit

/// The remote's palette: dark-first (as in the approved mockup), with light-mode counterparts.
extension Color {
    static let remoteBackground = dynamic(light: 0xF2F2F7, dark: 0x0B0B0D)
    /// The picker card and the D-pad ring.
    static let remoteCard = dynamic(light: 0xFFFFFF, dark: 0x1C1C1E)
    /// Round keys, the Source pill and the rockers.
    static let remoteKey = dynamic(light: 0xE3E3E8, dark: 0x2C2C2E)
    static let remoteOK = dynamic(light: 0xD1D1D6, dark: 0x3A3A3C)
    static let remotePowerFill = dynamic(light: 0xFFE3E1, dark: 0x3A1D1D)
    static let remotePowerSymbol = dynamic(light: 0xC4141C, dark: 0xFF6961)
    /// The D-pad arrows.
    static let remoteArrow = dynamic(light: 0x48484A, dark: 0xAEAEB2)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in
            let rgb = traits.userInterfaceStyle == .light ? light : dark
            return UIColor(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                           blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        })
    }
}

/// Sizes of the remote's keys.
enum RemoteMetrics {
    static let key: CGFloat = 64
    static let keySpacing: CGFloat = 14
    static let rockerHeight: CGFloat = key * 2 + keySpacing + 12
    static let dPad: CGFloat = 264
}

/// Dims a key while pressed (and while disabled), and reports the pressed state, so a key can act on
/// touch-down and touch-up.
struct RemoteKeyStyle: ButtonStyle {
    var onPressChange: ((Bool) -> Void)?

    func makeBody(configuration: Configuration) -> some View {
        StyledKey(configuration: configuration, onPressChange: onPressChange)
    }

    private struct StyledKey: View {
        let configuration: Configuration
        let onPressChange: ((Bool) -> Void)?
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .opacity(isEnabled ? (configuration.isPressed ? 0.55 : 1) : 0.35)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
                .onChange(of: configuration.isPressed) { _, pressed in onPressChange?(pressed) }
                .onDisappear { if configuration.isPressed { onPressChange?(false) } }
        }
    }
}

/// A key that acts once per tap, with a light haptic.
struct RemoteButton<Label: View>: View {
    let accessibilityLabel: String
    var accessibilityHint: String?
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var presses = 0

    var body: some View {
        Button {
            presses += 1
            action()
        } label: {
            label()
        }
        .buttonStyle(RemoteKeyStyle())
        .sensoryFeedback(.impact(weight: .light), trigger: presses)
        .remoteKeyAccessibility(accessibilityLabel, hint: accessibilityHint)
    }
}

/// A key that repeats while held: `onBegin` on touch-down, `onEnd` on touch-up or cancel.
/// VoiceOver's activate sends one press (`onPress`) instead, since a hold cannot be expressed there.
struct HoldButton<Label: View>: View {
    let accessibilityLabel: String
    let onBegin: () -> Void
    let onEnd: () -> Void
    let onPress: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var presses = 0

    var body: some View {
        Button {} label: {
            label()
        }
        .buttonStyle(RemoteKeyStyle { pressed in
            if pressed {
                presses += 1
                onBegin()
            } else {
                onEnd()
            }
        })
        .sensoryFeedback(.impact(weight: .light), trigger: presses)
        .remoteKeyAccessibility(accessibilityLabel, hint: nil)
        .accessibilityAction {
            presses += 1
            onPress()
        }
    }
}

/// A round key face: a symbol or short text on a filled circle.
struct KeyFace<Content: View>: View {
    var fill: Color = .remoteKey
    var size: CGFloat = RemoteMetrics.key
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .font(.title3.weight(.medium))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
            .background(Circle().fill(fill))
            .contentShape(Circle())
    }
}

extension View {
    /// The label, optional hint, button trait and large-content viewer every remote key gets.
    func remoteKeyAccessibility(_ label: String, hint: String?) -> some View {
        accessibilityLabel(label)
            .accessibilityHint(hint.map { Text($0) } ?? Text(verbatim: ""))
            .accessibilityAddTraits(.isButton)
            .accessibilityShowsLargeContentViewer { Text(label) }
    }
}

import SamsungTVKit
import SwiftUI

/// Which controls can be used: every key needs the selected TV connected and ready; Power only needs
/// a selected TV, since it can wake one the app cannot reach.
struct RemoteAvailability: Equatable {
    let controls: Bool
    let power: Bool

    init(screen: ScreenState, isConnected: Bool, hasSelection: Bool) {
        controls = screen == .ready && isConnected
        power = hasSelection
    }
}

/// The remote screen (layout B, "classic remote"): TV picker, Power / Source / Mute, the D-pad, and
/// the volume rocker, Back / Home / Play-Pause / 123, and the channel rocker.
struct RemoteView: View {
    /// Hooks for the TV management sheets and the number pad.
    var onRename: ((TVID) -> Void)?
    var onForget: ((TVID) -> Void)?
    var onAddTV: (() -> Void)?
    var onNumberPad: (() -> Void)?

    @Environment(AppModel.self) private var model
    @State private var sourcePresses = 0

    private var availability: RemoteAvailability {
        RemoteAvailability(screen: model.screen, isConnected: model.isConnected, hasSelection: model.selectedID != nil)
    }

    var body: some View {
        // Scrolls only when it must (the largest text sizes), so presses are never delayed otherwise.
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
        }
        .background(Color.remoteBackground.ignoresSafeArea())
    }

    private var content: some View {
        VStack(spacing: 16) {
            TVPicker(onRename: onRename, onForget: onForget, onAddTV: onAddTV)
            Spacer(minLength: 4)
            topRow
            StatusView(text: model.statusText)
            DPad(onBegin: model.beginHold, onEnd: model.endHold, onPress: model.press)
                .disabled(!availability.controls)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            Spacer(minLength: 4)
            bottomRow
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private var topRow: some View {
        HStack(spacing: RemoteMetrics.keySpacing + 6) {
            RemoteButton(accessibilityLabel: "Power", accessibilityHint: "Turns the TV on or off",
                         action: model.togglePower) {
                KeyFace(fill: .remotePowerFill) {
                    if model.powerBusy {
                        ProgressView()
                    } else {
                        Image(systemName: "power").foregroundStyle(Color.remotePowerSymbol)
                    }
                }
            }
            .disabled(!availability.power)

            source
                .disabled(!availability.controls)

            RemoteButton(accessibilityLabel: "Mute", action: { model.press(.mute) }) {
                KeyFace { Image(systemName: "speaker.slash.fill") }
            }
            .disabled(!availability.controls)
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    /// Tap for the Source key; touch and hold for HDMI 1–4.
    private var source: some View {
        Menu {
            Section("Inputs") {
                ForEach(Array([RemoteKey.hdmi1, .hdmi2, .hdmi3, .hdmi4].enumerated()), id: \.offset) { index, key in
                    Button("HDMI \(index + 1)") { pressSource(key) }
                }
            }
        } label: {
            Text("Source")
                .font(.body.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.remoteKey))
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        } primaryAction: {
            pressSource(.source)
        }
        .buttonStyle(RemoteKeyStyle())
        .sensoryFeedback(.impact(weight: .light), trigger: sourcePresses)
        .remoteKeyAccessibility("Source", hint: "Touch and hold to choose an HDMI input")
    }

    private func pressSource(_ key: RemoteKey) {
        sourcePresses += 1
        model.press(key)
    }

    private var bottomRow: some View {
        HStack(alignment: .center) {
            Rocker.volume(onBegin: model.beginHold, onEnd: model.endHold, onPress: model.press)
            Spacer(minLength: RemoteMetrics.keySpacing)
            Grid(horizontalSpacing: RemoteMetrics.keySpacing, verticalSpacing: RemoteMetrics.keySpacing) {
                GridRow {
                    RemoteButton(accessibilityLabel: "Back", action: { model.press(.back) }) {
                        KeyFace { Image(systemName: "arrow.uturn.backward") }
                    }
                    RemoteButton(accessibilityLabel: "Home", action: { model.press(.home) }) {
                        KeyFace { Image(systemName: "house") }
                    }
                }
                GridRow {
                    RemoteButton(accessibilityLabel: "Play or pause", action: model.playPause) {
                        KeyFace { Image(systemName: "playpause.fill") }
                    }
                    RemoteButton(accessibilityLabel: "Number pad", accessibilityHint: "Shows number keys",
                                 action: { onNumberPad?() }) {
                        KeyFace { Text("123").font(.headline) }
                    }
                }
            }
            Spacer(minLength: RemoteMetrics.keySpacing)
            Rocker.channel(onBegin: model.beginHold, onEnd: model.endHold, onPress: model.press)
        }
        .disabled(!availability.controls)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

#Preview("Connected") {
    @Previewable @State var model = AppModel(env: DemoEnvironment.make())
    RemoteView()
        .environment(model)
        .task { model.onAppear() }
}

#Preview("Light") {
    @Previewable @State var model = AppModel(env: DemoEnvironment.make())
    RemoteView()
        .environment(model)
        .task { model.onAppear() }
        .preferredColorScheme(.light)
}

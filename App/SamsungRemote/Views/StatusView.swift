import SwiftUI
import UIKit

extension Color {
    /// Status line tints, darker in light mode for contrast on their pale fill.
    static let statusProgress = dynamicStatus(light: 0x0A5AC2, dark: 0x5EA5FF)
    static let statusSuccess = dynamicStatus(light: 0x1B7A37, dark: 0x4CD964)
    static let statusWarning = dynamicStatus(light: 0x9A5700, dark: 0xFFB340)

    private static func dynamicStatus(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in
            let rgb = traits.userInterfaceStyle == .light ? light : dark
            return UIColor(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                           blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        })
    }
}

extension StatusTone {
    var color: Color {
        switch self {
        case .progress: .statusProgress
        case .success: .statusSuccess
        case .warning: .statusWarning
        case .info: .secondary
        }
    }
}

/// The status line above the D-pad: one short line, tinted by tone (blue with a spinner while something is
/// happening, green when it worked, orange for problems, neutral for information). Its height never
/// changes, even when empty, so the remote below never moves. A status with more to say shows ⓘ and opens
/// the explanation in a popover when tapped.
struct StatusView: View {
    let line: StatusLine?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsDetail = false
    /// Every icon gets a slot this tall (about one line of text), so no symbol can make a chip taller.
    @ScaledMetric(relativeTo: .subheadline) private var iconHeight: CGFloat = 18

    init(_ line: StatusLine?) { self.line = line }

    /// One line normally; two at the accessibility text sizes, where one would truncate too much.
    private var lineCount: Int { dynamicTypeSize.isAccessibilitySize ? 2 : 1 }

    var body: some View {
        ZStack {
            // Reserves the height of a full chip whatever is (or isn't) showing: text, an icon and the ⓘ.
            chip(StatusLine(Array(repeating: "Ag", count: lineCount).joined(separator: "\n"), tone: .warning,
                            detail: " "))
                .hidden()
                .accessibilityHidden(true)
            if let line {
                content(line)
                    .id(line) // a new status crossfades in place
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.2), value: line)
        .onChange(of: line) { showsDetail = false }
    }

    @ViewBuilder private func content(_ line: StatusLine) -> some View {
        if let detail = line.detail {
            Button { showsDetail = true } label: { chip(line) }
                .buttonStyle(.plain)
                .popover(isPresented: $showsDetail) {
                    Text(detail)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding()
                        .frame(idealWidth: 320)
                        .presentationCompactAdaptation(.popover)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(line.title)
                .accessibilityValue(detail)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("status")
        } else {
            chip(line)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(line.title)
                .accessibilityIdentifier("status")
        }
    }

    private func chip(_ line: StatusLine) -> some View {
        let tint = line.tone.color
        let shape = Capsule(style: .continuous)
        return HStack(spacing: 8) {
            if line.tone == .progress {
                ProgressView()
                    .controlSize(.small)
                    .tint(tint)
            } else if let symbol = line.symbol {
                Image(systemName: symbol)
                    .foregroundStyle(line.tone == .info ? Color.secondary : tint)
                    .frame(height: iconHeight)
            }
            Text(line.title)
                .foregroundStyle(line.tone == .info ? Color.primary : tint)
                .lineLimit(lineCount)
                .minimumScaleFactor(0.85)
                .multilineTextAlignment(.center)
            if line.detail != nil {
                Image(systemName: "info.circle")
                    .foregroundStyle(line.tone == .info ? Color.secondary : tint)
                    .frame(height: iconHeight)
            }
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(shape.fill(line.tone == .info ? Color.remoteCard : tint.opacity(0.14)))
        .overlay(shape.strokeBorder(line.tone == .info ? Color.clear : tint.opacity(0.35), lineWidth: 1))
    }
}

/// Takes the remote's place when there is no TV to control: why, and what to do about it.
struct StateCard: View {
    let screen: ScreenState
    var onAddTV: (() -> Void)?

    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    /// The explanation for each screen state other than `.ready`.
    static func message(for screen: ScreenState) -> String? {
        switch screen {
        case .ready: nil
        case .noWiFi: "Connect to Wi-Fi to control your TV."
        case .localNetworkDenied: "Simple TV Remote for Samsung needs Local Network access to find your TV."
        case .searching: "Looking for TVs…"
        case .noTVs: "No TVs found. Turn your TV on and make sure your iPhone and TV are on the same Wi-Fi network."
        case .chooseTV: "Choose your TV"
        case .pairing: "Look at your TV and choose Allow."
        case .pairingDenied:
            "Your TV blocked this iPhone. On the TV, open Settings → General → External Device Manager → "
                + "Device Connection Manager → Device List, allow TV Remote, then tap Try Again."
        case .identityChanged:
            "This TV's security identity changed (this can happen after a software update). Pair again to continue."
        }
    }

    /// A smaller second line for states where the TV has to be on to be found.
    static func hint(for screen: ScreenState) -> String? {
        switch screen {
        case .searching, .noTVs:
            "A TV can only be found while it's on. After that, the app remembers it, even when it's off."
        case .chooseTV: "Don't see your TV? Turn it on, then tap Scan Again."
        case .ready, .noWiFi, .localNetworkDenied, .pairing, .pairingDenied, .identityChanged: nil
        }
    }

    private var symbol: String {
        switch screen {
        case .noWiFi: "wifi.slash"
        case .localNetworkDenied: "lock.shield"
        case .searching, .pairing: ""
        case .noTVs: "tv.slash"
        case .chooseTV, .ready: "tv"
        case .pairingDenied: "hand.raised"
        case .identityChanged: "exclamationmark.shield"
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            if screen == .searching || screen == .pairing {
                ProgressView().controlSize(.large)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            if let message = Self.message(for: screen) {
                Text(message)
                    .font(screen == .chooseTV ? .title2.weight(.semibold) : .body)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(screen == .chooseTV ? .isHeader : [])
            }
            if let hint = Self.hint(for: screen) {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.remoteCard))
    }

    @ViewBuilder private var actions: some View {
        switch screen {
        case .noWiFi:
            Button("Try Again") { model.rescan() }
                .buttonStyle(.bordered)
        case .localNetworkDenied:
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .buttonStyle(.borderedProminent)
        case .noTVs:
            VStack(spacing: 10) {
                Button("Scan Again") { model.rescan() }
                    .buttonStyle(.borderedProminent)
                if let onAddTV {
                    Button("Add TV by IP Address", action: onAddTV)
                        .buttonStyle(.bordered)
                }
            }
        case .chooseTV:
            VStack(spacing: 10) {
                ForEach(model.tvs) { tv in
                    Button { model.select(tv.id) } label: {
                        HStack(spacing: 10) {
                            Circle().fill(tv.status.dotColor).frame(width: 9, height: 9)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tv.title).font(.headline)
                                Text("\(tv.subtitle) · \(tv.status.displayName)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.remoteKey))
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(RemoteKeyStyle())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(tv.title), \(tv.status.displayName)")
                    .accessibilityAddTraits(.isButton)
                }
                Button(model.scanFeedback == .scanning ? "Scanning…" : "Scan Again") { model.scanAgain() }
                    .buttonStyle(.bordered)
                    .disabled(model.scanFeedback == .scanning)
            }
        case .pairingDenied:
            Button("Try Again") { model.rescan() }
                .buttonStyle(.borderedProminent)
        case .identityChanged:
            Button("Pair Again") { model.repair() }
                .buttonStyle(.borderedProminent)
        case .ready, .searching, .pairing:
            EmptyView()
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        StatusView(.connecting(to: "Living Room"))
        StatusView(.connected(to: "Living Room"))
        StatusView(.notTurnedOn)
        StatusView(.tvOff)
        StatusView(nil)
    }
    .padding()
    .background(Color.remoteBackground)
}

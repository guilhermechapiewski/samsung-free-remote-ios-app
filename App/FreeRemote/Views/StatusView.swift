import SwiftUI
import UIKit

/// One line (or a few) above the D-pad explaining why the keys are unavailable, or what just went wrong.
struct StatusView: View {
    let text: String?

    var body: some View {
        Text(text ?? "")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, text == nil ? 0 : 12)
            .padding(.vertical, text == nil ? 0 : 6)
            .background {
                if text != nil { Capsule().fill(Color.remoteCard) }
            }
            .frame(maxWidth: .infinity, minHeight: 18)
            .accessibilityHidden(text == nil)
            .accessibilityIdentifier("status")
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
        case .localNetworkDenied: "Free Remote needs Local Network access to find your TV."
        case .searching: "Looking for TVs…"
        case .noTVs: "No TVs found. Turn your TV on and make sure your iPhone and TV are on the same Wi-Fi network."
        case .chooseTV: "Choose your TV"
        case .pairing: "Look at your TV and choose Allow."
        case .pairingDenied:
            "Your TV blocked this iPhone. On the TV, open Settings → General → External Device Manager → "
                + "Device Connection Manager → Device List, allow Free Remote, then tap Try Again."
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
                Button("Scan Again") { model.rescan() }
                    .buttonStyle(.bordered)
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
        StatusView(text: AppModel.screenStatusText(.searching))
        StatusView(text: AppModel.unreachableMessage)
    }
    .padding()
}

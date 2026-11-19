import SwiftUI

/// One line (or a few) above the D-pad explaining why the keys are unavailable, or what just went wrong.
struct StatusView: View {
    let text: String?

    var body: some View {
        Text(text ?? "")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 18)
            .accessibilityHidden(text == nil)
            .accessibilityIdentifier("status")
    }

    /// The model's transient message, else a short explanation of the screen state; nil when the
    /// selected TV is connected and there is nothing to explain.
    static func text(screen: ScreenState, isConnected: Bool, statusMessage: String?) -> String? {
        if let statusMessage { return statusMessage }
        switch screen {
        case .ready: return isConnected ? nil : "Connecting…"
        case .noWiFi: return "Not connected to Wi-Fi"
        case .localNetworkDenied: return "Local Network access is turned off"
        case .searching: return "Searching for TVs…"
        case .noTVs: return "No TVs found"
        case .chooseTV: return "Choose a TV"
        case .pairing: return "Pairing with the TV…"
        case .pairingDenied: return "The TV blocked this iPhone"
        case .identityChanged: return "The TV's security identity changed"
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        StatusView(text: StatusView.text(screen: .searching, isConnected: false, statusMessage: nil))
        StatusView(text: AppModel.unreachableMessage)
    }
    .padding()
}

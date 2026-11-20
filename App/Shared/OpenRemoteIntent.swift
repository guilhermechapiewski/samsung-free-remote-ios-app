import AppIntents

/// Opens the app on the remote for the last-used TV. Used by the Control Center control; it is also in
/// the app target, so iOS can run it in the app (which opens it) and offers it in Shortcuts.
struct OpenRemoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Open TV Remote"
    static let description = IntentDescription("Opens the remote for your TV.")
    /// Running it brings the app to the foreground; the app already opens on the last-used TV.
    static let supportedModes: IntentModes = .foreground

    func perform() async throws -> some IntentResult {
        .result()
    }
}

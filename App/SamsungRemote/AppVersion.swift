import Foundation

/// The version line shown at the bottom of the TV menu.
enum AppVersion {
    /// "Version 1.0.1 (3)"; nil when the bundle lacks either value.
    static func text(short: String?, build: String?) -> String? {
        guard let short, let build else { return nil }
        return "Version \(short) (\(build))"
    }

    /// "Version 1.0.1, build 3" (what VoiceOver reads); nil when the bundle lacks either value.
    static func accessibilityText(short: String?, build: String?) -> String? {
        guard let short, let build else { return nil }
        return "Version \(short), build \(build)"
    }

    static var text: String? {
        text(short: bundleShort, build: bundleBuild)
    }

    static var accessibilityText: String? {
        accessibilityText(short: bundleShort, build: bundleBuild)
    }

    private static var bundleShort: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    private static var bundleBuild: String? {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }
}

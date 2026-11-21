import Foundation

/// The version line shown at the bottom of the TV menu.
enum AppVersion {
    /// "Version 1.0.1 (3)"; nil when the bundle lacks either value.
    static func text(short: String?, build: String?) -> String? {
        guard let short, let build else { return nil }
        return "Version \(short) (\(build))"
    }

    static var text: String? {
        let info = Bundle.main.infoDictionary
        return text(short: info?["CFBundleShortVersionString"] as? String, build: info?["CFBundleVersion"] as? String)
    }
}

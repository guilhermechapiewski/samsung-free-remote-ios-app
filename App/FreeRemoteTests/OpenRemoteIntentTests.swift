import AppIntents
import Testing
@testable import FreeRemote

@Suite struct OpenRemoteIntentTests {
    @Test func opensTheApp() async throws {
        // The Control Center control relies on this: running the intent must bring the app forward.
        #expect(OpenRemoteIntent.supportedModes == .foreground)
        _ = try await OpenRemoteIntent().perform()
    }
}

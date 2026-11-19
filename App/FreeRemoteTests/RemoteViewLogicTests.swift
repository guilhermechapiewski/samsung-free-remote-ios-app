import Foundation
import Testing
import SamsungTVKit
@testable import FreeRemote

@MainActor
@Suite struct RemoteViewLogicTests {
    @Test func controlsNeedAReadyConnectedTV() {
        #expect(RemoteAvailability(screen: .ready, isConnected: true, hasSelection: true).controls)
        #expect(!RemoteAvailability(screen: .ready, isConnected: false, hasSelection: true).controls)
        #expect(!RemoteAvailability(screen: .pairing, isConnected: true, hasSelection: true).controls)
        #expect(!RemoteAvailability(screen: .chooseTV, isConnected: false, hasSelection: false).controls)
    }

    @Test func powerOnlyNeedsASelectedTV() {
        // Power can wake a TV the app cannot reach.
        #expect(RemoteAvailability(screen: .ready, isConnected: false, hasSelection: true).power)
        #expect(RemoteAvailability(screen: .pairingDenied, isConnected: false, hasSelection: true).power)
        #expect(!RemoteAvailability(screen: .chooseTV, isConnected: false, hasSelection: false).power)
    }

    @Test func statusMessageWinsOverScreenState() {
        #expect(StatusView.text(screen: .ready, isConnected: true, statusMessage: "Explained") == "Explained")
        #expect(StatusView.text(screen: .noWiFi, isConnected: false, statusMessage: "Explained") == "Explained")
    }

    @Test func connectedReadyScreenNeedsNoStatus() {
        #expect(StatusView.text(screen: .ready, isConnected: true, statusMessage: nil) == nil)
        #expect(StatusView.text(screen: .ready, isConnected: false, statusMessage: nil) == "Connecting…")
    }

    @Test func everyOtherScreenStateIsExplained() {
        let states: [ScreenState] = [
            .noWiFi, .localNetworkDenied, .searching, .noTVs, .chooseTV, .pairing, .pairingDenied, .identityChanged,
        ]
        let texts = states.map { StatusView.text(screen: $0, isConnected: false, statusMessage: nil) }
        #expect(texts.allSatisfy { !($0 ?? "").isEmpty })
        #expect(Set(texts).count == states.count)
    }

    @Test func tvStatusNames() {
        #expect(TVStatus.on.displayName == "On")
        #expect(TVStatus.asleep.displayName == "Asleep")
        #expect(TVStatus.unreachable.displayName == "Unreachable")
        #expect(TVStatus.pairing.displayName == "Pairing")
    }

    @Test func demoEnvironmentStartsConnectedToLivingRoom() async {
        let model = AppModel(env: DemoEnvironment.make())
        model.onAppear()
        for _ in 0..<10_000 where !(model.isConnected && model.tvs.count == 3) { await Task.yield() }
        #expect(model.screen == .ready)
        #expect(model.isConnected)
        #expect(model.tvs.map(\.title).sorted() == ["Bedroom", "Living Room", "Patio"])
        #expect(model.tvs.first { $0.id == model.selectedID }?.title == "Living Room")
        #expect(model.tvs.first { $0.title == "Living Room" }?.status == .on)
    }
}

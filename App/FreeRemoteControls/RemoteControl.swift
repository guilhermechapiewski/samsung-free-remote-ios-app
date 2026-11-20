import AppIntents
import SwiftUI
import WidgetKit

/// The Control Center (and Lock Screen / Action button) control: one tap opens the remote.
struct RemoteControl: ControlWidget {
    static let kind = "RemoteControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenRemoteIntent()) {
                Label("TV Remote", systemImage: "av.remote.fill")
            }
        }
        .displayName("TV Remote")
        .description("Opens the remote for your Samsung TV.")
    }
}

@main
struct FreeRemoteControls: WidgetBundle {
    var body: some Widget {
        RemoteControl()
    }
}

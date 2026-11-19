import SwiftUI

@main
struct FreeRemoteApp: App {
    @State private var model = AppModel(env: DemoEnvironment.isRequested ? DemoEnvironment.make() : .live())
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RemoteView()
                .environment(model)
                .task { model.onAppear() }
                .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(phase) }
        }
    }
}

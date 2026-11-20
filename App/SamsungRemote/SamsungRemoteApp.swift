import SwiftUI

@main
struct SamsungRemoteApp: App {
    @State private var model: AppModel
    /// Set only in demo mode: the keys sent, shown to UI tests.
    private let demoKeyLog: DemoKeyLog?
    @Environment(\.scenePhase) private var scenePhase

    init() {
        if let scenario = DemoEnvironment.requestedScenario {
            let keyLog = DemoKeyLog()
            demoKeyLog = keyLog
            _model = State(initialValue: AppModel(env: DemoEnvironment.make(scenario, keyLog: keyLog)))
        } else {
            demoKeyLog = nil
            _model = State(initialValue: AppModel(env: .live()))
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .overlay(alignment: .bottomLeading) {
                    if let demoKeyLog { DemoKeyLogView(log: demoKeyLog) }
                }
                .task { model.onAppear() }
                .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(phase) }
        }
    }
}

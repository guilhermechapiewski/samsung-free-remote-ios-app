import SamsungTVKit
import SwiftUI

/// The app's one screen: the remote when a TV is ready, else a card explaining the state; and the
/// rename, forget, add-TV, number pad and text entry sheets.
struct RootView: View {
    enum Sheet: Identifiable, Equatable {
        case rename(TVID)
        case addTV
        case numberPad
        case text

        var id: String {
            switch self {
            case .rename(let id): "rename:\(id.rawValue)"
            case .addTV: "addTV"
            case .numberPad: "numberPad"
            case .text: "text"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @State private var sheet: Sheet?
    @State private var forgetting: TVID?

    var body: some View {
        Group {
            if model.screen == .ready {
                RemoteView(onRename: rename, onForget: forget, onAddTV: addTV, onNumberPad: { sheet = .numberPad })
            } else {
                stateScreen
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .rename(let id):
                RenameSheet(currentTitle: model.tvs.first { $0.id == id }?.title ?? "") { model.rename(id, to: $0) }
            case .addTV:
                AddTVSheet()
            case .numberPad:
                NumberPadSheet()
            case .text:
                TextEntrySheet()
            }
        }
        .confirmationDialog(forgetTitle, isPresented: forgetPresented, titleVisibility: .visible,
                            presenting: forgetting) { id in
            Button("Forget TV", role: .destructive) { model.forget(id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes its name on your devices and its pairing. To use it again, you'll need to choose Allow on the TV.")
        }
        .onChange(of: sheet) { old, new in
            // Closing text entry (Done or a swipe) tells the TV, if it is still asking for text.
            if old == .text, new != .text, model.keyboardRequested { model.endText() }
        }
        .onChange(of: model.keyboardRequested, initial: true) { _, requested in
            if requested {
                sheet = .text
            } else if sheet == .text {
                sheet = nil
            }
        }
    }

    private var stateScreen: some View {
        ScrollView {
            VStack(spacing: 20) {
                TVPicker(onRename: rename, onForget: forget, onAddTV: addTV)
                StateCard(screen: model.screen, onAddTV: addTV)
                if let message = model.statusMessage {
                    StatusView(text: message)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .background(Color.remoteBackground.ignoresSafeArea())
    }

    private func rename(_ id: TVID) { sheet = .rename(id) }
    private func forget(_ id: TVID) { forgetting = id }
    private func addTV() { sheet = .addTV }

    private var forgetTitle: String {
        let name = model.tvs.first { $0.id == forgetting }?.title ?? "this TV"
        return "Forget \(name)?"
    }

    private var forgetPresented: Binding<Bool> {
        Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })
    }
}

#Preview {
    @Previewable @State var model = AppModel(env: DemoEnvironment.make())
    RootView()
        .environment(model)
        .task { model.onAppear() }
}

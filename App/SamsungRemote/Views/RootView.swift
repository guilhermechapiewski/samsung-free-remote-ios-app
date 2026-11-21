import SamsungTVKit
import SwiftUI

/// The app's one screen: the remote when a TV is ready, else a card explaining the state; and the
/// rename, forget, add-TV, number pad and text entry sheets.
struct RootView: View {
    enum Sheet: Identifiable, Equatable {
        case rename(TVID)
        case details(TVID)
        case addTV
        case findTVHelp
        case numberPad
        case text

        var id: String {
            switch self {
            case .rename(let id): "rename:\(id.rawValue)"
            case .details(let id): "details:\(id.rawValue)"
            case .addTV: "addTV"
            case .findTVHelp: "findTVHelp"
            case .numberPad: "numberPad"
            case .text: "text"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @State private var sheet: Sheet?
    @State private var forgetting: TVID?
    @State private var menuOpen = false
    /// The TV asked for text while another sheet was open; show text entry once that closes.
    @State private var textQueued = false

    /// What to do when the TV's keyboard request changes while `current` is showing.
    static func sheetUpdate(keyboardRequested: Bool, current: Sheet?, queued: Bool)
        -> (sheet: Sheet?, queued: Bool) {
        if keyboardRequested {
            switch current {
            case nil: return (.text, false)
            case .text: return (.text, false)
            default: return (current, true)
            }
        }
        return (current == .text ? nil : current, false)
    }

    /// What to do when the sheet changes to `current`.
    static func queuedTextAfterSheetChange(keyboardRequested: Bool, current: Sheet?, queued: Bool)
        -> (sheet: Sheet?, queued: Bool) {
        if queued, keyboardRequested, current == nil { return (.text, false) }
        return (current, current == .text ? false : queued)
    }

    var body: some View {
        Group {
            if model.screen == .ready {
                RemoteView(onNumberPad: { sheet = .numberPad })
            } else {
                stateScreen
            }
        }
        .modifier(TVMenuOverlay(isOpen: $menuOpen, onDetails: { sheet = .details($0) }, onRename: rename,
                                onForget: forget, onAddTV: addTV, onFindTVHelp: findTVHelp))
        // The card the menu grew from may be gone (Wi-Fi lost, TV forgotten on another device).
        .onChange(of: model.screen) { menuOpen = false }
        .sheet(item: $sheet) { sheetContent($0) }
        .confirmationDialog(forgetTitle, isPresented: forgetPresented, titleVisibility: .visible,
                            presenting: forgetting) { id in
            Button("Forget TV", role: .destructive) { model.forget(id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes its name on your devices and its pairing. To use it again, you'll need to choose Allow on the TV.")
        }
        .alert(AppModel.powerTipTitle, isPresented: powerTipPresented) {
            Button("OK") { model.dismissPowerTip() }
        } message: {
            Text(AppModel.powerTipMessage)
        }
        .onChange(of: sheet) { old, new in
            if new != nil { menuOpen = false } // e.g. the TV asked for text while the menu was open
            // Closing text entry (Done or a swipe) tells the TV, if it is still asking for text.
            if old == .text, new != .text, model.keyboardRequested { model.endText() }
            let next = Self.queuedTextAfterSheetChange(keyboardRequested: model.keyboardRequested, current: new,
                                                       queued: textQueued)
            textQueued = next.queued
            if next.sheet != new { sheet = next.sheet }
        }
        .onChange(of: model.keyboardRequested, initial: true) { _, requested in
            let next = Self.sheetUpdate(keyboardRequested: requested, current: sheet, queued: textQueued)
            textQueued = next.queued
            if next.sheet != sheet { sheet = next.sheet }
        }
    }

    private var stateScreen: some View {
        ScrollView {
            VStack(spacing: 20) {
                TVPicker()
                StateCard(screen: model.screen, onAddTV: addTV, onFindTVHelp: findTVHelp)
                if let event = model.statusEvent {
                    StatusView(event)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .background(Color.remoteBackground.ignoresSafeArea())
    }

    @ViewBuilder
    private func sheetContent(_ sheet: Sheet) -> some View {
        switch sheet {
        case .rename(let id):
            RenameSheet(currentTitle: model.tvs.first { $0.id == id }?.title ?? "") { model.rename(id, to: $0) }
        case .details(let id):
            TVDetailsSheet(id: id)
        case .addTV:
            AddTVSheet()
        case .findTVHelp:
            FindTVHelpSheet(onScanAgain: { self.sheet = nil; model.scanAgain() }, onAddTV: { self.sheet = .addTV })
        case .numberPad:
            NumberPadSheet()
        case .text:
            TextEntrySheet()
        }
    }

    private func rename(_ id: TVID) { sheet = .rename(id) }
    private func forget(_ id: TVID) { forgetting = id }
    private func addTV() { sheet = .addTV }
    private func findTVHelp() { sheet = .findTVHelp }

    private var forgetTitle: String {
        let name = model.tvs.first { $0.id == forgetting }?.title ?? "this TV"
        return "Forget \(name)?"
    }

    /// Not over a sheet: the tip waits until sheets close.
    private var powerTipPresented: Binding<Bool> {
        Binding(get: { model.powerTipTV != nil && sheet == nil && !menuOpen }, set: { _ in }) // only OK dismisses it
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

import SamsungTVKit
import SwiftUI

extension TVStatus {
    var displayName: String {
        switch self {
        case .on: "On"
        case .asleep: "Asleep"
        case .unreachable: "Unreachable"
        case .pairing: "Pairing"
        }
    }

    var dotColor: Color {
        switch self {
        case .on: .green
        case .asleep: .orange
        case .unreachable: .gray
        case .pairing: .blue
        }
    }
}

extension ScanFeedback {
    /// The line the TV card shows instead of the TV's details.
    var text: String {
        switch self {
        case .scanning: "Looking for TVs…"
        case .found(0): "No new TVs found"
        case .found(1): "Found 1 new TV"
        case .found(let count): "Found \(count) new TVs"
        }
    }
}

/// The card at the top: the selected TV with its status. Tapping it opens a menu of the known TVs
/// and the TV management actions.
struct TVPicker: View {
    /// Hooks for the management sheets; each menu item appears only when its hook is set.
    var onRename: ((TVID) -> Void)?
    var onForget: ((TVID) -> Void)?
    var onAddTV: (() -> Void)?

    @Environment(AppModel.self) private var model

    private var selected: TVListItem? { model.tvs.first { $0.id == model.selectedID } }

    var body: some View {
        Menu {
            if !model.tvs.isEmpty {
                Picker("TV", selection: selection) {
                    ForEach(model.tvs) { tv in
                        // Title and subtitle of the menu item.
                        VStack {
                            Text(tv.title)
                            Text(tv.status.displayName)
                        }
                        .tag(tv.id as TVID?)
                    }
                }
                .pickerStyle(.inline)
            }
            if let id = model.selectedID, onRename != nil || onForget != nil {
                Section {
                    if let onRename { Button("Rename…", systemImage: "pencil") { onRename(id) } }
                    if let onForget { Button("Forget…", systemImage: "trash", role: .destructive) { onForget(id) } }
                }
            }
            Section {
                if let onAddTV { Button("Add TV by IP Address…", systemImage: "plus") { onAddTV() } }
                Button(isScanning ? "Scanning…" : "Scan Again", systemImage: "arrow.clockwise") {
                    model.scanAgain()
                }
                .disabled(isScanning)
            }
        } label: {
            card
        }
        .buttonStyle(RemoteKeyStyle())
        .tint(.primary)
        .accessibilityLabel("TV picker")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Shows your TVs")
        .accessibilityAddTraits(.isButton)
        .sensoryFeedback(trigger: model.scanFeedback) { _, new in
            switch new {
            case .scanning: .impact(weight: .light)
            case .found: .success
            case nil: nil
            }
        }
        .onChange(of: model.scanFeedback) { _, new in
            if let new, new != .scanning {
                AccessibilityNotification.Announcement(new.text).post()
            }
        }
    }

    private var accessibilityValue: String {
        let tv = selected.map { "\($0.title), \($0.status.displayName)" } ?? "No TV selected"
        if let feedback = model.scanFeedback { return "\(tv). \(feedback.text)" }
        return tv
    }

    private var isScanning: Bool { model.scanFeedback == .scanning }

    private var detailText: String? {
        if let feedback = model.scanFeedback { return feedback.text }
        return selected.map { "\($0.subtitle) · \($0.status.displayName)" }
    }

    private var selection: Binding<TVID?> {
        Binding(get: { model.selectedID }, set: { id in if let id { model.select(id) } })
    }

    private var card: some View {
        HStack(spacing: 10) {
            if let selected {
                Circle()
                    .fill(selected.status.dotColor)
                    .frame(width: 9, height: 9)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(selected?.title ?? "Choose a TV")
                    .font(.headline)
                    .foregroundStyle(.primary)
                if let detailText {
                    Text(detailText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            if isScanning {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .animation(.default, value: model.scanFeedback)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.remoteCard))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

#Preview {
    @Previewable @State var model = AppModel(env: DemoEnvironment.make())
    TVPicker()
        .padding()
        .background(Color.remoteBackground)
        .environment(model)
        .task { model.onAppear() }
}

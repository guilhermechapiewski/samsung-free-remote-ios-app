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
                Button("Scan Again", systemImage: "arrow.clockwise") { model.rescan() }
            }
        } label: {
            card
        }
        .buttonStyle(RemoteKeyStyle())
        .tint(.primary)
        .accessibilityLabel("TV picker")
        .accessibilityValue(selected.map { "\($0.title), \($0.status.displayName)" } ?? "No TV selected")
        .accessibilityHint("Shows your TVs")
        .accessibilityAddTraits(.isButton)
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
                if let selected {
                    Text("\(selected.subtitle) · \(selected.status.displayName)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            Image(systemName: "chevron.down")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
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

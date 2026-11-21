import SwiftUI

/// Edits the TV's label on this user's devices; an empty name goes back to the TV's own name.
struct RenameSheet: View {
    static let note =
        // Not a menu path: it differs by model year (2025 TVs: Support → About This TV → Edit Name).
        "This name is only on your devices. Leave it empty to use the TV's own name. To change the name "
        + "everyone sees, change Device Name in the TV's own settings (where it is depends on the model)."

    /// The first `ICloudLabelStore.maxLength` characters.
    static func limited(_ s: String) -> String { String(s.prefix(ICloudLabelStore.maxLength)) }

    let onSave: (String) -> Void
    let reportedName: String?

    @State private var name: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    /// `currentTitle` prefills the field.
    init(currentTitle: String, reportedName: String? = nil, onSave: @escaping (String) -> Void) {
        self.onSave = onSave
        self.reportedName = reportedName
        _name = State(initialValue: currentTitle)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(reportedName ?? "TV name", text: $name)
                        .focused($focused)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .onSubmit(save)
                        .accessibilityIdentifier("TV name")
                        .onChange(of: name) { _, new in
                            let limited = Self.limited(new)
                            if limited != new { name = limited }
                        }
                } footer: {
                    Text(Self.note)
                }
            }
            .navigationTitle("Rename TV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                }
            }
            .onAppear { focused = true }
        }
    }

    private func save() {
        onSave(name)
        dismiss()
    }
}

#Preview {
    RenameSheet(currentTitle: "Living Room") { _ in }
}

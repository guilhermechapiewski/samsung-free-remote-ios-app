import SamsungTVKit
import SwiftUI

/// Adds a TV that discovery did not find, by its local IP address.
struct AddTVSheet: View {
    static let invalidAddressMessage = "Enter a local IP address like 192.168.0.20."
    static let noTVMessage = "No Samsung TV answered at that address. Make sure the TV is on and on the same Wi-Fi network."

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var error: String?
    @State private var adding = false
    @State private var addTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("192.168.0.20", text: $address)
                        .keyboardType(.decimalPad)
                        .textContentType(nil)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($focused)
                        .onChange(of: address) { error = nil }
                        .accessibilityLabel("IP address")
                        .accessibilityIdentifier("IP address")
                } header: {
                    Text("IP address")
                } footer: {
                    if let error {
                        Text(error).foregroundStyle(.red)
                    } else {
                        Text("Turn the TV on first. It shows its IP address in its network settings.")
                    }
                }
            }
            .navigationTitle("Add TV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        addTask?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if adding {
                        ProgressView()
                    } else {
                        Button("Add", action: add)
                            .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .onAppear { focused = true }
            // Swiped away mid-request: the TV must not be added and selected behind the user's back.
            .onDisappear { addTask?.cancel() }
        }
    }

    private func add() {
        let host = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard LocalAddress.isAllowed(host) else {
            error = Self.invalidAddressMessage
            return
        }
        adding = true
        addTask = Task {
            let added = await model.addManually(host: host)
            adding = false
            guard !Task.isCancelled else { return }
            if added {
                dismiss()
            } else {
                error = Self.noTVMessage
            }
        }
    }
}

#Preview {
    @Previewable @State var model = AppModel(env: DemoEnvironment.make())
    AddTVSheet().environment(model)
}

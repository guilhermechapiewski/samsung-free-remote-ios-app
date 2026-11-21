import SwiftUI

/// Shown when the TV asks for text (its on-screen keyboard is up). "Send" types the text on the TV;
/// "Done" (or dismissing the sheet) tells the TV text entry is finished.
struct TextEntrySheet: View {
    /// How long "Sent" stays. Demo mode (UI tests) keeps it longer: a tap can take over a second to return.
    static let sentDuration: Duration =
        ProcessInfo.processInfo.arguments.contains(DemoEnvironment.launchArgument) ? .seconds(6) : .milliseconds(1500)

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool
    @State private var showSent = false
    @State private var sentTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Text for the TV", text: $text)
                        .focused($focused)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.send)
                        .onSubmit(send)
                    Button("Send", action: send)
                        .disabled(text.isEmpty)
                        .accessibilityIdentifier("send-text")
                    if showSent {
                        Label("Sent", systemImage: "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.green)
                    }
                } footer: {
                    Text("Your TV is asking for text.")
                }
            }
            .navigationTitle("Type on TV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    // The sheet's dismissal ends text entry on the TV.
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }

    private func send() {
        guard !text.isEmpty else { return }
        model.sendText(text)
        focused = true
        showSent = true
        AccessibilityNotification.Announcement("Sent").post()
        sentTask?.cancel()
        sentTask = Task {
            try? await Task.sleep(for: Self.sentDuration)
            guard !Task.isCancelled else { return }
            showSent = false
        }
    }
}

#Preview {
    @Previewable @State var model = AppModel(env: DemoEnvironment.make())
    TextEntrySheet().environment(model)
}

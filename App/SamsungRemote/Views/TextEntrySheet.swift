import SwiftUI

/// Shown when the TV asks for text (its on-screen keyboard is up). "Send" types the text on the TV;
/// "Done" (or dismissing the sheet) tells the TV text entry is finished.
struct TextEntrySheet: View {
    /// How long "Sent" stays after each send.
    static let sentDuration: Duration = .seconds(3)

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool
    @State private var showSent = false
    /// Counts sends; each one restarts the "Sent" timer.
    @State private var sendCount = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Text for the TV", text: $text)
                        .focused($focused)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.send)
                        .onSubmit {
                            send()
                            // Submitting resigns the field after this runs: refocus one turn later.
                            Task { @MainActor in focused = true }
                        }
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
            // Cancelled when the sheet goes away, and restarted by the next send.
            .task(id: sendCount) {
                guard sendCount > 0 else { return }
                do {
                    try await Task.sleep(for: Self.sentDuration)
                } catch {
                    return // cancelled
                }
                showSent = false
            }
        }
        .presentationDetents([.medium])
    }

    private func send() {
        guard !text.isEmpty else { return }
        model.sendText(text)
        focused = true
        showSent = true
        sendCount += 1
        AccessibilityNotification.Announcement("Sent").post()
    }
}

#Preview {
    @Previewable @State var model = AppModel(env: DemoEnvironment.make())
    TextEntrySheet().environment(model)
}

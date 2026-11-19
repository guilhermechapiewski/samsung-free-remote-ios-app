import SwiftUI

/// Shown when the TV asks for text (its on-screen keyboard is up). "Send" types the text on the TV;
/// "Done" (or dismissing the sheet) tells the TV text entry is finished.
struct TextEntrySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Text for the TV", text: $text)
                        .focused($focused)
                        .autocorrectionDisabled()
                        .submitLabel(.send)
                        .onSubmit(send)
                    Button("Send", action: send)
                        .disabled(text.isEmpty)
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
    }
}

#Preview {
    @Previewable @State var model = AppModel(env: DemoEnvironment.make())
    TextEntrySheet().environment(model)
}

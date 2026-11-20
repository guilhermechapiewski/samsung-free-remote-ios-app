import SamsungTVKit
import SwiftUI
import UIKit

/// TV Details: what the TV reports about itself (asked again when the sheet opens) plus what the app
/// knows about it. Every value can be copied.
struct TVDetailsSheet: View {
    let id: TVID

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: TVDetailsSnapshot?
    @State private var checking = true
    @State private var copied = 0

    var body: some View {
        NavigationStack {
            List {
                if let snapshot {
                    let content = TVDetailsContent(snapshot)
                    if checking {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Checking the TV…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(content.sections) { section in
                        Section(section.title) {
                            ForEach(section.rows) { row in
                                LabeledContent(row.label) {
                                    Text(row.value)
                                        .multilineTextAlignment(.trailing)
                                        .textSelection(.enabled)
                                }
                                .contextMenu {
                                    Button("Copy", systemImage: "doc.on.doc") { copy(row.value) }
                                }
                            }
                        }
                    }
                    if !checking, let footnote = content.footnote {
                        Section { } footer: { Text(footnote) }
                    }
                } else if !checking {
                    ContentUnavailableView("TV Not Found", systemImage: "tv",
                                           description: Text("This TV was removed from the app."))
                }
            }
            .navigationTitle(snapshot?.title ?? "TV Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if let snapshot {
                        Button("Copy All", systemImage: "doc.on.doc") {
                            copy(TVDetailsContent(snapshot).plainText)
                        }
                        .disabled(checking)
                    }
                }
            }
            .sensoryFeedback(.success, trigger: copied)
        }
        .task {
            snapshot = model.details(for: id)
            if let live = await model.liveDetails(for: id) { snapshot = live }
            checking = false
        }
    }

    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        copied += 1
    }
}

#Preview {
    @Previewable @State var model = AppModel(env: DemoEnvironment.make())
    TVDetailsSheet(id: DemoEnvironment.livingRoom)
        .environment(model)
        .task { model.onAppear() }
}

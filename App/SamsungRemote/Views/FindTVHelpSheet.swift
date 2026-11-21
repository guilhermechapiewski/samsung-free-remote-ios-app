import SwiftUI

/// The copy for "Can't Find Your TV?", kept in one place so tests can pin it.
enum FindTVHelp {
    struct Step: Sendable, Equatable {
        let title: String
        let detail: String
    }

    static let title = "Can't Find Your TV?"

    static let steps: [Step] = [
        Step(title: "Turn the TV on.", detail: "A TV can only be found while it's on."),
        Step(title: "Use the same Wi-Fi.",
             detail: "Your iPhone and TV must be on the same network. Guest networks and networks that keep devices apart don't work."),
        Step(title: "Turn on AirPlay on the TV.",
             detail: "On most models: Settings → All Settings → Connection → Apple AirPlay Settings → AirPlay: On."),
        Step(title: "Restart the TV.",
             detail: "Turning it off and on with the remote isn't enough. Point the remote at the TV and hold the power button until the TV turns off and the Samsung logo appears, then let go. Wait about a minute after the TV is back, then tap Scan Again."),
        Step(title: "Add it by IP address.",
             detail: "On most models, the TV shows its IP address under Settings → All Settings → Connection → Network → Network Status → IP Settings. Then tap Add TV by IP Address."),
    ]
}

/// Numbered steps for when a scan finds no TV, with Scan Again and Add TV by IP Address at the end.
struct FindTVHelpSheet: View {
    var onScanAgain: () -> Void
    var onAddTV: () -> Void

    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .headline) private var badgeSize = 32

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(Array(FindTVHelp.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text("\(index + 1)")
                                .font(.headline)
                                .monospacedDigit()
                                .frame(width: badgeSize, height: badgeSize)
                                .background(.tint.opacity(0.15), in: Circle())
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(step.title).font(.headline)
                                Text(step.detail).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Step \(index + 1). \(step.title) \(step.detail)")
                    }
                    VStack(spacing: 12) {
                        Button(action: onScanAgain) {
                            Text("Scan Again").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        Button(action: onAddTV) {
                            Text("Add TV by IP Address").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .controlSize(.large)
                    .padding(.top, 4)
                }
                .padding(20)
            }
            .accessibilityIdentifier("find-tv-help")
            .navigationTitle(FindTVHelp.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    FindTVHelpSheet(onScanAgain: {}, onAddTV: {})
}

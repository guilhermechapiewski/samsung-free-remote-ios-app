import SamsungTVKit
import SwiftUI

/// Number keys 1–9 and 0, each sending its digit to the TV.
struct NumberPadSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private static let rows: [[RemoteKey]] = [
        [.digit1, .digit2, .digit3],
        [.digit4, .digit5, .digit6],
        [.digit7, .digit8, .digit9],
    ]

    var body: some View {
        NavigationStack {
            Grid(horizontalSpacing: 22, verticalSpacing: 14) {
                ForEach(Self.rows, id: \.self) { row in
                    GridRow {
                        ForEach(row, id: \.self) { digitKey($0) }
                    }
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    digitKey(.digit0)
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                }
            }
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.remoteBackground.ignoresSafeArea())
            .navigationTitle("Numbers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func digitKey(_ key: RemoteKey) -> some View {
        let digit = String(key.rawValue.last ?? "?")
        return RemoteButton(accessibilityLabel: digit, action: { model.press(key) }) {
            KeyFace { Text(digit).font(.title2.weight(.medium)) }
        }
    }
}

#Preview {
    @Previewable @State var model = AppModel(env: DemoEnvironment.make())
    Color.clear
        .sheet(isPresented: .constant(true)) { NumberPadSheet().environment(model) }
        .task { model.onAppear() }
}

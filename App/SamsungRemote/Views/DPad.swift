import SamsungTVKit
import SwiftUI

/// The circular arrow pad with OK in the centre. Arrows repeat while held; OK presses once.
struct DPad: View {
    let onBegin: (RemoteKey) -> Void
    let onEnd: () -> Void
    let onPress: (RemoteKey) -> Void
    var diameter: CGFloat = RemoteMetrics.dPad

    private var okSize: CGFloat { diameter * 0.4 }
    /// Depth of the ring between the OK key and the edge.
    private var ring: CGFloat { (diameter - okSize) / 2 }

    var body: some View {
        ZStack {
            Circle().fill(Color.remoteCard)
            arrow(.up, "Up", symbol: "arrowtriangle.up.fill", width: okSize, height: ring)
                .offset(y: -(okSize + ring) / 2)
            arrow(.down, "Down", symbol: "arrowtriangle.down.fill", width: okSize, height: ring)
                .offset(y: (okSize + ring) / 2)
            arrow(.left, "Left", symbol: "arrowtriangle.left.fill", width: ring, height: okSize)
                .offset(x: -(okSize + ring) / 2)
            arrow(.right, "Right", symbol: "arrowtriangle.right.fill", width: ring, height: okSize)
                .offset(x: (okSize + ring) / 2)
            RemoteButton(accessibilityLabel: "OK", accessibilityHint: "Selects the highlighted item") {
                onPress(.enter)
            } label: {
                KeyFace(fill: .remoteOK, size: okSize) {
                    Text("OK").font(.title3.weight(.semibold))
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .contain)
    }

    private func arrow(_ key: RemoteKey, _ label: String, symbol: String, width: CGFloat, height: CGFloat) -> some View {
        HoldButton(accessibilityLabel: label, onBegin: { onBegin(key) }, onEnd: onEnd, onPress: { onPress(key) }) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(Color.remoteArrow)
                .frame(width: width, height: height)
                .contentShape(Rectangle())
        }
    }
}

#Preview {
    DPad(onBegin: { _ in }, onEnd: {}, onPress: { _ in })
        .padding()
        .background(Color.remoteBackground)
}

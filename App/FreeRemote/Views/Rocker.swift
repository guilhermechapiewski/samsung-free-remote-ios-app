import SamsungTVKit
import SwiftUI

/// A vertical up/down rocker (volume or channel). Each half is its own key that repeats while held.
struct Rocker: View {
    struct Half {
        let key: RemoteKey
        let accessibilityLabel: String
        let symbol: String
    }

    /// The caption between the halves ("VOL", "CH").
    let title: String
    let up: Half
    let down: Half
    let onBegin: (RemoteKey) -> Void
    let onEnd: () -> Void
    let onPress: (RemoteKey) -> Void

    var body: some View {
        VStack(spacing: 0) {
            half(up)
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityHidden(true)
            half(down)
        }
        .frame(width: RemoteMetrics.key, height: RemoteMetrics.rockerHeight)
        .background(Capsule().fill(Color.remoteKey))
        .accessibilityElement(children: .contain)
    }

    private func half(_ half: Half) -> some View {
        HoldButton(accessibilityLabel: half.accessibilityLabel, onBegin: { onBegin(half.key) }, onEnd: onEnd,
                   onPress: { onPress(half.key) }) {
            Image(systemName: half.symbol)
                .font(.title3.weight(.medium))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
    }
}

extension Rocker {
    static func volume(onBegin: @escaping (RemoteKey) -> Void, onEnd: @escaping () -> Void,
                       onPress: @escaping (RemoteKey) -> Void) -> Rocker {
        Rocker(title: "VOL",
               up: Half(key: .volumeUp, accessibilityLabel: "Volume up", symbol: "plus"),
               down: Half(key: .volumeDown, accessibilityLabel: "Volume down", symbol: "minus"),
               onBegin: onBegin, onEnd: onEnd, onPress: onPress)
    }

    static func channel(onBegin: @escaping (RemoteKey) -> Void, onEnd: @escaping () -> Void,
                        onPress: @escaping (RemoteKey) -> Void) -> Rocker {
        Rocker(title: "CH",
               up: Half(key: .channelUp, accessibilityLabel: "Channel up", symbol: "chevron.up"),
               down: Half(key: .channelDown, accessibilityLabel: "Channel down", symbol: "chevron.down"),
               onBegin: onBegin, onEnd: onEnd, onPress: onPress)
    }
}

#Preview {
    HStack(spacing: 40) {
        Rocker.volume(onBegin: { _ in }, onEnd: {}, onPress: { _ in })
        Rocker.channel(onBegin: { _ in }, onEnd: {}, onPress: { _ in })
    }
    .padding()
    .background(Color.remoteBackground)
}

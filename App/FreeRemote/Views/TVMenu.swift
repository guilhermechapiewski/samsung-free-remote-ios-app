import SamsungTVKit
import SwiftUI

enum AppLinks {
    /// Where users send feedback and report bugs.
    static let issues = URL(string: "https://github.com/guilhermechapiewski/samsung-free-remote-ios-app/issues")!
}

extension EnvironmentValues {
    /// Opens the TV menu over the screen; set by `RootView`.
    @Entry var openTVMenu: (() -> Void)?
}

/// The TV card's bounds, so the open menu can grow out of it.
struct TVCardBoundsKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// The contents of the TV card: the selected TV's status dot, name and details (or the Scan Again
/// progress), and a chevron or spinner. Shared by the closed card and the open menu's header.
struct TVCardLabel: View {
    let selected: TVListItem?
    let feedback: ScanFeedback?
    var isOpen = false

    private var detailText: String? {
        if let feedback { return feedback.text }
        return selected.map { "\($0.subtitle) · \($0.status.displayName)" }
    }

    var body: some View {
        HStack(spacing: 10) {
            if let selected {
                Circle()
                    .fill(selected.status.dotColor)
                    .frame(width: 9, height: 9)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(selected?.title ?? "Choose a TV")
                    .font(.headline)
                    .foregroundStyle(.primary)
                if let detailText {
                    Text(detailText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            if feedback == .scanning {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.default, value: feedback)
    }
}

/// The open TV menu: the card grown into a panel with the TV list and the TV actions.
struct TVMenuPanel: View {
    var onClose: () -> Void
    var onDetails: (TVID) -> Void
    var onRename: (TVID) -> Void
    var onForget: (TVID) -> Void
    var onAddTV: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    private var selected: TVListItem? { model.tvs.first { $0.id == model.selectedID } }
    private var isScanning: Bool { model.scanFeedback == .scanning }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onClose) {
                TVCardLabel(selected: selected, feedback: model.scanFeedback, isOpen: true)
                    .contentShape(Rectangle())
            }
            .buttonStyle(MenuRowStyle())
            .accessibilityLabel("Close menu")
            .accessibilityValue(selected.map { "\($0.title), \($0.status.displayName)" } ?? "No TV selected")

            ViewThatFits(in: .vertical) {
                items
                ScrollView { items }
            }
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.remoteCard))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, onClose)
    }

    private var items: some View {
        VStack(spacing: 0) {
            if !model.tvs.isEmpty {
                divider
                ForEach(model.tvs) { tv in
                    tvRow(tv)
                }
            }
            divider
            if let id = model.selectedID {
                row("TV Details", systemImage: "info.circle") { onDetails(id) }
                row("Rename…", systemImage: "pencil") { onRename(id) }
                row("Forget…", systemImage: "trash", role: .destructive) { onForget(id) }
            }
            row("Add TV by IP Address…", systemImage: "plus") { onAddTV() }
            scanRow
            divider
            row("Send Feedback or Report a Bug", systemImage: "exclamationmark.bubble",
                trailing: "arrow.up.right") {
                onClose()
                openURL(AppLinks.issues)
            }
        }
    }

    private var divider: some View {
        Divider().padding(.leading, 16)
    }

    private func tvRow(_ tv: TVListItem) -> some View {
        Button {
            model.select(tv.id)
            onClose()
        } label: {
            HStack(spacing: 12) {
                Circle().fill(tv.status.dotColor).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tv.title).font(.body).foregroundStyle(.primary)
                    Text("\(tv.subtitle) · \(tv.status.displayName)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if tv.id == model.selectedID {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(tv.title), \(tv.status.displayName)")
        .accessibilityAddTraits(tv.id == model.selectedID ? [.isButton, .isSelected] : .isButton)
    }

    private var scanRow: some View {
        Button {
            model.scanAgain() // the menu stays open, so new TVs appear in the list above
        } label: {
            HStack(spacing: 12) {
                Group {
                    if isScanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .frame(width: 24)
                Text(isScanning ? "Scanning…" : "Scan Again")
                Spacer(minLength: 8)
            }
            .rowPadding()
        }
        .buttonStyle(MenuRowStyle())
        .disabled(isScanning)
        .foregroundStyle(isScanning ? .secondary : .primary)
    }

    private func row(_ title: String, systemImage: String, role: ButtonRole? = nil, trailing: String? = nil,
                     action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage).frame(width: 24)
                Text(title)
                Spacer(minLength: 8)
                if let trailing {
                    Image(systemName: trailing)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .rowPadding()
        }
        .buttonStyle(MenuRowStyle())
        .foregroundStyle(role == .destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
        .accessibilityLabel(title)
    }
}

private extension View {
    func rowPadding() -> some View {
        padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}

/// Highlights a menu row while pressed.
struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.remoteKey : .clear)
    }
}

/// Dims the screen behind the open TV menu and places the menu over the TV card.
struct TVMenuOverlay: ViewModifier {
    @Binding var isOpen: Bool
    var onDetails: (TVID) -> Void
    var onRename: (TVID) -> Void
    var onForget: (TVID) -> Void
    var onAddTV: () -> Void

    func body(content: Content) -> some View {
        content
            .environment(\.openTVMenu, { withAnimation(.snappy(duration: 0.25)) { isOpen = true } })
            .overlayPreferenceValue(TVCardBoundsKey.self) { anchor in
                GeometryReader { proxy in
                    if isOpen, let anchor {
                        let card = proxy[anchor]
                        ZStack(alignment: .topLeading) {
                            Color.black.opacity(0.3)
                                .ignoresSafeArea()
                                .onTapGesture(perform: close)
                                .accessibilityHidden(true)
                                .transition(.opacity)
                            TVMenuPanel(
                                onClose: close,
                                onDetails: { id in close(); onDetails(id) },
                                onRename: { id in close(); onRename(id) },
                                onForget: { id in close(); onForget(id) },
                                onAddTV: { close(); onAddTV() }
                            )
                            .frame(width: card.width)
                            .frame(maxHeight: max(card.height, proxy.size.height - card.minY - 12), alignment: .top)
                            .fixedSize(horizontal: false, vertical: true)
                            .offset(x: card.minX, y: card.minY)
                            .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
                        }
                    }
                }
            }
    }

    private func close() {
        withAnimation(.snappy(duration: 0.2)) { isOpen = false }
    }
}

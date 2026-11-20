import SamsungTVKit
import SwiftUI

enum AppLinks {
    /// Where users send feedback and report bugs.
    static let issues = URL(string: "https://github.com/guilhermechapiewski/samsung-free-remote-ios-app/issues")!
    /// The app's privacy policy (App Review 5.1.1(i) requires it to be reachable in the app).
    static let privacyPolicy = URL(string: "https://guilhermechapiewski.github.io/samsung-free-remote-ios-app/privacy/")!
}

/// Opens the TV menu over the screen. Equatable so SwiftUI can tell it has not changed (a bare closure
/// would make every reader update whenever the root view does): the action is the same for the life
/// of the screen, so any two values are equal.
struct OpenTVMenuAction: Equatable {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) { self.action = action }

    func callAsFunction() { action() }

    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

extension EnvironmentValues {
    /// Set by `RootView` (through `TVMenuOverlay`); nil in previews.
    @Entry var openTVMenu: OpenTVMenuAction?
    /// The TV menu is open (the TV card takes VoiceOver focus back when it closes).
    @Entry var isTVMenuOpen = false
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
    @AccessibilityFocusState private var headerFocused: Bool

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
            .accessibilityFocused($headerFocused)

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
        .onAppear { headerFocused = true }
    }

    /// Feedback row title; short enough to stay on one line at the default text size.
    static let feedbackTitle = "Feedback & Bug Reports"

    /// TVs are tiles (like the choose-your-TV screen) under a "Your TVs" label; actions are plain rows
    /// with icons below them, so the two kinds read differently at a glance.
    private var items: some View {
        VStack(spacing: 0) {
            if !model.tvs.isEmpty {
                Divider()
                Text("Your TVs")
                    .font(.footnote.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .accessibilityAddTraits(.isHeader)
                VStack(spacing: 6) {
                    ForEach(model.tvs) { tv in
                        tvTile(tv)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            Divider()
            if let id = model.selectedID {
                row("TV Details", systemImage: "info.circle") { onDetails(id) }
                row("Rename…", systemImage: "pencil") { onRename(id) }
                row("Forget…", systemImage: "trash", role: .destructive) { onForget(id) }
            }
            row("Add TV by IP Address…", systemImage: "plus") { onAddTV() }
            scanRow
            divider
            row(Self.feedbackTitle, systemImage: "exclamationmark.bubble",
                trailing: "arrow.up.right") {
                onClose()
                openURL(AppLinks.issues)
            }
            row("Privacy Policy", systemImage: "hand.raised", trailing: "arrow.up.right") {
                onClose()
                openURL(AppLinks.privacyPolicy)
            }
        }
    }

    private var divider: some View {
        Divider().padding(.leading, 16)
    }

    private func tvTile(_ tv: TVListItem) -> some View {
        let isSelected = tv.id == model.selectedID
        return Button {
            model.select(tv.id)
            onClose()
        } label: {
            HStack(spacing: 12) {
                Circle().fill(tv.status.dotColor).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tv.title).font(.headline).foregroundStyle(.primary)
                    Text("\(tv.subtitle) · \(tv.status.displayName)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(TVTileStyle(isSelected: isSelected))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(tv.title), \(tv.status.displayName)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
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

/// A TV in the menu: a filled tile, outlined when it is the selected TV, darker while pressed.
struct TVTileStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        configuration.label
            .background(shape.fill(configuration.isPressed ? Color.remoteOK : Color.remoteKey))
            .overlay(shape.strokeBorder(.tint, lineWidth: isSelected ? 1.5 : 0))
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
            .environment(\.openTVMenu, OpenTVMenuAction { withAnimation(.snappy(duration: 0.25)) { isOpen = true } })
            .environment(\.isTVMenuOpen, isOpen)
            .overlayPreferenceValue(TVCardBoundsKey.self) { anchor in
                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) {
                        // Separate `if`s, so each part gets its own transition.
                        if isOpen, anchor != nil {
                            Color.black.opacity(0.3)
                                .ignoresSafeArea()
                                .onTapGesture(perform: close)
                                .accessibilityHidden(true)
                                .transition(.opacity)
                        }
                        if isOpen, let anchor {
                            let card = proxy[anchor]
                            // A card scrolled partly off screen still opens the menu fully on screen.
                            let top = max(card.minY, 0)
                            TVMenuPanel(
                                onClose: close,
                                onDetails: { id in close(); onDetails(id) },
                                onRename: { id in close(); onRename(id) },
                                onForget: { id in close(); onForget(id) },
                                onAddTV: { close(); onAddTV() }
                            )
                            .frame(width: card.width)
                            // A real height limit, so the panel scrolls when its rows don't fit.
                            .frame(maxHeight: max(card.height, proxy.size.height - top - 12), alignment: .top)
                            .offset(x: card.minX, y: top)
                            .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
    }

    private func close() {
        withAnimation(.snappy(duration: 0.2)) { isOpen = false }
    }
}

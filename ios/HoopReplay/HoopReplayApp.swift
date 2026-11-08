import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    static var supportedOrientations: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.supportedOrientations
    }
}

/// Orientation is a hard rule that ignores the device's auto-rotate setting: the live score/record
/// screens are locked to landscape, every other page is locked to portrait.
enum OrientationLock {
    static func set(_ mask: UIInterfaceOrientationMask, preferred: UIInterfaceOrientation? = nil) {
        AppDelegate.supportedOrientations = mask
        apply(mask, preferred: preferred)
        // requestGeometryUpdate fails silently while a transition is running, so apply again once it settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { apply(mask, preferred: preferred) }
    }

    private static func apply(_ mask: UIInterfaceOrientationMask, preferred: UIInterfaceOrientation?) {
        guard AppDelegate.supportedOrientations == mask,
              let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        let target = preferred.map { UIInterfaceOrientationMask(rawValue: 1 << $0.rawValue) } ?? mask
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: target))
    }
}

@main
struct HoopReplayApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store)
        }
    }
}

// MARK: - Theme (the Android colour scheme and Material 3 type scale)

extension Color {
    init(hex: UInt32) {
        let alpha = hex > 0xFFFFFF ? Double((hex >> 24) & 0xFF) / 255 : 1
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

enum Theme {
    static let orange = Color(hex: 0xFF7A00)
    static let ink = Color(hex: 0x0B0F14)
    static let appBackground = Color(hex: 0xF5F6F8)
    static let scoreboardBackground = Color(hex: 0x4D1A1C20)
    static let madeGreen = Color(hex: 0x16A36D)
    static let missRed = Color(hex: 0xD63B52)
    static let freeThrowOrange = Color(hex: 0xC75B00)
    static let exitRed = Color(hex: 0xB3261E)
    // Disabled toolbar buttons keep their normal border and only gray the label.
    static let disabledLabel = Color(hex: 0x8F969F)
    static let panel = Color.white
    static let card = Color.white
    static let secondaryText = Color(hex: 0x5F6670)
    static let error = Color(hex: 0xB3261E)
    static let outline = Color(hex: 0x79747E)
    static let divider = Color(hex: 0xCAC4D0)
    static let keyboard = Color(hex: 0xF0F1F3)
}

enum Fonts {
    static let displayMedium = Font.system(size: 45)
    static let headlineMedium = Font.system(size: 28)
    static let headlineSmall = Font.system(size: 24)
    static let titleLarge = Font.system(size: 22)
    static let titleMedium = Font.system(size: 16, weight: .medium)
    static let titleSmall = Font.system(size: 14, weight: .medium)
    static let bodyLarge = Font.system(size: 16)
    static let bodyMedium = Font.system(size: 14)
    static let bodySmall = Font.system(size: 12)
    static let labelLarge = Font.system(size: 14, weight: .medium)
    static let labelMedium = Font.system(size: 12, weight: .medium)
    static let labelSmall = Font.system(size: 11, weight: .medium)
}

// Computed so the labels follow the interface language; the root view rebuilds on a language change.
var videoQualityOptions: [(key: String, label: String)] { [("HIGHEST", t("Device maximum")), ("UHD", t("4K · Largest file")), ("FHD", t("1080p · Recommended")), ("HD", t("720p · Smaller file")), ("SD", t("480p · Smallest file"))] }

// MARK: - Material-style controls shared by every screen

/// Filled button (Material `Button`): orange pill with white label.
struct MButton<Label: View>: View {
    var enabled = true
    var container: Color = Theme.orange
    var content: Color = .white
    var height: CGFloat = 40
    var horizontalPadding: CGFloat = 24
    var fullWidth = false
    let action: () -> Void
    @ViewBuilder var label: Label
    var body: some View {
        Button(action: action) {
            label
                .font(Fonts.labelLarge)
                .lineLimit(1)
                .padding(.horizontal, horizontalPadding)
                .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height, maxHeight: height)
                .foregroundStyle(enabled ? content : Theme.disabledLabel)
                .background(Capsule().fill(enabled ? container : Color(hex: 0x1F1F1F).opacity(0.12)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

extension MButton where Label == Text {
    init(_ title: String, enabled: Bool = true, container: Color = Theme.orange, content: Color = .white, height: CGFloat = 40, horizontalPadding: CGFloat = 24, fullWidth: Bool = false, action: @escaping () -> Void) {
        self.init(enabled: enabled, container: container, content: content, height: height, horizontalPadding: horizontalPadding, fullWidth: fullWidth, action: action) { Text(title) }
    }
}

/// Outlined button (Material `OutlinedButton`): pill outline; the border never changes when disabled.
struct MOutlinedButton<Label: View>: View {
    var enabled = true
    var container: Color = .clear
    var content: Color = Theme.orange
    var border: Color = Theme.outline
    var borderWidth: CGFloat = 1
    var height: CGFloat = 40
    var horizontalPadding: CGFloat = 24
    var fullWidth = false
    var font: Font = Fonts.labelLarge
    let action: () -> Void
    @ViewBuilder var label: Label
    var body: some View {
        Button(action: action) {
            label
                .font(font)
                .lineLimit(1)
                .padding(.horizontal, horizontalPadding)
                .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height, maxHeight: height)
                .foregroundStyle(enabled ? content : Theme.disabledLabel)
                .background(Capsule().fill(container))
                .overlay(Capsule().strokeBorder(border, lineWidth: borderWidth))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

extension MOutlinedButton where Label == Text {
    init(_ title: String, enabled: Bool = true, container: Color = .clear, content: Color = Theme.orange, border: Color = Theme.outline, borderWidth: CGFloat = 1, height: CGFloat = 40, horizontalPadding: CGFloat = 24, fullWidth: Bool = false, font: Font = Fonts.labelLarge, action: @escaping () -> Void) {
        self.init(enabled: enabled, container: container, content: content, border: border, borderWidth: borderWidth, height: height, horizontalPadding: horizontalPadding, fullWidth: fullWidth, font: font, action: action) { Text(title) }
    }
}

/// Text button (Material `TextButton`): orange label, no frame.
struct MTextButton: View {
    let title: String
    var color: Color = Theme.orange
    var font: Font = Fonts.labelLarge
    var enabled = true
    var minSize: CGFloat = 40
    var horizontalPadding: CGFloat = 12
    let action: () -> Void
    init(_ title: String, color: Color = Theme.orange, font: Font = Fonts.labelLarge, enabled: Bool = true, minSize: CGFloat = 40, horizontalPadding: CGFloat = 12, action: @escaping () -> Void) {
        self.title = title; self.color = color; self.font = font; self.enabled = enabled; self.minSize = minSize; self.horizontalPadding = horizontalPadding; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Text(title).font(font).lineLimit(1).fixedSize(horizontal: true, vertical: false).foregroundStyle(enabled ? color : Theme.disabledLabel)
                .padding(.horizontal, horizontalPadding).frame(minWidth: minSize, minHeight: minSize)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// Material `Card`: white rounded surface on the grey page background.
struct MCard<Content: View>: View {
    var padding: CGFloat = 0
    var action: (() -> Void)? = nil
    @ViewBuilder var content: Content
    var body: some View {
        let card = content.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        if let action { Button(action: action) { card }.buttonStyle(.plain) } else { card }
    }
}

/// Material `OutlinedTextField`: a boxed field with a floating label once the field holds text.
struct MTextField: View {
    var label: String? = nil
    var placeholder: String = ""
    @Binding var text: String
    var leadingIcon: String? = nil
    var trailing: AnyView? = nil
    var keyboard: UIKeyboardType = .default
    var secure = false
    var autocapitalize = true
    var onChange: ((String) -> String)? = nil
    var identifier: String? = nil
    var body: some View {
        HStack(spacing: 10) {
            if let leadingIcon { Image(systemName: leadingIcon).foregroundStyle(Theme.secondaryText) }
            VStack(alignment: .leading, spacing: 2) {
                if let label, !text.isEmpty { Text(label).font(Fonts.bodySmall).foregroundStyle(Theme.secondaryText) }
                Group {
                    if secure { SecureField(label ?? placeholder, text: $text) } else { TextField(text.isEmpty ? (placeholder.isEmpty ? (label ?? "") : placeholder) : "", text: $text) }
                }
                .font(Fonts.bodyLarge)
                .accessibilityIdentifier(identifier ?? "")
                .textInputAutocapitalization(autocapitalize ? .words : .never)
                .autocorrectionDisabled()
                .keyboardType(keyboard)
                .onChange(of: text) { _, value in if let onChange { let changed = onChange(value); if changed != value { text = changed } } }
            }
            if let trailing { trailing }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 56)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.outline, lineWidth: 1))
    }
}

/// Material `TabRow`: equal tabs with an orange indicator under the selected one.
struct MTabRow: View {
    let labels: [String]
    let selected: Int
    var containerColor: Color = Theme.card
    var contentColor: Color = Theme.orange
    var tintSelected = false
    var selectedFont: Font = Fonts.titleSmall
    var unselectedFont: Font = Fonts.titleSmall
    var unselectedColor: Color? = nil
    var height: CGFloat = 48
    let onSelect: (Int) -> Void
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                let isSelected = index == selected
                Button { onSelect(index) } label: {
                    VStack(spacing: 0) {
                        Text(label).font(isSelected ? selectedFont : unselectedFont).lineLimit(1).minimumScaleFactor(0.7)
                            .foregroundStyle(isSelected ? contentColor : (unselectedColor ?? contentColor))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Rectangle().fill(isSelected ? contentColor : .clear).frame(height: 3)
                    }
                    .background(tintSelected && isSelected ? contentColor.opacity(0.16) : .clear)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: height)
        .background(containerColor)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }
}

/// Material `FilterChip`.
struct MFilterChip: View {
    let label: String
    let selected: Bool
    var height: CGFloat = 32
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if selected { Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)) }
                Text(label).font(Fonts.labelLarge).lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: height, maxHeight: height)
            .foregroundStyle(Theme.ink)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.orange.opacity(0.2) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? .clear : Theme.outline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Material `TopAppBar`: 64pt bar with an optional leading control, title, and trailing actions.
struct MTopAppBar<Leading: View, Actions: View>: View {
    let title: String
    @ViewBuilder var leading: Leading
    @ViewBuilder var actions: Actions
    var body: some View {
        HStack(spacing: 4) {
            leading
            Text(title).font(Fonts.titleLarge).foregroundStyle(Theme.ink).lineLimit(1)
            Spacer(minLength: 8)
            actions
        }
        .padding(.horizontal, 4)
        .frame(height: 64)
        .background(Theme.card)
    }
}

struct BackButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left").font(.system(size: 18, weight: .medium)).foregroundStyle(Theme.orange)
                Text(t("Back")).font(Fonts.titleMedium).foregroundStyle(Theme.orange)
            }
            .padding(.leading, 8).padding(.trailing, 12).frame(minHeight: 40)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("BackButton")
    }
}

/// Underlined orange team name that opens the team's player list.
struct TeamNameLink: View {
    let name: String
    var font: Font = Fonts.titleMedium
    var maxLines = 2
    var alignment: TextAlignment = .center
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(name).font(font).underline().foregroundStyle(Theme.orange).multilineTextAlignment(alignment).lineLimit(maxLines).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Popups

/// Every popup keeps the same gap to all four screen edges; content scrolls inside that frame.
let dialogScreenMargin: CGFloat = 20
/// The jersey-number pad covers 95% of the screen's shorter side, margins equal on all edges.
let numberPadMarginFraction: CGFloat = 0.025

/// A full-screen scrim with the popup frame inset by one uniform margin on every side: the base
/// margin, widened to clear the largest system inset so a popup never sits under system UI.
struct ScreenDialog<Content: View>: View {
    var onDismiss: () -> Void
    var fullScreen = false
    var marginFraction: CGFloat? = nil
    var dismissOnScrim = true
    @ViewBuilder var content: Content
    var body: some View {
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            let margin: CGFloat = fullScreen ? 0 : marginFraction.map { min(proxy.size.width, proxy.size.height) * $0 } ?? max(dialogScreenMargin, insets.top, insets.bottom, insets.leading, insets.trailing)
            ZStack {
                Color.black.opacity(0.45).contentShape(Rectangle()).onTapGesture { if dismissOnScrim { onDismiss() } }
                content.padding(margin)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .transition(.opacity)
    }
}

/// Material `AlertDialog`: a centred card with a title, body content, and right-aligned buttons.
struct AlertPanel<Content: View, Buttons: View>: View {
    var title: String
    var onDismiss: () -> Void
    var dismissOnScrim = true
    @ViewBuilder var content: Content
    @ViewBuilder var buttons: Buttons
    var body: some View {
        ScreenDialog(onDismiss: onDismiss, dismissOnScrim: dismissOnScrim) {
            VStack(alignment: .leading, spacing: 16) {
                Text(title).font(Fonts.headlineSmall).foregroundStyle(Theme.ink)
                content.font(Fonts.bodyMedium).foregroundStyle(Theme.secondaryText)
                HStack(spacing: 8) { Spacer(); buttons }
            }
            .padding(24)
            .frame(minWidth: 280, maxWidth: 560)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 28))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The equivalent of an Android Toast: a short message near the bottom of the screen.
struct ToastView: View {
    let message: String
    var body: some View {
        Text(message).font(Fonts.bodyMedium).foregroundStyle(.white)
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(Color(hex: 0x323232), in: Capsule())
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}

/// Lays out children side by side with proportional widths, like Compose `Modifier.weight`.
struct WeightedRow<Content: View>: View {
    let weights: [CGFloat]
    var spacing: CGFloat = 8
    @ViewBuilder var content: (Int, CGFloat) -> Content
    var body: some View {
        GeometryReader { proxy in
            let total = weights.reduce(0, +)
            let available = proxy.size.width - spacing * CGFloat(max(0, weights.count - 1))
            HStack(spacing: spacing) {
                ForEach(Array(weights.enumerated()), id: \.offset) { index, weight in
                    content(index, available * weight / total).frame(width: available * weight / total)
                }
            }
        }
    }
}

// MARK: - Root navigation

indirect enum Page: Hashable {
    case home
    case playerList(teamId: RowID, back: Page)
    case playerDetail(teamId: RowID, playerId: RowID, back: Page)
    case gameForm(RowID?)
    case gameDetail(RowID)
    case record(RowID)
    case score(RowID)

    var landscape: Bool { if case .record = self { return true }; if case .score = self { return true }; return false }
}

enum HomeTab: CaseIterable {
    case home, games, teams, settings
    var key: String { switch self { case .home: return "home"; case .games: return "games"; case .teams: return "teams"; case .settings: return "settings" } }
    var label: String { switch self { case .home: return "Home"; case .games: return "Games"; case .teams: return "Teams"; case .settings: return "Settings" } }
    var icon: String { switch self { case .home: return "house.fill"; case .games: return "basketball.fill"; case .teams: return "person.3.fill"; case .settings: return "gearshape.fill" } }
}

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @State private var page: Page = .home
    @State private var tab: HomeTab = .home
    @StateObject private var i18n = I18n.shared

    var body: some View {
        ZStack {
            Theme.appBackground.ignoresSafeArea()
            switch page {
            case .home:
                MainShell(tab: tab, language: i18n.language, onLanguage: { I18n.shared.set($0) }, onTab: { tab = $0 }, onGame: { page = .gameForm(nil) }, onOpen: { page = .gameDetail($0) }, onOpenTeam: { page = .playerList(teamId: $0, back: .home) })
            case let .playerList(teamId, back):
                if let team = store.team(teamId) {
                    PlayerListScreen(team: team, onBack: { page = back }, onTeamDeleted: { page = back }, onPlayer: { page = .playerDetail(teamId: team.id, playerId: $0, back: page) })
                } else { Color.clear.onAppear { page = back } }
            case let .playerDetail(teamId, playerId, back):
                if let team = store.team(teamId), let player = store.player(playerId) {
                    PlayerDetailScreen(team: team, player: player, onBack: { page = back }, onDeleted: { page = back })
                } else { Color.clear.onAppear { page = back } }
            case let .gameForm(id):
                GameForm(onDone: { page = id.map(Page.gameDetail) ?? .home }, initialGame: id.flatMap { store.game($0) })
            case let .gameDetail(id):
                if let game = store.game(id) {
                    GameDetailScreen(initialGame: game, onBack: { page = .home }, onRecord: { page = .record(game.id) }, onScore: { page = .score(game.id) }, onDeleted: { page = .home }, onEdit: { page = .gameForm(game.id) }, onOpenTeam: { page = .playerList(teamId: $0, back: .gameDetail(game.id)) })
                } else { Color.clear.onAppear { page = .home } }
            case let .record(id):
                if let game = store.game(id) {
                    RecorderScreen(initial: game, scoreOnly: false, onOpenTeam: { page = .playerList(teamId: $0, back: .record(id)) }, onDone: { page = .gameDetail(id) })
                } else { Color.clear.onAppear { page = .home } }
            case let .score(id):
                if let game = store.game(id) {
                    RecorderScreen(initial: game, scoreOnly: true, onOpenTeam: { page = .playerList(teamId: $0, back: .score(id)) }, onDone: { page = .gameDetail(id) })
                } else { Color.clear.onAppear { page = .home } }
            }
            if let toast = store.toast { ToastView(message: toast) }
        }
        // Every view calls t() without observing I18n; rebuilding the tree on a language change refreshes them all.
        .id(i18n.language)
        .preferredColorScheme(.light)
        .tint(Theme.orange)
        .onAppear { applyOrientation() }
        .onChange(of: page) { _, _ in applyOrientation() }
    }

    /// Re-applied on every page change so a screen that rotated temporarily (full-screen statistics)
    /// can never leave the next page in the wrong orientation.
    private func applyOrientation() {
        if page.landscape { OrientationLock.set(.landscape, preferred: .landscapeRight) } else { OrientationLock.set(.portrait, preferred: .portrait) }
    }
}

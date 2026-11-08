import AuthenticationServices
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

// Home shell, team and player management, and the create-game form: the portrait screens of the
// Android MainActivity, one for one.

/// Name to greet the account by: a readable form of its email.
func accountLabel(_ email: String) -> String {
    let local = String(email.split(separator: "@").first ?? "")
    if local.isBlank { return t("Coach") }
    return local.split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" }).filter { !$0.isEmpty }.map { String($0).capitalizeInitial() }.joined(separator: " ")
}
func accountInitials(_ name: String) -> String {
    let initials = name.trimmed.split(separator: " ").filter { !$0.isEmpty }.prefix(2).map { String($0.first!).uppercased() }.joined()
    return initials.isEmpty ? "?" : initials
}

struct SettingsRow: View {
    let label: String; let value: String
    var body: some View {
        HStack {
            Text(label).font(Fonts.bodyMedium).foregroundStyle(Theme.secondaryText)
            Spacer()
            Text(value).font(Fonts.bodyMedium).foregroundStyle(Theme.ink).lineLimit(1)
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct ShareItem: Identifiable { let url: URL; var id: URL { url } }

// MARK: - Main shell

struct MainShell: View {
    @EnvironmentObject private var store: AppStore
    let tab: HomeTab
    let language: AppLanguage
    let onLanguage: (AppLanguage) -> Void
    let onTab: (HomeTab) -> Void
    let onGame: () -> Void
    let onOpen: (Int64) -> Void
    let onOpenTeam: (Int64) -> Void

    @State private var query = ""
    @State private var syncing = false
    @State private var syncMessage: String?
    @State private var showAuth = false
    @State private var showAccount = false
    @State private var email = HoopSync.signedInEmail
    @State private var password = HoopSync.rememberedPassword
    @State private var passwordVisible = false
    @State private var signUp = false
    /// The raw nonce of the Sign in with Apple request in flight; its SHA-256 goes to Apple.
    @State private var appleNonce = ""
    @State private var signedIn = HoopSync.isSignedIn
    @State private var uploadChoice = VideoUpload.uploadRecordings
    @State private var showImporter = false
    @State private var showDeleteAccount = false
    @State private var deletingAccount = false
    @State private var playerSort = savedPlayerSort()

    private var games: [Game] { store.games() }
    private var teams: [Team] { store.teams() }
    private var playerCount: Int { teams.reduce(0) { $0 + store.players($1.id).count } }
    private var shown: [Game] {
        let q = query.trimmed
        return q.isEmpty ? games : games.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.homeName.localizedCaseInsensitiveContains(q) || $0.awayName.localizedCaseInsensitiveContains(q) }
    }
    private var accountEmail: String { signedIn ? HoopSync.signedInEmail : "" }
    private var accountName: String { signedIn && !HoopSync.signedInName.isBlank ? HoopSync.signedInName : accountLabel(accountEmail) }
    private func messageColor(_ text: String) -> Color { text.hasSuffix("complete") || text.hasPrefix("Imported") ? Theme.orange : Theme.error }

    private func runSync(_ label: String, _ work: @escaping () async throws -> Void) {
        if !HoopSync.configured { syncMessage = "Add Supabase URL, publishable key, and sync space to the build settings"; return }
        if !HoopSync.isSignedIn { showAuth = true; return }
        syncing = true
        Task {
            do { try await work(); syncMessage = "\(label) complete" }
            catch {
                // A refused refresh-token exchange clears the stored session; mirror that here so
                // the account controls recover immediately.
                signedIn = HoopSync.isSignedIn
                syncMessage = "\(label) failed: \(error.localizedDescription)"
            }
            syncing = false
        }
    }
    private func signOut() { HoopSync.signOut(); signedIn = false; syncMessage = "Signed out" }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                topBar
                Group {
                    switch tab {
                    case .home: homeTab
                    case .games: gamesTab
                    case .teams: TeamsTab(onOpen: onOpenTeam)
                    case .settings: settingsTab
                    }
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                bottomBar
            }
            .background(Theme.appBackground)
            .overlay(alignment: .bottomTrailing) {
                if tab == .games { MButton(t("Create Game"), enabled: teams.count >= 2, action: onGame).padding(.trailing, 16).padding(.bottom, 96) }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json, .plainText, .data]) { result in
                switch result {
                case .success(let url):
                    do { let summary = try store.importGameJsonFile(url); syncMessage = "Imported \(summary.events) plays, \(summary.createdTeams) new teams, \(summary.createdPlayers) new players" }
                    catch { syncMessage = "Import failed: \(error.localizedDescription)" }
                case .failure(let error): syncMessage = "Import failed: \(error.localizedDescription)"
                }
            }
            if showAccount { accountMenu }
            if showAuth { authDialog }
            if showDeleteAccount { deleteAccountDialog }
            if syncing {
                Color.black.opacity(0.16).ignoresSafeArea()
                HStack(spacing: 12) { ProgressView().tint(Theme.orange); Text(t("Syncing…")).font(Fonts.bodyLarge).foregroundStyle(Theme.ink) }
                    .padding(.horizontal, 24).padding(.vertical, 18).background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var topBar: some View {
        MTopAppBar(title: "HoopReplay") { Spacer().frame(width: 12) } actions: {
            if signedIn {
                Button { showAccount = true } label: { avatar(accountName, size: 38) }.buttonStyle(.plain).padding(.trailing, 8).accessibilityIdentifier("account-button")
            } else {
                MTextButton(t("Sign in")) { showAuth = true }
            }
        }
    }

    private func avatar(_ name: String, size: CGFloat) -> some View {
        Text(accountInitials(name)).font(Fonts.labelLarge).foregroundStyle(.white).frame(width: size, height: size).background(Circle().fill(Theme.orange))
    }

    private var accountMenu: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.001).ignoresSafeArea().onTapGesture { showAccount = false }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    avatar(accountName, size: 40)
                    VStack(alignment: .leading) { Text(accountName).font(Fonts.titleSmall).foregroundStyle(Theme.ink); Text(accountEmail).font(Fonts.bodySmall).foregroundStyle(Theme.secondaryText) }
                }.padding(.horizontal, 16).padding(.vertical, 10)
                Divider()
                menuItem(t("Account settings"), icon: "person.fill") { showAccount = false; onTab(.settings) }
                menuItem(t("Sync status"), icon: "icloud") { showAccount = false; onTab(.settings) }
                Divider()
                Button { showAccount = false; signOut() } label: {
                    HStack(spacing: 12) { Image(systemName: "rectangle.portrait.and.arrow.right").foregroundStyle(Theme.error); Text(t("Sign out")).font(Fonts.bodyLarge).foregroundStyle(Theme.error); Spacer() }
                        .padding(.horizontal, 16).frame(height: 48)
                }.buttonStyle(.plain)
            }
            .frame(width: 280)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 4))
            .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
            .padding(.top, 56).padding(.trailing, 8)
        }
    }
    private func menuItem(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) { Image(systemName: icon).foregroundStyle(Theme.ink); Text(title).font(Fonts.bodyLarge).foregroundStyle(Theme.ink); Spacer(); Image(systemName: "chevron.right").foregroundStyle(Theme.ink) }
                .padding(.horizontal, 16).frame(height: 48)
        }.buttonStyle(.plain)
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            ForEach(HomeTab.allCases, id: \.self) { entry in
                Button { onTab(entry) } label: {
                    VStack(spacing: 4) {
                        Image(systemName: entry.icon).font(.system(size: 22))
                        Text(t(entry.label)).font(Fonts.labelMedium)
                    }
                    .foregroundStyle(tab == entry ? Theme.orange : Theme.secondaryText)
                    .frame(maxWidth: .infinity).frame(height: 80)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tab-\(entry.key)")
                .accessibilityLabel(t(entry.label))
            }
        }
        .background(Color.white)
    }

    private var homeTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Spacer().frame(height: 12)
                Text(signedIn ? t("Welcome back, {name}", ["name": accountName]) : t("Welcome back")).font(Fonts.headlineMedium).foregroundStyle(Theme.ink)
                Text(t("Every game leaves a trail.")).font(Fonts.bodyLarge).foregroundStyle(Theme.secondaryText)
                Spacer().frame(height: 16)
                HStack(spacing: 12) {
                    MCard(padding: 16, action: { onTab(.teams) }) {
                        HStack(spacing: 12) { Image(systemName: "person.3.fill").font(.system(size: 24)).foregroundStyle(Theme.orange); VStack(alignment: .leading) { Text("\(teams.count)").font(Fonts.headlineSmall).foregroundStyle(Theme.ink); Text(t("Teams")).font(Fonts.bodyMedium).foregroundStyle(Theme.secondaryText) } }
                    }
                    MCard(padding: 16, action: { onTab(.teams) }) {
                        HStack(spacing: 12) { Image(systemName: "person.fill").font(.system(size: 24)).foregroundStyle(Theme.orange); VStack(alignment: .leading) { Text("\(playerCount)").font(Fonts.headlineSmall).foregroundStyle(Theme.ink); Text(t("Players")).font(Fonts.bodyMedium).foregroundStyle(Theme.secondaryText) } }
                    }
                }
                Spacer().frame(height: 12)
                MCard(padding: 16) {
                    HStack(spacing: 12) {
                        Image(systemName: signedIn ? "checkmark.icloud.fill" : "icloud").font(.system(size: 24)).foregroundStyle(Theme.orange)
                        VStack(alignment: .leading) { Text(t("Cloud sync")).font(Fonts.titleMedium).lineLimit(1).minimumScaleFactor(0.7).foregroundStyle(Theme.ink); Text(signedIn ? t("Signed in") : t("Local only")).font(Fonts.bodySmall).foregroundStyle(Theme.secondaryText) }
                        Spacer()
                        MTextButton(syncing ? "…" : t("Download"), enabled: !syncing, horizontalPadding: 8) { runSync("Download") { try await HoopSync.pull(store) } }
                        MTextButton(syncing ? "…" : t("Upload"), enabled: !syncing, horizontalPadding: 8) { runSync("Upload") { try await HoopSync.push(store) } }
                    }
                }
                if let syncMessage { Text(t(syncMessage)).font(Fonts.bodySmall).foregroundStyle(messageColor(syncMessage)).padding(.top, 8) }
            }
        }
    }

    private var gamesTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 12)
            Text(t("Games")).font(Fonts.headlineSmall).foregroundStyle(Theme.ink)
            Spacer().frame(height: 12)
            MTextField(placeholder: t("Search games…"), text: $query, leadingIcon: "magnifyingglass", autocapitalize: false)
            Spacer().frame(height: 10)
            if shown.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "basketball.fill").font(.system(size: 64)).foregroundStyle(Theme.orange)
                    Text(query.isBlank ? t("No games yet") : t("No games found")).font(Fonts.titleLarge).foregroundStyle(Theme.ink)
                    Text(teams.count < 2 ? t("Add two teams first, then create your first game.") : t("Create your first game to start tracking highlights.")).font(Fonts.bodyLarge).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
                    MButton(teams.count < 2 ? t("Add teams") : "+  " + t("Create Game"), height: 48) { if teams.count < 2 { onTab(.teams) } else { onGame() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(shown) { g in
                            MCard(padding: 16, action: { onOpen(g.id) }) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(g.title).font(Fonts.titleMedium).foregroundStyle(Theme.ink)
                                    Text(formatGameDateTime(g.scheduledAt)).font(Fonts.bodyLarge).foregroundStyle(Theme.orange)
                                    // Plain text on purpose: a tappable team name inside the card was too easy to hit
                                    // when aiming for the game itself.
                                    HStack(spacing: 0) {
                                        Text(g.homeName).font(Fonts.bodyMedium).foregroundStyle(Theme.ink).lineLimit(1)
                                        Text("  \(g.homeScore) : \(g.awayScore)  ").font(Fonts.bodyLarge).foregroundStyle(Theme.secondaryText)
                                        Text(g.awayName).font(Fonts.bodyMedium).foregroundStyle(Theme.ink).lineLimit(1)
                                    }
                                    Text(t(g.status.titleCased)).font(Fonts.bodyLarge).foregroundStyle(Theme.orange)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 80)
                }
            }
        }
    }

    /// "1.0.19 (10019)": marketing version followed by the build number from Info.plist.
    private var appVersionLabel: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "—"
        let build = info["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    private var settingsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Spacer().frame(height: 0)
                Text(t("Settings")).font(Fonts.headlineSmall).foregroundStyle(Theme.ink)
                MCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(t("Interface Language")).font(Fonts.labelMedium).foregroundStyle(Theme.secondaryText)
                        ForEach(AppLanguage.allCases, id: \.self) { option in
                            Button { onLanguage(option) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: language == option ? "largecircle.fill.circle" : "circle").font(.system(size: 22)).foregroundStyle(language == option ? Theme.orange : Theme.secondaryText)
                                    Text(option.nativeName).font(Fonts.bodyLarge).foregroundStyle(Theme.ink)
                                    Spacer()
                                }.padding(.vertical, 8)
                            }.buttonStyle(.plain)
                        }
                    }
                }
                MCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(t("Player selection order")).font(Fonts.labelMedium).foregroundStyle(Theme.secondaryText)
                        Text(t("Choose how players are ordered in selection dialogs.")).font(Fonts.bodySmall).foregroundStyle(Theme.secondaryText)
                        ForEach(PlayerSort.allCases, id: \.self) { option in
                            Button { playerSort = option; savePlayerSort(option) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: playerSort == option ? "largecircle.fill.circle" : "circle").font(.system(size: 22)).foregroundStyle(playerSort == option ? Theme.orange : Theme.secondaryText)
                                    Text(t(option.label)).font(Fonts.bodyLarge).foregroundStyle(Theme.ink)
                                    Spacer()
                                }.padding(.vertical, 6)
                            }.buttonStyle(.plain)
                        }
                    }
                }
                MCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(t("Account")).font(Fonts.labelMedium).foregroundStyle(Theme.secondaryText)
                        if signedIn {
                            SettingsRow(label: t("Name"), value: accountName); SettingsRow(label: t("Email"), value: accountEmail)
                        } else {
                            Text(t("Sign in to sync games across mobile and Web.")).font(Fonts.bodyMedium).foregroundStyle(Theme.secondaryText)
                            MButton(t("Sign in")) { showAuth = true }
                        }
                    }
                }
                MCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(t("Sync")).font(Fonts.labelMedium).foregroundStyle(Theme.secondaryText)
                        SettingsRow(label: t("Status"), value: !HoopSync.configured ? t("Setup required") : signedIn ? t("Signed in") : t("Local only"))
                        if let syncMessage { Text(t(syncMessage)).font(Fonts.bodySmall).foregroundStyle(messageColor(syncMessage)) }
                        HStack(spacing: 12) {
                            MOutlinedButton(syncing ? "…" : t("Download"), enabled: !syncing, fullWidth: true) { runSync("Download") { try await HoopSync.pull(store) } }
                            MOutlinedButton(syncing ? "…" : t("Upload"), enabled: !syncing, fullWidth: true) { runSync("Upload") { try await HoopSync.push(store) } }
                        }
                    }
                }
                MCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(t("Upload recordings")).font(Fonts.labelMedium).foregroundStyle(Theme.secondaryText)
                        Text(t("Whole-game recordings upload to the cloud so highlights can be cut on HoopReplay Web.")).font(Fonts.bodyMedium).foregroundStyle(Theme.secondaryText)
                        HStack(spacing: 8) {
                            ForEach(UploadRecordings.allCases, id: \.self) { choice in
                                MFilterChip(label: t(choice.rawValue), selected: uploadChoice == choice) { uploadChoice = choice; VideoUpload.uploadRecordings = choice }
                            }
                        }
                    }
                }
                MCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(t("Import")).font(Fonts.labelMedium).foregroundStyle(Theme.secondaryText)
                        Text(t("Bring in a game exported as JSON from HoopReplay Web or another device. Missing teams and players are created automatically.")).font(Fonts.bodyMedium).foregroundStyle(Theme.secondaryText)
                        MButton(t("Choose JSON file")) { showImporter = true }
                        if let syncMessage { Text(t(syncMessage)).font(Fonts.bodySmall).foregroundStyle(syncMessage.hasPrefix("Imported") ? Theme.orange : Theme.error) }
                    }
                }
                MCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(t("Storage")).font(Fonts.labelMedium).foregroundStyle(Theme.secondaryText)
                        SettingsRow(label: t("Teams"), value: "\(teams.count)"); SettingsRow(label: t("Players"), value: "\(playerCount)"); SettingsRow(label: t("Games"), value: "\(games.count)")
                    }
                }
                if signedIn {
                    MCard(padding: 16) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(t("Account actions")).font(Fonts.labelMedium).foregroundStyle(Theme.secondaryText)
                            MButton(t("Sign out"), container: Theme.error) { signOut() }
                            MButton(t("Delete Account"), container: Theme.error) { showDeleteAccount = true }
                        }
                    }
                }
                // The installed build's version sits at the very bottom so support questions can
                // be answered from a screenshot of this screen.
                MCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(t("About")).font(Fonts.labelMedium).foregroundStyle(Theme.secondaryText)
                        SettingsRow(label: t("Version"), value: appVersionLabel)
                    }
                }
                Spacer().frame(height: 24)
            }
            .padding(.top, 12)
        }
    }

    private var deleteAccountDialog: some View {
        AlertPanel(title: t("Delete Account"), onDismiss: { if !deletingAccount { showDeleteAccount = false } }) {
            Text(t("This permanently deletes your sign-in account and all synced teams, players, games, videos, and statistics. This cannot be undone."))
                .font(Fonts.bodyMedium).foregroundStyle(Theme.ink)
        } buttons: {
            MButton(t("Cancel"), enabled: !deletingAccount) { showDeleteAccount = false }
            MButton(deletingAccount ? t("Deleting…") : t("Delete Account"), enabled: !deletingAccount, container: Theme.error) {
                deletingAccount = true
                Task {
                    do {
                        try await HoopSync.deleteAccount()
                        await store.clearAllAccountData()
                        signedIn = false; showDeleteAccount = false; deletingAccount = false; syncMessage = "Account deleted"
                    } catch {
                        await MainActor.run { deletingAccount = false; syncMessage = "Account deletion failed: \(error.localizedDescription)" }
                    }
                }
            }
        }
    }

    private static func randomNonce() -> String {
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        return String((0..<32).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    }

    /// Runs the browser Google sign-in, then syncs like a password sign-in does.
    private func signInWithGoogle() {
        syncMessage = nil
        Task {
            do {
                try await HoopSync.authenticateWithGoogle()
                syncing = true
                email = HoopSync.signedInEmail
                signedIn = true; showAuth = false; passwordVisible = false
                try await HoopSync.pull(store); try await HoopSync.push(store)
                syncMessage = "Sync complete"
            } catch SyncError.cancelled {
                // The user closed the browser sheet; nothing to report.
            } catch {
                syncMessage = "Sign in failed: \(error.localizedDescription)"
            }
            syncing = false
        }
    }

    /// Exchanges Apple's identity token for a sync session, then syncs like a password sign-in does.
    private func completeAppleSignIn(_ authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken, let token = String(data: tokenData, encoding: .utf8) else {
            syncMessage = "Sign in failed: Apple returned no identity token"; return
        }
        let fullName = [credential.fullName?.givenName, credential.fullName?.familyName].compactMap { $0 }.joined(separator: " ")
        syncing = true; syncMessage = nil
        Task {
            do {
                try await HoopSync.authenticateWithApple(identityToken: token, nonce: appleNonce, fullName: fullName)
                email = HoopSync.signedInEmail
                signedIn = true; showAuth = false; passwordVisible = false
                try await HoopSync.pull(store); try await HoopSync.push(store)
                syncMessage = "Sync complete"
            } catch {
                syncMessage = "Sign in failed: \(error.localizedDescription)"
            }
            syncing = false
        }
    }

    private var authDialog: some View {
        AlertPanel(title: signUp ? t("Create sync account") : t("Sign in to sync"), onDismiss: { showAuth = false; passwordVisible = false }) {
            VStack(alignment: .leading, spacing: 8) {
                Text(t("Games stay on this device until you choose to sync.")).foregroundStyle(.gray)
                GoogleSignInButton(enabled: !syncing) { signInWithGoogle() }
                SignInWithAppleButton(.signIn) { request in
                    appleNonce = Self.randomNonce()
                    request.requestedScopes = [.fullName, .email]
                    request.nonce = SHA256.hash(data: Data(appleNonce.utf8)).map { String(format: "%02x", $0) }.joined()
                } onCompletion: { result in
                    switch result {
                    case .success(let authorization): completeAppleSignIn(authorization)
                    case .failure(let error):
                        if (error as? ASAuthorizationError)?.code != .canceled { syncMessage = "Sign in failed: \(error.localizedDescription)" }
                    }
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 44)
                .disabled(syncing)
                HStack(spacing: 8) {
                    Rectangle().fill(Theme.outline).frame(height: 1)
                    Text(t("or use email")).font(Fonts.bodySmall).foregroundStyle(.gray)
                    Rectangle().fill(Theme.outline).frame(height: 1)
                }
                MTextField(label: t("Email"), text: $email, keyboard: .emailAddress, autocapitalize: false)
                MTextField(label: t("Password"), text: $password, trailing: AnyView(MTextButton(passwordVisible ? t("Hide") : t("Show"), horizontalPadding: 4) { passwordVisible.toggle() }), secure: !passwordVisible, autocapitalize: false)
                MTextButton(signUp ? t("Already have an account? Sign in") : t("New here? Create account"), horizontalPadding: 0) { signUp.toggle(); syncMessage = nil }
                if let syncMessage, !syncMessage.hasSuffix("complete") { Text(t(syncMessage)).foregroundStyle(Theme.error) }
            }
        } buttons: {
            MButton(t("Cancel"), enabled: !syncing) { showAuth = false; passwordVisible = false }
            MButton(syncing ? t("Please wait…") : signUp ? t("Create account") : t("Sign in & sync"), enabled: !syncing && email.contains("@") && password.count >= 6) {
                syncing = true
                Task {
                    do {
                        try await HoopSync.authenticate(email: email, password: password, signUp: signUp)
                        signedIn = true; showAuth = false; passwordVisible = false
                        try await HoopSync.pull(store); try await HoopSync.push(store)
                        syncMessage = "Sync complete"
                    } catch {
                        let message = error.localizedDescription
                        if message.hasPrefix("Check your email") { signUp = false; password = ""; passwordVisible = false; syncMessage = message }
                        else { syncMessage = "Sign in failed: \(message)" }
                    }
                    syncing = false
                }
            }
        }
    }
}

// MARK: - Teams tab

struct TeamsTab: View {
    @EnvironmentObject private var store: AppStore
    let onOpen: (Int64) -> Void
    @State private var query = ""
    @State private var newName = ""
    @State private var showAdd = false
    private var teams: [Team] { store.teams() }
    private var shown: [Team] { teams.filter { $0.name.localizedCaseInsensitiveContains(query.trimmed) || query.isBlank } }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                Spacer().frame(height: 12)
                HStack {
                    VStack(alignment: .leading) {
                        Text(t("Teams & Players")).font(Fonts.headlineSmall).foregroundStyle(Theme.ink)
                        Text(t("{count} teams", ["count": teams.count])).font(Fonts.bodyMedium).foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                    MButton(t("Add team"), horizontalPadding: 16) { showAdd = true }.accessibilityIdentifier("add-team-button")
                }
                Spacer().frame(height: 12)
                MTextField(placeholder: t("Search teams…"), text: $query, leadingIcon: "magnifyingglass", autocapitalize: false)
                if shown.isEmpty {
                    Text(query.isBlank ? t("No teams yet.") : t("No teams found")).font(Fonts.bodyLarge).foregroundStyle(Theme.secondaryText).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(shown) { team in
                                MCard(padding: 16, action: { onOpen(team.id) }) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(team.name).font(Fonts.titleMedium).foregroundStyle(Theme.ink)
                                        Text(t("{count} players", ["count": store.players(team.id).count])).font(Fonts.bodyLarge).foregroundStyle(Theme.secondaryText)
                                    }
                                }
                            }
                        }.padding(.top, 12)
                    }
                }
            }
            if showAdd {
                AlertPanel(title: t("Add Team"), onDismiss: { showAdd = false }) {
                    MTextField(label: t("Team name"), text: $newName, onChange: { $0.capitalizeInitial() }, identifier: "team-name-field")
                } buttons: {
                    MButton(t("Cancel")) { showAdd = false }
                    MButton(t("Save"), enabled: !newName.isBlank) { store.addTeam(newName.trimmed); newName = ""; showAdd = false }.accessibilityIdentifier("team-save-button")
                }
            }
        }
    }
}

// MARK: - Player list and detail

struct PlayerListScreen: View {
    @EnvironmentObject private var store: AppStore
    let team: Team
    let onBack: () -> Void
    let onTeamDeleted: () -> Void
    let onPlayer: (Int64) -> Void
    @State private var query = ""
    @State private var first = ""
    @State private var last = ""
    @State private var number = ""
    @State private var showAdd = false
    @State private var deletingTeam = false
    @State private var message: String?
    private var shown: [Player] {
        let q = query.trimmed
        return rosterOrder(store.players(team.id).filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) || $0.number.contains(q) })
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                MTopAppBar(title: team.name) { BackButton(action: onBack) } actions: {
                    HStack(spacing: 8) {
                        MButton(t("Delete team"), container: Theme.error, height: 36, horizontalPadding: 12) { deletingTeam = true }
                        MButton(t("Add player"), height: 36, horizontalPadding: 16) { showAdd = true }.accessibilityIdentifier("add-player-button")
                    }.padding(.trailing, 12)
                }
                VStack(alignment: .leading, spacing: 0) {
                    MTextField(label: t("Search players…"), placeholder: t("Enter a name or number"), text: $query, autocapitalize: false).padding(.top, 8)
                    if let message { Text(t(message)).font(Fonts.bodyLarge).foregroundStyle(Theme.error).padding(.top, 8) }
                    if shown.isEmpty {
                        Text(query.isBlank ? t("No players yet.") : t("No players found")).font(Fonts.bodyLarge).foregroundStyle(.gray).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 8) {
                                ForEach(shown) { player in
                                    MCard(padding: 16, action: { onPlayer(player.id) }) {
                                        HStack(spacing: 14) {
                                            Text(player.number.isBlank ? "--" : player.number).font(Fonts.bodyLarge).foregroundStyle(.white).frame(width: 44, height: 44).background(Theme.orange)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(player.name.isBlank ? t("Player #{number}", ["number": player.number]) : player.name).font(Fonts.titleMedium).foregroundStyle(Theme.ink)
                                                Text(t("Jersey {number}", ["number": player.number.isBlank ? t("Not set") : player.number])).font(Fonts.bodyLarge).foregroundStyle(.gray)
                                            }
                                        }
                                    }
                                }
                            }.padding(.top, 12)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .background(Theme.appBackground)
            if showAdd {
                AlertPanel(title: t("Add player"), onDismiss: { showAdd = false }) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(t("Name or jersey number is required")).foregroundStyle(.gray)
                        MTextField(label: t("First name"), text: $first, onChange: { $0.capitalizeInitial() }, identifier: "player-first-name-field")
                        MTextField(label: t("Last name"), text: $last, onChange: { $0.capitalizeInitial() }, identifier: "player-last-name-field")
                        MTextField(label: t("Jersey number"), text: $number, keyboard: .numberPad, onChange: { $0.filter(\.isNumber) }, identifier: "player-number-field")
                    }
                } buttons: {
                    MButton(t("Cancel")) { showAdd = false }
                    MButton(t("Save"), enabled: !first.isBlank || !last.isBlank || !number.isBlank) {
                        store.addPlayer(team.id, name: fullName(first, last), number: number.trimmed); first = ""; last = ""; number = ""; showAdd = false
                    }.accessibilityIdentifier("player-save-button")
                }
            }
            if deletingTeam {
                AlertPanel(title: t("Delete team?"), onDismiss: { deletingTeam = false }) {
                    Text(t("This will delete {name} and all of its players. Teams used in games cannot be deleted.", ["name": team.name]))
                } buttons: {
                    MButton(t("Cancel")) { deletingTeam = false }
                    MButton(t("Delete"), container: Theme.error) { deletingTeam = false; if store.deleteTeam(team.id) { onTeamDeleted() } else { message = "This team is used in a game and cannot be deleted" } }
                }
            }
        }
    }
}

struct PlayerDetailScreen: View {
    @EnvironmentObject private var store: AppStore
    let team: Team
    let player: Player
    let onBack: () -> Void
    let onDeleted: () -> Void
    @State private var editing = false
    @State private var deleting = false
    @State private var editFirst = ""
    @State private var editLast = ""
    @State private var editNumber = ""
    private var current: Player { store.player(player.id) ?? player }
    private var displayName: String { current.name.isBlank ? t("Player #{number}", ["number": current.number]) : current.name }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                MTopAppBar(title: displayName) { BackButton(action: onBack) } actions: { EmptyView() }
                VStack(spacing: 16) {
                    MCard(padding: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(displayName).font(Fonts.headlineSmall).foregroundStyle(Theme.ink)
                            Text(t("Jersey {number}", ["number": current.number.isBlank ? t("Not set") : current.number])).font(Fonts.bodyLarge).foregroundStyle(Theme.secondaryText)
                            Text(team.name).font(Fonts.bodyLarge).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    Spacer()
                    HStack(spacing: 12) {
                        MButton(t("Delete"), container: Theme.error, height: 48, fullWidth: true) { deleting = true }
                        MButton(t("Edit"), height: 48, fullWidth: true) { editFirst = firstNameOf(current.name); editLast = lastNameOf(current.name); editNumber = current.number; editing = true }
                    }
                }
                .padding(16)
            }
            .background(Theme.appBackground)
            if editing {
                AlertPanel(title: t("Edit player"), onDismiss: { editing = false }) {
                    VStack(alignment: .leading, spacing: 8) {
                        MTextField(label: t("First name"), text: $editFirst, onChange: { $0.capitalizeInitial() })
                        MTextField(label: t("Last name"), text: $editLast, onChange: { $0.capitalizeInitial() })
                        MTextField(label: t("Jersey number"), text: $editNumber, keyboard: .numberPad, onChange: { $0.filter(\.isNumber) })
                    }
                } buttons: {
                    MButton(t("Cancel")) { editing = false }
                    MButton(t("Save"), enabled: !editFirst.isBlank || !editLast.isBlank || !editNumber.isBlank) { store.updatePlayer(current.id, name: fullName(editFirst, editLast), number: editNumber.trimmed); editing = false }
                }
            }
            if deleting {
                AlertPanel(title: t("Delete Player?"), onDismiss: { deleting = false }) {
                    Text(t("Delete {name} from {team}?", ["name": current.name, "team": team.name]))
                } buttons: {
                    MButton(t("Cancel")) { deleting = false }
                    MButton(t("Delete"), container: Theme.error) { store.deletePlayer(current.id); deleting = false; onDeleted() }
                }
            }
        }
    }
}

// MARK: - Create game

struct FormTableRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 0) {
            Text(label).font(Fonts.labelLarge).foregroundStyle(.gray).frame(width: 72, alignment: .leading)
            content
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(minHeight: 72)
    }
}

/// Read-only dropdown field (Compose `ExposedDropdownMenuBox`).
struct DropdownField<Option: Hashable>: View {
    let value: String
    var placeholder = ""
    let options: [Option]
    let label: (Option) -> String
    let onSelected: (Option) -> Void
    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in Button(label(option)) { onSelected(option) } }
        } label: {
            HStack {
                Text(value.isEmpty ? placeholder : value).font(Fonts.bodyLarge).foregroundStyle(value.isEmpty ? Theme.secondaryText : Theme.ink).lineLimit(1)
                Spacer()
                Image(systemName: "arrowtriangle.down.fill").font(.system(size: 10)).foregroundStyle(Theme.secondaryText)
            }
            .padding(.horizontal, 16).frame(height: 56).frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.outline, lineWidth: 1))
        }
    }
}

struct GameForm: View {
    @EnvironmentObject private var store: AppStore
    let onDone: () -> Void
    let initialGame: Game?
    @State private var home: Team?
    @State private var away: Team?
    @State private var videoQuality = "HIGHEST"
    @State private var periodCount = 4
    @State private var periodDurationMinutes = 8
    @State private var scheduledAt = Date()
    @State private var pickingDate = false
    @State private var pickingTime = false
    @State private var draftDate = Date()
    private var teams: [Team] { store.teams().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
    private var canSave: Bool { home != nil && away != nil && home?.id != away?.id }
    private func format(_ pattern: String) -> String { let f = DateFormatter(); f.dateFormat = pattern; return f.string(from: scheduledAt) }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                MTopAppBar(title: initialGame == nil ? t("Create Game") : t("Edit game")) { BackButton(action: onDone) } actions: { EmptyView() }
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(initialGame == nil ? t("New Game") : t("Edit game")).font(Fonts.headlineMedium).foregroundStyle(Theme.ink)
                            Text(t("Set up the game and choose the teams")).font(Fonts.bodyLarge).foregroundStyle(.gray)
                        }
                        MCard {
                            VStack(spacing: 0) {
                                FormTableRow(label: t("Date")) { MOutlinedButton(format("MMM d, yyyy"), content: Theme.orange, fullWidth: true) { draftDate = scheduledAt; pickingDate = true } }
                                Divider()
                                FormTableRow(label: t("Time")) { MOutlinedButton(format("h:mm a"), content: Theme.orange, fullWidth: true) { draftDate = scheduledAt; pickingTime = true } }
                                Divider()
                                FormTableRow(label: t("Home")) { DropdownField(value: home?.name ?? "", placeholder: t("Select a team"), options: teams, label: \.name) { picked in if picked.id == away?.id { away = home }; home = picked }.accessibilityIdentifier("home-team-picker") }
                                Divider()
                                FormTableRow(label: t("Away")) { DropdownField(value: away?.name ?? "", placeholder: t("Select a team"), options: teams, label: \.name) { picked in if picked.id == home?.id { home = away }; away = picked }.accessibilityIdentifier("away-team-picker") }
                                Divider()
                                FormTableRow(label: t("Periods")) {
                                    MOutlinedButton("−", enabled: periodCount > 1) { periodCount = max(1, periodCount - 1) }
                                    Text("\(periodCount)").font(Fonts.titleMedium).foregroundStyle(Theme.ink).padding(.horizontal, 16)
                                    MOutlinedButton("+", enabled: periodCount < 20) { periodCount = min(20, periodCount + 1) }
                                }
                                Divider()
                                FormTableRow(label: t("Per period")) {
                                    MOutlinedButton("−", enabled: periodDurationMinutes > 1) { periodDurationMinutes = max(1, periodDurationMinutes - 1) }
                                    Text(t("{count} min", ["count": periodDurationMinutes])).font(Fonts.titleMedium).foregroundStyle(Theme.ink).padding(.horizontal, 16)
                                    MOutlinedButton("+", enabled: periodDurationMinutes < 60) { periodDurationMinutes = min(60, periodDurationMinutes + 1) }
                                }
                                Divider()
                                FormTableRow(label: t("Resolution")) { DropdownField(value: t(videoQualityOptions.first { $0.key == videoQuality }?.label ?? ""), options: videoQualityOptions.map(\.key), label: { key in t(videoQualityOptions.first { $0.key == key }?.label ?? key) }) { videoQuality = $0 }.accessibilityIdentifier("video-quality-picker") }
                            }
                        }
                        MCard(padding: 20) {
                            HStack {
                                Text(home?.name ?? t("Home")).font(Fonts.titleLarge).foregroundStyle(Theme.ink).frame(maxWidth: .infinity, alignment: .leading)
                                Text(t("VS")).font(Fonts.titleMedium).foregroundStyle(Theme.orange).padding(.horizontal, 16)
                                Text(away?.name ?? t("Away")).font(Fonts.titleLarge).foregroundStyle(Theme.ink).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        MButton(initialGame == nil ? t("Create Game") : t("Save Changes"), enabled: canSave, height: 56, fullWidth: true) {
                            guard let home, let away else { return }
                            let title = "\(home.name) vs \(away.name)"; let duration = Int64(periodDurationMinutes) * 60_000
                            if let initialGame { store.updateGame(initialGame.id, title: title, home: home.id, away: away.id, scheduledAt: Int64(scheduledAt.timeIntervalSince1970 * 1000), videoQuality: videoQuality, periodCount: periodCount, periodDurationMs: duration) }
                            else { store.addGame(title: title, home: home.id, away: away.id, scheduledAt: Int64(scheduledAt.timeIntervalSince1970 * 1000), videoQuality: videoQuality, periodCount: periodCount, periodDurationMs: duration) }
                            onDone()
                        }.accessibilityIdentifier("game-create-button")
                    }
                    .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 32)
                }
            }
            .background(Theme.appBackground)
            if pickingDate || pickingTime {
                AlertPanel(title: pickingDate ? t("Select date") : t("Select time"), onDismiss: { pickingDate = false; pickingTime = false }) {
                    if pickingDate {
                        DatePicker("", selection: $draftDate, displayedComponents: .date).datePickerStyle(.graphical).labelsHidden().tint(Theme.orange)
                    } else {
                        DatePicker("", selection: $draftDate, displayedComponents: .hourAndMinute).datePickerStyle(.wheel).labelsHidden().tint(Theme.orange)
                    }
                } buttons: {
                    MTextButton(t("Cancel")) { pickingDate = false; pickingTime = false }
                    MTextButton(t("OK")) { scheduledAt = draftDate; pickingDate = false; pickingTime = false }
                }
            }
        }
        .onAppear {
            guard home == nil else { return }
            if let initialGame { home = teams.first { $0.id == initialGame.homeId }; away = teams.first { $0.id == initialGame.awayId }; videoQuality = initialGame.videoQuality; periodCount = initialGame.periodCount; periodDurationMinutes = max(1, Int(initialGame.periodDurationMs / 60_000)); scheduledAt = Date(timeIntervalSince1970: TimeInterval(initialGame.scheduledAt) / 1000) }
            else { home = teams.first; away = teams.first { $0.id != home?.id } }
        }
    }
}

/// Google's white "Continue with Google" button, in the style of its branding guidelines.
struct GoogleSignInButton: View {
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text("G").font(Fonts.titleMedium).foregroundStyle(Color(hex: 0x4285F4))
                Text(t("Continue with Google")).font(Fonts.labelLarge).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
            .foregroundStyle(enabled ? Theme.ink : Theme.disabledLabel)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: 0xDADCE0), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

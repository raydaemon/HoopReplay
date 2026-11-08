import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

// Cloud sync mirroring the Android HoopSync object: the same Supabase REST calls, the same
// revision check before an upload, the same deletion tombstones, and a refresh-token exchange
// that only ends the session when the auth server explicitly refuses it.

enum SyncError: LocalizedError {
    case notConfigured, signInRequired, cloudNewer, sessionExpired, confirmEmail, cancelled
    case authRejected(Int, String), signInFailed(Int, String), requestFailed(Int, String)
    var errorDescription: String? {
        switch self {
        case .notConfigured: return t("Sync is not configured")
        case .signInRequired: return t("Sign in required")
        case .cloudNewer: return t("Cloud has newer changes. Download first, then upload")
        case .sessionExpired: return t("Session expired. Please sign in again")
        case .confirmEmail: return "Check your email to confirm the account, then sign in"
        case .cancelled: return t("Sign in was cancelled")
        case let .authRejected(code, text), let .signInFailed(code, text): return t("Sign in failed ({code}): {text}", ["code": code, "text": text])
        case let .requestFailed(code, text): return t("Sync failed ({code}): {text}", ["code": code, "text": text])
        }
    }
}

/// Small keychain wrapper: every stored value lives under one service, keyed by account name.
private enum Keychain {
    private static let service = "com.connectedai.hoopreplay.auth"
    static func read(_ account: String) -> String? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account, kSecReturnData: true] as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func write(_ value: String, _ account: String) {
        delete(account)
        // ThisDeviceOnly: session tokens and the remembered password never travel in a backup to another phone.
        SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account, kSecValueData: Data(value.utf8), kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary, nil)
    }
    static func delete(_ account: String) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary)
    }
}

struct SyncConfiguration {
    let url: String; let key: String; let space: String
    init() {
        // Build settings from scripts/run-iphone-13.sh are the first choice; a direct Xcode run falls
        // back to the same public client configuration. Never put the service-role key in the app.
        // Values fetched from the web app's /api/config (see HoopSync.refreshRemoteConfig) win, so the
        // backend can move without an App Store release.
        let remote = UserDefaults.standard
        let bundleURL = Bundle.main.object(forInfoDictionaryKey: "HOOPREPLAY_SUPABASE_URL") as? String ?? ""
        let bundleKey = Bundle.main.object(forInfoDictionaryKey: "HOOPREPLAY_SUPABASE_ANON_KEY") as? String ?? ""
        let bundleSpace = Bundle.main.object(forInfoDictionaryKey: "HOOPREPLAY_SYNC_SPACE") as? String ?? ""
        url = remote.string(forKey: "cfg_supabase_url").flatMap { $0.isEmpty ? nil : $0 }
            ?? (bundleURL.isEmpty || bundleURL.hasPrefix("$(") ? "https://ugpkignlnssfllfbznlq.supabase.co" : bundleURL)
        key = remote.string(forKey: "cfg_anon_key").flatMap { $0.isEmpty ? nil : $0 }
            ?? (bundleKey.isEmpty || bundleKey.hasPrefix("$(") ? "sb_publishable_octpLDHZuLLmylm4pJ3BSg_B-XG9dR9" : bundleKey)
        space = remote.string(forKey: "cfg_sync_space").flatMap { $0.isEmpty ? nil : $0 }
            ?? (bundleSpace.isEmpty || bundleSpace.hasPrefix("$(") ? "4d73c2ea-78c2-417f-bb36-893bf4f47ed7" : bundleSpace)
    }
    var configured: Bool { !url.isEmpty && !key.isEmpty && !space.isEmpty }
}

enum HoopSync {
    private static let entities: [(table: String, key: String)] = [("teams", "teams"), ("players", "players"), ("games", "games"), ("segments", "segments"), ("events", "events")]
    private static var configuration: SyncConfiguration { SyncConfiguration() }

    /// Fetches the public client configuration from the web app before a sign-in and caches it
    /// (mirrors Android); failures keep whatever is cached or compiled in.
    private static func refreshRemoteConfig() async {
        guard let url = URL(string: webURL + "/api/config"),
              let (data, response) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 5)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let defaults = UserDefaults.standard
        defaults.set(json["supabase_url"] as? String ?? "", forKey: "cfg_supabase_url")
        defaults.set(json["supabase_anon_key"] as? String ?? "", forKey: "cfg_anon_key")
        defaults.set(json["sync_space"] as? String ?? "", forKey: "cfg_sync_space")
    }

    static var configured: Bool { configuration.configured }
    static var isSignedIn: Bool { Keychain.read("access_token") != nil }
    static var signedInEmail: String { Keychain.read("email") ?? "" }
    /// The name the account chose (or its provider supplied), or "" when the account only has an email.
    static var signedInName: String { Keychain.read("display_name") ?? "" }

    /**
     Ends the session and forgets everything tied to the account: tokens, the remembered email and
     password, the sync revision and which account the local rows belong to. The caller pushes
     pending changes first and clears the local rows (AppStore.clearLocalRows), so the next account
     to sign in on this phone never sees, or uploads, this account's data.
     */
    static func signOut() { forgetCredentials() }
    static func forgetCredentials() { ["access_token", "refresh_token", "expires_at", "user_id", "email", "password", "display_name", "sync_revision", "data_owner"].forEach(Keychain.delete) }
    private static func clearSession() { ["access_token", "refresh_token", "expires_at", "user_id", "display_name"].forEach(Keychain.delete) }

    /// Permanently deletes the authenticated Supabase user. The database function performs the
    /// deletion in one transaction; auth.users cascading foreign keys remove all owned records.
    static func deleteAccount() async throws {
        _ = try await request("POST", "/rest/v1/rpc/delete_my_account", body: Data("{}".utf8), prefer: "return=minimal")
        forgetCredentials()
    }

    static func rememberCredentials(email: String, password: String) {
        Keychain.write(email.trimmed, "email")
        Keychain.write(password, "password")
    }
    /// The remembered password, or "" when none was stored.
    static var rememberedPassword: String { Keychain.read("password") ?? "" }

    static func authenticate(email: String, password: String, signUp: Bool) async throws {
        guard configured else { throw SyncError.notConfigured }
        await refreshRemoteConfig()
        let body = try JSONSerialization.data(withJSONObject: ["email": email.trimmed, "password": password])
        let path = signUp ? "/auth/v1/signup" : "/auth/v1/token?grant_type=password"
        let json = try await authRequest(path, body)
        guard let token = json["access_token"] as? String, !token.isEmpty else { throw SyncError.confirmEmail }
        let user = json["user"] as? [String: Any] ?? [:]
        let userEmail = (user["email"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? email.trimmed
        storeSession(json, user: user, email: userEmail)
        // Keep the credentials for the next sign-in prompt, so a session that does expire costs
        // one tap rather than typing an email and password again.
        rememberCredentials(email: userEmail, password: password)
    }

    /// Where the browser sends the user back after a Google sign-in; listed in the Supabase redirect allow list.
    private static let oauthRedirect = "hoopreplay://auth-callback"
    private static var webAuthSession: ASWebAuthenticationSession?

    /// The web app, whose API runs the Google sign-in (see web/app/api/login/google) and publishes /api/config.
    private static let webURL = "https://www.hoopreplay.com"

    /// Signs in with Google without the Supabase Google provider (mirroring the Android browser
    /// flow): the system's web-auth sheet opens our web API, which sends the user to Google, mints
    /// the Supabase session itself, and returns it in the fragment of the `hoopreplay://auth-callback` link.
    @MainActor
    static func authenticateWithGoogle() async throws {
        guard configured else { throw SyncError.notConfigured }
        await refreshRemoteConfig()
        // Mirrors Android: the state ties the callback to the sign-in this app started, and the
        // PKCE verifier lets only this app redeem the code the deep link carries.
        let state = randomToken()
        let verifier = randomToken()
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        var components = URLComponents(string: webURL + "/api/login/google/start")!
        components.queryItems = [URLQueryItem(name: "redirect_to", value: oauthRedirect), URLQueryItem(name: "state", value: state), URLQueryItem(name: "code_challenge", value: challenge)]
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: components.url!, callbackURLScheme: "hoopreplay") { url, error in
                if let url { continuation.resume(returning: url) }
                else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { continuation.resume(throwing: SyncError.cancelled) }
                else { continuation.resume(throwing: error ?? SyncError.cancelled) }
            }
            session.presentationContextProvider = WebAuthPresenter.shared
            session.prefersEphemeralWebBrowserSession = false
            webAuthSession = session
            session.start()
        }
        webAuthSession = nil
        // The web API form-encodes the fragment (a space is "+"); URLComponents only decodes %XX.
        let fragment = URLComponents(string: "hoopreplay://x?" + (callback.fragment ?? "").replacingOccurrences(of: "+", with: "%20"))?.queryItems ?? []
        let params = Dictionary(fragment.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        if let message = params["login_error"] { throw SyncError.signInFailed(0, message) }
        guard let code = params["code"], !code.isEmpty else { throw SyncError.cancelled }
        guard params["state"] == state else { throw SyncError.signInFailed(0, t("Sign in expired. Try again")) }
        let fields = try await exchangeCode(code, verifier: verifier)
        guard let token = fields["access_token"], !token.isEmpty, let refresh = fields["refresh_token"] else { throw SyncError.signInFailed(0, t("no session returned")) }
        let userEmail = fields["email"] ?? ""
        let json: [String: Any] = ["access_token": token, "refresh_token": refresh, "expires_at": NSNumber(value: Int64(fields["expires_at"] ?? "") ?? 0)]
        let user: [String: Any] = ["id": fields["user_id"] ?? "", "email": userEmail, "user_metadata": ["full_name": fields["name"] ?? ""]]
        storeSession(json, user: user, email: userEmail)
        Keychain.write(userEmail, "email")
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func randomToken() -> String {
        var random = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, random.count, &random)
        return base64URL(Data(random))
    }

    /// Redeems the deep link's sign-in code for the session fields (web/app/api/login/exchange).
    private static func exchangeCode(_ code: String, verifier: String) async throws -> [String: String] {
        var request = URLRequest(url: URL(string: webURL + "/api/login/exchange")!, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code, "code_verifier": verifier])
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SyncError.signInFailed(0, json["error"] as? String ?? t("Sign in expired. Try again"))
        }
        return json.compactMapValues { $0 as? String }
    }

    /// Signs in with the identity token Apple issued to this device (Sign in with Apple, native flow).
    /// `nonce` is the raw nonce whose SHA-256 went into the Apple request; Supabase checks it against
    /// the token. Apple only shares the user's name on the first authorization, so when it arrives it
    /// is written to the account's metadata, where every client reads the display name from.
    static func authenticateWithApple(identityToken: String, nonce: String, fullName: String) async throws {
        guard configured else { throw SyncError.notConfigured }
        await refreshRemoteConfig()
        let body = try JSONSerialization.data(withJSONObject: ["provider": "apple", "id_token": identityToken, "nonce": nonce])
        let json = try await authRequest("/auth/v1/token?grant_type=id_token", body)
        guard let token = json["access_token"] as? String, !token.isEmpty else { throw SyncError.signInFailed(0, t("no session returned")) }
        var user = json["user"] as? [String: Any] ?? [:]
        let userEmail = (user["email"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? signedInEmail
        let name = fullName.trimmed
        let meta = user["user_metadata"] as? [String: Any] ?? [:]
        if !name.isBlank, (meta["full_name"] as? String ?? "").isBlank {
            var updated = meta; updated["full_name"] = name; user["user_metadata"] = updated
        }
        storeSession(json, user: user, email: userEmail)
        Keychain.write(userEmail, "email")
        if !name.isBlank, (meta["full_name"] as? String ?? "").isBlank {
            _ = try? await request("PUT", "/auth/v1/user", body: try JSONSerialization.data(withJSONObject: ["data": ["full_name": name]]))
        }
    }

    private static func storeSession(_ json: [String: Any], user: [String: Any], email: String) {
        Keychain.write(json["access_token"] as? String ?? "", "access_token")
        Keychain.write(json["refresh_token"] as? String ?? "", "refresh_token")
        Keychain.write(user["id"] as? String ?? "", "user_id")
        Keychain.write(email, "email")
        let meta = user["user_metadata"] as? [String: Any] ?? [:]
        let name = ["display_name", "full_name", "name"].compactMap { (meta[$0] as? String)?.trimmed }.first { !$0.isBlank } ?? ""
        Keychain.write(name, "display_name")
        I18n.shared.adoptFromAccount(meta[I18n.key] as? String)
        let expiresIn = (json["expires_in"] as? NSNumber)?.int64Value ?? 3600
        let expiresAt = (json["expires_at"] as? NSNumber)?.int64Value ?? (Int64(Date().timeIntervalSince1970) + expiresIn)
        Keychain.write(String(expiresAt), "expires_at")
    }

    /// The server's change counter for this account and sync space, or 0 when nothing has ever been written.
    private static func remoteRevision() async throws -> Int64 {
        let rows = try await requestRows("GET", "/rest/v1/hoop_sync_revisions?select=revision")
        return rows.compactMap { ($0["revision"] as? NSNumber)?.int64Value }.max() ?? 0
    }
    private static var seenRevision: Int64 { Keychain.read("sync_revision").flatMap(Int64.init) ?? -1 }
    private static func rememberRevision(_ revision: Int64) { Keychain.write(String(revision), "sync_revision") }

    private static func encoded(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value }

    /**
     Runs before every pull and push. Local rows belong to one account: when a different account
     signs in on this phone (a session expired and someone else signed in), the previous account's
     rows are dropped instead of being merged into, and uploaded as, the new account's data. Then
     placeholders left by the integer-id store are mapped onto the server's ids (contract rule 6b),
     always before anything is pushed. Returns this account's user id and sync space.
     */
    @MainActor
    private static func prepareLocalData(_ store: AppStore) async throws -> (userId: String, space: String) {
        _ = try await validAccessToken()
        guard let userId = Keychain.read("user_id")?.lowercased(), !userId.isEmpty else { throw SyncError.signInRequired }
        let space = configuration.space
        if let owner = Keychain.read("data_owner"), owner != userId {
            store.clearLocalRows()
            Keychain.delete("sync_revision")
        }
        Keychain.write(userId, "data_owner")
        if store.hasLegacyIds { try await adoptLegacyIds(store, userId: userId, space: space) }
        return (userId, space)
    }

    /// Fetches this account's legacy id mappings and legacy tombstones, then rewrites the local placeholders in one go.
    @MainActor
    private static func adoptLegacyIds(_ store: AppStore, userId: String, space: String) async throws {
        let scope = "user_id=eq.\(userId)&sync_space=eq.\(encoded(space))&legacy_local_id=not.is.null"
        func legacy(_ row: [String: Any]) -> Int64? { (row["legacy_local_id"] as? NSNumber)?.int64Value }
        var mapped: [String: [Int64: RowID]] = [:]
        for (table, _) in entities {
            let rows = try await requestRows("GET", "/rest/v1/hoop_\(table)?select=id,legacy_local_id&\(scope)&order=id.asc")
            for row in rows {
                if let n = legacy(row), let id = (row["id"] as? String)?.lowercased() { mapped[table, default: [:]][n] = id }
            }
        }
        var tombstoned: [String: Set<Int64>] = [:]
        for row in try await requestRows("GET", "/rest/v1/hoop_deletions?select=entity,legacy_local_id&\(scope)&order=entity.asc,row_id.asc") {
            if let entity = row["entity"] as? String, let n = legacy(row) { tombstoned[entity, default: []].insert(n) }
        }
        store.adoptLegacyIds(mapped: mapped, tombstoned: tombstoned)
    }

    /**
     Uploads this account's own rows (contract rule 4): shared games are read-only copies and never
     leave the phone. A row missing from the snapshot never means "delete it"; removals travel as
     tombstones. A push also refuses to run while the server holds changes this device has not
     pulled, so the user downloads and merges first.
     */
    @MainActor
    static func push(_ store: AppStore) async throws {
        guard configured else { throw SyncError.notConfigured }
        let (userId, space) = try await prepareLocalData(store)
        guard !store.hasLegacyIds else { throw SyncError.requestFailed(0, "legacy ids remain") }
        let revision = try await remoteRevision()
        let seen = seenRevision
        // An empty account has nothing to lose, so a first upload from a device that never pulled is fine.
        guard revision == seen || (revision == 0 && seen < 0) else { throw SyncError.cloudNewer }
        let scope = "user_id=eq.\(userId)&sync_space=eq.\(encoded(space))"
        let snapshot = store.exportSyncSnapshot()
        func rows(_ key: String) -> [[String: Any]] { snapshot[key] as? [[String: Any]] ?? [] }

        let tombstones = rows("deletions")
        if !tombstones.isEmpty {
            let upload = tombstones.map { tombstone -> [String: Any] in
                var row = tombstone
                row["user_id"] = userId; row["sync_space"] = space
                return row
            }
            _ = try await request("POST", "/rest/v1/hoop_deletions?on_conflict=user_id,sync_space,entity,row_id", body: try JSONSerialization.data(withJSONObject: upload), prefer: "resolution=merge-duplicates,return=minimal")
        }

        // Surviving rows first: a player can only be removed once the events naming them let go.
        for (table, key) in entities {
            let localRows = rows(key)
            guard !localRows.isEmpty else { continue }
            let cloudRows = localRows.map { localRow -> [String: Any] in
                var row = localRow
                row["user_id"] = userId; row["sync_space"] = space
                // Older iOS builds stored the display-only alias FOULED. Normalize it during
                // upload so existing local games remain compatible with event_type_check.
                if table == "events", row["type"] as? String == "FOULED" { row["type"] = "FOUL_DRAWN" }
                if table == "events", let reverted = row["reverted"] as? NSNumber { row["reverted"] = reverted.intValue != 0 }
                return row
            }
            for start in stride(from: 0, to: cloudRows.count, by: 500) {
                let batch = Array(cloudRows[start..<min(start + 500, cloudRows.count)])
                _ = try await request("POST", "/rest/v1/hoop_\(table)?on_conflict=id", body: try JSONSerialization.data(withJSONObject: batch), prefer: "resolution=merge-duplicates,return=minimal")
            }
        }

        // Dependent rows first so the relational schema stays valid while tombstones are applied.
        for entity in ["events", "segments", "games", "players", "teams"] {
            let ids = tombstones.filter { $0["entity"] as? String == entity }.compactMap { $0["row_id"] as? String }
            for start in stride(from: 0, to: ids.count, by: 100) {
                let batch = ids[start..<min(start + 100, ids.count)].joined(separator: ",")
                _ = try await request("DELETE", "/rest/v1/hoop_\(entity)?\(scope)&id=in.(\(batch))", prefer: "return=minimal")
            }
        }
        rememberRevision(try await remoteRevision())
    }

    /**
     Downloads this account's rows and tombstones plus every shared game it can see. Each row keeps
     its owner (`user_id`) and sync space, so shared rows stay read-only copies (AppStore.mergeSyncSnapshot).
     */
    @MainActor
    static func pull(_ store: AppStore) async throws {
        guard configured else { throw SyncError.notConfigured }
        let (userId, space) = try await prepareLocalData(store)
        // Read before the rows: a write that lands mid-pull then still counts as unseen.
        let revision = try await remoteRevision()
        let own = "user_id=eq.\(userId)&sync_space=eq.\(encoded(space))"
        var snapshot: [String: Any] = ["schemaVersion": 3, "updatedAt": nowMs()]
        snapshot["deletions"] = try await requestRows("GET", "/rest/v1/hoop_deletions?select=entity,row_id,deleted_at,device_id&\(own)&order=deleted_at.asc,row_id.asc")
        for (table, key) in entities {
            let ownRows = try await requestRows("GET", "/rest/v1/hoop_\(table)?select=*&\(own)&order=id.asc")
            let sharedRows = try await requestRows("GET", "/rest/v1/hoop_\(table)?select=*&user_id=neq.\(userId)&order=id.asc")
            snapshot[key] = (ownRows + sharedRows).map { cloudRow -> [String: Any] in
                var row = cloudRow
                if table == "events", let reverted = row["reverted"] as? Bool { row["reverted"] = reverted ? 1 : 0 }
                return row
            }
        }
        store.mergeSyncSnapshot(snapshot, ownUserId: userId)
        rememberRevision(revision)
    }

    // MARK: - HTTP

    private static func authRequest(_ path: String, _ body: Data) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: configuration.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path)!)
        request.httpMethod = "POST"; request.timeoutInterval = 20; request.httpBody = body
        request.setValue(configuration.key, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(data: data, encoding: .utf8) ?? ""
        // A refusal and an unreachable server must stay distinguishable: only the first one may
        // end the session, so the caller can tell them apart by error case.
        if code == 400 || code == 401 || code == 403 { throw SyncError.authRejected(code, text) }
        guard 200..<300 ~= code else { throw SyncError.signInFailed(code, text) }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Supabase's PostgREST max_rows; a GET never returns more than this many rows.
    private static let pageSize = 1000

    /// Every row of a GET. PostgREST caps a response at max_rows, which silently dropped the newest
    /// events of a busy account, so read page by page until a short page says the table is done.
    /// `path` already carries its own query string.
    private static func requestRows(_ method: String, _ path: String) async throws -> [[String: Any]] {
        var rows: [[String: Any]] = []
        var offset = 0
        while true {
            let data = try await request(method, "\(path)&limit=\(pageSize)&offset=\(offset)")
            let page = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
            rows += page
            if page.count < pageSize { return rows }
            offset += pageSize
        }
    }

    private static func request(_ method: String, _ path: String, body: Data? = nil, prefer: String? = nil, retried: Bool = false) async throws -> Data {
        let token = try await validAccessToken()
        var urlRequest = URLRequest(url: URL(string: configuration.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path)!)
        urlRequest.httpMethod = method; urlRequest.timeoutInterval = 20; urlRequest.httpBody = body
        urlRequest.setValue(configuration.key, forHTTPHeaderField: "apikey")
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(configuration.space, forHTTPHeaderField: "x-sync-space")
        if let prefer { urlRequest.setValue(prefer, forHTTPHeaderField: "Prefer") }
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        // A rejected access token is not a dead session: it usually just aged out. Refresh once and
        // retry before making the user sign in again.
        if code == 401 && !retried {
            _ = try await refreshAccessToken()
            return try await request(method, path, body: body, prefer: prefer, retried: true)
        }
        guard 200..<300 ~= code else { throw SyncError.requestFailed(code, String(data: data, encoding: .utf8) ?? "") }
        return data
    }

    /// Calls a Web API route (e.g. /api/highlights/upload) as the signed-in user; throws the route's error message.
    static func webRequest(_ method: String, _ path: String, body: [String: Any]? = nil, retried: Bool = false) async throws -> Data {
        let token = try await validAccessToken()
        var urlRequest = URLRequest(url: URL(string: webURL + path)!)
        urlRequest.httpMethod = method; urlRequest.timeoutInterval = 60
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 && !retried {
            _ = try await refreshAccessToken()
            return try await webRequest(method, path, body: body, retried: true)
        }
        guard 200..<300 ~= code else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw NSError(domain: "HoopReplay", code: code, userInfo: [NSLocalizedDescriptionKey: message ?? t("Request failed ({code})", ["code": code])])
        }
        return data
    }

    private static func validAccessToken() async throws -> String {
        guard let current = Keychain.read("access_token") else { throw SyncError.signInRequired }
        let expiresAt = Keychain.read("expires_at").flatMap(Int64.init) ?? 0
        if expiresAt > Int64(Date().timeIntervalSince1970) + 60 { return current }
        // Sessions stored before refresh tokens existed have no expiry: keep using the token
        // until the server rejects it, at which point the 401 path refreshes or signs out.
        if expiresAt == 0 && Keychain.read("refresh_token") == nil { return current }
        return try await refreshAccessToken()
    }

    /// Only an explicit refusal from the auth server ends the session; a timeout leaves the stored tokens alone.
    private static func refreshAccessToken() async throws -> String {
        guard let refresh = Keychain.read("refresh_token"), !refresh.isEmpty else { clearSession(); throw SyncError.sessionExpired }
        let json: [String: Any]
        do {
            json = try await authRequest("/auth/v1/token?grant_type=refresh_token", try JSONSerialization.data(withJSONObject: ["refresh_token": refresh]))
        } catch let error as SyncError {
            if case .authRejected = error { clearSession(); throw SyncError.sessionExpired }
            throw error
        }
        let user = json["user"] as? [String: Any] ?? [:]
        storeSession(json, user: user, email: user["email"] as? String ?? signedInEmail)
        return json["access_token"] as? String ?? ""
    }

    /// Stores the interface language on the account (user_metadata.language) so Web and Android pick it up.
    static func updateLanguage(_ code: String) async throws {
        _ = try await request("PUT", "/auth/v1/user", body: try JSONSerialization.data(withJSONObject: ["data": [I18n.key: code]]))
    }
}

/// Anchors the web-auth sheet to the key window, as ASWebAuthenticationSession requires.
private final class WebAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = WebAuthPresenter()
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }.first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}

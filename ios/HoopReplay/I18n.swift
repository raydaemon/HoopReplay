import Foundation
import Combine

/// Interface languages, in menu order; codes and native names match the Web and Android apps.
enum AppLanguage: String, CaseIterable {
    case english = "en", chineseSimplified = "zh-Hans", chineseTraditional = "zh-Hant", spanish = "es", french = "fr"
    case german = "de", portuguese = "pt", japanese = "ja", korean = "ko", italian = "it"

    var nativeName: String {
        switch self {
        case .english: return "English"
        case .chineseSimplified: return "简体中文"
        case .chineseTraditional: return "繁體中文"
        case .spanish: return "Español"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .portuguese: return "Português"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .italian: return "Italiano"
        }
    }

    /// The shipped language a BCP 47 tag or saved code maps to, or nil when we do not ship it.
    static func match(_ tag: String?) -> AppLanguage? {
        guard let lower = tag?.lowercased(), !lower.isEmpty else { return nil }
        if lower.hasPrefix("zh") { return lower.range(of: "hant|tw|hk|mo", options: .regularExpression) != nil ? .chineseTraditional : .chineseSimplified }
        let primary = lower.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? lower
        return allCases.first { $0.rawValue == primary }
    }
}

/// Interface language for the iOS app. The dictionary for the chosen language is the shared
/// web/i18n/<code>.json bundled under i18n/, and `t()` looks every UI string up by its English text.
/// RootView re-renders its whole tree on `language` changes, so views just call `t()`.
final class I18n: ObservableObject {
    static let shared = I18n()
    static let key = "language"

    @Published private(set) var language: AppLanguage = .english
    private var dict: [String: String] = [:]

    private init() {
        apply(AppLanguage.match(UserDefaults.standard.string(forKey: I18n.key)) ?? AppLanguage.match(Locale.preferredLanguages.first) ?? .english)
    }

    /// The user picked a language: keep it locally and, when signed in, on the account so other devices follow.
    func set(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: I18n.key)
        apply(language)
        if HoopSync.isSignedIn { Task { try? await HoopSync.updateLanguage(language.rawValue) } }
    }

    /// A session arrived carrying the account's language: it wins over the device's.
    func adoptFromAccount(_ code: String?) {
        guard let language = AppLanguage.match(code), language != self.language else { return }
        UserDefaults.standard.set(language.rawValue, forKey: I18n.key)
        DispatchQueue.main.async { self.apply(language) }
    }

    private func apply(_ language: AppLanguage) {
        if language == .english { dict = [:] } else if let url = Bundle.main.url(forResource: language.rawValue, withExtension: "json", subdirectory: "i18n"),
            let data = try? Data(contentsOf: url), let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            dict = json
        } else { dict = [:] }
        self.language = language
    }

    func t(_ key: String, _ vars: [String: Any] = [:]) -> String {
        var text = dict[key] ?? key
        for (name, value) in vars { text = text.replacingOccurrences(of: "{\(name)}", with: "\(value)") }
        return text
    }
}

/// `t("Sign out")` → the current language's text, or the English key; `{name}` placeholders come from `vars`.
func t(_ key: String, _ vars: [String: Any] = [:]) -> String { I18n.shared.t(key, vars) }

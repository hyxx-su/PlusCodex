import Foundation

extension Notification.Name {
    static let plusCodexLanguageDidChange = Notification.Name("PlusCodexLanguageDidChange")
}

enum AppLanguage: String, CaseIterable {
    case korean = "ko", english = "en"
    var locale: Locale { Locale(identifier: rawValue == "ko" ? "ko_KR" : "en_US") }
}

/// Language changes take effect on the next launch so AppKit and Sparkle, whose
/// bundles cache localization, cannot disagree with the custom menu content.
final class LanguageSettings {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var selected: AppLanguage {
        AppLanguage(rawValue: defaults.string(forKey: "appLanguage") ?? "") ?? .korean
    }
    func select(_ language: AppLanguage) {
        guard selected != language else { return }
        defaults.set(language.rawValue, forKey: "appLanguage")
        NotificationCenter.default.post(name: .plusCodexLanguageDidChange, object: language)
    }
    func configureFrameworkLanguage() {
        // App domain only: never changes the user's macOS language preference.
        defaults.set([selected.rawValue], forKey: "AppleLanguages")
    }
}

enum L10n {
    /// Read the current preference on demand so language changes are visible
    /// without restarting the process or rebuilding the app bundle.
    static var language: AppLanguage { LanguageSettings().selected }
    static var locale: Locale { language.locale }

    static func text(_ key: String, _ arguments: CVarArg...) -> String {
        let value = translation(key, language: language)
        return arguments.isEmpty ? value : String(format: value, locale: locale, arguments: arguments)
    }

    static func translation(_ key: String, language: AppLanguage) -> String {
        guard let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// Provider parsing keeps its stable canonical labels; only their display is translated.
    static func quotaLabel(_ label: String) -> String {
        if label.hasSuffix(" 주간") { return text("%@ 주간", text(String(label.dropLast(3)))) }
        if label.hasSuffix("시간"), let hours = Int(label.dropLast(2)) { return text("%d시간", hours) }
        if label.hasSuffix("분"), let minutes = Int(label.dropLast()) { return text("%d분", minutes) }
        return text(label)
    }
}

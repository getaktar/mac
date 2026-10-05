import AppKit

/// In-app language override. macOS picks an app's language from the
/// `AppleLanguages` default at launch, so writing it to Aktar's own domain
/// switches the UI language on the next launch without touching the
/// system-wide setting. This is the same value System Settings writes for a
/// per-app language, so the two stay in sync.
@MainActor
enum AppLanguage {
    /// Localizations shipped in the String Catalog, in the same order as
    /// getaktar.com. Names are native so they're recognizable in any UI language.
    static let supported: [(code: String, name: String)] = [
        ("en", "English"),
        ("tr", "Türkçe"),
        ("de", "Deutsch"),
        ("fr", "Français"),
        ("es", "Español"),
        ("pt-BR", "Português (Brasil)"),
        ("ja", "日本語"),
        ("zh-Hans", "简体中文"),
        ("zh-Hant", "繁體中文"),
        ("ko", "한국어"),
        ("it", "Italiano"),
        ("nl", "Nederlands"),
        ("pl", "Polski"),
        ("ru", "Русский"),
        ("uk", "Українська"),
        ("id", "Bahasa Indonesia"),
        ("vi", "Tiếng Việt"),
    ]

    private static let key = "AppleLanguages"

    /// The override in effect when the app launched, used to tell whether a
    /// restart is needed to apply the current selection.
    static let atLaunch = override

    /// The overridden language code, or nil when Aktar follows the system.
    static var override: String? {
        get {
            guard let domain = Bundle.main.bundleIdentifier,
                  let languages = UserDefaults.standard.persistentDomain(forName: domain)?[key] as? [String] else {
                return nil
            }
            return languages.first
        }
        set {
            if let newValue {
                UserDefaults.standard.set([newValue], forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}

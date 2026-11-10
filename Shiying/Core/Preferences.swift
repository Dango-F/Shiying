import AppKit

extension Notification.Name { static let preferencesChanged = Notification.Name("Shiying.preferencesChanged") }

@MainActor enum Preferences {
    static let defaults = UserDefaults.standard
    static let glassStyles = ["adaptive", "ink"]
    static func register() {
        // 固定和拖动位置现在只属于本次显示，清除旧版本遗留的持久化 UI 状态。
        defaults.removeObject(forKey: "panelPinned"); defaults.removeObject(forKey: "panelOrigin")
        // Upgrade the former default, while preserving shortcuts explicitly recorded by users.
        if defaults.object(forKey: "hotkeyTitle") == nil,
            defaults.integer(forKey: "hotkeyCode") == 49,
            defaults.integer(forKey: "hotkeyModifiers") == 2304 {
            defaults.removeObject(forKey: "hotkeyCode"); defaults.removeObject(forKey: "hotkeyModifiers")
        }
        defaults.register(defaults: ["language": "system", "theme": "system", "glass": "adaptive", "clarity": 0.75,
            "pollInterval": 0.5, "fontScale": 1.0,
            "hotkeyCode": 9, "hotkeyModifiers": 4096, "showStatusItem": false, "launchAtLogin": true,
            "excludedApps": ["com.agilebits.onepassword7", "com.1password.1password", "com.bitwarden.desktop", "org.keepassxc.keepassxc", "com.apple.Passwords"]])
    }
    static func set(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: .preferencesChanged, object: nil)
    }
    static var language: String { defaults.string(forKey: "language") ?? "system" }
    static var resolvedLanguage: String {
        if language != "system" { return language }
        for lang in Locale.preferredLanguages {
            if lang.hasPrefix("zh-Hans") || lang == "zh" || lang.hasPrefix("zh-CN") || lang.hasPrefix("zh-SG") { return "zh-Hans" }
            if lang.hasPrefix("en") { return "en" }
        }
        return "en"
    }
    static var appearance: NSAppearance? {
        switch defaults.string(forKey: "theme") { case "light": NSAppearance(named: .aqua); case "dark": NSAppearance(named: .darkAqua); default: nil }
    }
    static var glass: String { defaults.string(forKey: "glass") == "ink" ? "ink" : "adaptive" }
    static var clarity: Double { min(1, max(0, defaults.double(forKey: "clarity"))) }
    static var scale: Double { min(1.3, max(1, defaults.double(forKey: "fontScale"))) }
}
private final class LocalizationAnchor: NSObject {}

@MainActor func L(_ key: String) -> String {
    guard let path = Bundle(for: LocalizationAnchor.self).path(forResource: Preferences.resolvedLanguage, ofType: "lproj"), let bundle = Bundle(path: path) else { return key }
    return bundle.localizedString(forKey: key, value: key, table: "Localizable")
}
@MainActor func F(_ key: String, _ value: Int) -> String {
    String(format: L(key), locale: Locale.current, value)
}

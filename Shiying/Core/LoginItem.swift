import Foundation
import ServiceManagement

@MainActor enum LoginItem {
    /// Register once for the installed app, respecting subsequent user choices in macOS.
    /// Development builds never create a second automatic login item.
    static func applyDefault() throws {
        guard !BuildInfo.isDevelopment, !Preferences.defaults.bool(forKey: "loginDefaultApplied") else { return }
        Preferences.defaults.set(true, forKey: "loginDefaultApplied")
        guard Preferences.defaults.bool(forKey: "launchAtLogin") else { return }
        if SMAppService.mainApp.status != .enabled && SMAppService.mainApp.status != .requiresApproval { try SMAppService.mainApp.register() }
    }
    static func setEnabled(_ enabled: Bool) throws {
        Preferences.defaults.set(enabled, forKey: "launchAtLogin")
        Preferences.defaults.set(true, forKey: "loginDefaultApplied")
        if enabled {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        } else { try SMAppService.mainApp.unregister() }
    }
}

enum BuildInfo {
    static let displayName = "拾影·Shiying"
    static var isDevelopment: Bool { Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true }
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.17" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "19" }
    static var shortVersion: String { "v" + version + (isDevelopment ? " · Dev" : "") }
    static var fullVersion: String { version + " (" + build + ")" + (isDevelopment ? " · Dev" : "") }
}

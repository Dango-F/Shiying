import XCTest
import AppKit
import Carbon

@MainActor final class HotKeyTests: XCTestCase {
    func testNewAndUpgradedPreferencesDefaultToOptionV() {
        withStoredShortcut(modifiers: nil, title: nil) {
            XCTAssertEqual(Preferences.defaults.integer(forKey: "hotkeyCode"), kVK_ANSI_V)
            XCTAssertEqual(Preferences.defaults.integer(forKey: "hotkeyModifiers"), optionKey)
            XCTAssertEqual(ShortcutRecorder(frame: .zero).title, "⌥V")
        }
        withStoredShortcut(modifiers: controlKey, title: nil) {
            XCTAssertEqual(Preferences.defaults.integer(forKey: "hotkeyCode"), kVK_ANSI_V)
            XCTAssertEqual(Preferences.defaults.integer(forKey: "hotkeyModifiers"), optionKey)
            XCTAssertEqual(ShortcutRecorder(frame: .zero).title, "⌥V")
        }
    }

    func testExplicitlyRecordedControlVIsPreserved() {
        withStoredShortcut(modifiers: controlKey, title: "⌃V") {
            XCTAssertEqual(Preferences.defaults.integer(forKey: "hotkeyCode"), kVK_ANSI_V)
            XCTAssertEqual(Preferences.defaults.integer(forKey: "hotkeyModifiers"), controlKey)
            XCTAssertEqual(ShortcutRecorder(frame: .zero).title, "⌃V")
        }
    }

    private func withStoredShortcut(modifiers: Int?, title: String?, check: () -> Void) {
        _ = NSApplication.shared
        let defaults = Preferences.defaults
        let keys = ["hotkeyCode", "hotkeyModifiers", "hotkeyTitle"]
        let saved = Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
        defer { for key in keys { defaults.set(saved[key], forKey: key) } }
        defaults.set(modifiers.map { _ in kVK_ANSI_V }, forKey: "hotkeyCode")
        defaults.set(modifiers, forKey: "hotkeyModifiers")
        defaults.set(title, forKey: "hotkeyTitle")
        Preferences.register()
        check()
    }

    func testOptionVRegistrationConflictAndCustomization() {
        _ = NSApplication.shared
        let first = HotKey(), second = HotKey()
        defer { first.stop(); second.stop() }
        XCTAssertTrue(first.register(code: UInt32(kVK_ANSI_V), modifiers: UInt32(optionKey)))
        XCTAssertFalse(second.register(code: UInt32(kVK_ANSI_V), modifiers: UInt32(optionKey)))
        XCTAssertTrue(first.register(code: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | optionKey)))
        XCTAssertTrue(second.register(code: UInt32(kVK_ANSI_V), modifiers: UInt32(optionKey)))
    }
}

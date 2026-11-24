import XCTest
import AppKit
import Carbon

@MainActor final class HotKeyTests: XCTestCase {
    func testNewAndUpgradedPreferencesDefaultToFnV() {
        for modifiers in [nil, optionKey, controlKey] as [Int?] {
            withStoredShortcut(modifiers: modifiers, title: nil) {
                XCTAssertEqual(Preferences.defaults.integer(forKey: "hotkeyCode"), kVK_ANSI_V)
                XCTAssertEqual(Preferences.defaults.integer(forKey: "hotkeyModifiers"), Int(kEventKeyModifierFnMask))
                XCTAssertEqual(ShortcutRecorder(frame: .zero).title, "Fn+V")
            }
        }
    }

    func testExplicitlyRecordedOptionVIsPreserved() {
        withStoredShortcut(modifiers: optionKey, title: "⌥V") {
            XCTAssertEqual(Preferences.defaults.integer(forKey: "hotkeyCode"), kVK_ANSI_V)
            XCTAssertEqual(Preferences.defaults.integer(forKey: "hotkeyModifiers"), optionKey)
            XCTAssertEqual(ShortcutRecorder(frame: .zero).title, "⌥V")
        }
    }

    func testRecorderAcceptsFnVAndRejectsBareV() throws {
        _ = NSApplication.shared
        let recorder = ShortcutRecorder(frame: .zero)
        var captured: (UInt32, UInt32, String)?
        recorder.onRecorded = { captured = ($0, $1, $2) }
        recorder.performClick(nil)

        func key(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil, characters: "v",
                charactersIgnoringModifiers: "v", isARepeat: false, keyCode: UInt16(kVK_ANSI_V)))
        }
        recorder.keyDown(with: try key([]))
        XCTAssertNil(captured)
        recorder.keyDown(with: try key(.function))
        let (code, modifiers, title) = try XCTUnwrap(captured)
        XCTAssertEqual(code, UInt32(kVK_ANSI_V))
        XCTAssertEqual(modifiers, UInt32(kEventKeyModifierFnMask))
        XCTAssertEqual(title, "Fn+V")
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

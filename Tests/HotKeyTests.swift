import XCTest
import AppKit
import Carbon

@MainActor final class HotKeyTests: XCTestCase {
    func testControlVRegistrationConflictAndCustomization() {
        _ = NSApplication.shared
        let first = HotKey(), second = HotKey()
        defer { first.stop(); second.stop() }
        XCTAssertTrue(first.register(code: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey)))
        XCTAssertFalse(second.register(code: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey)))
        XCTAssertTrue(first.register(code: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | optionKey)))
        XCTAssertTrue(second.register(code: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey)))
    }
}

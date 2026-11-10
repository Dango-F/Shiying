import XCTest
import AppKit
import CryptoKit

@MainActor final class CopyOnlyTests: XCTestCase {
    private var fixtures: [(AppModel, NSPasteboard, URL)] = []
    private var panels: [PanelController] = []
    override func setUp() async throws {
        _ = NSApplication.shared; Preferences.register()
        Preferences.defaults.set(false, forKey: "consent")
        // Simulate a user upgrading from the former default paste action.
        Preferences.defaults.set("paste", forKey: "defaultAction")
    }
    override func tearDown() async throws {
        panels.forEach { $0.hide() }; panels.removeAll()
        for (model, board, directory) in fixtures {
            model.stop(); await model.store.close(); board.releaseGlobally()
            try? FileManager.default.removeItem(at: directory)
        }
        fixtures.removeAll()
        for key in ["consent", "defaultAction", "language"] { Preferences.defaults.removeObject(forKey: key) }
    }
    private func fixture() async throws -> (AppModel, NSPasteboard, ClipPayload, String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let board = NSPasteboard.withUniqueName()
        let store = HistoryStore(directory: directory, testKey: SymmetricKey(size: .bits256))
        let model = AppModel(store: store, pasteboard: board, clipboardAccess: { _ in true }, sourceBundleID: { "com.example.copy-test" })
        fixtures.append((model, board, directory)); await model.start()
        let payload = ClipPayload(items: [ClipItem(representations: [Representation(type: "public.html", data: Data("<b>Original 👋</b>".utf8)), Representation(type: "public.utf8-plain-text", data: Data("Original 👋".utf8))])])
        let id = try await store.insert(CapturedClip(kind: .text, payload: payload, summary: ClipSummary(title: "Original 👋", detail: "", hasText: true), partial: false))
        return (model, board, payload, id)
    }
    func testAllPanelEntryPointsCopyEvenWithLegacyPastePreference() async throws {
        let (model, board, payload, _) = try await fixture()
        let controller = PanelController(model: model); panels.append(controller); controller.show()
        let table = try XCTUnwrap(descendants(controller.panel.contentView!).compactMap { $0 as? NSTableView }.first)
        let search = try XCTUnwrap(descendants(controller.panel.contentView!).compactMap { $0 as? NSSearchField }.first)
        for _ in 0..<100 {
            if table.numberOfRows == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(table.numberOfRows, 1)
        for action in ["doubleClick", "return", "searchReturn", "number", "copy", "plain", "context"] {
            board.clearContents(); board.setString("Before copy", forType: .string)
            let generation = board.changeCount
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            controller.panel.makeFirstResponder(table)
            let responder = controller.panel.firstResponder
            switch action {
            case "doubleClick":
                XCTAssertEqual(table.doubleAction, #selector(PanelController.copySelected))
                XCTAssertTrue(NSApp.sendAction(table.doubleAction!, to: table.target, from: table))
            case "searchReturn":
                XCTAssertTrue(controller.control(search, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
            case "context":
                let menu = NSMenu(); controller.menuNeedsUpdate(menu)
                let item = try XCTUnwrap(menu.items.first { $0.action == #selector(PanelController.copySelected) })
                XCTAssertTrue(NSApp.sendAction(item.action!, to: item.target, from: menu))
            default:
                let code: UInt16 = action == "return" ? 36 : action == "number" ? 18 : 8
                let characters = action == "return" ? "\r" : action == "number" ? "1" : "c"
                let flags: NSEvent.ModifierFlags = action == "return" ? [] : action == "plain" ? [.command, .shift] : .command
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: controller.panel.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
                XCTAssertTrue(controller.panel.handleKey!(event))
            }
            for _ in 0..<100 {
                if board.changeCount != generation { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNotEqual(board.changeCount, generation, action)
            XCTAssertEqual(board.string(forType: .string), payload.plainText, action)
            XCTAssertEqual(board.data(forType: .html), action == "plain" ? nil : payload.items[0].data("public.html"), action)
            XCTAssertEqual(model.noticeKey, "notice.copied", action)
            XCTAssertTrue(controller.panel.isVisible, action)
            XCTAssertTrue(controller.panel.firstResponder === responder, action)
        }
    }
    func testCopyAcknowledgesItsGenerationWithoutAddingHistory() async throws {
        let (model, board, payload, id) = try await fixture()
        Preferences.defaults.set(true, forKey: "consent")
        try model.copy(payload)
        model.poll(); await model.captureTask?.value
        let records = try await model.store.records()
        XCTAssertEqual(records.count, 1); XCTAssertEqual(records.first?.id, id); XCTAssertEqual(records.first?.copies, 1)
        XCTAssertEqual(try Clipboard.read(board)?.payload, payload)
    }
    func testSettingsRemoveActionAndAccessibilityPermissionInBothLanguages() {
        for language in ["zh-Hans", "en"] {
            Preferences.defaults.set(language, forKey: "language")
            for page in [0, 4] {
                let settings = SettingsController(model: AppModel(), initialPage: page)
                let views = descendants(settings.window!.contentView!)
                XCTAssertFalse(views.contains { $0.identifier?.rawValue == "form.defaultAction" })
                let titles = views.compactMap { ($0 as? NSTextField)?.stringValue ?? ($0 as? NSButton)?.title }.joined(separator: "\n")
                for removed in ["默认使用动作", "Default Action", "启用粘贴", "Enable Paste", "辅助功能", "Accessibility", "自动粘贴", "Automatic paste"] {
                    XCTAssertFalse(titles.contains(removed), removed)
                }
                XCTAssertTrue(titles.contains(page == 4 ? L("clipboardAccess") : L("shortcut")))
                settings.window?.close()
            }
        }
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}

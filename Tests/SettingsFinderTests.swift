import XCTest
import AppKit
import CryptoKit

@MainActor final class SettingsFinderTests: XCTestCase {
    private var models: [AppModel] = []
    private var panels: [PanelController] = []
    private var directories: [URL] = []
    override func setUp() async throws {
        _ = NSApplication.shared; Preferences.register()
        Preferences.defaults.set(false, forKey: "consent")
    }
    override func tearDown() async throws {
        panels.forEach { $0.hide() }
        for model in models { model.stop(); await model.store.close() }
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        Preferences.defaults.removeObject(forKey: "consent")
        Preferences.defaults.removeObject(forKey: "language")
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url); return url
    }
    private func payload(_ urls: [URL]) -> ClipPayload {
        ClipPayload(items: urls.map { ClipItem(representations: [Representation(type: "public.file-url", data: Data($0.absoluteString.utf8))]) })
    }
    private func filePanel(_ urls: [URL], reveal: @escaping @MainActor ([URL]) -> Void) async throws -> (PanelController, AppModel) {
        let store = HistoryStore(directory: try directory(), testKey: SymmetricKey(size: .bits256))
        let model = AppModel(store: store); models.append(model); await model.start()
        let content = payload(urls)
        _ = try await store.insert(CapturedClip(kind: .file, payload: content, summary: ClipSummary(title: urls.map(\.lastPathComponent).joined(separator: ", "), detail: "", hasText: false, format: ClipFormat.detect(content, kind: .file)), partial: false))
        let rows = try await store.search("", kind: nil, savedOnly: false)
        let controller = PanelController(model: model, initialRows: rows, revealInFinder: reveal)
        panels.append(controller); controller.show()
        table(controller).reloadData(); table(controller).selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        return (controller, model)
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Timed out waiting for the panel operation")
    }
    func testSettingsKeepPanelVisibleWithSelectionPositionAndPin() {
        for pinned in [false, true] {
            let model = AppModel()
            let rows = (0..<2).map { n in
                ClipRow(record: ClipRecord(id: String(n), created: .now, copied: .now, kind: .text, bytes: 0, saved: false, copies: 1, partial: false), summary: ClipSummary(title: "Text \(n)", detail: "", hasText: true))
            }
            let controller = PanelController(model: model, initialRows: rows)
            models.append(model); panels.append(controller)
            let settings = SettingsController(model: model)
            controller.openSettings = { settings.present() }
            controller.show()
            let search = descendants(controller.panel.contentView!).compactMap { $0 as? NSSearchField }.first!
            search.stringValue = "保留搜索"
            table(controller).reloadData(); table(controller).selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            if pinned { button(controller, "panel.pin").performClick(nil) }
            let frame = controller.panel.frame
            let gear = descendants(controller.panel.contentView!).compactMap { $0 as? NSButton }.first { $0.action.map(NSStringFromSelector) == "settings" }!
            gear.performClick(nil)
            XCTAssertTrue(settings.window!.isVisible); XCTAssertTrue(controller.panel.isVisible)
            XCTAssertEqual(controller.isPinned, pinned); XCTAssertEqual(controller.panel.frame, frame)
            XCTAssertEqual(search.stringValue, "保留搜索")
            XCTAssertEqual(table(controller).selectedRow, 1)
            settings.window?.close()
            XCTAssertTrue(controller.panel.isVisible); XCTAssertEqual(controller.isPinned, pinned)
            controller.hide()
        }
    }
    func testFinderTargetsFileFolderAndMultipleItemsFromBothEntries() async throws {
        let root = try directory(), file = root.appendingPathComponent("带 空格 📄.txt"), folder = root.appendingPathComponent("文件夹", isDirectory: true)
        try Data("fixture".utf8).write(to: file)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for urls in [[file], [folder], [file, folder]] {
            var revealed: [[URL]] = []
            let (controller, _) = try await filePanel(urls) { revealed.append($0) }
            button(controller, "panel.details").performClick(nil)
            let reveal = button(controller, "panel.reveal")
            try await waitUntil { reveal.isEnabled }
            XCTAssertFalse(reveal.isHidden)
            reveal.performClick(nil)
            try await waitUntil { revealed.count == 1 }
            XCTAssertEqual(revealed[0], urls)
            let menu = NSMenu(); controller.menuNeedsUpdate(menu)
            let item = try XCTUnwrap(menu.items.first { $0.action.map(NSStringFromSelector) == "reveal" })
            XCTAssertEqual(item.title, L("reveal")); XCTAssertTrue(item.isEnabled)
            XCTAssertTrue(NSApp.sendAction(item.action!, to: item.target, from: menu))
            try await waitUntil { revealed.count == 2 }
            XCTAssertEqual(revealed[1], urls)
            controller.hide()
        }
    }
    func testMissingFileIsDisabledInDetailsAndContextReportsError() async throws {
        let file = try directory().appendingPathComponent("removed.txt")
        try Data("fixture".utf8).write(to: file)
        var revealed: [[URL]] = []
        let (controller, model) = try await filePanel([file]) { revealed.append($0) }
        try FileManager.default.removeItem(at: file)
        button(controller, "panel.details").performClick(nil)
        XCTAssertFalse(button(controller, "panel.reveal").isEnabled)
        let menu = NSMenu(); controller.menuNeedsUpdate(menu)
        let item = try XCTUnwrap(menu.items.first { $0.action.map(NSStringFromSelector) == "reveal" })
        XCTAssertTrue(NSApp.sendAction(item.action!, to: item.target, from: menu))
        try await waitUntil { model.noticeKey == "error.fileUnavailable" }
        XCTAssertTrue(revealed.isEmpty); XCTAssertNil(model.errorKey)
        XCTAssertFalse(button(controller, "panel.reveal").isEnabled)
    }
    func testEmptyReferencesAreRejectedAndTextHasNoFinderAction() throws {
        XCTAssertThrowsError(try FileReferences.availableURLs(in: ClipPayload(items: [])))
        let record = ClipRecord(id: "text", created: .now, copied: .now, kind: .text, bytes: 0, saved: false, copies: 1, partial: false)
        let controller = PanelController(model: AppModel(), initialRows: [ClipRow(record: record, summary: ClipSummary(title: "text", detail: "", hasText: true))])
        panels.append(controller); controller.show(); table(controller).reloadData()
        table(controller).selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let menu = NSMenu(); controller.menuNeedsUpdate(menu)
        XCTAssertFalse(menu.items.contains { $0.action.map(NSStringFromSelector) == "reveal" })
    }
    func testClosingPanelBeforeRevealCompletesDoesNotOpenFinder() async throws {
        let root = try directory()
        var revealed: [[URL]] = []
        let (controller, _) = try await filePanel([root]) { revealed.append($0) }
        let menu = NSMenu(); controller.menuNeedsUpdate(menu)
        let item = try XCTUnwrap(menu.items.first { $0.action.map(NSStringFromSelector) == "reveal" })
        XCTAssertTrue(NSApp.sendAction(item.action!, to: item.target, from: menu))
        controller.hide()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(revealed.isEmpty)
    }
    private func table(_ controller: PanelController) -> NSTableView { descendants(controller.panel.contentView!).compactMap { $0 as? NSTableView }.first! }
    private func button(_ controller: PanelController, _ id: String) -> NSButton { descendants(controller.panel.contentView!).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == id }! }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}

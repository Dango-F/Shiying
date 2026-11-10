import XCTest
import AppKit
import CryptoKit

@MainActor final class AppModelCaptureTests: XCTestCase {
    private var fixtures: [(AppModel, NSPasteboard, URL)] = []
    private var panels: [PanelController] = []
    override func setUp() async throws {
        _ = NSApplication.shared
        Preferences.register()
        Preferences.defaults.set(true, forKey: "consent")
        Preferences.defaults.set(false, forKey: "paused")
        Preferences.defaults.set([], forKey: "excludedApps")
    }
    override func tearDown() async throws {
        panels.forEach { $0.hide() }; panels.removeAll()
        for (model, board, folder) in fixtures {
            model.stop(); await model.store.close(); board.releaseGlobally()
            try FileManager.default.removeItem(at: folder)
        }
        fixtures.removeAll()
        for key in ["consent", "paused", "excludedApps"] { Preferences.defaults.removeObject(forKey: key) }
    }
    private func makeModel(source: @escaping @MainActor () -> String) async -> (AppModel, NSPasteboard) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShiyingCapture-" + UUID().uuidString)
        let board = NSPasteboard.withUniqueName()
        let store = HistoryStore(directory: folder, testKey: SymmetricKey(size: .bits256))
        let model = AppModel(store: store, pasteboard: board, clipboardAccess: { _ in true }, sourceBundleID: source)
        fixtures.append((model, board, folder)); await model.start()
        return (model, board)
    }
    private func imagePayload() throws -> ClipPayload {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 12, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        return ClipPayload(items: [ClipItem(representations: [Representation(type: "public.png", data: png)])])
    }
    func testScreenshotCaptureAcrossPanelVisibilityAndForegroundStates() async throws {
        let payload = try imagePayload()
        // 可见未固定、固定且前台是拾影、固定且前台是其他应用、面板隐藏。
        for (visible, pinned, frontmostSelf) in [(true, false, true), (true, true, true), (true, true, false), (false, false, false)] {
            let selfID = Bundle.main.bundleIdentifier ?? "com.shiying.capture.tests"
            let (model, board) = await makeModel(source: { frontmostSelf ? selfID : "com.example.editor" })
            let panel = PanelController(model: model); panels.append(panel)
            if visible { panel.show() }
            if pinned {
                let button = try XCTUnwrap(find(panel.panel.contentView!, id: "panel.pin") as? NSButton)
                button.performClick(nil)
            }
            _ = try Clipboard.write(payload, plain: false, to: board)
            model.poll(); await model.captureTask?.value
            XCTAssertNil(model.errorKey)
            XCTAssertEqual(model.stats.count, 1, "visible=\(visible), pinned=\(pinned), self=\(frontmostSelf)")
            let records = try await model.store.records()
            let record = try XCTUnwrap(records.first)
            XCTAssertEqual(record.kind, .image)
            let restored = try await model.store.payload(record.id)
            XCTAssertEqual(restored, payload)
            panel.hide(); model.stop()
        }
    }
    func testAcknowledgedOwnWriteDoesNotLoopButExternalCopyIsCaptured() async throws {
        let selfID = Bundle.main.bundleIdentifier ?? "com.shiying.capture.tests"
        let (model, board) = await makeModel(source: { selfID })
        let payload = try imagePayload()
        _ = try Clipboard.write(payload, plain: false, to: board)
        model.poll(); await model.captureTask?.value
        let ownGeneration = try Clipboard.write(payload, plain: false, to: board)
        model.acknowledgeWrite(ownGeneration); model.poll()
        XCTAssertNil(model.captureTask)
        let before = try await model.store.records()
        XCTAssertEqual(before.first?.copies, 1)
        _ = try Clipboard.write(payload, plain: false, to: board) // 模拟截图/其他外部写入，不作自身代次确认。
        model.poll(); await model.captureTask?.value
        let after = try await model.store.records()
        XCTAssertEqual(after.count, 1); XCTAssertEqual(after.first?.copies, 2)
    }
    func testExcludedGenerationIsNotImportedAfterFocusReturns() async throws {
        var source = "com.example.excluded"
        Preferences.defaults.set([source], forKey: "excludedApps")
        let (model, board) = await makeModel(source: { source })
        let payload = try imagePayload()
        _ = try Clipboard.write(payload, plain: false, to: board)
        model.poll(); XCTAssertNil(model.captureTask)
        source = Bundle.main.bundleIdentifier ?? "com.shiying.capture.tests"
        model.poll(); XCTAssertNil(model.captureTask)
        let excluded = try await model.store.records()
        XCTAssertTrue(excluded.isEmpty)
        _ = try Clipboard.write(payload, plain: false, to: board)
        model.poll(); await model.captureTask?.value
        XCTAssertEqual(model.stats.count, 1)
    }
    private func find(_ view: NSView, id: String) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        return view.subviews.lazy.compactMap { self.find($0, id: id) }.first
    }
}

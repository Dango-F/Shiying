import XCTest
import AppKit
import ObjectiveC.runtime

@MainActor final class LayoutTests: XCTestCase {
    override func setUp() async throws {
        _ = NSApplication.shared
        Preferences.register()
    }
    override func tearDown() async throws {
        for key in ["language", "fontScale", "theme", "glass", "panelPinned", "panelOrigin"] { Preferences.defaults.removeObject(forKey: key) }
    }
    func testBottomRightFrameOnDifferentScreens() {
        for screen in [CGRect(x: 0, y: 32, width: 1_440, height: 840), CGRect(x: -1_920, y: 0, width: 1_920, height: 1_055), CGRect(x: 800, y: -900, width: 1_024, height: 720)] {
            for scale in [1.0, 1.3] {
                for details in [false, true] {
                    let frame = PanelGeometry.frame(in: screen, scale: scale, details: details)
                    XCTAssertEqual(frame.maxX, screen.maxX - 16, accuracy: 0.001)
                    XCTAssertEqual(frame.minY, screen.minY + 16, accuracy: 0.001)
                    XCTAssertTrue(screen.contains(frame))
                }
            }
        }
        let compact = PanelGeometry.frame(in: CGRect(x: 0, y: 0, width: 1_440, height: 900))
        XCTAssertEqual(compact.size, CGSize(width: 384, height: 408))
        XCTAssertLessThan(compact.width * compact.height, 440 * 600 * 0.7)
    }
    func testAllSettingsPagesAlignInBothLanguagesAndSizes() {
        let model = AppModel() // No start(): never reads or changes user clipboard/history.
        var checks = 0
        XCTAssertEqual(L("general"), Preferences.resolvedLanguage == "en" ? "General" : "通用")
        for language in ["zh-Hans", "en"] {
            Preferences.defaults.set(language, forKey: "language")
            for scale in [1.0, 1.3] {
                Preferences.defaults.set(scale, forKey: "fontScale")
                for page in 0..<6 {
                    for size in [NSSize(width: 680, height: 480), NSSize(width: 740, height: 560)] {
                        let controller = SettingsController(model: model, initialPage: page)
                        let window = controller.window!
                        window.setContentSize(size)
                        window.contentView!.layoutSubtreeIfNeeded()
                        let views = descendants(window.contentView!)
                        let navigation = views.compactMap { $0 as? SidebarButton }
                        XCTAssertEqual(navigation.count, 6)
                        let left = navigation.first?.frame.minX ?? -1
                        let width = navigation.first?.frame.width ?? -1
                        for item in navigation {
                            XCTAssertEqual(item.frame.minX, left, accuracy: 0.5)
                            XCTAssertEqual(item.frame.width, width, accuracy: 0.5)
                            XCTAssertGreaterThanOrEqual(item.bounds.height, 36)
                            let textWidth = (item.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13 * scale, weight: .medium)]).width
                            XCTAssertLessThanOrEqual(textWidth + SidebarButton.textInset * 2, item.bounds.width + 1)
                        }
                        let body = views.first { $0.identifier?.rawValue == "settings.body" } as! NSStackView
                        for child in body.arrangedSubviews where !child.isHidden {
                            XCTAssertEqual(child.alignmentRect(forFrame: child.frame).minX, 0, accuracy: 1, "page \(page), \(language), \(size)")
                            XCTAssertEqual(child.alignmentRect(forFrame: child.frame).width, body.bounds.width, accuracy: 1)
                        }
                        for row in views where row.identifier?.rawValue.hasPrefix("form.") == true {
                            XCTAssertGreaterThanOrEqual(row.bounds.height, 28)
                            for child in row.subviews where child is NSControl {
                                let rect = child.alignmentRect(forFrame: child.frame)
                                XCTAssertGreaterThanOrEqual(rect.minX, -2)
                                XCTAssertLessThanOrEqual(rect.maxX, row.bounds.width + 2)
                            }
                        }
                        XCTAssertTrue(views.contains { $0.identifier?.rawValue == "settings.version" })
                        window.close(); checks += 1
                    }
                }
            }
        }
        XCTAssertEqual(checks, 48)
    }
    func testCompactPanelControlsFit() {
        Preferences.defaults.set("en", forKey: "language")
        let controller = PanelController(model: AppModel())
        let window = controller.panel
        window.setContentSize(NSSize(width: 384, height: 408))
        window.contentView!.layoutSubtreeIfNeeded()
        let controls = descendants(window.contentView!).compactMap { $0 as? NSControl }
        XCTAssertFalse(controls.compactMap { $0 as? NSButton }.contains { ["copySelected", "pasteSelected", "enablePaste"].contains($0.action.map(NSStringFromSelector) ?? "") })
        let favorite = controls.first { $0.identifier?.rawValue == "panel.favorite" }!
        let detail = controls.first { $0.identifier?.rawValue == "panel.details" }!
        XCTAssertTrue(favorite.superview === detail.superview)
        let table = controls.compactMap { $0 as? NSTableView }.first!
        XCTAssertGreaterThan(window.contentView!.convert(favorite.bounds, from: favorite).minY, window.contentView!.convert(table.bounds, from: table).maxY)
        for control in descendants(window.contentView!).compactMap({ $0 as? NSControl }) where !control.isHidden && control.superview != nil {
            // Private native subcontrols have their own drawing overflow; inspect app-owned controls only.
            guard control.superview is NSStackView else { continue }
            let rect = control.alignmentRect(forFrame: control.frame)
            XCTAssertGreaterThanOrEqual(rect.width, 0)
            XCTAssertLessThanOrEqual(rect.maxX, control.superview!.bounds.width + 2)
        }
        controller.hide()
    }
    func testSearchHighlightsContentButNotTimeDimensionsOrPartialMetadata() {
        Preferences.defaults.set("zh-Hans", forKey: "language")
        let record = ClipRecord(id: "highlight", created: .now, copied: .now.addingTimeInterval(-25 * 60), kind: .text, bytes: 1, saved: false, copies: 1, partial: true)
        let cell = ClipCell(frame: NSRect(x: 0, y: 0, width: 344, height: 70))
        func label(_ id: String) -> NSTextField { descendants(cell).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == id }! }
        func hasHighlight(_ text: NSAttributedString) -> Bool {
            var found = false
            text.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: text.length)) { value, _, _ in if value != nil { found = true } }
            return found
        }
        cell.configure(ClipRow(record: record, summary: ClipSummary(title: "2. 正文", detail: "", hasText: true)), number: 1, query: "2", section: nil)
        XCTAssertTrue(hasHighlight(label("clip.title").attributedStringValue))
        XCTAssertTrue(label("clip.detail").stringValue.contains("2"))
        XCTAssertFalse(hasHighlight(label("clip.detail").attributedStringValue))
        cell.configure(ClipRow(record: record, summary: ClipSummary(title: "标题", detail: "正文中的2", hasText: true)), number: 1, query: "2", section: nil)
        XCTAssertTrue(hasHighlight(label("clip.detail").attributedStringValue))
        cell.configure(ClipRow(record: record, summary: ClipSummary(title: "格式", detail: "正文", hasText: true)), number: 1, query: "格式", section: nil)
        XCTAssertFalse(label("clip.detail").stringValue.contains("部分格式"))
        XCTAssertFalse(hasHighlight(label("clip.detail").attributedStringValue))
        cell.configure(ClipRow(record: record, summary: ClipSummary(title: "标题2", detail: "", hasText: false, pixelWidth: 25, pixelHeight: 200)), number: 1, query: "2", section: nil)
        XCTAssertFalse(hasHighlight(label("clip.detail").attributedStringValue))
    }
    func testSourceFormatMetadataDoesNotAddVisibleHintsOrHoverText() {
        for language in ["zh-Hans", "en"] {
            Preferences.defaults.set(language, forKey: "language")
            let cell = ClipCell(frame: NSRect(x: 0, y: 0, width: 344, height: 70))
            let summary = ClipSummary(title: "部分格式 is copied content", detail: "Actual preview", hasText: true)
            for partial in [true, false, true] {
                let row = ClipRow(record: ClipRecord(id: "format", created: .now, copied: .now, kind: .text, bytes: 1, saved: false, copies: 1, partial: partial), summary: summary)
                cell.configure(row, number: 1, query: "", section: nil)
                cell.layoutSubtreeIfNeeded()
                let views = descendants(cell)
                XCTAssertFalse(views.contains { $0.identifier?.rawValue == "clip.formatInfo" })
                XCTAssertTrue(views.allSatisfy { $0.toolTip == nil })
                XCTAssertNil(cell.accessibilityHelp())
                let title = views.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "clip.title" }!
                let detail = views.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "clip.detail" }!
                XCTAssertEqual(title.stringValue, summary.title)
                XCTAssertTrue(detail.stringValue.hasPrefix(L("text") + " · "))
                XCTAssertFalse(detail.stringValue.contains("Actual preview"))
            }
        }
    }
    func testSystemScreenshotModifiersAreNotConsumedByHistoryShortcuts() {
        let record = ClipRecord(id: "key", created: .now, copied: .now, kind: .text, bytes: 1, saved: false, copies: 1, partial: false)
        let rows = (0..<9).map { _ in ClipRow(record: record, summary: ClipSummary(title: "Fixture", detail: "", hasText: true)) }
        let controller = PanelController(model: AppModel(), initialRows: rows)
        let table = descendants(controller.panel.contentView!).compactMap { $0 as? NSTableView }.first!
        table.reloadData(); table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        for modifiers: NSEvent.ModifierFlags in [[.command, .shift], [.command, .control, .shift], [.command, .control], [.command, .option]] {
            let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: controller.panel.windowNumber, context: nil, characters: "3", charactersIgnoringModifiers: "3", isARepeat: false, keyCode: 20)!
            XCTAssertFalse(controller.panel.handleKey!(key))
            XCTAssertEqual(table.selectedRow, 0)
        }
        controller.hide()
    }
    func testLongClipRowUsesAvailableWidthAndKeepsReadableSelection() {
        let record = ClipRecord(id: "layout", created: .now, copied: .now, kind: .text, bytes: 1, saved: false, copies: 1, partial: false)
        let row = ClipRow(record: record, summary: ClipSummary(title: String(repeating: "Long fragment title 片段 ", count: 10), detail: "Preview remains readable", hasText: true))
        let cell = ClipCell(frame: NSRect(x: 0, y: 0, width: 344, height: 70))
        cell.configure(row, number: 1, query: "", section: "Today")
        cell.layoutSubtreeIfNeeded()
        let views = descendants(cell)
        let title = views.first { $0.identifier?.rawValue == "clip.title" }!
        let detail = views.first { $0.identifier?.rawValue == "clip.detail" }!
        let shortcut = views.first { $0.identifier?.rawValue == "clip.shortcut" }!
        XCTAssertGreaterThan(title.bounds.width, 200)
        XCTAssertGreaterThanOrEqual(detail.bounds.height, 12)
        XCTAssertEqual(cell.convert(shortcut.alignmentRect(forFrame: shortcut.frame), from: shortcut.superview!).maxX, 336, accuracy: 1)
        XCTAssertEqual(ClipSelectionRow().interiorBackgroundStyle, .normal)
    }
    func testPopulatedTableKeepsSelectedPreviewInsideItsRow() {
        let record = ClipRecord(id: "preview", created: .now, copied: .now, kind: .text, bytes: 1, saved: false, copies: 1, partial: false)
        let row = ClipRow(record: record, summary: ClipSummary(title: String(repeating: "Long title 片段 ", count: 10), detail: "Preview remains readable", hasText: true))
        let controller = PanelController(model: AppModel(), initialRows: [row])
        controller.panel.contentView!.layoutSubtreeIfNeeded()
        let table = descendants(controller.panel.contentView!).compactMap { $0 as? NSTableView }.first!
        table.reloadData(); table.layoutSubtreeIfNeeded()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let cell = table.view(atColumn: 0, row: 0, makeIfNecessary: true) as! ClipCell
        cell.layoutSubtreeIfNeeded(); cell.backgroundStyle = .emphasized
        let detail = descendants(cell).first { $0.identifier?.rawValue == "clip.detail" }!
        let rect = cell.convert(detail.bounds, from: detail)
        XCTAssertGreaterThanOrEqual(rect.minY, 0)
        XCTAssertLessThanOrEqual(rect.maxY, cell.bounds.height)
        XCTAssertGreaterThanOrEqual(rect.height, 12)
        XCTAssertEqual(cell.backgroundStyle, .normal)
        controller.hide()
    }
    func testMovedPositionRestoresAndClampsToScreen() {
        let screen = CGRect(x: -1_920, y: -100, width: 1_920, height: 1_000)
        let origin = CGPoint(x: -1_600, y: 100)
        XCTAssertEqual(PanelGeometry.frame(in: screen, origin: origin).origin, origin)
        for point in [CGPoint(x: -9_999, y: 9_999), CGPoint(x: 9_999, y: -9_999)] {
            XCTAssertTrue(screen.insetBy(dx: 16, dy: 16).contains(PanelGeometry.frame(in: screen, details: true, origin: point)))
        }
        let defaultFrame = PanelGeometry.frame(in: screen)
        XCTAssertEqual(PanelGeometry.frame(in: screen, origin: CGPoint(x: CGFloat.nan, y: 0)), defaultFrame)
    }
    func testPinButtonIsSessionScopedAndOutsideClickRespectsPin() {
        Preferences.defaults.set(false, forKey: "panelPinned")
        let controller = PanelController(model: AppModel())
        controller.panel.contentView!.layoutSubtreeIfNeeded()
        let button = descendants(controller.panel.contentView!).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "panel.pin" }!
        button.performClick(nil)
        XCTAssertTrue(controller.isPinned); XCTAssertEqual(button.state, .on)
        XCTAssertEqual(button.bezelColor, UI.pinnedBackground)
        XCTAssertEqual(button.contentTintColor, UI.brand)
        XCTAssertEqual(controller.panel.level, .floating)
        XCTAssertFalse(controller.dismissForOutsideClick())
        let restored = PanelController(model: AppModel())
        XCTAssertFalse(restored.isPinned)
        button.performClick(nil)
        XCTAssertFalse(controller.isPinned); XCTAssertEqual(button.state, .off)
        XCTAssertTrue(controller.dismissForOutsideClick())
        restored.hide()
    }
    func testDragHandlePreservesHeaderButtonsAndOrigin() {
        let controller = PanelController(model: AppModel())
        controller.panel.contentView!.layoutSubtreeIfNeeded()
        let header = descendants(controller.panel.contentView!).compactMap { $0 as? PanelDragRegion }.first!
        let pin = descendants(header).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "panel.pin" }!
        let buttonPoint = header.convert(NSPoint(x: pin.bounds.midX, y: pin.bounds.midY), from: pin)
        let buttonHit = header.hitTest(header.convert(buttonPoint, to: header.superview))
        XCTAssertTrue(buttonHit === pin)
        let label = descendants(header).compactMap { $0 as? NSTextField }.first!
        let labelPoint = header.convert(NSPoint(x: label.bounds.midX, y: label.bounds.midY), from: label)
        XCTAssertTrue(header.hitTest(header.convert(labelPoint, to: header.superview)) === header)
        XCTAssertFalse(controller.panel.isMovable)
        XCTAssertTrue(controller.panel.canStartDragging(at: NSPoint(x: 5, y: controller.panel.frame.height - 4)))
        XCTAssertFalse(controller.panel.canStartDragging(at: pin.convert(NSPoint(x: 15, y: 15), to: nil)))
        XCTAssertFalse(controller.panel.canStartDragging(at: NSPoint(x: 80, y: header.convert(header.bounds, to: nil).minY - 30)))
        controller.panel.setFrameOrigin(NSPoint(x: 200, y: 200))
        let dragAnchor = header.convert(labelPoint, to: nil)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: dragAnchor, modifierFlags: [], timestamp: 0, windowNumber: controller.panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let drag = NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: dragAnchor.x - 60, y: dragAnchor.y + 30), modifierFlags: [], timestamp: 1, windowNumber: controller.panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let queued = NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: dragAnchor.x - 40, y: dragAnchor.y + 45), modifierFlags: [], timestamp: 2, windowNumber: controller.panel.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: dragAnchor.x - 40, y: dragAnchor.y + 45), modifierFlags: [], timestamp: 3, windowNumber: controller.panel.windowNumber, context: nil, eventNumber: 3, clickCount: 1, pressure: 0)!
        controller.panel.sendEvent(down); controller.panel.sendEvent(drag)
        XCTAssertEqual(controller.panel.frame.origin, NSPoint(x: 140, y: 230))
        controller.panel.sendEvent(queued)
        XCTAssertEqual(controller.panel.frame.origin, NSPoint(x: 160, y: 245))
        controller.panel.sendEvent(up); header.mouseDragged(with: drag)
        XCTAssertEqual(controller.panel.frame.origin, NSPoint(x: 160, y: 245))
        controller.hide()
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func testNativeGlassCoversWholeSurfaceAndCarriesContent() {
        for theme in ["light", "dark"] {
            Preferences.defaults.set(theme, forKey: "theme")
            for scheme in ["adaptive", "groups", "surface", "ink"] {
                Preferences.defaults.set(scheme, forKey: "glass")
                let expected = scheme == "ink" ? "ink" : "adaptive"
                XCTAssertEqual(Preferences.glass, expected)
                let settings = SettingsController(model: AppModel(), initialPage: 3)
                let popup = descendants(settings.window!.contentView!).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "glass" }!
                XCTAssertEqual(popup.itemTitles, [L("adaptive"), L("ink")])
                XCTAssertEqual(popup.selectedItem?.representedObject as? String, expected)
                settings.window?.close()
                let controller = PanelController(model: AppModel())
                controller.show()
                let root = controller.panel.contentView!
                root.layoutSubtreeIfNeeded()
                let glasses = descendants(root).compactMap { $0 as? NSGlassEffectView }
                XCTAssertEqual(glasses.count, 1)
                let glass = glasses[0]
                XCTAssertEqual(glass.frame, root.bounds)
                XCTAssertNil(glass.layer?.mask, "Liquid Glass must render its center, not just a rim")
                XCTAssertFalse(root.subviews.contains { $0 is NSVisualEffectView }, "A replacement material must not cover native glass")
                let content = glass.contentView!
                XCTAssertTrue(descendants(content).contains { $0 is NSSearchField })
                XCTAssertTrue(descendants(content).contains { $0 is NSTableView })
                controller.panel.resignKey()
                NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: controller.panel)
                XCTAssertFalse(glass.isHidden)
                XCTAssertTrue(glass.contentView === content)
                XCTAssertNil(glass.layer?.mask)
                XCTAssertFalse(descendants(root).compactMap { $0 as? NSButton }.contains { $0.action == NSSelectorFromString("togglePause") })
                controller.hide()
            }
        }
    }
    func testOnlyPinnedPositionRestoresAfterClosing() {
        Preferences.defaults.set(false, forKey: "panelPinned")
        Preferences.defaults.set([120.0, 120.0], forKey: "panelOrigin")
        Preferences.register() // 升级时清除旧版持久化的面板状态。
        let controller = PanelController(model: AppModel())
        let screen = NSScreen.screens.first!
        let defaultFrame = PanelGeometry.frame(in: screen.visibleFrame)
        for _ in 0..<3 {
            controller.show(screen: screen)
            XCTAssertEqual(controller.panel.frame, defaultFrame)
            controller.panel.setFrameOrigin(NSPoint(x: defaultFrame.minX - 80, y: defaultFrame.minY + 30))
            XCTAssertTrue(controller.dismissForOutsideClick())
            XCTAssertNil(Preferences.defaults.object(forKey: "panelOrigin"))
        }
        controller.show(screen: screen)
        let button = descendants(controller.panel.contentView!).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "panel.pin" }!
        controller.panel.setFrameOrigin(NSPoint(x: defaultFrame.minX - 80, y: defaultFrame.minY + 30))
        button.performClick(nil)
        let pinned = controller.panel.frame
        XCTAssertNotEqual(pinned, defaultFrame)
        controller.toggle()
        XCTAssertFalse(controller.panel.isVisible); XCTAssertFalse(controller.isPinned)
        controller.toggle()
        XCTAssertTrue(controller.panel.isVisible); XCTAssertFalse(controller.isPinned)
        controller.hide(); controller.show(screen: screen)
        XCTAssertEqual(controller.panel.frame, defaultFrame)
        XCTAssertEqual(button.state, .off)
        controller.hide()
    }
    func testNativeGlassKeepsActiveAppearanceWithoutHoldingKeyboardFocus() {
        XCTAssertTrue(NativeGlassAppearance.installIfSupported(), "Current macOS must support the checked appearance query")
        let original = class_getMethodImplementation(NSPanel.self, NativeGlassAppearance.query)!
        let installed = class_getMethodImplementation(KeyPanel.self, NativeGlassAppearance.query)!
        XCTAssertNotEqual(unsafeBitCast(original, to: UInt.self), unsafeBitCast(installed, to: UInt.self))
        let appearance = unsafeBitCast(installed, to: (@convention(c) (AnyObject, Selector) -> Bool).self)
        let systemAppearance = unsafeBitCast(original, to: (@convention(c) (AnyObject, Selector) -> Bool).self)
        let controller = PanelController(model: AppModel())
        controller.show()
        let pin = descendants(controller.panel.contentView!).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "panel.pin" }!
        pin.performClick(nil)
        controller.panel.displayIfNeeded()
        // 直接调用之前，确认 AppKit 渲染确实使用了这个查询。
        XCTAssertGreaterThan(controller.panel.glassAppearanceQueryCount, 0)
        defer { controller.hide() }
        // 命令行 XCTest 不具备真实前台 App 身份；这里验证失去 key 状态后
        // 外观仍为 active，查询不修改实际 key window，也不修改系统基类。
        for _ in 0..<3 {
            controller.panel.resignKey()
            let actualKeyWindow = NSApp.keyWindow
            XCTAssertFalse(controller.panel.isKeyWindow)
            XCTAssertTrue(appearance(controller.panel, NativeGlassAppearance.query))
            XCTAssertFalse(controller.panel.isKeyWindow)
            XCTAssertTrue(NSApp.keyWindow === actualKeyWindow)
            XCTAssertEqual(unsafeBitCast(class_getMethodImplementation(NSPanel.self, NativeGlassAppearance.query)!, to: UInt.self), unsafeBitCast(original, to: UInt.self))
        }
        // 取消固定后，返回值必须与系统原实现一致，不能永久强制 active。
        pin.performClick(nil)
        XCTAssertEqual(appearance(controller.panel, NativeGlassAppearance.query), systemAppearance(controller.panel, NativeGlassAppearance.query))
        // 独立的未固定面板也保持系统行为，不继承另一个窗口的固定状态。
        let unpinned = PanelController(model: AppModel())
        XCTAssertEqual(appearance(unpinned.panel, NativeGlassAppearance.query), systemAppearance(unpinned.panel, NativeGlassAppearance.query))
        unpinned.hide()
    }
}

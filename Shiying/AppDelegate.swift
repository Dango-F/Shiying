import AppKit
import Darwin

@main @MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var model: AppModel!
    private var statusItem: NSStatusItem!
    private var panelController: PanelController!
    private var settingsController: SettingsController?
    private var hotkey: HotKey!
    private var terminationSignal: DispatchSourceSignal?
    private var lastPreferences = ""
    private var lastIconState = -1
    static func main() {
        let app = NSApplication.shared; let delegate = AppDelegate(); app.delegate = delegate
        app.setActivationPolicy(.accessory); withExtendedLifetime(delegate) { app.run() }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Preferences.register(); buildMainMenu()
        Darwin.signal(SIGTERM, SIG_IGN)
        let signal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        signal.setEventHandler { [weak self] in
            RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { self?.quit() } }
        }
        signal.resume(); terminationSignal = signal
        model = AppModel(); panelController = PanelController(model: model)
        panelController.openSettings = { [weak self] in self?.showSettings() }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = Preferences.defaults.bool(forKey: "showStatusItem")
        if let button = statusItem.button {
            button.target = self; button.action = #selector(statusClicked); button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        panelController.onVisibilityChange = { [weak self] visible in
            self?.statusItem.button?.state = visible ? .on : .off
            self?.statusItem.button?.setAccessibilityValue(L(visible ? "expanded" : "collapsed"))
        }
        hotkey = HotKey(); hotkey.onPress = { [weak self] in self?.togglePanel() }
        if !registerHotkey() { model.notice("error.hotkey") }
        model.onChange = { [weak self] in self?.modelChanged() }
        model.onSessionLock = { [weak self] in self?.panelController.purgePreviews() }
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged), name: .preferencesChanged, object: nil)
        Task {
            await model.start(); modelChanged()
            do { try LoginItem.applyDefault() } catch { model.notice("error.login") }
            if model.errorKey == "error.instance" {
                if let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.shiying.mac").first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) { other.activate(options: []) }
                let alert = NSAlert(); alert.messageText = L("error.instance"); alert.addButton(withTitle: L("close")); alert.runModal(); NSApp.terminate(nil); return
            }
            if ProcessInfo.processInfo.arguments.contains("--settings") { showSettings() }
            else if !model.consent { showOnboarding() }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { if !flag { showPanel() }; return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        hotkey?.stop(); model.stop(); panelController.purgePreviews()
        let store = model.store
        Task.detached {
            await store.close()
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated { NSApp.reply(toApplicationShouldTerminate: true) }
            }
        }
        return .terminateLater
    }
    private func showOnboarding() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = L("onboarding.title"); alert.informativeText = L("onboarding.detail").replacingOccurrences(of: "~/Library/Application Support/com.shiying.mac", with: (model.store.location.path as NSString).abbreviatingWithTildeInPath)
        alert.icon = NSApp.applicationIconImage; alert.addButton(withTitle: L("start")); alert.addButton(withTitle: L("later"))
        if alert.runModal() == .alertFirstButtonReturn { model.enableRecording() }
        showPanel()
    }
    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu(); menu.delegate = self; statusItem.menu = menu; statusItem.button?.performClick(nil); statusItem.menu = nil
        } else { togglePanel() }
    }
    private func togglePanel() { panelController.toggle() }
    private func showPanel() { panelController.show() }
    @objc private func openPanel() { showPanel() }
    @objc private func showSettings() {
        if settingsController == nil {
            settingsController = SettingsController(model: model)
            settingsController?.onShortcutChange = { [weak self] in self?.registerHotkey() ?? false }
        }
        settingsController?.present()
    }
    @objc private func preferencesChanged() {
        let signature = Preferences.resolvedLanguage + String(Preferences.scale)
        if lastPreferences != signature { lastPreferences = signature; buildMainMenu(); panelController.localize() }
        panelController.panel.appearance = Preferences.appearance
        statusItem.isVisible = Preferences.defaults.bool(forKey: "showStatusItem")
    }
    private func registerHotkey() -> Bool { hotkey.register(code: UInt32(Preferences.defaults.integer(forKey: "hotkeyCode")), modifiers: UInt32(Preferences.defaults.integer(forKey: "hotkeyModifiers"))) }
    private func modelChanged() {
        let state = model.errorKey != nil || model.consent && !model.accessAllowed ? 2 : model.recording ? 0 : 1
        if state != lastIconState { statusItem.button?.image = FragmentMark.image(state: state); lastIconState = state }
        let title = BuildInfo.displayName + ", " + L(model.statusKey)
        statusItem.button?.toolTip = title; statusItem.button?.setAccessibilityLabel(title)
        statusItem.button?.setAccessibilityValue(panelController.panel.isVisible ? L("expanded") : L("collapsed"))
        if model.errorKey == "error.key" || model.errorKey == "error.keyAuthorization" || model.errorKey == "error.authentication" { panelController.purgePreviews() }
        if panelController.panel.isVisible { panelController.updateState(); panelController.refresh() }
        settingsController?.refreshStatus()
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = NSMenuItem(title: L(model.statusKey), action: nil, keyEquivalent: ""); state.isEnabled = false; menu.addItem(state)
        add(menu, "open", #selector(openPanel)); menu.addItem(.separator())
        if !model.consent { add(menu, "start", #selector(startRecording)) }
        else if model.paused { add(menu, "resume", #selector(resume)) }
        // 手动暂停入口暂时关闭，保留原菜单实现。旧版本暂停中的用户仍可恢复。
        // else {
        //     add(menu, "pause15", #selector(pause15)); add(menu, "pause60", #selector(pause60)); add(menu, "pauseManual", #selector(pauseManual))
        // }
        add(menu, "settings", #selector(showSettings)); menu.addItem(.separator())
        add(menu, "quit", #selector(quit))
    }
    private func add(_ menu: NSMenu, _ key: String, _ selector: Selector, equivalent: String = "") {
        let item = NSMenuItem(title: L(key), action: selector, keyEquivalent: equivalent); item.target = self; menu.addItem(item)
    }
    private func buildMainMenu() {
        let main = NSMenu(); let appItem = NSMenuItem(); let app = NSMenu(title: BuildInfo.displayName); appItem.submenu = app; main.addItem(appItem)
        let open = NSMenuItem(title: L("open"), action: #selector(openPanel), keyEquivalent: "")
        open.target = self; app.addItem(open)
        let close = NSMenuItem(title: L("closeWindow"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        app.addItem(close)
        add(app, "settings", #selector(showSettings), equivalent: ","); app.addItem(.separator()); add(app, "quit", #selector(quit), equivalent: "q")
        let editItem = NSMenuItem(title: L("edit"), action: nil, keyEquivalent: ""); let edit = NSMenu(title: L("edit")); editItem.submenu = edit; main.addItem(editItem)
        for (key, selector, equivalent) in [("undo", Selector(("undo:")), "z"), ("cut", #selector(NSText.cut(_:)), "x"), ("copy", #selector(NSText.copy(_:)), "c"), ("paste", #selector(NSText.paste(_:)), "v"), ("selectAll", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(NSMenuItem(title: L(key), action: selector, keyEquivalent: equivalent))
        }
        NSApp.mainMenu = main
    }
    @objc private func startRecording() { showOnboarding() }
    // 暂停操作暂不开放，保留原实现以便后续恢复。
    // @objc private func pause15() { model.pause(seconds: 15 * 60) }
    // @objc private func pause60() { model.pause(seconds: 60 * 60) }
    // @objc private func pauseManual() { model.pause() }
    @objc private func resume() { model.resume() }
    @objc private func quit() { NSApp.terminate(nil) }
}

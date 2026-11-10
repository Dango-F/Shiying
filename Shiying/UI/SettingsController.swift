import AppKit
import ServiceManagement
import Carbon

@MainActor final class SettingsController: NSWindowController, NSWindowDelegate {
    private let model: AppModel
    private let surface = GlassSurface()
    private let sidebar = NSStackView()
    private let content = FlippedView()
    private let scroll = NSScrollView()
    private var page = 0
    private var buttons: [SidebarButton] = []
    private let pages = ["general", "history", "privacy", "appearance", "permissions", "about"]
    private var language = Preferences.resolvedLanguage
    private var scale = Preferences.scale
    private var preview: GlassSurface?
    private var stateLabel: NSTextField?
    private var capacityLabel: NSTextField?
    private var usageLabel: NSTextField?
    private var diskLabel: NSTextField?
    private var permissionsLabel: NSTextField?
    private var loginLabel: NSTextField?
    private var clarityLabel: NSTextField?
    private var shortcut: ShortcutRecorder?
    private var loginSwitch: NSSwitch?
    var onShortcutChange: (() -> Bool)?

    init(model: AppModel, initialPage: Int = 0) {
        self.model = model; page = min(5, max(0, initialPage))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 560), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        super.init(window: window)
        window.delegate = self; window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 680, height: 480)
        window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.isOpaque = false; window.backgroundColor = .clear
        surface.usesSchemeInk = false; surface.update(); window.contentView = surface
        sidebar.orientation = .vertical; sidebar.alignment = .leading; sidebar.spacing = 6
        let brand = UI.row([NSImageView(image: FragmentMark.image()), UI.label(BuildInfo.displayName, size: 14, weight: .semibold)])
        brand.heightAnchor.constraint(equalToConstant: 28).isActive = true
        sidebar.addArrangedSubview(brand); sidebar.setCustomSpacing(20, after: brand)
        for (n, key) in pages.enumerated() {
            let b = SidebarButton(title: L(key), target: self, action: #selector(changePage)); b.tag = n
            b.isBordered = false; b.setAccessibilityLabel(L(key)); b.identifier = .init("settings.nav." + key)
            b.heightAnchor.constraint(equalToConstant: 36).isActive = true
            sidebar.addArrangedSubview(b); UI.fill(b, in: sidebar); buttons.append(b)
        }
        sidebar.addArrangedSubview(UI.spacer())
        let version = UI.label(BuildInfo.shortVersion, size: 10, secondary: true)
        version.identifier = .init("settings.version"); version.toolTip = BuildInfo.fullVersion
        let footer = NSView(); UI.pin(version, in: footer)
        footer.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addArrangedSubview(footer)
        footer.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: SidebarButton.textInset).isActive = true
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.documentView = content
        sidebar.translatesAutoresizingMaskIntoConstraints = false; scroll.translatesAutoresizingMaskIntoConstraints = false; content.translatesAutoresizingMaskIntoConstraints = false
        surface.foreground.addSubview(sidebar); surface.foreground.addSubview(scroll)
        NSLayoutConstraint.activate([sidebar.leadingAnchor.constraint(equalTo: surface.foreground.leadingAnchor, constant: 20), sidebar.topAnchor.constraint(equalTo: surface.foreground.topAnchor, constant: 52), sidebar.bottomAnchor.constraint(equalTo: surface.foreground.bottomAnchor, constant: -20), sidebar.widthAnchor.constraint(equalToConstant: 144), scroll.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 16), scroll.trailingAnchor.constraint(equalTo: surface.foreground.trailingAnchor, constant: -16), scroll.topAnchor.constraint(equalTo: surface.foreground.topAnchor, constant: 52), scroll.bottomAnchor.constraint(equalTo: surface.foreground.bottomAnchor, constant: -16), content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)])
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged), name: .preferencesChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshStatus), name: NSApplication.didBecomeActiveNotification, object: nil)
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError() }
    func present(page: Int? = nil) {
        if let page { self.page = page; rebuild() }
        window?.appearance = Preferences.appearance
        window?.center(); NSApp.activate(ignoringOtherApps: true); showWindow(nil); window?.makeKeyAndOrderFront(nil); refreshStatus()
    }
    func windowWillClose(_ notification: Notification) { shortcut?.cancelRecording() }
    @objc private func changePage(_ sender: NSButton) { page = sender.tag; rebuild() }
    @objc private func preferencesChanged() {
        window?.appearance = Preferences.appearance
        if language != Preferences.resolvedLanguage || scale != Preferences.scale {
            language = Preferences.resolvedLanguage; scale = Preferences.scale; rebuild()
        }
        surface.update(); preview?.update(); refreshStatus()
    }
    @objc func refreshStatus() {
        guard window?.isVisible == true else { return }
        stateLabel?.stringValue = L(model.noticeKey ?? model.statusKey)
        loginSwitch?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let s = model.stats
        capacityLabel?.stringValue = s.saved == 30 ? F("saved.count", s.saved) + " · " + F("buffer.count", s.buffer) : F("history.count", s.count) + " · " + F("saved.count", s.saved)
        let formatter = ByteCountFormatter(); formatter.countStyle = .binary
        usageLabel?.stringValue = formatter.string(fromByteCount: Int64(s.bytes)) + " / 200 MiB"
        diskLabel?.stringValue = formatter.string(fromByteCount: Int64(s.databaseBytes))
        permissionsLabel?.stringValue = L(model.accessAllowed ? "permission.allowed" : "permission.required")
        loginLabel?.stringValue = L(SMAppService.mainApp.status == .enabled ? "login.enabled" : SMAppService.mainApp.status == .requiresApproval ? "login.approval" : "login.disabled")
        clarityLabel?.stringValue = Preferences.clarity.formatted(.percent.precision(.fractionLength(0)))
    }
    private func rebuild() {
        shortcut?.cancelRecording(); shortcut = nil; preview = nil; loginSwitch = nil
        content.subviews.forEach { $0.removeFromSuperview() }
        stateLabel = nil; capacityLabel = nil; usageLabel = nil; diskLabel = nil; permissionsLabel = nil; loginLabel = nil; clarityLabel = nil
        for (n, button) in buttons.enumerated() {
            button.title = L(pages[n]); button.setAccessibilityLabel(L(pages[n])); button.selected = n == page
        }
        window?.title = BuildInfo.displayName + " · " + L("settings"); window?.appearance = Preferences.appearance
        let heading = UI.label(L(pages[page]), size: 23, weight: .semibold)
        let body = UI.column([heading, UI.paragraph(L(pages[page] + ".subtitle"))], spacing: 16)
        body.identifier = .init("settings.body")
        switch page {
        case 0: general(body)
        case 1: history(body)
        case 2: privacy(body)
        case 3: appearance(body)
        case 4: permissions(body)
        default: about(body)
        }
        body.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(body)
        NSLayoutConstraint.activate([body.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12), body.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12), body.topAnchor.constraint(equalTo: content.topAnchor), body.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24)])
        for child in body.arrangedSubviews { UI.fill(child, in: body) }
        scroll.contentView.scroll(to: .zero)
        refreshStatus()
    }
    private func group(_ views: [NSView], in body: NSStackView) {
        let stack = UI.column(views, spacing: 12)
        for child in views { UI.fill(child, in: stack) }
        body.addArrangedSubview(UI.card(stack))
    }
    private func popup(key: String, values: [String], titles: [String]) -> NSPopUpButton {
        let button = NSPopUpButton(); button.addItems(withTitles: titles)
        for (n, value) in values.enumerated() { button.item(at: n)?.representedObject = value }
        button.identifier = .init(key); button.selectItem(at: values.firstIndex(of: Preferences.defaults.string(forKey: key) ?? "") ?? 0)
        button.widthAnchor.constraint(equalToConstant: 156).isActive = true
        button.target = self; button.action = #selector(popupChanged); return button
    }
    private func formRow(_ key: String, control: NSView) -> NSView {
        let label = UI.label(L(key)); label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = UI.row([label, UI.spacer(), control], spacing: 12)
        row.identifier = .init("form." + key)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        return row
    }
    @objc private func popupChanged(_ sender: NSPopUpButton) {
        guard let key = sender.identifier?.rawValue, let value = sender.selectedItem?.representedObject as? String else { return }
        Preferences.set(value, key)
    }
    private func general(_ body: NSStackView) {
        let login = NSSwitch(); login.target = self; login.action = #selector(loginChanged)
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.setAccessibilityLabel(L("launchAtLogin")); loginSwitch = login
        let status = NSSwitch(); status.target = self; status.action = #selector(statusItemChanged)
        status.state = Preferences.defaults.bool(forKey: "showStatusItem") ? .on : .off
        status.setAccessibilityLabel(L("showStatusItem"))
        let recorder = ShortcutRecorder(); shortcut = recorder
        recorder.onRecorded = { [weak self] code, modifiers, title in
            let oldCode = Preferences.defaults.integer(forKey: "hotkeyCode"), oldFlags = Preferences.defaults.integer(forKey: "hotkeyModifiers"), oldTitle = Preferences.defaults.string(forKey: "hotkeyTitle")
            Preferences.defaults.set(code, forKey: "hotkeyCode"); Preferences.defaults.set(modifiers, forKey: "hotkeyModifiers")
            if self?.onShortcutChange?() != true {
                Preferences.defaults.set(oldCode, forKey: "hotkeyCode"); Preferences.defaults.set(oldFlags, forKey: "hotkeyModifiers"); Preferences.defaults.set(oldTitle, forKey: "hotkeyTitle")
                _ = self?.onShortcutChange?(); self?.model.notice("error.hotkey"); recorder.updateTitle(); return
            }
            Preferences.set(title, "hotkeyTitle")
        }
        let language = popup(key: "language", values: ["system", "zh-Hans", "en"], titles: [L("system"), "简体中文", "English"])
        let poll = NSPopUpButton(); poll.addItems(withTitles: ["250 ms", "500 ms", "1,000 ms"])
        poll.selectItem(at: Preferences.defaults.double(forKey: "pollInterval") < 0.5 ? 0 : Preferences.defaults.double(forKey: "pollInterval") < 1 ? 1 : 2)
        poll.widthAnchor.constraint(equalToConstant: 156).isActive = true
        poll.target = self; poll.action = #selector(pollChanged)
        group([formRow("launchAtLogin", control: login), formRow("showStatusItem", control: status), formRow("shortcut", control: recorder), formRow("language", control: language), formRow("poll", control: poll)], in: body)
        body.addArrangedSubview(UI.paragraph(L("general.note")))
        if BuildInfo.isDevelopment { body.addArrangedSubview(UI.paragraph(L("development.note"))) }
        stateLabel = UI.paragraph(""); body.addArrangedSubview(stateLabel!)
    }
    @objc private func pollChanged(_ sender: NSPopUpButton) { Preferences.set([0.25, 0.5, 1.0][sender.indexOfSelectedItem], "pollInterval") }
    @objc private func statusItemChanged(_ sender: NSSwitch) { Preferences.set(sender.state == .on, "showStatusItem") }
    @objc private func loginChanged(_ sender: NSSwitch) {
        do {
            try LoginItem.setEnabled(sender.state == .on)
            refreshStatus()
        } catch { sender.state = SMAppService.mainApp.status == .enabled ? .on : .off; model.notice("error.login") }
    }
    private func history(_ body: NSStackView) {
        capacityLabel = UI.label("", weight: .medium)
        let formatter = ByteCountFormatter(); formatter.countStyle = .binary
        let usage = formatter.string(fromByteCount: Int64(model.stats.bytes)) + " / 200 MiB"
        let database = formatter.string(fromByteCount: Int64(model.stats.databaseBytes))
        usageLabel = UI.label(usage); diskLabel = UI.label(database)
        group([UI.paragraph(L("retention")), capacityLabel!, formRow("capacity", control: usageLabel!), formRow("databaseSize", control: diskLabel!), UI.paragraph(L("limits"))], in: body)
        group([UI.button(L("clearUnsaved"), target: self, action: #selector(clearUnsaved)), UI.button(L("clearAll"), target: self, action: #selector(clearAll)), UI.paragraph(L("delete.note")), UI.button(L("clearClipboard"), target: self, action: #selector(clearClipboard))], in: body)
    }
    @objc private func clearUnsaved() {
        guard UI.confirm(title: L("clearUnsaved"), message: L("clearUnsaved.detail"), destructive: L("clearUnsaved")) else { return }
        Task { do { try await model.store.clear(includeSaved: false); await model.refresh(); rebuild() } catch { model.report(error) } }
    }
    @objc private func clearAll() {
        guard UI.confirm(title: L("clearAll.title"), message: L("clearAll.detail"), destructive: L("clearAll")) else { return }
        Task { do { try await model.store.clear(includeSaved: true); await model.refresh(); rebuild() } catch { model.report(error) } }
    }
    @objc private func clearClipboard() {
        if UI.confirm(title: L("clearClipboard"), message: L("clearClipboard.detail"), destructive: L("clearClipboard")) { model.clearClipboard() }
    }
    private func privacy(_ body: NSStackView) {
        stateLabel = UI.label("", weight: .medium)
        // 原暂停入口暂不开放，保留实现：
        // group([stateLabel!, UI.button(L(!model.consent ? "start" : model.paused ? "resume" : "pause"), target: self, action: #selector(toggleRecording)), UI.paragraph(L("privacy.capture"))], in: body)
        var recordingControls: [NSView] = [stateLabel!]
        if !model.consent || model.paused { recordingControls.append(UI.button(L(!model.consent ? "start" : "resume"), target: self, action: #selector(enableOrResumeRecording))) }
        recordingControls.append(UI.paragraph(L("privacy.capture")))
        group(recordingControls, in: body)
        let apps = Preferences.defaults.stringArray(forKey: "excludedApps") ?? []
        group([UI.label(L("excludedApps"), weight: .medium), UI.paragraph(apps.joined(separator: "\n")), UI.button(L("editExcluded"), target: self, action: #selector(editExcluded)), UI.button(L("addApplication"), target: self, action: #selector(addApplication)), UI.paragraph(L("exclusion.note"))], in: body)
        group([UI.label("AES-GCM · Keychain", weight: .medium), UI.paragraph(L("privacy.encryption")), UI.paragraph(L("privacy.sensitive")), UI.button(L("openStorage"), target: self, action: #selector(openStorage))], in: body)
    }
    // 暂停按钮及 action 注释保留。首次启用和旧暂停状态的恢复入口继续有效。
    // @objc private func toggleRecording() {
    //     if !model.consent { model.enableRecording() } else if model.paused { model.resume() } else { model.pause() }; rebuild()
    // }
    @objc private func enableOrResumeRecording() {
        if !model.consent { model.enableRecording() } else if model.paused { model.resume() }
        rebuild()
    }
    @objc private func editExcluded() {
        let alert = NSAlert(); alert.messageText = L("excludedApps"); alert.informativeText = L("excluded.edit.detail")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 180)); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let editor = NSTextView(frame: scroll.bounds); editor.isRichText = false; editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.string = (Preferences.defaults.stringArray(forKey: "excludedApps") ?? []).joined(separator: "\n")
        scroll.documentView = editor; alert.accessoryView = scroll
        alert.addButton(withTitle: L("cancel")); alert.addButton(withTitle: L("apply"))
        if alert.runModal() == .alertSecondButtonReturn {
            let apps = editor.string.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            Preferences.set(Array(Set(apps)).sorted(), "excludedApps"); rebuild()
        }
    }
    @objc private func addApplication() {
        let picker = NSOpenPanel(); picker.canChooseDirectories = false; picker.allowedContentTypes = [.application]; picker.directoryURL = URL(fileURLWithPath: "/Applications")
        picker.prompt = L("addApplication")
        if picker.runModal() == .OK, let url = picker.url, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier {
            let apps = Preferences.defaults.stringArray(forKey: "excludedApps") ?? []
            Preferences.set(Array(Set(apps + [id])).sorted(), "excludedApps"); rebuild()
        }
    }
    @objc private func openStorage() { NSWorkspace.shared.open(model.store.location) }
    private func appearance(_ body: NSStackView) {
        let theme = popup(key: "theme", values: ["system", "light", "dark"], titles: [L("system"), L("light"), L("dark")])
        let glass = popup(key: "glass", values: Preferences.glassStyles, titles: Preferences.glassStyles.map(L))
        let textScale = NSPopUpButton(); textScale.addItems(withTitles: ["100%", "115%", "130%"])
        textScale.widthAnchor.constraint(equalToConstant: 156).isActive = true
        textScale.selectItem(at: Preferences.scale < 1.1 ? 0 : Preferences.scale < 1.25 ? 1 : 2); textScale.target = self; textScale.action = #selector(scaleChanged)
        group([formRow("theme", control: theme), formRow("glass", control: glass), formRow("textSize", control: textScale)], in: body)
        let sample = GlassSurface(); preview = sample
        let sampleText = UI.column([UI.label(L("empty.title"), size: 15, weight: .medium), UI.paragraph(L("preview.detail"))], spacing: 6)
        UI.pin(UI.card(sampleText), in: sample.foreground, inset: 16)
        let backdrop = PreviewBackdrop(); UI.pin(sample, in: backdrop, inset: 14)
        backdrop.heightAnchor.constraint(equalToConstant: 160).isActive = true; body.addArrangedSubview(backdrop)
        let slider = NSSlider(value: Preferences.clarity, minValue: 0, maxValue: 1, target: self, action: #selector(clarityChanged))
        slider.isContinuous = true; slider.setAccessibilityLabel(L("clarity"))
        clarityLabel = UI.label("", size: 11, secondary: true)
        let labels = UI.row([UI.label(L("diffused"), size: 11, secondary: true), UI.spacer(), UI.label(L("clear"), size: 11, secondary: true)])
        group([formRow("clarity", control: clarityLabel!), slider, labels, UI.paragraph(L("clarity.note")), UI.button(L("restoreAppearance"), target: self, action: #selector(restoreAppearance))], in: body)
    }
    @objc private func clarityChanged(_ sender: NSSlider) { Preferences.set(sender.doubleValue, "clarity") }
    @objc private func scaleChanged(_ sender: NSPopUpButton) { Preferences.set([1.0, 1.15, 1.3][sender.indexOfSelectedItem], "fontScale") }
    @objc private func restoreAppearance() {
        Preferences.defaults.set("system", forKey: "theme"); Preferences.defaults.set("adaptive", forKey: "glass"); Preferences.defaults.set(0.75, forKey: "clarity")
        Preferences.set(1.0, "fontScale"); rebuild()
    }
    private func permissions(_ body: NSStackView) {
        permissionsLabel = UI.paragraph(""); loginLabel = UI.label("", size: 12, secondary: true)
        group([UI.label(L("clipboardAccess"), weight: .medium), permissionsLabel!, UI.paragraph(L("permission.detail")), UI.button(L("requestClipboard"), target: self, action: #selector(requestClipboard)), UI.button(L("clipboardSettings"), target: self, action: #selector(clipboardSettings))], in: body)
        group([UI.label(L("launchAtLogin"), weight: .medium), loginLabel!, UI.button(L("loginSettings"), target: self, action: #selector(loginSettings))], in: body)
        stateLabel = UI.paragraph(""); body.addArrangedSubview(stateLabel!)
        body.addArrangedSubview(UI.paragraph(L("keychain.authorization")))
        body.addArrangedSubview(UI.button(L("authorizeKeychain"), target: self, action: #selector(retryStorage)))
        body.addArrangedSubview(UI.button(L("retryStorage"), target: self, action: #selector(retryStorage)))
    }
    @objc private func requestClipboard() { model.requestClipboardAccess(); refreshStatus() }
    @objc private func clipboardSettings() { AppModel.openPrivacy("Privacy_Pasteboard") }
    @objc private func loginSettings() { SMAppService.openSystemSettingsLoginItems() }
    @objc private func retryStorage() { Task { await model.retry(); refreshStatus() } }
    private func about(_ body: NSStackView) {
        let icon = NSImageView(image: NSApp.applicationIconImage); icon.imageScaling = .scaleProportionallyUpOrDown; icon.heightAnchor.constraint(equalToConstant: 72).isActive = true
        let version = BuildInfo.fullVersion
        group([icon, UI.label(BuildInfo.displayName, size: 20, weight: .semibold), formRow("version", control: UI.label(version)), UI.label("arm64 · macOS 26+", size: 11, secondary: true), UI.paragraph(L("about.story")), UI.paragraph(L("about.technology")), UI.paragraph(L("about.website"))], in: body)
        group([UI.label(L("diagnostics"), weight: .medium), UI.paragraph(L("diagnostics.detail")), UI.button(L("copyDiagnostics"), target: self, action: #selector(copyDiagnostics))], in: body)
    }
    @objc private func copyDiagnostics() {
        let alert = NSAlert(); alert.messageText = L("diagnostics"); alert.informativeText = "\(BuildInfo.displayName) \(BuildInfo.version)\narm64\nmacOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n\(L(model.statusKey))\n\(L("capacity")): \(model.stats.bytes) B\n\(L("history")): \(model.stats.count)"
        alert.addButton(withTitle: L("cancel")); alert.addButton(withTitle: L("copy"))
        if alert.runModal() == .alertSecondButtonReturn {
            let payload = ClipPayload(items: [ClipItem(representations: [Representation(type: "public.utf8-plain-text", data: Data(alert.informativeText.utf8))])])
            do { try model.copy(payload, plain: true) } catch { model.report(error) }
        }
    }
}

@MainActor final class ShortcutRecorder: NSButton {
    var onRecorded: ((UInt32, UInt32, String) -> Void)?
    private var recording = false
    override init(frame: NSRect) {
        super.init(frame: frame); bezelStyle = .rounded; target = self; action = #selector(beginRecording); updateTitle()
        setAccessibilityLabel(L("shortcut")); widthAnchor.constraint(equalToConstant: 156).isActive = true
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    func updateTitle() { title = Preferences.defaults.string(forKey: "hotkeyTitle") ?? "⌃V" }
    @objc private func beginRecording() { recording = true; title = L("shortcut.record"); window?.makeFirstResponder(self) }
    func cancelRecording() { recording = false; updateTitle() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { if recording { keyDown(with: event); return true }; return super.performKeyEquivalent(with: event) }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { cancelRecording(); return }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.intersection([.command, .option, .control]).isEmpty else { NSSound.beep(); return }
        var modifiers: UInt32 = 0; var label = ""
        if flags.contains(.control) { modifiers |= UInt32(controlKey); label += "⌃" }
        if flags.contains(.option) { modifiers |= UInt32(optionKey); label += "⌥" }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey); label += "⇧" }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey); label += "⌘" }
        label += event.keyCode == 49 ? "Space" : event.charactersIgnoringModifiers?.uppercased() ?? "\(event.keyCode)"
        recording = false; onRecorded?(UInt32(event.keyCode), modifiers, label); updateTitle()
    }
}

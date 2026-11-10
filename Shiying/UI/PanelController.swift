import AppKit

@MainActor final class PanelController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    let panel: KeyPanel
    let model: AppModel
    var openSettings: (() -> Void)?
    var onVisibilityChange: ((Bool) -> Void)?
    private let surface = GlassSurface()
    private let search = NSSearchField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let savedFilter = NSSegmentedControl()
    private let typeFilter = NSPopUpButton()
    private let subtitle = UI.label("", size: 11, secondary: true)
    private let newItemsButton = NSButton()
    private let groupTitle = UI.label("", size: 11, weight: .medium, secondary: true)
    // 底部常驻“正在记录”行暂时停用，保留原定义与状态更新说明。
    // private let stateLabel = UI.label("", size: 11, secondary: true)
    private let emptyTitle = UI.label("", size: 16, weight: .medium)
    private let emptyDetail = UI.paragraph("")
    private let emptyAction = NSButton()
    private let pinButton = NSButton()
    // 暂停功能暂不开放，保留原按钮及其接线代码，未来可整段恢复。
    // private let pauseButton = NSButton()
    private let settingsButton = NSButton()
    private let favoriteButton = NSButton()
    private let detailButton = NSButton()
    private let emptyStack: NSStackView
    private let details = NSStackView()
    private let detailText = NSTextView()
    private let detailScroll = NSScrollView()
    private let detailImage = NSImageView()
    private let revealButton = NSButton()
    private let fullButton = NSButton()
    private var queryTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var rows: [ClipRow] = []
    private var outsideMonitor: Any?
    private let revealInFinder: @MainActor ([URL]) -> Void
    private var detailOpen = false
    private var positioning = false
    private var acceptingDragMoves = false
    private var pendingOrigin: NSPoint?
    private(set) var isPinned = false
    private var pinnedOrigin: NSPoint?
    private var preferredOrigin: NSPoint? {
        isPinned ? pinnedOrigin : nil
    }
    private var requestID = 0
    private var selectedID: String?
    private var savedOnly = false
    private var kind: ClipKind?
    private var format: ClipFormat.Filter?
    private var previewWindows: [NSWindow] = []
    private let imageCache = NSCache<NSString, NSImage>()
    private var thumbnailQueue: [String] = []
    private var thumbnailWorker: Task<Void, Never>?
    private var selected: ClipRow? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }

    init(model: AppModel, initialRows: [ClipRow] = [], revealInFinder: @escaping @MainActor ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }) {
        self.model = model; rows = initialRows
        self.revealInFinder = revealInFinder
        NativeGlassAppearance.installIfSupported()
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 384, height: 408), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        emptyStack = UI.column([emptyTitle, emptyDetail, emptyAction], spacing: 12)
        super.init()
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .popUpMenu; panel.hidesOnDeactivate = false; panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = surface; panel.delegate = self
        // 仅使用 KeyPanel 的 AppKit 事件拖动，关闭竞争的 Window Server 拖动路径。
        panel.isMovable = false
        panel.handleKey = { [weak self] event in self?.handle(event) ?? false }
        imageCache.totalCostLimit = 16 * 1_024 * 1_024
        build(); localize()
    }
    private func build() {
        let mark = NSImageView(image: FragmentMark.image(size: NSSize(width: 26, height: 24)))
        mark.contentTintColor = UI.brand; mark.setAccessibilityElement(false)
        let brand = UI.column([UI.label(BuildInfo.displayName, size: 20, weight: .semibold), subtitle], spacing: 2)
        brand.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        UI.fill(subtitle, in: brand)
        pinButton.target = self; pinButton.action = #selector(togglePinned); pinButton.bezelStyle = .rounded
        pinButton.setButtonType(.toggle); pinButton.identifier = .init("panel.pin")
        // pauseButton.target = self; pauseButton.action = #selector(togglePause); pauseButton.bezelStyle = .rounded
        settingsButton.target = self; settingsButton.action = #selector(settings); settingsButton.bezelStyle = .rounded
        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        // 原按钮组：[pinButton, pauseButton, settingsButton]；暂停入口暂时注释保留。
        for b in [pinButton, settingsButton] { b.imagePosition = .imageOnly; b.widthAnchor.constraint(equalToConstant: 30).isActive = true; b.heightAnchor.constraint(equalToConstant: 30).isActive = true }
        let header = PanelDragRegion()
        header.identifier = .init("panel.drag")
        header.onDragStarted = { [weak self] in self?.acceptingDragMoves = true }
        header.onDragEnded = { [weak self] in self?.savePosition() }
        panel.dragRegion = header
        // UI.pin(UI.row([mark, brand, UI.spacer(), pinButton, pauseButton, settingsButton], spacing: 10), in: header)
        UI.pin(UI.row([mark, brand, UI.spacer(), pinButton, settingsButton], spacing: 10), in: header)
        header.heightAnchor.constraint(equalToConstant: 44).isActive = true
        search.delegate = self; search.sendsSearchStringImmediately = true; search.font = .systemFont(ofSize: 14)
        search.heightAnchor.constraint(equalToConstant: 32).isActive = true
        savedFilter.segmentCount = 2; savedFilter.selectedSegment = 0; savedFilter.trackingMode = .selectOne
        savedFilter.target = self; savedFilter.action = #selector(filterChanged)
        for n in 0..<2 { savedFilter.setWidth(72, forSegment: n) }
        typeFilter.target = self; typeFilter.action = #selector(filterChanged); typeFilter.bezelStyle = .rounded
        typeFilter.widthAnchor.constraint(equalToConstant: 106).isActive = true
        typeFilter.identifier = .init("panel.typeFilter")
        let filters = UI.row([savedFilter, UI.spacer(), typeFilter])
        let column = NSTableColumn(identifier: .init("clip")); column.width = 344; column.resizingMask = .autoresizingMask; table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle; table.autoresizingMask = [.width]
        table.headerView = nil; table.backgroundColor = .clear; table.style = .plain; table.selectionHighlightStyle = .regular
        table.rowHeight = 52 * Preferences.scale; table.intercellSpacing = NSSize(width: 0, height: 1)
        table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(copySelected)
        table.setAccessibilityLabel(L("history"))
        let menu = NSMenu(); menu.autoenablesItems = false; menu.delegate = self; table.menu = menu
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false; scroll.autohidesScrollers = true
        let list = ReadingView(); UI.pin(scroll, in: list, inset: 4)
        emptyStack.alignment = .centerX; emptyTitle.alignment = .center; emptyDetail.alignment = .center
        emptyStack.translatesAutoresizingMaskIntoConstraints = false; list.addSubview(emptyStack)
        NSLayoutConstraint.activate([emptyStack.centerYAnchor.constraint(equalTo: list.centerYAnchor), emptyStack.leadingAnchor.constraint(equalTo: list.leadingAnchor, constant: 16), emptyStack.trailingAnchor.constraint(equalTo: list.trailingAnchor, constant: -16)])
        emptyAction.target = self; emptyAction.action = #selector(emptyClicked); emptyAction.bezelStyle = .rounded
        details.orientation = .vertical; details.alignment = .leading; details.spacing = 8; details.isHidden = true
        detailText.isEditable = false; detailText.isSelectable = true; detailText.drawsBackground = false
        detailText.font = .systemFont(ofSize: 12); detailText.textColor = .labelColor
        detailText.isHorizontallyResizable = false; detailText.autoresizingMask = [.width]; detailText.textContainer?.widthTracksTextView = true
        detailScroll.documentView = detailText; detailScroll.drawsBackground = false; detailScroll.hasVerticalScroller = true
        detailScroll.heightAnchor.constraint(equalToConstant: 80).isActive = true
        detailImage.imageScaling = .scaleProportionallyUpOrDown; detailImage.heightAnchor.constraint(equalToConstant: 80).isActive = true
        details.addArrangedSubview(detailScroll); UI.fill(detailScroll, in: details)
        details.addArrangedSubview(detailImage); UI.fill(detailImage, in: details)
        revealButton.target = self; revealButton.action = #selector(reveal); revealButton.bezelStyle = .rounded
        revealButton.identifier = .init("panel.reveal")
        fullButton.target = self; fullButton.action = #selector(showFull); fullButton.bezelStyle = .rounded
        let detailActions = UI.row([revealButton, fullButton, UI.spacer()]); details.addArrangedSubview(detailActions); UI.fill(detailActions, in: details)
        favoriteButton.target = self; favoriteButton.action = #selector(favoriteSelected)
        favoriteButton.identifier = .init("panel.favorite")
        detailButton.target = self; detailButton.action = #selector(toggleDetails)
        detailButton.identifier = .init("panel.details"); detailButton.setButtonType(.toggle)
        detailButton.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        for button in [favoriteButton, detailButton] {
            button.bezelStyle = .inline; button.imagePosition = .imageOnly
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        newItemsButton.target = self; newItemsButton.action = #selector(showNewest); newItemsButton.bezelStyle = .inline; newItemsButton.isHidden = true
        let timelineHeader = UI.row([groupTitle, UI.spacer(), newItemsButton, favoriteButton, detailButton], spacing: 6)
        // 原底部布局：[... list, details, stateLabel, actions]；常驻记录状态行已注释停用。
        let root = UI.column([header, search, filters, timelineHeader, list, details], spacing: 8)
        UI.pin(root, in: surface.foreground, inset: 16)
        for child in [header, search, filters, timelineHeader, list, details] { UI.fill(child, in: root) }
        list.heightAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        list.setContentHuggingPriority(.init(1), for: .vertical)
        root.setCustomSpacing(10, after: header); root.setCustomSpacing(6, after: timelineHeader)
    }
    func localize() {
        newItemsButton.title = L("newItems")
        let header = surface.foreground.subviews.flatMap { $0.subviews }.first { $0 is PanelDragRegion }
        header?.toolTip = L("panel.move")
        panel.title = BuildInfo.displayName; panel.appearance = Preferences.appearance
        subtitle.font = .systemFont(ofSize: 11 * Preferences.scale)
        // stateLabel.font = .systemFont(ofSize: 11 * Preferences.scale)
        groupTitle.font = .systemFont(ofSize: 11 * Preferences.scale, weight: .medium)
        search.font = .systemFont(ofSize: 14 * Preferences.scale)
        subtitle.stringValue = L("tagline"); search.placeholderString = L("search")
        savedFilter.setLabel(L("all"), forSegment: 0); savedFilter.setLabel(L("saved"), forSegment: 1)
        typeFilter.removeAllItems(); typeFilter.addItems(withTitles: [L("type")] + ClipKind.allCases.map { L($0.rawValue) })
        typeFilter.menu?.addItem(.separator())
        typeFilter.addItems(withTitles: ClipFormat.Filter.allCases.map(\.label))
        let selectedType = format.flatMap { ClipFormat.Filter.allCases.firstIndex(of: $0) }.map { $0 + ClipKind.allCases.count + 2 }
            ?? kind.flatMap { ClipKind.allCases.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        typeFilter.selectItem(at: selectedType)
        revealButton.title = L("reveal"); fullButton.title = L("viewFull")
        detailButton.toolTip = L("details"); detailButton.setAccessibilityLabel(L("details"))
        settingsButton.toolTip = L("settings"); settingsButton.setAccessibilityLabel(L("settings"))
        table.rowHeight = 52 * Preferences.scale; table.setAccessibilityLabel(L("history"))
        search.setAccessibilityLabel(L("search")); savedFilter.setAccessibilityLabel(L("filter")); typeFilter.setAccessibilityLabel(L("type"))
        updateState(); refresh()
    }
    func updateState() {
        NativeGlassAppearance.setPinned(isPinned, for: panel)
        pinButton.state = isPinned ? .on : .off
        let pinLabel = L(isPinned ? "panel.unpin" : "panel.pin")
        pinButton.image = NSImage(systemSymbolName: isPinned ? "pin.fill" : "pin", accessibilityDescription: pinLabel)
        pinButton.toolTip = pinLabel; pinButton.setAccessibilityLabel(pinLabel)
        pinButton.bezelColor = isPinned ? UI.pinnedBackground : nil
        pinButton.contentTintColor = isPinned ? UI.brand : .labelColor
        panel.level = isPinned ? .floating : .popUpMenu
        // 旧底部状态行保留：stateLabel.stringValue = L(model.noticeKey ?? model.statusKey)
        // stateLabel.toolTip = stateLabel.stringValue
        // stateLabel.textColor = model.errorKey == nil ? .secondaryLabelColor : .systemOrange
        // 正常记录时保留品牌副标题，错误/权限/临时反馈复用它，不再独占一行。
        let message = model.noticeKey ?? (model.statusKey == "status.recording" ? nil : model.statusKey)
        subtitle.stringValue = L(message ?? "tagline"); subtitle.toolTip = message.map { L($0) }
        subtitle.textColor = model.errorKey == nil ? .secondaryLabelColor : .systemOrange
        // 暂停按钮的状态与图标更新暂不执行，保留原实现：
        // let pauseLabel = L(!model.consent ? "start" : model.paused ? "resume" : "pause")
        // pauseButton.image = NSImage(systemSymbolName: !model.consent || model.paused ? "play.fill" : "pause.fill", accessibilityDescription: pauseLabel)
        // pauseButton.toolTip = pauseLabel; pauseButton.setAccessibilityLabel(pauseLabel)
        favoriteButton.isEnabled = selected != nil; detailButton.isEnabled = selected != nil
        detailButton.state = detailOpen ? .on : .off
        favoriteButton.image = NSImage(systemSymbolName: selected?.record.saved == true ? "star.fill" : "star", accessibilityDescription: L("save"))
        favoriteButton.toolTip = L(selected?.record.saved == true ? "unsave" : "save"); favoriteButton.setAccessibilityLabel(favoriteButton.toolTip)
        let noResults = !search.stringValue.isEmpty || savedOnly || kind != nil || format != nil
        emptyTitle.stringValue = L(noResults ? "empty.results" : "empty.title")
        emptyDetail.stringValue = L(noResults ? "empty.results.detail" : "empty.detail")
        emptyAction.title = L(noResults ? "clearFilters" : model.errorKey == "error.keyAuthorization" ? "authorizeKeychain" : !model.consent ? "start" : model.accessAllowed ? "settings" : "permissions")
        let count = model.stats.count
        groupTitle.stringValue = model.stats.saved == 30 ? F("buffer.count", model.stats.buffer) : F("history.count", count)
    }
    func show(screen: NSScreen? = nil) {
        panel.appearance = Preferences.appearance; surface.update()
        let rememberedScreen = preferredOrigin.flatMap { origin in NSScreen.screens.first { $0.visibleFrame.contains(origin) } }
        let screen = screen ?? rememberedScreen ?? NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame, visible.width > 0 else { return }
        acceptingDragMoves = false; positioning = true
        panel.setFrame(PanelGeometry.frame(in: visible, scale: Preferences.scale, details: detailOpen, origin: preferredOrigin), display: false)
        positioning = false
        NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(search)
        onVisibilityChange?(true); installOutsideMonitor(); refresh(); updateState()
    }
    func toggle() { if panel.isVisible { hide() } else { show() } }
    func hide() {
        acceptingDragMoves = false; pendingOrigin = nil; pinnedOrigin = nil
        panel.cancelDragging()
        panel.orderOut(nil); onVisibilityChange?(false); queryTask?.cancel(); detailTask?.cancel(); requestID += 1
        isPinned = false
        thumbnailWorker?.cancel(); thumbnailWorker = nil; thumbnailQueue.removeAll(); imageCache.removeAllObjects()
        newItemsButton.isHidden = true; rows.removeAll(); table.reloadData(); detailText.string = ""; detailImage.image = nil
        removeMonitors(); updateState()
    }
    func purgePreviews() {
        selectedID = nil; hide(); let windows = previewWindows; previewWindows.removeAll(); windows.forEach { $0.close() }
    }
    private func installOutsideMonitor() {
        removeMonitors()
        guard !isPinned else { return }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.dismissForOutsideClick() }
        }
        // Settings and context menus belong to this app. Interacting with them
        // must preserve the panel, its selection, position and pin state.
        // The global monitor still dismisses an unpinned panel on external clicks.
    }
    @discardableResult func dismissForOutsideClick() -> Bool {
        guard !isPinned else { return false }
        hide(); return true
    }
    @objc private func togglePinned() {
        isPinned.toggle()
        if isPinned { pendingOrigin = panel.frame.origin }
        savePosition()
        updateState()
        if panel.isVisible { installOutsideMonitor() }
    }
    func windowDidMove(_ notification: Notification) {
        guard !positioning, acceptingDragMoves, panel.isVisible else { return }
        pendingOrigin = panel.frame.origin
        // 只记录坐标；在 mouseUp/hide 时保存，避免拖动途中持续创建异步任务。
    }
    private func savePosition() {
        defer { pendingOrigin = nil }
        guard isPinned else { pinnedOrigin = nil; return }
        guard let origin = pendingOrigin else { return }
        pinnedOrigin = origin
    }
    private func removeMonitors() {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor); self.outsideMonitor = nil }
    }
    func refresh() {
        guard panel.isVisible, model.ready, !model.sessionLocked, model.errorKey != "error.key", model.errorKey != "error.keyAuthorization", model.errorKey != "error.authentication" else { return }
        queryTask?.cancel(); requestID += 1
        let request = requestID, query = String(search.stringValue.prefix(1_024)), kind = kind, saved = savedOnly, format = format
        queryTask = Task { [weak self] in
            guard let self else { return }
            do {
                let results = try await model.store.search(query, kind: kind, savedOnly: saved, format: format)
                guard !Task.isCancelled, requestID == request, panel.isVisible else { return }
                let previousIDs = Set(rows.map { $0.record.id })
                if !rows.isEmpty, selectedID != results.first?.record.id, results.contains(where: { !previousIDs.contains($0.record.id) }) { newItemsButton.isHidden = false }
                rows = results; table.reloadData()
                let index = selectedID.flatMap { id in rows.firstIndex { $0.record.id == id } } ?? (rows.isEmpty ? -1 : 0)
                table.selectRowIndexes(index >= 0 ? IndexSet(integer: index) : [], byExtendingSelection: false)
                emptyStack.isHidden = !rows.isEmpty; scroll.isHidden = rows.isEmpty
                updateState(); if detailOpen { loadDetail() }
            } catch { if !Task.isCancelled { model.report(error); rows.removeAll(); table.reloadData(); updateState() } }
        }
    }
    func controlTextDidChange(_ obj: Notification) { refresh() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if textView.hasMarkedText() { return false }
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)): copySelected(); return true
        case #selector(NSResponder.cancelOperation(_:)): hide(); return true
        default: return false
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    private func sectionKey(_ row: Int) -> String {
        if model.stats.saved == 30 && !rows[row].record.saved { return "recentBuffer" }
        return Calendar.current.isDateInToday(rows[row].record.copied) ? "today" : "earlier"
    }
    private func section(_ row: Int) -> String? { row == 0 || sectionKey(row) != sectionKey(row - 1) ? L(sectionKey(row)) : nil }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        ((rows[row].record.kind == .image || rows[row].record.kind == .file ? 60 : 52) + (section(row) == nil ? 0 : 18)) * Preferences.scale
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = ClipSelectionRow()
        view.sectionInset = section(row) == nil ? 0 : 18 * Preferences.scale
        return view
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: .init("row"), owner: self) as? ClipCell) ?? ClipCell()
        let item = rows[row]; cell.configure(item, number: row + 1, query: search.stringValue, section: section(row))
        if item.record.kind == .image {
            if let image = imageCache.object(forKey: item.record.id as NSString) { cell.icon.image = image; cell.icon.contentTintColor = nil }
            else { loadThumbnail(item.record.id) }
        }
        return cell
    }
    private func loadThumbnail(_ id: String) {
        if !thumbnailQueue.contains(id) { thumbnailQueue.append(id) }
        guard thumbnailWorker == nil else { return }
        thumbnailWorker = Task { [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { thumbnailWorker = nil } }
            while !thumbnailQueue.isEmpty && !Task.isCancelled && panel.isVisible {
                let id = thumbnailQueue.removeFirst()
                do {
                    let payload = try await model.store.payload(id)
                    guard !Task.isCancelled else { return }
                    guard let cg = await model.thumbnails.make(payload), !Task.isCancelled, panel.isVisible else { continue }
                    let image = NSImage(cgImage: cg, size: .zero)
                    imageCache.setObject(image, forKey: id as NSString, cost: cg.bytesPerRow * cg.height)
                    if let row = rows.firstIndex(where: { $0.record.id == id }), let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ClipCell { cell.icon.image = image; cell.icon.contentTintColor = nil }
                } catch { if !Task.isCancelled { model.report(error) } }
            }
        }
    }
    func tableViewSelectionDidChange(_ notification: Notification) { selectedID = selected?.record.id; updateState(); if detailOpen { loadDetail() } }
    @objc private func showNewest() {
        selectedID = nil; newItemsButton.isHidden = true
        if !rows.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); table.scrollRowToVisible(0) }
    }
    @objc private func filterChanged() {
        savedOnly = savedFilter.selectedSegment == 1
        let index = typeFilter.indexOfSelectedItem
        kind = (1...ClipKind.allCases.count).contains(index) ? ClipKind.allCases[index - 1] : nil
        let formatIndex = index - ClipKind.allCases.count - 2
        format = ClipFormat.Filter.allCases.indices.contains(formatIndex) ? ClipFormat.Filter.allCases[formatIndex] : nil
        refresh()
    }
    @objc private func emptyClicked() {
        if !search.stringValue.isEmpty || savedOnly || kind != nil || format != nil { search.stringValue = ""; kind = nil; format = nil; savedOnly = false; savedFilter.selectedSegment = 0; typeFilter.selectItem(at: 0); refresh() }
        else if model.errorKey == "error.keyAuthorization" { Task { await model.retry() } }
        else if !model.consent { model.enableRecording() }
        else { settings() }
    }
    // 暂停按钮暂不开放，保留原 action，不删除实现。
    // @objc private func togglePause() { if !model.consent { model.enableRecording() } else if model.paused { model.resume() } else { model.pause() } }
    @objc private func settings() { openSettings?() }
    @objc func copySelected() { copySelection() }
    private func copySelection(plain: Bool = false) {
        guard let selected, !model.sessionLocked else { return }
        let id = selected.record.id
        Task {
            do {
                let payload = try await model.store.payload(id)
                guard !model.sessionLocked, panel.isVisible, self.selected?.record.id == id else { return }
                if !plain && !payload.fileURLs.isEmpty && payload.fileURLs.contains(where: { !FileManager.default.isReadableFile(atPath: $0.path) }) { throw ShiyingError.fileUnavailable }
                try model.copy(payload, plain: plain)
            } catch { model.report(error) }
        }
    }
    @objc func favoriteSelected() { modify(deleting: false) }
    @objc func deleteSelected() { modify(deleting: true) }
    private func modify(deleting: Bool) {
        guard let id = selected?.record.id else { return }
        Task {
            do {
                let impact = try await model.store.favoriteImpact(id, deleting: deleting)
                if impact > 0 {
                    removeMonitors()
                    let confirmed = UI.confirm(title: L("merge.title"), message: F("merge.detail", impact), destructive: L(deleting ? "delete" : "unsave"))
                    if panel.isVisible { installOutsideMonitor() }
                    if !confirmed { return }
                }
                if deleting { try await model.store.delete(id, confirmedImpact: impact) }
                else { try await model.store.toggleSaved(id, confirmedImpact: impact) }
                imageCache.removeObject(forKey: id as NSString); detailText.string = ""; detailImage.image = nil
                await model.refresh(); refresh()
            } catch { model.report(error) }
        }
    }
    @objc private func toggleDetails() {
        detailOpen.toggle(); details.isHidden = !detailOpen
        if let screen = panel.screen {
            positioning = true
            panel.setFrame(PanelGeometry.frame(in: screen.visibleFrame, scale: Preferences.scale, details: detailOpen, origin: panel.frame.origin), display: true)
            positioning = false
        }
        if detailOpen { loadDetail() } else { detailTask?.cancel(); detailText.string = ""; detailImage.image = nil }
        updateState()
    }
    private func loadDetail() {
        detailTask?.cancel(); detailText.string = ""; detailImage.image = nil
        guard let selected else { return }
        let id = selected.record.id
        detailImage.isHidden = selected.record.kind != .image; detailScroll.isHidden = selected.record.kind == .image
        revealButton.isHidden = selected.record.kind != .file; fullButton.isHidden = !selected.summary.hasText
        revealButton.isEnabled = false
        detailTask = Task {
            do {
                let payload = try await model.store.payload(id)
                guard !Task.isCancelled, self.selected?.record.id == id, panel.isVisible else { return }
                if selected.record.kind == .image, let cg = await model.thumbnails.make(payload), !Task.isCancelled { detailImage.image = NSImage(cgImage: cg, size: .zero) }
                else if selected.record.kind == .file {
                    let urls = payload.fileURLs
                    detailText.string = urls.map { "\($0.path)\(FileManager.default.fileExists(atPath: $0.path) ? "" : " — " + L("error.fileUnavailable"))" }.joined(separator: "\n")
                    revealButton.isEnabled = (try? FileReferences.availableURLs(in: payload)) != nil
                } else {
                    let text = payload.plainText ?? selected.summary.detail
                    detailText.string = String(text.prefix(8_192)) + (text.count > 8_192 ? "\n… " + L("preview.truncated") : "")
                }
            } catch { if !Task.isCancelled { model.report(error) } }
        }
    }
    @objc private func reveal() {
        guard let selected, selected.record.kind == .file, !model.sessionLocked else { return }
        let id = selected.record.id
        Task {
            do {
                let payload = try await model.store.payload(id)
                guard !model.sessionLocked, panel.isVisible, self.selected?.record.id == id else { return }
                revealInFinder(try FileReferences.availableURLs(in: payload))
            } catch { model.report(error) }
        }
    }
    @objc private func showFull() {
        guard let id = selected?.record.id else { return }
        Task {
            do {
                guard let text = try await model.store.payload(id).plainText, !model.sessionLocked, panel.isVisible else { return }
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 460), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                window.title = L("viewFull"); window.isReleasedWhenClosed = false
                let scroll = NSScrollView(); scroll.hasVerticalScroller = true
                let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 460)); view.isEditable = false; view.isSelectable = true
                view.font = .monospacedSystemFont(ofSize: 13, weight: .regular); view.string = text
                view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
                scroll.documentView = view; window.contentView = scroll
                let oldWindows = previewWindows; previewWindows.removeAll(); oldWindows.forEach { $0.close() }
                previewWindows.append(window)
                NotificationCenter.default.addObserver(self, selector: #selector(previewClosed), name: NSWindow.willCloseNotification, object: window)
                hide(); window.center(); window.makeKeyAndOrderFront(nil)
            } catch { model.report(error) }
        }
    }
    @objc private func previewClosed(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if let view = (window.contentView as? NSScrollView)?.documentView as? NSTextView { view.string = "" }
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
        previewWindows.removeAll { $0 === window }
    }
    private func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let index = min(max(table.selectedRow + delta, 0), rows.count - 1)
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); table.scrollRowToVisible(index)
    }
    private func handle(_ event: NSEvent) -> Bool {
        let textEditor = panel.firstResponder as? NSTextView
        if textEditor?.hasMarkedText() == true { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
        let command = flags == .command
        let plainCopy = flags == [.command, .shift]
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.keyCode == 53, flags.isEmpty { hide(); return true }
        // 精确匹配应用快捷键，尤其不能把系统截图的 Command+Shift(+Control)+数字吞掉。
        if (command || plainCopy), chars == "c", textEditor == nil || textEditor?.isFieldEditor == true && textEditor?.selectedRange().length == 0 {
            copySelection(plain: plainCopy); return true
        }
        if command {
            if chars == "k" { panel.makeFirstResponder(search); return true }
            if let n = Int(chars), (1...9).contains(n), n <= rows.count { table.selectRowIndexes(IndexSet(integer: n - 1), byExtendingSelection: false); copySelected(); return true }
            if chars == "d" { favoriteSelected(); return true }
            if event.keyCode == 51, panel.firstResponder === table { deleteSelected(); return true }
        }
        if flags.isEmpty, panel.firstResponder === table {
            if event.keyCode == 36 { copySelected(); return true }
            if event.keyCode == 49 { toggleDetails(); return true }
        }
        return false
    }
}

extension PanelController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if table.clickedRow >= 0 { table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false) }
        menu.removeAllItems()
        var actions: [(String, Selector)] = [("copy", #selector(copySelected)), ("copyPlain", #selector(copyPlain)), (selected?.record.saved == true ? "unsave" : "save", #selector(favoriteSelected)), ("details", #selector(toggleDetails))]
        if selected?.record.kind == .file { actions.append(("reveal", #selector(reveal))) }
        actions.append(("delete", #selector(deleteSelected)))
        for (key, action) in actions {
            let item = NSMenuItem(title: L(key), action: action, keyEquivalent: ""); item.target = self
            item.isEnabled = selected != nil && (key != "copyPlain" || selected?.summary.hasText == true); menu.addItem(item)
        }
    }
    @objc private func copyPlain() { copySelection(plain: true) }
}

@MainActor final class ClipCell: NSTableCellView {
    let icon = NSImageView()
    override var backgroundStyle: NSView.BackgroundStyle {
        get { .normal }
        set { super.backgroundStyle = .normal }
    }
    private let sectionLabel = UI.label("", size: 10, weight: .medium, secondary: true)
    private var bodyTop: NSLayoutConstraint!
    private let title = UI.label("", weight: .medium)
    private let detail = UI.label("", size: 11, secondary: true)
    private let trailing = UI.label("", size: 11, secondary: true)
    override init(frame: NSRect) {
        super.init(frame: frame); identifier = .init("row")
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 36).isActive = true; icon.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let text = UI.column([title, detail], spacing: 5); UI.fill(title, in: text); UI.fill(detail, in: text)
        text.setContentHuggingPriority(.init(1), for: .horizontal)
        text.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        title.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        title.identifier = .init("clip.title"); detail.identifier = .init("clip.detail"); trailing.identifier = .init("clip.shortcut")
        let row = UI.row([icon, text, trailing], spacing: 12); row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false; sectionLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row); addSubview(sectionLabel)
        bodyTop = row.topAnchor.constraint(equalTo: topAnchor, constant: 8)
        NSLayoutConstraint.activate([bodyTop, row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8), sectionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), sectionLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7)])
        trailing.widthAnchor.constraint(equalToConstant: 20).isActive = true
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    func configure(_ row: ClipRow, number: Int, query: String, section: String?) {
        sectionLabel.stringValue = section ?? ""; sectionLabel.isHidden = section == nil
        bodyTop.constant = 8 + (section == nil ? 0 : 18 * Preferences.scale)
        let s = row.summary, r = row.record
        let titleString = s.title.isEmpty ? L(r.kind.rawValue) : s.title
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13 * Preferences.scale, weight: .medium), .foregroundColor: NSColor.labelColor]
        let attributed = NSMutableAttributedString(string: titleString, attributes: attributes)
        if !query.isEmpty, !s.title.isEmpty {
            let range = (titleString as NSString).range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
            if range.location != NSNotFound { attributed.addAttribute(.backgroundColor, value: NSColor.findHighlightColor, range: range) }
        }
        title.attributedStringValue = attributed
        let displayFormat = (s.format ?? ClipFormat(family: r.kind == .image ? .image : r.kind == .file ? .file : r.kind == .link ? .link : .text)).displayed(for: r.kind)
        var info = displayFormat.label
        if displayFormat.count > 1 { info += " · " + String(format: L("format.itemCount"), displayFormat.count) }
        let formatInfo = info
        if let width = s.pixelWidth, let height = s.pixelHeight { info += " · \(width) × \(height)" }
        else { info += " · " + ClipTime.label(for: r.copied) }
        // Normally the second line is metadata. Only reveal body context when
        // the search hits content beyond the title; never highlight metadata.
        var bodyRange: NSRange?
        if !query.isEmpty, !s.title.localizedStandardContains(query), !s.detail.isEmpty,
           s.detail.localizedStandardContains(query), r.kind != .image {
            info = formatInfo + " · "
            bodyRange = NSRange(location: (info as NSString).length, length: (s.detail as NSString).length)
            info += s.detail
        }
        // 来源附加格式的缺失不再在列表中提示；保留记录内的 partial 元数据，
        // 不显示图标、长悬停说明，也不改变用户复制的原文。
        let snippet = NSMutableAttributedString(string: info, attributes: [.font: NSFont.systemFont(ofSize: 11 * Preferences.scale), .foregroundColor: NSColor.secondaryLabelColor])
        if let bodyRange {
            let range = (info as NSString).range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: bodyRange)
            if range.location != NSNotFound { snippet.addAttribute(.backgroundColor, value: NSColor.findHighlightColor, range: range) }
        }
        detail.attributedStringValue = snippet; trailing.stringValue = r.saved ? "★" : number <= 9 ? String(number) : ""
        icon.image = NSImage(systemSymbolName: displayFormat.symbol, accessibilityDescription: displayFormat.label); icon.contentTintColor = UI.brand
        setAccessibilityElement(true); setAccessibilityLabel(titleString + ", " + info + (r.saved ? ", " + L("saved") : ""))
    }
}

@MainActor final class ClipSelectionRow: NSTableRowView {
    var sectionInset: CGFloat = 0
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        var rect = bounds.insetBy(dx: 4, dy: 2)
        rect.origin.y += sectionInset; rect.size.height = max(0, rect.height - sectionInset)
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
    }
}

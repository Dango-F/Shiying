import AppKit

@MainActor final class AppModel: NSObject {
    let store: HistoryStore
    let thumbnails = ThumbnailMaker()
    var stats = StorageStats()
    var onChange: (() -> Void)?
    var onSessionLock: (() -> Void)?
    private var timer: Timer?
    private var resumeTask: Task<Void, Never>?
    private(set) var captureTask: Task<Void, Never>?
    private let pasteboard: NSPasteboard
    private let clipboardAccess: @MainActor (NSPasteboard) -> Bool
    private let sourceBundleID: @MainActor () -> String
    private var baseline: Int
    private var sessionEpoch = 0
    private var suspensionReasons: Set<String> = []
    private var timerInterval: Double = 0
    private(set) var sessionLocked = false
    private(set) var ready = false
    private(set) var errorKey: String?
    private(set) var noticeKey: String?
    private var noticeTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    var consent: Bool { Preferences.defaults.bool(forKey: "consent") }
    var paused: Bool { Preferences.defaults.bool(forKey: "paused") }
    var accessAllowed: Bool { clipboardAccess(pasteboard) }
    var recording: Bool { consent && !paused && !sessionLocked && ready && errorKey == nil && accessAllowed }
    var statusKey: String {
        if let errorKey { return errorKey }
        if !consent { return "status.off" }
        if sessionLocked || paused { return "status.paused" }
        if !ready { return "status.loading" }
        if !accessAllowed { return "error.clipboard" }
        return "status.recording"
    }
    override convenience init() { self.init(store: nil) }
    init(store: HistoryStore?, pasteboard: NSPasteboard = .general,
         clipboardAccess: @escaping @MainActor (NSPasteboard) -> Bool = { $0.accessBehavior == .alwaysAllow },
         sourceBundleID: @escaping @MainActor () -> String = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "" }) {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.shiying.mac", isDirectory: true)
        self.store = store ?? HistoryStore(directory: folder)
        self.pasteboard = pasteboard; self.clipboardAccess = clipboardAccess; self.sourceBundleID = sourceBundleID
        baseline = pasteboard.changeCount
        super.init()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.screensDidSleepNotification] {
            center.addObserver(self, selector: #selector(lockSession(_:)), name: name, object: nil)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.screensDidWakeNotification] {
            center.addObserver(self, selector: #selector(unlockSession(_:)), name: name, object: nil)
        }
        // macOS's distributed lock notifications supplement documented workspace signals.
        // No private API, event tap, keyboard capture or screen recording is used.
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(lockSession(_:)), name: .init("com.apple.screenIsLocked"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(unlockSession(_:)), name: .init("com.apple.screenIsUnlocked"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(configurationChanged), name: .preferencesChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(configurationChanged), name: NSApplication.didBecomeActiveNotification, object: nil)
    }
    func start(interaction: InstallationKey.Interaction = .background) async {
        guard !sessionLocked else { return }
        ready = false
        let epoch = sessionEpoch
        do {
            try await store.open(interaction: interaction)
            guard epoch == sessionEpoch, !sessionLocked else { await store.suspendKey(); return }
            stats = try await store.stats(); ready = true; errorKey = nil
        } catch { report(error) }
        restorePause(); resetTimer(); onChange?()
    }
    func enableRecording() {
        Preferences.defaults.set(true, forKey: "consent")
        Preferences.defaults.set(false, forKey: "paused")
        requestClipboardAccess()
    }
    func requestClipboardAccess() {
        // Only an explicit user action may cause a permission prompt. Background polling
        // requires Always Allow, so Ask never causes a recurring stream of prompts.
        if pasteboard.accessBehavior != .alwaysDeny { _ = pasteboard.string(forType: .string) }
        baseline = pasteboard.changeCount
        resetTimer(); onChange?()
    }
    // 2026-11：手动暂停功能暂时停用，保留实现，后续需要时连同 UI 一起恢复。
    // 仅注释手动操作；睡眠、锁屏和会话切换的隐私保护仍独立生效。
    // func pause(seconds: Double? = nil) {
    //     Preferences.defaults.set(true, forKey: "paused")
    //     Preferences.defaults.set(seconds.map { Date.now.addingTimeInterval($0).timeIntervalSince1970 } ?? 0, forKey: "resumeAt")
    //     restorePause(); resetTimer(); onChange?()
    // }
    func resume() {
        Preferences.defaults.set(false, forKey: "paused"); Preferences.defaults.removeObject(forKey: "resumeAt")
        resumeTask?.cancel(); baseline = pasteboard.changeCount; resetTimer(); onChange?()
    }
    private func restorePause() {
        resumeTask?.cancel()
        let timestamp = Preferences.defaults.double(forKey: "resumeAt")
        guard paused, timestamp > 0 else { return }
        let delay = timestamp - Date.now.timeIntervalSince1970
        if delay <= 0 { resume(); return }
        resumeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self?.resume()
        }
    }
    @objc private func configurationChanged() { restorePause(); resetTimer(); onChange?() }
    private func resetTimer() {
        guard recording else {
            timer?.invalidate(); timer = nil; baseline = pasteboard.changeCount; return
        }
        let interval = Preferences.defaults.double(forKey: "pollInterval")
        if timer?.isValid == true && timerInterval == interval { return }
        if timer == nil { baseline = pasteboard.changeCount }
        timer?.invalidate(); timer = nil; timerInterval = interval
        let t = Timer(timeInterval: max(0.25, interval), target: self, selector: #selector(poll), userInfo: nil, repeats: true)
        t.tolerance = min(0.2, interval * 0.3); RunLoop.main.add(t, forMode: .common); timer = t
    }
    @objc func poll() {
        guard recording else { timer?.invalidate(); timer = nil; onChange?(); return }
        guard captureTask == nil else { return }
        let board = pasteboard
        let count = board.changeCount
        guard count != baseline else { return }
        baseline = count
        let source = sourceBundleID()
        // 系统截图写入时前台仍可能是拾影，不能以“前台是自己”丢弃整代数据。
        // 自身复制由 acknowledgeWrite 的明确代次去回环；应用排除规则继续生效。
        if (Preferences.defaults.stringArray(forKey: "excludedApps") ?? []).contains(source) { return }
        do {
            guard let clip = try Clipboard.read(board), board.changeCount == count else { return }
            let epoch = sessionEpoch
            captureTask = Task { [weak self] in
                guard let self else { return }
                defer { captureTask = nil }
                guard !Task.isCancelled, epoch == sessionEpoch, recording else { return }
                do {
                    _ = try await store.insert(clip)
                    stats = try await store.stats(); noticeKey = nil; onChange?()
                } catch { report(error) }
            }
        } catch { report(error) }
    }
    func acknowledgeWrite(_ generation: Int) { baseline = generation }
    func copy(_ payload: ClipPayload, plain: Bool = false) throws {
        guard !sessionLocked else { return }
        acknowledgeWrite(try Clipboard.write(payload, plain: plain, to: pasteboard))
        notice("notice.copied")
    }
    func refresh() async {
        do { stats = try await store.stats(); onChange?() } catch { report(error) }
    }
    // 只有设置/面板中用户主动点击的重试才可以弹出系统授权窗口。
    func retry() async {
        guard !sessionLocked else { return }
        wakeTask?.cancel(); ready = false; errorKey = nil
        await start(interaction: .userInitiated)
    }
    func report(_ error: Error) {
        if error is CancellationError { return }
        let typed = error as? ShiyingError ?? .database
        switch typed {
        case .tooLarge, .unreadable, .unsupported, .fileUnavailable, .write, .capacity, .favoriteLimit: notice(typed.key)
        default:
            let changed = errorKey != typed.key
            errorKey = typed.key; timer?.invalidate(); timer = nil
            if changed { onChange?() }
        }
    }
    func notice(_ key: String) {
        noticeTask?.cancel(); noticeKey = key; onChange?()
        noticeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            self?.noticeKey = nil; self?.onChange?()
        }
    }
    private func suspensionReason(_ name: Notification.Name) -> String {
        switch name {
        case NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification: "sleep"
        case NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification: "display"
        case NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification: "session"
        default: "lock"
        }
    }
    @objc private func lockSession(_ notification: Notification) {
        suspensionReasons.insert(suspensionReason(notification.name))
        sessionEpoch += 1; sessionLocked = true
        captureTask?.cancel(); wakeTask?.cancel(); timer?.invalidate(); timer = nil
        onSessionLock?(); onChange?()
        Task { await store.suspendKey() }
    }
    @objc private func unlockSession(_ notification: Notification) {
        suspensionReasons.remove(suspensionReason(notification.name))
        guard sessionLocked, suspensionReasons.isEmpty,
            let info = CGSessionCopyCurrentDictionary() as? [String: Any],
            info[kCGSessionOnConsoleKey as String] as? Bool == true,
            info[kCGSessionLoginDoneKey as String] as? Bool == true else { return }
        sessionEpoch += 1; sessionLocked = false
        baseline = pasteboard.changeCount
        wakeTask?.cancel()
        let epoch = sessionEpoch
        wakeTask = Task { [weak self] in
            guard let self else { return }
            await start()
            // login 钥匙串可能稍晚于会话解锁。仅作三次有界静默重试，
            // 不弹授权、不死循环；用户明确授权的路径也不会由此触发。
            for delay in [1, 2, 4] {
                guard errorKey == "error.keyAuthorization", !Task.isCancelled else { return }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard !Task.isCancelled, sessionEpoch == epoch, !sessionLocked else { return }
                await start()
            }
        }
    }
    func stop() {
        sessionEpoch += 1; timer?.invalidate(); timer = nil
        captureTask?.cancel(); resumeTask?.cancel(); noticeTask?.cancel(); wakeTask?.cancel()
    }
    func clearClipboard() {
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        acknowledgeWrite(pasteboard.changeCount); notice("notice.clipboardCleared")
    }
    static func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
}

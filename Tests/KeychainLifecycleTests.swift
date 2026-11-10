import XCTest
import AppKit
import CryptoKit
import Security

private final class KeyLoadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(Bool, InstallationKey.Interaction)] = []
    func record(_ create: Bool, _ interaction: InstallationKey.Interaction) {
        lock.lock(); defer { lock.unlock() }; calls.append((create, interaction))
    }
    func snapshot() -> [(Bool, InstallationKey.Interaction)] {
        lock.lock(); defer { lock.unlock() }; return calls
    }
}

final class KeychainLifecycleTests: XCTestCase {
    private static func clip() -> CapturedClip {
        CapturedClip(kind: .text,
            payload: ClipPayload(items: [ClipItem(representations: [Representation(type: "public.utf8-plain-text", data: Data("preserved fixture".utf8))])]),
            summary: ClipSummary(title: "fixture", detail: "", hasText: true), partial: false)
    }
    private static func seeded(_ folder: URL, key: SymmetricKey) async throws -> String {
        let store = HistoryStore(directory: folder, testKey: key)
        try await store.open(); let id = try await store.insert(clip())
        await store.close(); return id
    }
    func testBackgroundInteractionScopeRestoresPreviousPolicyOnSuccessAndFailure() throws {
        var previous: DarwinBoolean = false
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&previous), errSecSuccess)
        try InstallationKey.withInteraction(.background) {
            var current: DarwinBoolean = true
            XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&current), errSecSuccess)
            XCTAssertFalse(current.boolValue)
        }
        var restored: DarwinBoolean = false
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&restored), errSecSuccess)
        XCTAssertEqual(restored.boolValue, previous.boolValue)
        XCTAssertThrowsError(try InstallationKey.withInteraction(.background) {
            throw ShiyingError.keyAuthorization
        })
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&restored), errSecSuccess)
        XCTAssertEqual(restored.boolValue, previous.boolValue)
    }
    func testWakeReopensAreSilentAndPreserveSameKeyAndHistory() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShiyingWake-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = SymmetricKey(size: .bits256), probe = KeyLoadProbe()
        let id = try await Self.seeded(folder, key: key)
        let store = HistoryStore(directory: folder, keyLoader: { create, interaction in
            probe.record(create, interaction); return key
        })
        try await store.open()
        for _ in 0..<5 {
            await store.suspendKey()
            do { _ = try await store.payload(id); XCTFail("Suspended key must be unavailable") } catch ShiyingError.key { }
            try await store.open()
            let payload = try await store.payload(id)
            XCTAssertEqual(payload.plainText, "preserved fixture")
        }
        await store.close()
        XCTAssertEqual(probe.snapshot().count, 6)
        XCTAssertTrue(probe.snapshot().allSatisfy { !$0.0 && $0.1 == .background })
    }
    func testDeniedBackgroundReadNeverCreatesKeyOrChangesExistingDatabase() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShiyingDenied-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = SymmetricKey(size: .bits256), probe = KeyLoadProbe()
        let id = try await Self.seeded(folder, key: key)
        let file = folder.appendingPathComponent("history.sqlite")
        let before = try Data(contentsOf: file)
        let store = HistoryStore(directory: folder, keyLoader: { create, interaction in
            probe.record(create, interaction)
            guard interaction == .userInitiated else { throw ShiyingError.keyAuthorization }
            return key
        })
        for _ in 0..<4 {
            do { try await store.open(); XCTFail("Requires explicit authorization") } catch ShiyingError.keyAuthorization { }
            XCTAssertEqual(try Data(contentsOf: file), before)
        }
        try await store.open(interaction: .userInitiated)
        let payload = try await store.payload(id)
        XCTAssertEqual(payload.plainText, "preserved fixture")
        await store.close()
        XCTAssertTrue(probe.snapshot().allSatisfy { !$0.0 })
        XCTAssertEqual(probe.snapshot().filter { $0.1 == .userInitiated }.count, 1)
    }
    @MainActor func testAppStartupIsSilentAndExplicitRetryAloneMayAuthorize() async throws {
        Preferences.register()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShiyingStartup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = SymmetricKey(size: .bits256), probe = KeyLoadProbe()
        _ = try await Self.seeded(folder, key: key)
        let store = HistoryStore(directory: folder, keyLoader: { create, interaction in
            probe.record(create, interaction)
            guard interaction == .userInitiated else { throw ShiyingError.keyAuthorization }
            return key
        })
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let model = AppModel(store: store, pasteboard: board, clipboardAccess: { _ in false })
        await model.start()
        XCTAssertEqual(model.errorKey, "error.keyAuthorization"); XCTAssertFalse(model.recording)
        await model.retry()
        XCTAssertNil(model.errorKey); XCTAssertTrue(model.ready); XCTAssertEqual(model.stats.count, 1)
        // 已成功使用过的历史在下次解锁拒绝时也必须撤销 ready，避免 UI 查询
        // 关闭的数据库并把“需要授权”覆盖成泛化存储错误。
        await store.suspendKey(); await model.start()
        XCTAssertFalse(model.ready); XCTAssertEqual(model.errorKey, "error.keyAuthorization")
        await model.retry()
        XCTAssertTrue(model.ready); XCTAssertNil(model.errorKey)
        model.stop(); await store.close()
        XCTAssertEqual(probe.snapshot().map { $0.1 }, [.background, .userInitiated, .background, .userInitiated])
    }
    func testFirstWriteAuthorizationCanBeCompletedExplicitlyForEmptyHistory() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShiyingFirstKey-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = SymmetricKey(size: .bits256), probe = KeyLoadProbe()
        let store = HistoryStore(directory: folder, keyLoader: { create, interaction in
            probe.record(create, interaction)
            guard interaction == .userInitiated else { throw ShiyingError.keyAuthorization }
            return key
        })
        try await store.open()
        XCTAssertTrue(probe.snapshot().isEmpty, "Empty startup must not create a key")
        do { _ = try await store.insert(Self.clip()); XCTFail("First write requires authorization") } catch ShiyingError.keyAuthorization { }
        try await store.open(interaction: .userInitiated)
        let id = try await store.insert(Self.clip())
        let payload = try await store.payload(id)
        XCTAssertEqual(payload.plainText, "preserved fixture")
        await store.close()
        XCTAssertEqual(probe.snapshot().map { $0.1 }, [.background, .userInitiated])
        XCTAssertTrue(probe.snapshot().allSatisfy { $0.0 })
    }
    func testAuthorizationErrorsRemainDistinctFromMissingKey() {
        for status in [errSecInteractionNotAllowed, errSecInteractionRequired, errSecAuthFailed, errSecUserCanceled] {
            XCTAssertTrue(InstallationKey.needsAuthorization(status))
        }
        XCTAssertFalse(InstallationKey.needsAuthorization(errSecItemNotFound))
        XCTAssertFalse(InstallationKey.needsAuthorization(errSecSuccess))
        XCTAssertNotEqual(ShiyingError.key.key, ShiyingError.keyAuthorization.key)
    }
}

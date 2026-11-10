import XCTest
import CryptoKit
import SQLite3
import AppKit

@MainActor final class HistoryStoreTests: XCTestCase {
    private func clip(_ text: String) -> CapturedClip {
        CapturedClip(kind: .text, payload: ClipPayload(items: [ClipItem(representations: [Representation(type: "public.utf8-plain-text", data: Data(text.utf8))])]), summary: ClipSummary(title: String(text.prefix(160)), detail: "", hasText: true), partial: false)
    }
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("ShiyingTests-" + UUID().uuidString) }
    func testRollingHistoryDeduplicationAndRestart() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let key = SymmetricKey(size: .bits256)
        let store = HistoryStore(directory: path, testKey: key); try await store.open()
        var ids: [String] = []
        for i in 0..<31 { ids.append(try await store.insert(clip("片段 \(i) 👋\n\tcode"), now: Date(timeIntervalSince1970: Double(i)))) }
        var records = try await store.records()
        XCTAssertEqual(records.count, 30); XCTAssertFalse(records.contains { $0.id == ids[0] })
        let duplicate = try await store.insert(clip("片段 10 👋\n\tcode"), now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(duplicate, ids[10])
        try await store.toggleSaved(duplicate)
        records = try await store.records(); XCTAssertEqual(records.first?.id, duplicate); XCTAssertEqual(records.first?.copies, 2)
        let content = try await store.payload(duplicate); XCTAssertEqual(content.plainText, "片段 10 👋\n\tcode")
        await store.close()
        let restarted = HistoryStore(directory: path, testKey: key); try await restarted.open()
        records = try await restarted.records()
        XCTAssertEqual(records.count, 30); XCTAssertEqual(records.first?.id, duplicate); XCTAssertEqual(records.first?.saved, true)
        let afterRestart = try await restarted.insert(clip("片段 10 👋\n\tcode")); XCTAssertEqual(afterRestart, duplicate)
        let found = try await restarted.search("👋", kind: .text, savedOnly: true); XCTAssertEqual(found.count, 1)
        await restarted.close()
    }
    func testThirtyFavoritesFivePersistentBuffersAndMerge() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let key = SymmetricKey(size: .bits256)
        let store = HistoryStore(directory: path, testKey: key); try await store.open()
        var favorites: [String] = []
        for n in 0..<30 {
            let id = try await store.insert(clip("saved-\(n)"), now: Date(timeIntervalSince1970: Double(n)))
            try await store.toggleSaved(id); favorites.append(id)
        }
        var buffers: [String] = []
        for n in 0..<6 { buffers.append(try await store.insert(clip("buffer-\(n)"), now: Date(timeIntervalSince1970: Double(100 + n)))) }
        var records = try await store.records()
        XCTAssertEqual(records.count, 35); XCTAssertEqual(records.filter(\.saved).count, 30); XCTAssertFalse(records.contains { $0.id == buffers[0] })
        do { try await store.toggleSaved(buffers[5]); XCTFail("Must refuse a 31st favorite") } catch ShiyingError.favoriteLimit { }
        let repeatID = try await store.insert(clip("buffer-2"), now: Date(timeIntervalSince1970: 200)); XCTAssertEqual(repeatID, buffers[2])
        await store.close()
        let restarted = HistoryStore(directory: path, testKey: key); try await restarted.open()
        records = try await restarted.records(); XCTAssertEqual(records.count, 35)
        let impact = try await restarted.favoriteImpact(favorites[0], deleting: false); XCTAssertEqual(impact, 5)
        do { try await restarted.toggleSaved(favorites[0]); XCTFail("Must require merge confirmation") } catch ShiyingError.capacity { }
        let checkedValue1 = try await restarted.stats().count; XCTAssertEqual(checkedValue1, 35)
        try await restarted.toggleSaved(favorites[0], confirmedImpact: impact)
        records = try await restarted.records()
        XCTAssertEqual(records.count, 30); XCTAssertEqual(records.filter(\.saved).count, 29)
        XCTAssertEqual(records.first(where: { !$0.saved })?.id, repeatID)
        await restarted.close()
    }
    func testDeletionOfFavoritePredictsActualMerge() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let store = HistoryStore(directory: path, testKey: SymmetricKey(size: .bits256)); try await store.open()
        var first = ""
        for n in 0..<30 { let id = try await store.insert(clip("s\(n)")); if n == 0 { first = id }; try await store.toggleSaved(id) }
        for n in 0..<5 { _ = try await store.insert(clip("b\(n)")) }
        let impact = try await store.favoriteImpact(first, deleting: true); XCTAssertEqual(impact, 4)
        try await store.delete(first, confirmedImpact: impact)
        let stats = try await store.stats(); XCTAssertEqual(stats.count, 30); XCTAssertEqual(stats.saved, 29)
        await store.close()
    }
    func testBudgetFailureAndInsertFailureRollbackEvictions() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let key = SymmetricKey(size: .bits256)
        let store = HistoryStore(directory: path, budget: 1_200, testKey: key); try await store.open()
        let old = try await store.insert(clip("keep")); try await store.toggleSaved(old)
        do { _ = try await store.insert(clip(String(repeating: "x", count: 2_000))); XCTFail("Must reject overflow") } catch ShiyingError.capacity { }
        let checkedValue2 = try await store.records().map(\.id); XCTAssertEqual(checkedValue2, [old])
        await store.close()
        let full = HistoryStore(directory: path, testKey: key); try await full.open()
        for n in 0..<29 { _ = try await full.insert(clip("item\(n)")) }
        let before = try await full.records().map(\.id)
        try sql(path, "CREATE TRIGGER force_insert_failure BEFORE INSERT ON clips BEGIN SELECT RAISE(ABORT, 'forced'); END;")
        do { _ = try await full.insert(clip("new")); XCTFail("Injected write failure should abort") } catch ShiyingError.database { }
        let checkedValue3 = try await full.records().map(\.id); XCTAssertEqual(checkedValue3, before)
        await full.close()
    }
    func testCipherHasFreshNoncesAndAuthenticatesRecordIdentity() throws {
        let cipher = ContentCipher(master: SymmetricKey(size: .bits256)), bytes = Data("secret".utf8)
        let a = try cipher.seal(bytes, context: "a.payload"), b = try cipher.seal(bytes, context: "a.payload")
        XCTAssertNotEqual(a, b); XCTAssertEqual(try cipher.open(a, context: "a.payload"), bytes)
        XCTAssertThrowsError(try cipher.open(a, context: "b.payload"))
        var broken = a; broken[broken.count - 1] ^= 1
        XCTAssertThrowsError(try cipher.open(broken, context: "a.payload"))
        XCTAssertEqual(cipher.digest(bytes), cipher.digest(bytes))
        XCTAssertNotEqual(cipher.digest(bytes), ContentCipher(master: SymmetricKey(size: .bits256)).digest(bytes))
    }
    func testNoPlaintextOnDiskAndWrongKeyPreservesHistory() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let key = SymmetricKey(size: .bits256), secret = "shiying-private-token-9e73a481"
        let store = HistoryStore(directory: path, testKey: key); try await store.open()
        _ = try await store.insert(clip(secret)); await store.close()
        let database = path.appendingPathComponent("history.sqlite")
        let before = try Data(contentsOf: database)
        XCTAssertNil(before.range(of: Data(secret.utf8)))
        let wrong = HistoryStore(directory: path, testKey: SymmetricKey(size: .bits256))
        do { try await wrong.open(); XCTFail("Wrong key must fail") } catch ShiyingError.authentication { }
        await wrong.close()
        XCTAssertEqual(try Data(contentsOf: database), before)
        let restored = HistoryStore(directory: path, testKey: key); try await restored.open()
        let checkedValue4 = try await restored.records().count; XCTAssertEqual(checkedValue4, 1); await restored.close()
    }
    func testTamperedPayloadStopsDecryption() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let store = HistoryStore(directory: path, testKey: SymmetricKey(size: .bits256)); try await store.open()
        let id = try await store.insert(clip("authentic"))
        try sql(path, "UPDATE clips SET payload = zeroblob(length(payload));")
        do { _ = try await store.payload(id); XCTFail("Tampering must fail") } catch ShiyingError.authentication { }
        do { _ = try await store.insert(clip("must not persist")); XCTFail("Key must be suspended") } catch ShiyingError.key { }
        let checkedValue5 = try await store.records().count; XCTAssertEqual(checkedValue5, 1); await store.close()
    }
    func testMultiInstanceLockAndIndependentClear() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let key = SymmetricKey(size: .bits256)
        let store = HistoryStore(directory: path, testKey: key); try await store.open()
        let second = HistoryStore(directory: path, testKey: key)
        do { try await second.open(); XCTFail("Second writer must be refused") } catch ShiyingError.busy { }
        await second.close()
        let saved = try await store.insert(clip("favorite")); try await store.toggleSaved(saved)
        _ = try await store.insert(clip("discard"))
        try await store.clear(includeSaved: false); let checkedValue6 = try await store.records().map(\.id); XCTAssertEqual(checkedValue6, [saved])
        try await store.clear(includeSaved: true); let checkedValue7 = try await store.records().count; XCTAssertEqual(checkedValue7, 0)
        await store.close()
    }
    func testSearchFindsTextBeyondPreview() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let store = HistoryStore(directory: path, testKey: SymmetricKey(size: .bits256)); try await store.open()
        _ = try await store.insert(clip(String(repeating: "前言", count: 1_000) + "needle-🔎"))
        let rows = try await store.search("needle-🔎", kind: nil, savedOnly: false)
        XCTAssertEqual(rows.count, 1)
        await store.close()
    }
    func testProcessDeathRecoversUncommittedDeletion() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let key = SymmetricKey(size: .bits256)
        let store = HistoryStore(directory: path, testKey: key); try await store.open()
        let id = try await store.insert(clip("survives-process-death")); await store.close()
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [path.appendingPathComponent("history.sqlite").path]
        let input = Pipe(); process.standardInput = input; process.standardOutput = Pipe(); process.standardError = Pipe()
        try process.run()
        // Kill only this child SQLite process while its write transaction is open.
        input.fileHandleForWriting.write(Data("PRAGMA synchronous=EXTRA;\nBEGIN IMMEDIATE;\nDELETE FROM clips;\n.shell /bin/kill -KILL $PPID\n".utf8))
        try input.fileHandleForWriting.close(); process.waitUntilExit()
        XCTAssertNotEqual(process.terminationStatus, 0)
        let restarted = HistoryStore(directory: path, testKey: key); try await restarted.open()
        let records = try await restarted.records(); XCTAssertEqual(records.map(\.id), [id])
        let text = try await awaitPayloadText(restarted, id); XCTAssertEqual(text, "survives-process-death")
        await restarted.close()
    }
    private func awaitPayloadText(_ store: HistoryStore, _ id: String) async throws -> String? { try await store.payload(id).plainText }
    func testUnsupportedSchemaNeverBecomesValidOnRetry() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let key = SymmetricKey(size: .bits256)
        let store = HistoryStore(directory: path, testKey: key); try await store.open()
        _ = try await store.insert(clip("preserve")); await store.close()
        try sql(path, "PRAGMA user_version=99")
        for _ in 0..<2 {
            do { try await store.open(); XCTFail("Unknown schema must remain refused") } catch ShiyingError.schema { }
        }
        try sql(path, "PRAGMA user_version=1")
        try await store.open(); let records = try await store.records(); XCTAssertEqual(records.count, 1); await store.close()
    }
    private func sql(_ path: URL, _ statement: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path.appendingPathComponent("history.sqlite").path, &db) == SQLITE_OK else { throw ShiyingError.database }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else { throw ShiyingError.database }
    }
}

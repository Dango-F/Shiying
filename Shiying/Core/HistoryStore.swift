import Foundation
import CryptoKit
import SQLite3

/// Owns the only connection. All queries, encryption and decoding run on this actor.
actor HistoryStore {
    private var db: OpaquePointer?
    private var cipher: ContentCipher?
    private var formatCache: [String: ClipFormat] = [:]
    private var suspended = false
    private var lockFD: Int32 = -1
    let location: URL
    private let budget: Int
    private let injectedKey: SymmetricKey?
    private let keyLoader: @Sendable (Bool, InstallationKey.Interaction) throws -> SymmetricKey
    private let encoder = PropertyListEncoder()
    private let decoder = PropertyListDecoder()

    init(directory: URL, budget: Int = 200 * 1_024 * 1_024, testKey: SymmetricKey? = nil,
         keyLoader: @escaping @Sendable (Bool, InstallationKey.Interaction) throws -> SymmetricKey = { try InstallationKey.load(allowCreate: $0, interaction: $1) }) {
        location = directory; self.budget = budget; injectedKey = testKey; self.keyLoader = keyLoader
        encoder.outputFormat = .binary
    }
    func open(interaction: InstallationKey.Interaction = .background) throws {
        do { try openConnection(interaction: interaction) } catch { close(); throw error }
    }
    private func openConnection(interaction: InstallationKey.Interaction) throws {
        if db == nil {
            try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            lockFD = Darwin.open(location.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
            guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw ShiyingError.busy }
            let path = location.appendingPathComponent("history.sqlite").path
            guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else { throw ShiyingError.database }
            chmod(path, 0o600)
            sqlite3_busy_timeout(db, 1_000)
            try execute("PRAGMA journal_mode=DELETE; PRAGMA synchronous=EXTRA; PRAGMA secure_delete=ON; PRAGMA temp_store=MEMORY;")
            guard try scalar("PRAGMA synchronous") == 3 else { throw ShiyingError.database }
            let journal = try prepare("PRAGMA journal_mode")
            let isDelete = sqlite3_step(journal) == SQLITE_ROW && string(journal, 0).lowercased() == "delete"
            sqlite3_finalize(journal)
            guard isDelete else { throw ShiyingError.database }
            let version = try scalar("PRAGMA user_version")
            guard version == 0 || version == 1 else { throw ShiyingError.schema }
            if version == 0 {
                try transaction {
                    try execute("CREATE TABLE IF NOT EXISTS clips (id TEXT PRIMARY KEY, created REAL NOT NULL, copied REAL NOT NULL, kind TEXT NOT NULL, bytes INTEGER NOT NULL, saved INTEGER NOT NULL DEFAULT 0, copies INTEGER NOT NULL DEFAULT 1, partial INTEGER NOT NULL, digest BLOB NOT NULL UNIQUE, summary BLOB NOT NULL, payload BLOB NOT NULL); PRAGMA user_version=1;")
                }
            }
        }
        suspended = false
        if cipher == nil {
            if injectedKey == nil, interaction == .background, try scalar("SELECT count(*) FROM clips") == 0 { return }
            let key = try injectedKey ?? keyLoader(try scalar("SELECT count(*) FROM clips") == 0, interaction)
            let candidate = ContentCipher(master: key)
            // Authenticate existing content before enabling new persistent writes.
            let statement = try prepare("SELECT id, summary FROM clips LIMIT 1")
            defer { sqlite3_finalize(statement) }
            if sqlite3_step(statement) == SQLITE_ROW {
                _ = try candidate.open(blob(statement, 1), context: string(statement, 0) + ".summary")
            }
            cipher = candidate
        }
    }
    func close() {
        cipher = nil
        formatCache.removeAll()
        if let db { sqlite3_close(db); self.db = nil }
        if lockFD >= 0 { flock(lockFD, LOCK_UN); Darwin.close(lockFD); lockFD = -1 }
    }
    func suspendKey() { cipher = nil; formatCache.removeAll(); suspended = true }
    private func requireCipher() throws -> ContentCipher {
        guard let cipher else { throw ShiyingError.key }; return cipher
    }
    func records() throws -> [ClipRecord] {
        guard db != nil else { throw ShiyingError.database }
        let s = try prepare("SELECT id,created,copied,kind,bytes,saved,copies,partial FROM clips ORDER BY copied DESC, id DESC")
        defer { sqlite3_finalize(s) }
        var results: [ClipRecord] = []
        var status = sqlite3_step(s)
        while status == SQLITE_ROW {
            guard let kind = ClipKind(rawValue: string(s, 3)) else { throw ShiyingError.schema }
            results.append(ClipRecord(id: string(s, 0), created: Date(timeIntervalSince1970: sqlite3_column_double(s, 1)), copied: Date(timeIntervalSince1970: sqlite3_column_double(s, 2)), kind: kind, bytes: Int(sqlite3_column_int64(s, 4)), saved: sqlite3_column_int(s, 5) != 0, copies: Int(sqlite3_column_int(s, 6)), partial: sqlite3_column_int(s, 7) != 0))
            status = sqlite3_step(s)
        }
        guard status == SQLITE_DONE, results.count <= 35, results.filter(\.saved).count <= 30 else { throw ShiyingError.database }
        return results
    }
    func stats() throws -> StorageStats {
        let all = try records()
        let size = (try? FileManager.default.attributesOfItem(atPath: location.appendingPathComponent("history.sqlite").path)[.size] as? Int) ?? 0
        return StorageStats(count: all.count, saved: all.filter(\.saved).count, bytes: all.reduce(0) { $0 + $1.bytes }, databaseBytes: size)
    }
    func summary(_ id: String) throws -> ClipSummary {
        let data = try encryptedColumn("summary", id: id)
        do { return try decoder.decode(ClipSummary.self, from: requireCipher().open(data, context: id + ".summary")) }
        catch { cipher = nil; throw error }
    }
    func payload(_ id: String) throws -> ClipPayload {
        let data = try encryptedColumn("payload", id: id)
        do { return try decoder.decode(ClipPayload.self, from: requireCipher().open(data, context: id + ".payload")) }
        catch { cipher = nil; throw error }
    }
    func search(_ query: String, kind: ClipKind?, savedOnly: Bool, format: ClipFormat.Filter? = nil) async throws -> [ClipRow] {
        var results: [ClipRow] = []
        let all = try records(), ids = Set(all.map(\.id))
        formatCache = formatCache.filter { ids.contains($0.key) }
        for record in all {
            try Task.checkCancellation()
            if let kind, record.kind != kind { continue }
            if savedOnly && !record.saved { continue }
            var summary = try summary(record.id)
            summary.format = record.kind == .text ? ClipFormat(family: .text) : summary.format ?? formatCache[record.id]
            // Old records gain a display format from their encrypted payload in
            // memory only. No history rewrite, new key or schema migration.
            var content: ClipPayload?
            if summary.format == nil {
                let loaded = try payload(record.id)
                content = loaded
                summary.format = ClipFormat.detect(loaded, kind: record.kind)
            }
            if let detected = summary.format {
                formatCache[record.id] = detected
                if let format, !format.matches(detected) { continue }
            }
            var match = query.isEmpty || summary.title.localizedStandardContains(query) || summary.detail.localizedStandardContains(query)
            if !match && record.kind != .image {
                let payload = try content ?? payload(record.id)
                match = payload.plainText?.localizedStandardContains(query) == true || payload.fileURLs.contains { $0.lastPathComponent.localizedStandardContains(query) }
                if let text = payload.plainText, let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
                    let start = text.index(range.lowerBound, offsetBy: -32, limitedBy: text.startIndex) ?? text.startIndex
                    let end = text.index(range.upperBound, offsetBy: 80, limitedBy: text.endIndex) ?? text.endIndex
                    summary.detail = (start == text.startIndex ? "" : "…") + String(text[start..<end]).replacingOccurrences(of: "\n", with: " ")
                }
            }
            if match { results.append(ClipRow(record: record, summary: summary)) }
            await Task.yield()
        }
        return results
    }
    @discardableResult func insert(_ clip: CapturedClip, now: Date = .now) throws -> String {
        guard !suspended else { throw ShiyingError.key }
        if cipher == nil {
            guard try scalar("SELECT count(*) FROM clips") == 0 else { throw ShiyingError.key }
            cipher = ContentCipher(master: try injectedKey ?? keyLoader(true, .background))
        }
        let cipher = try requireCipher()
        guard clip.payload.rawBytes <= 32 * 1_024 * 1_024 else { throw ShiyingError.tooLarge }
        let plain = try clip.payload.encoded()
        let digest = cipher.digest(clip.payload)
        let id = UUID().uuidString
        let sealed = try cipher.seal(plain, context: id + ".payload")
        let summary = try cipher.seal(encoder.encode(clip.summary), context: id + ".summary")
        let bytes = sealed.count + summary.count
        return try transaction {
            let existing = try prepare("SELECT id FROM clips WHERE digest=?")
            bind(digest, to: existing, at: 1)
            let step = sqlite3_step(existing)
            let existingID = step == SQLITE_ROW ? string(existing, 0) : nil
            sqlite3_finalize(existing)
            guard step == SQLITE_ROW || step == SQLITE_DONE else { throw ShiyingError.database }
            if let existingID {
                let s = try prepare("UPDATE clips SET copied=?, copies=copies+1 WHERE id=?")
                defer { sqlite3_finalize(s) }
                sqlite3_bind_double(s, 1, now.timeIntervalSince1970); bind(existingID, to: s, at: 2)
                try done(s); return existingID
            }
            let removed = try Retention.evictions(records(), incomingBytes: bytes, budget: budget)
            for old in removed { try deleteSQL(old) }
            let s = try prepare("INSERT INTO clips(id,created,copied,kind,bytes,partial,digest,summary,payload) VALUES(?,?,?,?,?,?,?,?,?)")
            defer { sqlite3_finalize(s) }
            bind(id, to: s, at: 1)
            sqlite3_bind_double(s, 2, now.timeIntervalSince1970); sqlite3_bind_double(s, 3, now.timeIntervalSince1970)
            bind(clip.kind.rawValue, to: s, at: 4); sqlite3_bind_int64(s, 5, Int64(bytes))
            sqlite3_bind_int(s, 6, clip.partial ? 1 : 0)
            bind(digest, to: s, at: 7); bind(summary, to: s, at: 8); bind(sealed, to: s, at: 9)
            try done(s); return id
        }
    }
    /// Preview is repeated inside the transaction to prevent stale UI decisions.
    func favoriteImpact(_ id: String, deleting: Bool) throws -> Int {
        let all = try records()
        guard all.first(where: { $0.id == id })?.saved == true else { return 0 }
        return Retention.overflowAfterRemovingFavorite(all, deleting: deleting)
    }
    func toggleSaved(_ id: String, confirmedImpact: Int = 0) throws {
        try transaction {
            let all = try records()
            guard let record = all.first(where: { $0.id == id }) else { return }
            if !record.saved && all.filter(\.saved).count >= 30 { throw ShiyingError.favoriteLimit }
            let impact = try favoriteImpact(id, deleting: false)
            guard impact <= confirmedImpact else { throw ShiyingError.capacity }
            let s = try prepare("UPDATE clips SET saved=? WHERE id=?")
            defer { sqlite3_finalize(s) }
            sqlite3_bind_int(s, 1, record.saved ? 0 : 1); bind(id, to: s, at: 2); try done(s)
            try trim()
        }
    }
    func delete(_ id: String, confirmedImpact: Int = 0) throws {
        try transaction {
            guard try favoriteImpact(id, deleting: true) <= confirmedImpact else { throw ShiyingError.capacity }
            try deleteSQL(id); try trim()
        }
    }
    func clear(includeSaved: Bool) throws {
        try transaction { try execute(includeSaved ? "DELETE FROM clips" : "DELETE FROM clips WHERE saved=0") }
        // User-requested maintenance, never on every capture. SQLite owns journal recovery.
        try execute("PRAGMA incremental_vacuum")
    }
    private func trim() throws {
        let all = try records(); let limit = all.filter(\.saved).count == 30 ? 35 : 30
        for record in all.filter({ !$0.saved }).sorted(by: { $0.copied < $1.copied }).prefix(max(0, all.count - limit)) { try deleteSQL(record.id) }
    }
    private func deleteSQL(_ id: String) throws {
        let s = try prepare("DELETE FROM clips WHERE id=?"); defer { sqlite3_finalize(s) }
        bind(id, to: s, at: 1); try done(s)
    }
    private func encryptedColumn(_ column: String, id: String) throws -> Data {
        let s = try prepare("SELECT \(column) FROM clips WHERE id=?"); defer { sqlite3_finalize(s) }
        bind(id, to: s, at: 1)
        guard sqlite3_step(s) == SQLITE_ROW else { throw ShiyingError.unreadable }
        return blob(s, 0)
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let db else { throw ShiyingError.database }
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else { throw ShiyingError.database }
        return s
    }
    private func execute(_ sql: String) throws {
        guard let db, sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw ShiyingError.database }
    }
    private func scalar(_ sql: String) throws -> Int {
        let s = try prepare(sql); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else { throw ShiyingError.database }
        return Int(sqlite3_column_int64(s, 0))
    }
    private func done(_ s: OpaquePointer) throws { guard sqlite3_step(s) == SQLITE_DONE else { throw ShiyingError.database } }
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let value = try body(); try execute("COMMIT"); return value }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func bind(_ text: String, to s: OpaquePointer, at index: Int32) {
        _ = text.withCString { sqlite3_bind_text(s, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
    private func bind(_ data: Data, to s: OpaquePointer, at index: Int32) {
        _ = data.withUnsafeBytes { sqlite3_bind_blob(s, index, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
    private func string(_ s: OpaquePointer, _ index: Int32) -> String { String(cString: sqlite3_column_text(s, index)) }
    private func blob(_ s: OpaquePointer, _ index: Int32) -> Data {
        guard let pointer = sqlite3_column_blob(s, index) else { return Data() }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(s, index)))
    }
}

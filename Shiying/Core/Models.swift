import Foundation

enum ClipKind: String, Codable, Sendable, CaseIterable {
    case text, link, image, file
    var symbol: String { switch self { case .text: "text.alignleft"; case .link: "arrow.up.right"; case .image: "photo"; case .file: "doc" } }
}

struct Representation: Codable, Sendable, Equatable {
    let type: String
    let data: Data
}
struct ClipItem: Codable, Sendable, Equatable {
    var representations: [Representation]
    func data(_ type: String) -> Data? { representations.first { $0.type == type }?.data }
}
struct ClipPayload: Codable, Sendable, Equatable {
    var items: [ClipItem]
    var plainText: String? {
        let texts = items.compactMap { item in
            item.data("public.utf8-plain-text").flatMap { String(data: $0, encoding: .utf8) }
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }
    var fileURLs: [URL] {
        items.compactMap { $0.data("public.file-url").flatMap { String(data: $0, encoding: .utf8) }.flatMap(URL.init(string:)) }.filter(\.isFileURL)
    }
    var rawBytes: Int { items.reduce(0) { $0 + $1.representations.reduce(0) { $0 + $1.data.count } } }
    func encoded() throws -> Data {
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        return try encoder.encode(self)
    }
}
struct ClipSummary: Codable, Sendable {
    var title: String
    var detail: String
    var hasText: Bool
    var pixelWidth: Int?
    var pixelHeight: Int?
    // Optional for decoding existing encrypted summaries without a migration.
    var format: ClipFormat? = nil
}
struct CapturedClip: Sendable {
    var kind: ClipKind
    var payload: ClipPayload
    var summary: ClipSummary
    var partial: Bool
}
struct ClipRecord: Sendable, Identifiable {
    let id: String
    let created: Date
    let copied: Date
    let kind: ClipKind
    let bytes: Int
    let saved: Bool
    let copies: Int
    let partial: Bool
}
struct ClipRow: Sendable {
    let record: ClipRecord
    let summary: ClipSummary
}
struct StorageStats: Sendable {
    var count = 0
    var saved = 0
    var bytes = 0
    var databaseBytes = 0
    var buffer: Int { saved == 30 ? count - saved : 0 }
}

enum ShiyingError: Error, Sendable {
    case database, schema, key, keyAuthorization, authentication, capacity, favoriteLimit, tooLarge, unreadable, unsupported, fileUnavailable, write, busy
    var key: String {
        switch self {
        case .database: "error.storage"
        case .schema: "error.schema"
        case .key: "error.key"
        case .keyAuthorization: "error.keyAuthorization"
        case .authentication: "error.authentication"
        case .capacity: "error.capacity"
        case .favoriteLimit: "error.favoriteLimit"
        case .tooLarge: "error.tooLarge"
        case .unreadable: "error.unreadable"
        case .unsupported: "error.unsupported"
        case .fileUnavailable: "error.fileUnavailable"
        case .write: "error.write"
        case .busy: "error.instance"
        }
    }
}

/// Pure planning: never change the database until a complete valid plan exists.
enum Retention {
    static func evictions(_ records: [ClipRecord], incomingBytes: Int, budget: Int) throws -> [String] {
        let favorites = records.filter(\.saved).count
        let limit = favorites == 30 ? 35 : 30
        var count = records.count + 1
        var bytes = records.reduce(incomingBytes) { $0 + $1.bytes }
        var removed: [String] = []
        for record in records.filter({ !$0.saved }).sorted(by: { $0.copied < $1.copied }) {
            if count <= limit && bytes <= budget { break }
            removed.append(record.id); count -= 1; bytes -= record.bytes
        }
        guard count <= limit && bytes <= budget else { throw ShiyingError.capacity }
        return removed
    }
    static func overflowAfterRemovingFavorite(_ records: [ClipRecord], deleting: Bool) -> Int {
        guard records.filter(\.saved).count == 30 else { return 0 }
        return max(0, records.count - (deleting ? 1 : 0) - 30)
    }
}

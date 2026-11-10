import XCTest
import AppKit
import CryptoKit

@MainActor final class TextMetadataTests: XCTestCase {
    override func tearDown() async throws { Preferences.defaults.removeObject(forKey: "language") }

    func testRelativeTimeAlwaysPointsIntoPastIncludingZeroAndClockChanges() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for language in ["zh-Hans", "en"] {
            Preferences.defaults.set(language, forKey: "language")
            for age: Double in [-3_600, -0.1, 0, 0.001, 0.49, 0.99, 1, 1.99, 59, 59.99, 60, 90, 3_600, 86_400] {
                let result = ClipTime.label(for: now.addingTimeInterval(-age), relativeTo: now)
                if age < 60 {
                    let seconds = Int(max(0, age))
                    XCTAssertEqual(result, language == "zh-Hans" ? "\(seconds)秒前" : "\(seconds) sec. ago")
                } else {
                    XCTAssertTrue(result.contains(language == "zh-Hans" ? "前" : "ago"), result)
                }
                XCTAssertFalse(result.contains("后")); XCTAssertFalse(result.contains("in "))
            }
        }
    }
    func testLegacyTextRowsShareTextLabelAndIconWithoutChangingContent() {
        let families: [ClipFormat.Family] = [.text, .code, .markdown, .rtf, .html]
        for language in ["zh-Hans", "en"] {
            Preferences.defaults.set(language, forKey: "language")
            for family in families {
                let cell = ClipCell(frame: NSRect(x: 0, y: 0, width: 344, height: 60))
                let summary = ClipSummary(title: "# 原始 **正文** <tag>", detail: "下一行", hasText: true, format: ClipFormat(family: family, name: family == .code ? "Swift" : nil))
                let record = ClipRecord(id: family.rawValue, created: .now, copied: .now.addingTimeInterval(1), kind: .text, bytes: 0, saved: false, copies: 1, partial: false)
                cell.configure(ClipRow(record: record, summary: summary), number: 1, query: "", section: nil)
                let labels = descendants(cell).compactMap { $0 as? NSTextField }
                XCTAssertEqual(labels.first { $0.identifier?.rawValue == "clip.title" }?.stringValue, summary.title)
                XCTAssertEqual(labels.first { $0.identifier?.rawValue == "clip.detail" }?.stringValue, language == "zh-Hans" ? "文本 · 0秒前" : "Text · 0 sec. ago")
                XCTAssertEqual(cell.icon.accessibilityLabel(), L("text"))
            }
            for filter: ClipFormat.Filter in [.code, .markdown, .rtf, .html] {
                XCTAssertTrue(filter.label.contains(language == "zh-Hans" ? "文件" : "File"), filter.label)
            }
        }
    }
    func testOldTextSummariesMergeInSearchWhileCodeFilesStaySpecific() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(directory: directory, testKey: SymmetricKey(size: .bits256)); try await store.open()
        var originals: [(String, ClipFormat.Family, ClipPayload)] = []
        for (family, type, content) in [(ClipFormat.Family.html, "public.html", "<b>HTML</b>"), (.rtf, "public.rtf", "{\\rtf1 RTF}"), (.markdown, "net.daringfireball.markdown", "# Markdown"), (.code, "public.swift-source", "let x = 1")] {
            let payload = ClipPayload(items: [ClipItem(representations: [Representation(type: type, data: Data(content.utf8)), Representation(type: "public.utf8-plain-text", data: Data(content.utf8))])])
            let summary = ClipSummary(title: content, detail: "", hasText: true, format: ClipFormat(family: family))
            let id = try await store.insert(CapturedClip(kind: .text, payload: payload, summary: summary, partial: false))
            originals.append((id, family, payload))
        }
        let filePayload = ClipPayload(items: [ClipItem(representations: [Representation(type: "public.file-url", data: Data(URL(fileURLWithPath: "/not-opened/main.swift").absoluteString.utf8))])])
        _ = try await store.insert(CapturedClip(kind: .file, payload: filePayload, summary: ClipSummary(title: "main.swift", detail: "", hasText: false, format: ClipFormat(family: .code, name: "Swift")), partial: false))
        let textRows = try await store.search("", kind: .text, savedOnly: false)
        XCTAssertEqual(textRows.count, 4); XCTAssertTrue(textRows.allSatisfy { $0.summary.format?.family == .text })
        let codeFiles = try await store.search("", kind: nil, savedOnly: false, format: .code)
        XCTAssertEqual(codeFiles.count, 1); XCTAssertEqual(codeFiles.first?.record.kind, .file)
        let htmlFiles = try await store.search("", kind: nil, savedOnly: false, format: .html)
        XCTAssertTrue(htmlFiles.isEmpty)
        for (id, family, payload) in originals {
            let storedSummary = try await store.summary(id), storedPayload = try await store.payload(id)
            XCTAssertEqual(storedSummary.format?.family, family)
            XCTAssertEqual(storedPayload, payload)
        }
        await store.close()
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}

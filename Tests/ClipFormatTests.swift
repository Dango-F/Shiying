import XCTest
import AppKit
import CryptoKit

@MainActor final class ClipFormatTests: XCTestCase {
    private func payload(_ urls: [URL]) -> ClipPayload {
        ClipPayload(items: urls.map { ClipItem(representations: [Representation(type: "public.file-url", data: Data($0.absoluteString.utf8))]) })
    }
    func testFinderFileFormatsAndOriginalReferencesRoundTrip() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixtures: [(String, ClipFormat.Family, String?)] = [
            ("论文.PDF", .pdf, nil), ("报告.docx", .word, "DOCX"), ("旧稿.doc", .word, "DOC"),
            ("资料.zip", .archive, "ZIP"), ("资料.rar", .archive, "RAR"), ("资料.7z", .archive, "7Z"), ("源码.tar.gz", .archive, "TAR.GZ"),
            ("App.swift", .code, "Swift"), ("main.py", .code, "Python"), ("index.ts", .code, "TypeScript"), ("main.cpp", .code, "C++"),
            ("Dockerfile", .code, "Dockerfile"), ("CMakeLists.txt", .code, "CMake"), ("config.json", .code, "JSON"),
            ("说明.md", .markdown, nil), ("说明.markdown", .markdown, nil), ("稿件.rtf", .rtf, nil), ("页面.html", .html, nil),
            ("截图.png", .image, "PNG"), ("照片.jpg", .image, "JPEG"), ("照片.jpeg", .image, "JPEG"), ("扫描.tif", .image, "TIFF"),
            ("动画.gif", .image, "GIF"), ("照片.heic", .image, "HEIC"), ("插图.webp", .image, "WebP"), ("矢量.svg", .image, "SVG"),
            ("统计.xlsx", .spreadsheet, "XLSX"), ("汇报.pptx", .presentation, "PPTX"), ("说明.txt", .text, "TXT"),
            ("data.custom", .file, "CUSTOM"), ("no-extension", .file, nil)
        ]
        for (filename, family, name) in fixtures {
            let url = directory.appendingPathComponent(filename)
            try Data("The file contents are not copied into history.".utf8).write(to: url)
            let original = payload([url])
            _ = try Clipboard.write(original, plain: false, to: board)
            let clip = try XCTUnwrap(Clipboard.read(board), filename)
            XCTAssertEqual(clip.kind, .file, filename)
            XCTAssertEqual(clip.summary.title, filename)
            XCTAssertEqual(clip.summary.format?.family, family, filename)
            XCTAssertEqual(clip.summary.format?.name, name, filename)
            XCTAssertEqual(clip.payload.fileURLs, original.fileURLs)
        }
    }
    func testMultipleFilesFoldersAndUnknownNames() {
        let folder = URL(fileURLWithPath: "/not-opened/Folder", isDirectory: true)
        XCTAssertEqual(ClipFormat.detect(payload([folder]), kind: .file).family, .folder)
        let pdf = URL(fileURLWithPath: "/not-opened/a.pdf")
        let pdf2 = URL(fileURLWithPath: "/not-opened/b.pdf")
        let same = ClipFormat.detect(payload([pdf, pdf2]), kind: .file)
        XCTAssertEqual(same.family, .pdf); XCTAssertEqual(same.count, 2)
        let mixed = ClipFormat.detect(payload([pdf, folder]), kind: .file)
        XCTAssertEqual(mixed.family, .mixed); XCTAssertEqual(mixed.count, 2)
        XCTAssertTrue(ClipFormat.Filter.pdf.matches(same))
        XCTAssertFalse(ClipFormat.Filter.pdf.matches(mixed))
    }
    func testEncodedImageFormatsIncludingMislabelledRepresentation() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 12, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let fixtures: [(NSBitmapImageRep.FileType, String, String)] = [(.png, "public.png", "PNG"), (.jpeg, "public.jpeg", "JPEG"), (.tiff, "public.tiff", "TIFF"), (.gif, "com.compuserve.gif", "GIF"), (.jpeg, "public.png", "JPEG")]
        for (encoding, type, name) in fixtures {
            let data = try XCTUnwrap(bitmap.representation(using: encoding, properties: [:]))
            board.clearContents(); board.setData(data, forType: .init(type))
            if encoding == .tiff { board.setString(" \t \u{00A0}", forType: .string) }
            let captured = try XCTUnwrap(Clipboard.read(board))
            XCTAssertEqual(captured.kind, .image); XCTAssertEqual(captured.summary.format?.name, name)
            XCTAssertEqual(captured.summary.pixelWidth, 16); XCTAssertEqual(captured.summary.pixelHeight, 12)
            let cell = ClipCell(frame: NSRect(x: 0, y: 0, width: 344, height: 60))
            let record = ClipRecord(id: type, created: .now, copied: .now, kind: captured.kind, bytes: data.count, saved: false, copies: 1, partial: false)
            cell.configure(ClipRow(record: record, summary: captured.summary), number: 1, query: "", section: nil)
            let labels = descendants(cell).compactMap { $0 as? NSTextField }
            XCTAssertEqual(labels.first { $0.identifier?.rawValue == "clip.title" }?.stringValue, L("image"))
            XCTAssertEqual(labels.first { $0.identifier?.rawValue == "clip.detail" }?.stringValue, "\(name) · 16 × 12")
            _ = try Clipboard.write(captured.payload, plain: false, to: board)
            XCTAssertEqual(board.data(forType: .init(type)), data)
        }
    }
    func testExplicitMarkdownAndSourceCodeKeepBytesAndPlainFallback() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        for (type, text) in [("net.daringfireball.markdown", "# 标题\n**正文**"), ("public.swift-source", "let x = 2\nprint(x)")] {
            board.clearContents(); board.setString(text, forType: .init(type))
            let clip = try XCTUnwrap(Clipboard.read(board))
            XCTAssertEqual(clip.summary.format?.family, .text)
            XCTAssertEqual(clip.payload.plainText, text)
            _ = try Clipboard.write(clip.payload, plain: false, to: board)
            XCTAssertEqual(board.string(forType: .init(type)), text)
            _ = try Clipboard.write(clip.payload, plain: true, to: board)
            XCTAssertEqual(board.string(forType: .string), text)
            XCTAssertNil(board.data(forType: .init(type)))
        }
        board.clearContents()
        board.setString(String(repeating: "x", count: 1_024 * 1_024 + 1), forType: .init("net.daringfireball.markdown"))
        XCTAssertThrowsError(try Clipboard.read(board))
    }
    func testPlainAndRichTextShareOneCategory() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        for text in ["# 标题\n**正文**", "let x = 2", "<p>literal HTML</p>", "README.md"] {
            board.clearContents(); board.setString(text, forType: .string)
            let clip = try XCTUnwrap(Clipboard.read(board))
            XCTAssertEqual(clip.summary.format?.family, .text)
            XCTAssertEqual(clip.payload.plainText, text)
        }
        board.clearContents(); board.setString("<p>正文</p>", forType: .html)
        XCTAssertEqual(try Clipboard.read(board)?.summary.format?.family, .text)
        let rtf = NSAttributedString(string: "富文本")
        board.clearContents(); board.setData(rtf.rtf(from: NSRange(location: 0, length: rtf.length), documentAttributes: [:]), forType: .rtf)
        XCTAssertEqual(try Clipboard.read(board)?.summary.format?.family, .text)
    }
    func testOldEncryptedHistoryGainsFormatWithoutBeingRewritten() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        let store = HistoryStore(directory: directory, testKey: key); try await store.open()
        let old = ClipSummary(title: "报告.docx", detail: "报告.docx", hasText: false)
        var plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: PropertyListEncoder().encode(old), format: nil) as? [String: Any])
        plist.removeValue(forKey: "format")
        let decoded = try PropertyListDecoder().decode(ClipSummary.self, from: PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0))
        XCTAssertNil(decoded.format)
        let id = try await store.insert(CapturedClip(kind: .file, payload: payload([URL(fileURLWithPath: "/not-opened/报告.docx")]), summary: decoded, partial: true))
        await store.close()
        let reopened = HistoryStore(directory: directory, testKey: key); try await reopened.open()
        let before = try Data(contentsOf: directory.appendingPathComponent("history.sqlite"))
        let found = try await reopened.search("", kind: nil, savedOnly: false, format: .word)
        XCTAssertEqual(found.count, 1); XCTAssertEqual(found.first?.summary.format?.name, "DOCX")
        let original = try await reopened.summary(id); XCTAssertNil(original.format)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("history.sqlite")), before)
        let filtered = try await reopened.search("", kind: nil, savedOnly: false, format: .pdf)
        XCTAssertTrue(filtered.isEmpty)
        await reopened.close()
    }
    func testRowsHaveConsistentMetadataAndFileNamesInBothLanguages() {
        for language in ["zh-Hans", "en"] {
            Preferences.defaults.set(language, forKey: "language")
            for (filename, expected) in [("report.pdf", "PDF"), ("report.docx", "Word (DOCX)"), ("archive.zip", "ZIP"), ("main.swift", "Swift"), ("README.md", "Markdown"), ("draft.rtf", "RTF"), ("index.html", "HTML"), ("photo.jpg", "JPEG")] {
                let format = ClipFormat.file(URL(fileURLWithPath: "/not-opened/" + filename))
                let summary = ClipSummary(title: filename, detail: filename, hasText: false, format: format)
                let record = ClipRecord(id: filename, created: .now, copied: .now, kind: .file, bytes: 0, saved: false, copies: 1, partial: true)
                let cell = ClipCell(frame: NSRect(x: 0, y: 0, width: 344, height: 60))
                cell.configure(ClipRow(record: record, summary: summary), number: 1, query: "", section: nil)
                let labels = descendants(cell).compactMap { $0 as? NSTextField }
                XCTAssertEqual(labels.first { $0.identifier?.rawValue == "clip.title" }?.stringValue, filename)
                let detail = labels.first { $0.identifier?.rawValue == "clip.detail" }!
                XCTAssertTrue(detail.stringValue.hasPrefix(expected), detail.stringValue)
                XCTAssertFalse(detail.stringValue.contains(filename))
                cell.layoutSubtreeIfNeeded()
                XCTAssertLessThanOrEqual(detail.convert(detail.bounds, to: cell).maxX, cell.bounds.width)
            }
        }
        Preferences.defaults.removeObject(forKey: "language")
    }
    func testTypeMenuIncludesSpecificFormatsAndKeepsCompactWidth() {
        let controller = PanelController(model: AppModel())
        let popup = descendants(controller.panel.contentView!).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "panel.typeFilter" }!
        XCTAssertEqual(popup.numberOfItems, 1 + ClipKind.allCases.count + 1 + ClipFormat.Filter.allCases.count)
        XCTAssertTrue(popup.itemTitles.contains("PDF")); XCTAssertTrue(popup.itemTitles.contains("PNG")); XCTAssertTrue(popup.itemTitles.contains("JPEG"))
        controller.panel.contentView!.layoutSubtreeIfNeeded()
        XCTAssertEqual(popup.frame.width, 106, accuracy: 1)
        controller.hide()
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}

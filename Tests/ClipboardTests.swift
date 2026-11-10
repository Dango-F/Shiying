import XCTest
import AppKit

@MainActor final class ClipboardTests: XCTestCase {
    func testOrderedItemsAndRichFormatsRoundTrip() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let text = "中文 👋\n\tlet x = 1"
        let payload = ClipPayload(items: [
            ClipItem(representations: [Representation(type: "public.html", data: Data("<b>中文 👋</b>".utf8)), Representation(type: "public.utf8-plain-text", data: Data(text.utf8))]),
            ClipItem(representations: [Representation(type: "public.utf8-plain-text", data: Data("second".utf8))])])
        let generation = try Clipboard.write(payload, plain: false, to: board)
        let captured = try XCTUnwrap(Clipboard.read(board))
        XCTAssertEqual(board.changeCount, generation); XCTAssertEqual(captured.payload.items.count, 2)
        XCTAssertEqual(captured.payload.items[0].data("public.html"), payload.items[0].data("public.html"))
        XCTAssertEqual(captured.payload.plainText, text + "\nsecond")
        _ = try Clipboard.write(captured.payload, plain: true, to: board)
        XCTAssertEqual(board.string(forType: .string), text + "\nsecond")
        XCTAssertNil(board.data(forType: .html))
    }
    func testSensitiveMarkersSkipWholeCapture() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let first = NSPasteboardItem(); first.setString("secret", forType: .string)
        let second = NSPasteboardItem(); second.setString("", forType: .init("org.nspasteboard.ConcealedType")); second.setString("password", forType: .string)
        board.writeObjects([first, second]); XCTAssertNil(try Clipboard.read(board))
    }
    func testOrderedFileReferencesAndNoMoveFlags() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShiyingFiles-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = [folder.appendingPathComponent("first.txt"), folder.appendingPathComponent("second.txt")]
        for url in urls { try Data("fixture".utf8).write(to: url) }
        let files = urls.map(\.absoluteString)
        let items = files.map { value in
            let item = NSPasteboardItem(); item.setString(value, forType: .fileURL); item.setString("move", forType: .init("com.apple.finder.node")); return item
        }
        board.writeObjects(items)
        let captured = try XCTUnwrap(Clipboard.read(board)); XCTAssertEqual(captured.kind, .file); XCTAssertTrue(captured.partial)
        XCTAssertEqual(captured.payload.fileURLs.map(\.absoluteString), files)
        _ = try Clipboard.write(captured.payload, plain: false, to: board)
        XCTAssertNil(board.pasteboardItems?.first?.data(forType: .init("com.apple.finder.node")))
    }
    func testHTMLFallbackIsPlainAndOriginalBytesPreserved() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let html = "<html><script>doNotExecute()</script><p>Hello &amp; 中文</p><img src='https://invalid.local/remote'></html>"
        board.setString(html, forType: .html)
        let captured = try XCTUnwrap(Clipboard.read(board))
        XCTAssertEqual(captured.payload.items[0].data("public.html"), Data(html.utf8))
        XCTAssertTrue(captured.payload.plainText?.contains("Hello & 中文") == true)
        XCTAssertFalse(captured.payload.plainText?.contains("doNotExecute") == true)
    }
    func testOversizeTextIsRejectedWithoutPartialRecord() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setString(String(repeating: "x", count: 1_024 * 1_024 + 1), forType: .string)
        XCTAssertThrowsError(try Clipboard.read(board)) { error in
            guard case ShiyingError.tooLarge = error else { return XCTFail("Wrong error") }
        }
    }
    func testUnsupportedItemDoesNotSilentlyReorderMultiItemCapture() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let first = NSPasteboardItem(); first.setString("ok", forType: .string)
        let unknown = NSPasteboardItem(); unknown.setString("opaque", forType: .init("com.example.unknown"))
        board.writeObjects([first, unknown]); XCTAssertThrowsError(try Clipboard.read(board))
    }
    func testRTFAndPNGKeepOriginalBytes() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let rich = NSAttributedString(string: "富文本 👋", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
        let rtf = try XCTUnwrap(rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]))
        board.setData(rtf, forType: .rtf)
        let text = try XCTUnwrap(Clipboard.read(board))
        XCTAssertEqual(text.payload.items[0].data("public.rtf"), rtf)
        XCTAssertEqual(text.payload.plainText, "富文本 👋")
        board.clearContents()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 12, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        board.setData(png, forType: .png)
        let image = try XCTUnwrap(Clipboard.read(board))
        XCTAssertEqual(image.kind, .image); XCTAssertEqual(image.summary.pixelWidth, 16); XCTAssertEqual(image.summary.pixelHeight, 12)
        _ = try Clipboard.write(image.payload, plain: false, to: board)
        XCTAssertEqual(board.data(forType: .png), png)
    }

}

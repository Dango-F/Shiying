import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A display format, kept inside the encrypted summary. It does not change the
/// four storage kinds, the original clipboard bytes, or the database schema.
struct ClipFormat: Codable, Sendable, Equatable {
    enum Family: String, Codable, Sendable {
        case text, link, image, pdf, word, spreadsheet, presentation, archive
        case code, markdown, rtf, html, folder, file, mixed
    }
    var family: Family
    var name: String?
    var count: Int = 1

    /// Text fragments share one display category, including summaries written
    /// by older versions that stored HTML / RTF / Markdown / code labels.
    func displayed(for kind: ClipKind) -> Self {
        kind == .text ? Self(family: .text) : self
    }

    static let imageTypes = ["public.png", "public.tiff", "public.jpeg", "com.compuserve.gif", "public.heic", "public.heif", "org.webmproject.webp", "com.microsoft.bmp"]
    static let markdownTypes: Set<String> = ["net.daringfireball.markdown", "public.markdown"]
    static func isSourceText(_ type: String) -> Bool {
        markdownTypes.contains(type) || UTType(type)?.conforms(to: .sourceCode) == true
    }
    static func imageData(in payload: ClipPayload) -> Data? {
        payload.items.lazy.compactMap { item in imageTypes.lazy.compactMap { item.data($0) }.first }.first
    }
    static func detect(_ payload: ClipPayload, kind: ClipKind) -> Self {
        if kind == .text { return Self(family: .text) }
        let files = payload.fileURLs
        if !files.isEmpty {
            let formats = files.map(file)
            var first = formats[0]
            if !formats.allSatisfy({ $0.family == first.family && $0.name == first.name }) {
                first = Self(family: .mixed)
            }
            first.count = files.count
            return first
        }
        if kind == .image, let data = imageData(in: payload),
           let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
           let identifier = CGImageSourceGetType(source) as String? {
            // Read the encoded format, not the source application's advertised UTI.
            let names = ["public.png": "PNG", "public.jpeg": "JPEG", "public.tiff": "TIFF", "com.compuserve.gif": "GIF", "public.heic": "HEIC", "public.heif": "HEIF", "org.webmproject.webp": "WebP", "com.microsoft.bmp": "BMP"]
            return Self(family: .image, name: names[identifier] ?? UTType(identifier)?.preferredFilenameExtension?.uppercased())
        }
        if kind == .link { return Self(family: .link) }
        return Self(family: kind == .file ? .file : kind == .image ? .image : .text)
    }
    static func file(_ url: URL) -> Self {
        // Classify references by their names. Never open or render file contents,
        // including cloud placeholders, archives and documents.
        if url.hasDirectoryPath { return Self(family: .folder) }
        let ext = url.pathExtension.lowercased()
        let filename = url.lastPathComponent.lowercased()
        if ["makefile", "dockerfile", "cmakelists.txt"].contains(filename) { return Self(family: .code, name: filename == "cmakelists.txt" ? "CMake" : filename == "makefile" ? "Makefile" : "Dockerfile") }
        if let suffix = ["tar.gz", "tar.bz2", "tar.xz", "tar.zst"].first(where: { filename.hasSuffix("." + $0) }) {
            return Self(family: .archive, name: suffix.uppercased())
        }
        switch ext {
        case "pdf": return Self(family: .pdf)
        case "doc", "docx", "docm", "dot", "dotx": return Self(family: .word, name: ext.uppercased())
        case "xls", "xlsx", "xlsm", "csv", "tsv", "numbers", "ods": return Self(family: .spreadsheet, name: ext.uppercased())
        case "ppt", "pptx", "pptm", "key", "odp": return Self(family: .presentation, name: ext.uppercased())
        case "zip", "rar", "7z", "tar", "gz", "gzip", "bz2", "xz", "zst", "tgz": return Self(family: .archive, name: ext.uppercased())
        case "md", "markdown", "mdown", "mkd": return Self(family: .markdown)
        case "rtf", "rtfd": return Self(family: .rtf)
        case "html", "htm", "xhtml": return Self(family: .html)
        case "png", "jpg", "jpeg", "jpe", "tif", "tiff", "gif", "heic", "heif", "webp", "bmp", "svg", "avif", "ico":
            let name = ["jpg": "JPEG", "jpe": "JPEG", "jpeg": "JPEG", "tif": "TIFF", "webp": "WebP"][ext] ?? ext.uppercased()
            return Self(family: .image, name: name)
        default: break
        }
        let languages = ["swift": "Swift", "m": "Objective-C", "mm": "Objective-C++", "h": "C/C++", "c": "C", "cc": "C++", "cpp": "C++", "cxx": "C++", "hpp": "C++", "py": "Python", "pyw": "Python", "js": "JavaScript", "jsx": "JSX", "ts": "TypeScript", "tsx": "TSX", "java": "Java", "kt": "Kotlin", "kts": "Kotlin", "go": "Go", "rs": "Rust", "rb": "Ruby", "php": "PHP", "cs": "C#", "sh": "Shell", "bash": "Bash", "zsh": "Zsh", "fish": "Fish", "sql": "SQL", "r": "R", "lua": "Lua", "dart": "Dart", "vue": "Vue", "svelte": "Svelte", "css": "CSS", "scss": "SCSS", "json": "JSON", "yaml": "YAML", "yml": "YAML", "toml": "TOML", "xml": "XML", "tex": "LaTeX"]
        if let language = languages[ext] { return Self(family: .code, name: language) }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .sourceCode) { return Self(family: .code, name: ext.uppercased()) }
        if ["txt", "text", "log"].contains(ext) { return Self(family: .text, name: ext.uppercased()) }
        return Self(family: .file, name: ext.isEmpty ? nil : String(ext.prefix(20)).uppercased())
    }
    enum Filter: String, CaseIterable, Sendable {
        case pdf, word, spreadsheet, presentation, archive, code, markdown, rtf, html, folder
        case png, jpeg, tiff, gif, heic, webp
        func matches(_ format: ClipFormat) -> Bool {
            switch self {
            case .png, .jpeg, .tiff, .gif, .heic, .webp:
                return format.family == .image && format.name?.lowercased() == rawValue
            default: return format.family.rawValue == rawValue
            }
        }
    }
}

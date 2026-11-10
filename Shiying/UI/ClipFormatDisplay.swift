import AppKit

@MainActor extension ClipFormat {
    var label: String {
        switch family {
        case .pdf: return "PDF"
        case .word: return "Word" + (name.map { " (\($0))" } ?? "")
        case .markdown: return "Markdown"
        case .rtf: return "RTF"
        case .html: return "HTML"
        case .image: return name ?? L("image")
        case .archive, .code, .spreadsheet, .presentation, .file, .text:
            return (name.map { $0 + " " } ?? "") + L("format." + family.rawValue)
        case .folder, .mixed: return L("format." + family.rawValue)
        case .link: return L("link")
        }
    }
    var symbol: String {
        switch family {
        case .pdf: "doc.richtext"
        case .word, .spreadsheet, .presentation, .rtf, .html, .markdown: "doc.text"
        case .archive: "archivebox"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .folder: "folder"
        case .file, .mixed: "doc"
        case .image: "photo"
        case .text: "text.alignleft"
        case .link: "arrow.up.right"
        }
    }
}

@MainActor extension ClipFormat.Filter {
    var label: String {
        switch self {
        case .png, .jpeg, .tiff, .gif, .heic: rawValue.uppercased()
        case .webp: "WebP"
        case .code, .markdown, .rtf, .html:
            String(format: L("format.fileType"), ClipFormat(family: ClipFormat.Family(rawValue: rawValue)!).label)
        default: ClipFormat(family: ClipFormat.Family(rawValue: rawValue)!).label
        }
    }
}

@MainActor enum ClipTime {
    static func label(for copied: Date, relativeTo now: Date = .now) -> String {
        // RelativeDateTimeFormatter rounds a subsecond past interval to zero,
        // whose direction becomes "after". Format whole seconds explicitly;
        // a future timestamp after a clock adjustment also starts at zero ago.
        let elapsed = max(0, now.timeIntervalSince(copied))
        if elapsed < 60 { return String(format: L("time.secondsAgo"), Int(elapsed)) }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: Preferences.resolvedLanguage)
        formatter.unitsStyle = .short
        return formatter.localizedString(fromTimeInterval: -elapsed)
    }
}

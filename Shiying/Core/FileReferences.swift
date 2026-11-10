import Foundation

enum FileReferences {
    /// Finder can select a file or folder without reading its contents. Reject
    /// empty or stale references rather than silently opening Finder with no target.
    static func availableURLs(in payload: ClipPayload) throws -> [URL] {
        let urls = payload.fileURLs
        guard !urls.isEmpty, urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw ShiyingError.fileUnavailable
        }
        return urls
    }
}

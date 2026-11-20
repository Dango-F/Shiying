import Foundation

@MainActor final class UpdateChecker {
    enum Status: Equatable {
        case idle, current, available(tag: String), failed
    }

    private static let endpoint = URL(string: "https://api.github.com/repos/Dango-F/Shiying/releases/latest")!
    private static let releasePage = URL(string: "https://github.com/Dango-F/Shiying/releases/tag")!
    private static let lastAttemptKey = "updates.lastAttempt"
    private static let cachedTagKey = "updates.cachedTag"
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    private let defaults: UserDefaults
    private let version: ReleaseVersion?
    private let isDevelopment: Bool
    private let fetch: (URLRequest) async throws -> (Data, URLResponse)
    private var scheduledCheck: Task<Void, Never>?
    private var request: Task<Void, Never>?
    private var lastResult: Status = .idle
    private(set) var status: Status = .idle
    var onChange: (() -> Void)?

    var supportsAutomaticChecks: Bool { !isDevelopment }
    var automaticChecksEnabled: Bool {
        supportsAutomaticChecks && (defaults.object(forKey: "automaticUpdateChecks") as? Bool ?? true)
    }
    var isChecking: Bool { request != nil }
    var downloadURL: URL? {
        guard case let .available(tag) = status else { return nil }
        return Self.releasePage.appendingPathComponent(tag)
    }

    init(defaults: UserDefaults = .standard, version: String = BuildInfo.version,
         isDevelopment: Bool = BuildInfo.isDevelopment,
         fetch: @escaping (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) {
        self.defaults = defaults
        self.version = ReleaseVersion(version)
        self.isDevelopment = isDevelopment
        self.fetch = fetch
        if let tag = defaults.string(forKey: Self.cachedTagKey),
           let remote = ReleaseVersion(tag), let local = self.version, remote > local {
            status = .available(tag: tag)
            lastResult = status
        }
    }

    func setAutomaticChecksEnabled(_ enabled: Bool) {
        guard supportsAutomaticChecks else { return }
        defaults.set(enabled, forKey: "automaticUpdateChecks")
        scheduleAutomaticCheck()
        onChange?()
    }

    func scheduleAutomaticCheck() {
        scheduledCheck?.cancel()
        scheduledCheck = nil
        guard automaticChecksEnabled, !isChecking else { return }
        let lastAttempt = defaults.object(forKey: Self.lastAttemptKey) as? Date
        let elapsed = lastAttempt.map { Date.now.timeIntervalSince($0) } ?? Self.checkInterval
        let delay = elapsed < 0 ? 3 : max(3, Self.checkInterval - elapsed)
        scheduledCheck = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay), tolerance: .seconds(2)) }
            catch { return }
            self?.scheduledCheck = nil
            self?.startCheck(manual: false)
        }
    }

    func checkNow() { startCheck(manual: true) }

    func stop() {
        scheduledCheck?.cancel()
        request?.cancel()
        scheduledCheck = nil
        request = nil
    }

    private func startCheck(manual: Bool) {
        guard !isChecking, manual || automaticChecksEnabled else { return }
        scheduledCheck?.cancel()
        scheduledCheck = nil
        defaults.set(Date.now, forKey: Self.lastAttemptKey)
        request = Task { [weak self] in
            guard let self else { return }
            do {
                let tag = try await latestTag()
                try Task.checkCancellation()
                guard let local = version, let remote = ReleaseVersion(tag) else { throw URLError(.cannotParseResponse) }
                if remote > local {
                    defaults.set(tag, forKey: Self.cachedTagKey)
                    lastResult = .available(tag: tag)
                } else {
                    defaults.removeObject(forKey: Self.cachedTagKey)
                    lastResult = .current
                }
                status = lastResult
            } catch {
                guard !Task.isCancelled else { return }
                status = manual ? .failed : lastResult
            }
            request = nil
            scheduleAutomaticCheck()
            onChange?()
        }
        onChange?()
    }

    private func latestTag() async throws -> String {
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await fetch(request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.draft, !release.prerelease else { throw URLError(.cannotParseResponse) }
        return release.tag_name
    }

    private struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
    }
}

private struct ReleaseVersion: Comparable {
    private let components: [UInt]

    init?(_ text: String) {
        let number = text.hasPrefix("v") ? text.dropFirst() : text[...]
        let parts = number.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        components = parts.compactMap { UInt($0) }
        guard components.count == 3 else { return nil }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

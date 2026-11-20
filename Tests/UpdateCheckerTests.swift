import AppKit
import XCTest

@MainActor final class UpdateCheckerTests: XCTestCase {
    func testAutomaticCheckThrottlesAcrossLaunches() async throws {
        let suite = "ShiyingUpdateTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var attempts = 0
        let fetch: (URLRequest) async throws -> (Data, URLResponse) = { request in
            attempts += 1
            XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/Dango-F/Shiying/releases/latest")
            return try Self.response(to: request, tag: "v0.1.20")
        }
        let checker = UpdateChecker(defaults: defaults, version: "0.1.9", isDevelopment: false, fetch: fetch)
        checker.scheduleAutomaticCheck()
        try await wait { checker.status == .available(tag: "v0.1.20") }
        checker.stop()
        let restarted = UpdateChecker(defaults: defaults, version: "0.1.9", isDevelopment: false, fetch: fetch)
        defer { restarted.stop() }
        XCTAssertEqual(restarted.downloadURL?.absoluteString, "https://github.com/Dango-F/Shiying/releases/tag/v0.1.20")
        restarted.scheduleAutomaticCheck()
        try await Task.sleep(for: .seconds(3.2))
        XCTAssertEqual(attempts, 1)
        let upgraded = UpdateChecker(defaults: defaults, version: "0.1.20", isDevelopment: false, fetch: fetch)
        XCTAssertNil(upgraded.downloadURL)
    }

    func testAboutSwitchPersistsAndManualButtonStillChecksWhenDisabled() async throws {
        _ = NSApplication.shared
        let suite = "ShiyingUpdateTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let checker = UpdateChecker(defaults: defaults, version: "0.1.20", isDevelopment: false) { request in
            try Self.response(to: request, tag: "v0.1.20")
        }
        defer { checker.stop() }
        let settings = SettingsController(model: AppModel(), initialPage: 5, updateChecker: checker)
        let content = try XCTUnwrap(settings.window?.contentView)
        defer { settings.window?.close() }
        let controls = descendants(content).compactMap { $0 as? NSControl }
        let toggle = try XCTUnwrap(controls.compactMap { $0 as? NSSwitch }.first)
        let check = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.title == L("update.check") })
        let download = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.title == L("update.download") })
        XCTAssertEqual(toggle.state, .on)
        toggle.state = .off
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(toggle.action), to: toggle.target, from: toggle))
        XCTAssertFalse(UpdateChecker(defaults: defaults, isDevelopment: false).automaticChecksEnabled)
        check.performClick(nil)
        XCTAssertTrue(checker.isChecking)
        XCTAssertFalse(check.isEnabled)
        try await wait { !checker.isChecking }
        XCTAssertEqual(checker.status, .current)
        XCTAssertTrue(check.isEnabled)
        XCTAssertTrue(download.isHidden)
    }

    func testRateLimitAndNonStableVersionsNeverOfferDownloads() async throws {
        let suite = "ShiyingUpdateTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for (code, tag, prerelease) in [(429, "v0.1.20", false), (200, "v0.1.20", true), (200, "v0.1.20-beta.1", false)] {
            let checker = UpdateChecker(defaults: defaults, version: "0.1.19", isDevelopment: true) { request in
                try Self.response(to: request, code: code, tag: tag, prerelease: prerelease)
            }
            XCTAssertFalse(checker.automaticChecksEnabled)
            checker.checkNow()
            try await wait { !checker.isChecking }
            XCTAssertEqual(checker.status, .failed)
            XCTAssertNil(checker.downloadURL)
        }
    }

    private static func response(to request: URLRequest, code: Int = 200, tag: String, prerelease: Bool = false) throws -> (Data, URLResponse) {
        let data = try JSONSerialization.data(withJSONObject: ["tag_name": tag, "draft": false, "prerelease": prerelease])
        let url = try XCTUnwrap(request.url)
        return (data, try XCTUnwrap(HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)))
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func wait(until condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for update check")
    }
}

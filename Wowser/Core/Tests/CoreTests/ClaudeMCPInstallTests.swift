import XCTest
@testable import Core

#if os(macOS)
final class ClaudeMCPInstallTests: XCTestCase {

    private func tempSettingsURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("settings.json")
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    func testCreatesSettingsWhenMissing() throws {
        let url = try tempSettingsURL()
        try ClaudeMCPInstall.applyRecommendedPermissions(serverName: "wowser", settingsURL: url)
        let allow = (try readJSON(url)["permissions"] as? [String: Any])?["allow"] as? [String]
        XCTAssertEqual(allow, ClaudeMCPInstall.allowRules(serverName: "wowser"))
        XCTAssertTrue(allow?.contains("mcp__wowser__read_browser_js") == true)
        XCTAssertFalse(allow?.contains("mcp__wowser__run_browser_js") == true)
    }

    func testPreservesExistingSettingsAndDoesNotDuplicate() throws {
        let url = try tempSettingsURL()
        let existing: [String: Any] = [
            "model": "opus",
            "permissions": ["allow": ["Bash(ls)", "mcp__wowser__read_browser_js"], "deny": ["Bash(rm *)"]],
        ]
        try JSONSerialization.data(withJSONObject: existing).write(to: url)

        try ClaudeMCPInstall.applyRecommendedPermissions(serverName: "wowser", settingsURL: url)
        try ClaudeMCPInstall.applyRecommendedPermissions(serverName: "wowser", settingsURL: url)

        let json = try readJSON(url)
        XCTAssertEqual(json["model"] as? String, "opus")
        let permissions = json["permissions"] as? [String: Any]
        XCTAssertEqual(permissions?["deny"] as? [String], ["Bash(rm *)"])
        let allow = permissions?["allow"] as? [String] ?? []
        XCTAssertEqual(allow.first, "Bash(ls)")
        XCTAssertEqual(allow.filter { $0 == "mcp__wowser__read_browser_js" }.count, 1)
        XCTAssertEqual(Set(allow), Set(["Bash(ls)"] + ClaudeMCPInstall.allowRules(serverName: "wowser")))
    }

    func testRefusesUnparseableSettings() throws {
        let url = try tempSettingsURL()
        let junk = Data("{ // comment\n \"model\": \"opus\" }".utf8)
        try junk.write(to: url)
        XCTAssertThrowsError(try ClaudeMCPInstall.applyRecommendedPermissions(serverName: "wowser", settingsURL: url))
        XCTAssertEqual(try Data(contentsOf: url), junk)
    }

    func testWritesThroughSymlink() throws {
        let link = try tempSettingsURL()
        let real = link.deletingLastPathComponent().appendingPathComponent("real.json")
        try Data("{}".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        try ClaudeMCPInstall.applyRecommendedPermissions(serverName: "wowser", settingsURL: link)

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), real.path)
        XCTAssertNotNil(try readJSON(real)["permissions"])
    }
}
#endif

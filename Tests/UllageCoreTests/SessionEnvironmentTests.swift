import Foundation
import XCTest
@testable import UllageCore

/// M2.5 — the snapshot that cannot be reconstructed later.
final class SessionEnvironmentTests: XCTestCase {
    /// Builds a fake `~/.claude` and project tree, and a provider pointed at it.
    private func makeFixture() throws -> (root: URL, provider: SessionEnvironmentProvider, cwd: String) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ullage-env-" + UUID().uuidString, isDirectory: true)
        let config = root.appendingPathComponent(".claude", isDirectory: true)
        let project = root.appendingPathComponent("proj", isDirectory: true)
        let manager = FileManager.default
        for directory in [
            config.appendingPathComponent("skills/reviewer"),
            config.appendingPathComponent("skills/half-a-skill"),
            project.appendingPathComponent(".claude/skills/deploy"),
        ] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try "# reviewer".write(to: config.appendingPathComponent("skills/reviewer/SKILL.md"), atomically: true, encoding: .utf8)
        try "# deploy".write(to: project.appendingPathComponent(".claude/skills/deploy/SKILL.md"), atomically: true, encoding: .utf8)
        // No SKILL.md: a directory alone is not a skill.

        try #"{"mcpServers":{"github":{"command":"x"},"linear":{"command":"y"}}}"#
            .write(to: config.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        try #"{"mcpServers":{"playwright":{"command":"z"}}}"#
            .write(to: project.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)

        try "# user memory\n"
            .write(to: config.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        try "# project rules\n@shared/style.md\ncontact: @someone in chat\n"
            .write(to: project.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        try manager.createDirectory(at: project.appendingPathComponent("shared"), withIntermediateDirectories: true)
        try "two-space indents\n"
            .write(to: project.appendingPathComponent("shared/style.md"), atomically: true, encoding: .utf8)

        let provider = SessionEnvironmentProvider(environment: ["CLAUDE_CONFIG_DIR": config.path])
        return (root, provider, project.path)
    }

    func testSnapshotCapturesServersSkillsAndMemory() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let snapshot = fixture.provider.snapshot(
            sessionId: "sess-1",
            cwd: fixture.cwd,
            claudeVersion: "2.0.14"
        )
        XCTAssertEqual(snapshot.claudeVersion, "2.0.14")
        XCTAssertEqual(snapshot.mcpServers, #"["github","linear","playwright"]"#)
        XCTAssertEqual(snapshot.skills, #"["deploy","reviewer"]"#)

        let body = try XCTUnwrap(snapshot.claudeMdBody)
        XCTAssertTrue(body.contains("# user memory"))
        XCTAssertTrue(body.contains("# project rules"))
        XCTAssertTrue(body.contains("two-space indents"))      // @import expanded inline
        XCTAssertTrue(body.contains("contact: @someone in chat"))  // prose left alone
        XCTAssertEqual(snapshot.claudeMdBytes, body.utf8.count)
        XCTAssertEqual(snapshot.claudeMdHash, SHA256.hexDigest(body))
        XCTAssertFalse(snapshot.capturedAt.isEmpty)
    }

    func testSnapshotIsEmptyRatherThanAbsentWhenNothingIsConfigured() {
        let provider = SessionEnvironmentProvider(environment: ["CLAUDE_CONFIG_DIR": "/nonexistent-\(UUID().uuidString)"])
        let snapshot = provider.snapshot(sessionId: "sess-2", cwd: nil, claudeVersion: nil)
        XCTAssertNil(snapshot.mcpServers)
        XCTAssertNil(snapshot.skills)
        XCTAssertNil(snapshot.claudeMdBody)
        XCTAssertEqual(snapshot.sessionId, "sess-2")
    }

    func testImportCyclesTerminate() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ullage-cycle-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "a\n@b.md\n".write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "b\n@a.md\n".write(to: root.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)

        let provider = SessionEnvironmentProvider(environment: [:])
        let expanded = try XCTUnwrap(provider.expand(fileAt: root.appendingPathComponent("a.md")))
        XCTAssertTrue(expanded.contains("a"))
        XCTAssertTrue(expanded.contains("b"))
    }

    func testIngestSnapshotsEachSessionExactlyOnce() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let workspace = try TempWorkspace(environmentProvider: fixture.provider)

        let first = try workspace.ingestor.ingestFile(at: try workspace.copyFixture("basic-session.jsonl"))
        XCTAssertEqual(first.sessionEnvSnapshots, 1)
        XCTAssertEqual(try workspace.store.sessionEnvCount(), 1)

        let env = try XCTUnwrap(try workspace.store.sessionEnv(sessionId: "sess-abc123"))
        XCTAssertEqual(env.claudeVersion, "2.0.14")   // read off the transcript entry
        XCTAssertEqual(try workspace.store.sessionsMissingEnv(), [])

        // A second ingestor over the same data must not re-snapshot.
        try workspace.store.database.run("DELETE FROM file_cursor;")
        let second = Ingestor(store: workspace.store, environmentProvider: fixture.provider)
        let stats = try second.ingestFile(at: workspace.root.appendingPathComponent("basic-session.jsonl"))
        XCTAssertEqual(stats.sessionEnvSnapshots, 0)
        XCTAssertEqual(try workspace.store.sessionEnvCount(), 1)
    }

    func testSHA256MatchesKnownVectors() {
        XCTAssertEqual(
            SHA256.hexDigest(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(
            SHA256.hexDigest("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(
            SHA256.hexDigest("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
        // Crosses the 64-byte block boundary.
        XCTAssertEqual(
            SHA256.hexDigest(String(repeating: "a", count: 1_000_000)),
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        )
    }
}

/// The retention check that every entry point repeats until it is set.
final class RetentionTests: XCTestCase {
    private func makeConfig(_ settings: String?) throws -> (URL, [String: String]) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ullage-retention-" + UUID().uuidString, isDirectory: true)
        let config = root.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        if let settings {
            try settings.write(to: config.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        }
        return (root, ["CLAUDE_CONFIG_DIR": config.path])
    }

    func testUnsetIsWarnedAbout() throws {
        let (root, environment) = try makeConfig(nil)
        defer { try? FileManager.default.removeItem(at: root) }
        let status = Retention.status(environment: environment)
        XCTAssertEqual(status, .unset)
        XCTAssertFalse(status.isSafe)
        XCTAssertNotNil(Retention.warning(for: status))
    }

    func testDefaultThirtyDaysIsWarnedAbout() throws {
        let (root, environment) = try makeConfig(#"{"cleanupPeriodDays":30}"#)
        defer { try? FileManager.default.removeItem(at: root) }
        let status = Retention.status(environment: environment)
        XCTAssertEqual(status, .days(30))
        XCTAssertFalse(status.isSafe)
        XCTAssertTrue(try XCTUnwrap(Retention.warning(for: status)).contains("3650"))
    }

    func testLongRetentionIsSilent() throws {
        let (root, environment) = try makeConfig(#"{"cleanupPeriodDays":3650,"model":"opus"}"#)
        defer { try? FileManager.default.removeItem(at: root) }
        let status = Retention.status(environment: environment)
        XCTAssertEqual(status, .days(3_650))
        XCTAssertTrue(status.isSafe)
        XCTAssertNil(Retention.warning(for: status))
    }

    func testUnreadableSettingsAreReportedNotIgnored() throws {
        let (root, environment) = try makeConfig("{ not json")
        defer { try? FileManager.default.removeItem(at: root) }
        guard case .unreadable = Retention.status(environment: environment) else {
            return XCTFail("expected .unreadable")
        }
    }
}

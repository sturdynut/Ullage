import Foundation
import XCTest
@testable import UllageCore

/// Crush's per-project `crush.db`, synthesized with the columns from
/// `internal/db/migrations` (sessions, messages).
final class HarnessCrushTests: XCTestCase {
    private func makeDatabase(in workspace: TempWorkspace) throws -> URL {
        let dir = workspace.root.appendingPathComponent("proj/.crush", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("crush.db")
        try SQLiteDatabase(path: url.path).execute("""
        CREATE TABLE sessions (id TEXT PRIMARY KEY, parent_session_id TEXT, title TEXT NOT NULL, message_count INTEGER NOT NULL DEFAULT 0,
            prompt_tokens INTEGER NOT NULL DEFAULT 0, completion_tokens INTEGER NOT NULL DEFAULT 0, cost REAL NOT NULL DEFAULT 0,
            updated_at INTEGER NOT NULL, created_at INTEGER NOT NULL, summary_message_id TEXT);
        CREATE TABLE messages (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, role TEXT NOT NULL, parts TEXT NOT NULL DEFAULT '[]',
            model TEXT, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, finished_at INTEGER, provider TEXT);
        INSERT INTO sessions VALUES ('s1', NULL, 't', 4, 42000, 800, 0.1, 1790000000, 1789990000, NULL);
        INSERT INTO sessions VALUES ('s2', 's1', 'task', 2, 9000, 100, 0, 1790000050, 1790000010, NULL);
        INSERT INTO sessions VALUES ('s3', NULL, 'summarized', 9, 0, 300, 0, 1790000100, 1789000000, 'm9');
        INSERT INTO messages VALUES ('m1', 's1', 'assistant', '[]', 'claude-sonnet-4', 1789990100, 1789990100, NULL, 'anthropic');
        INSERT INTO messages VALUES ('m2', 's1', 'assistant', '[]', 'claude-sonnet-4-5', 1789999000, 1789999000, NULL, 'anthropic');
        INSERT INTO messages VALUES ('m3', 's1', 'user', '[]', 'other', 1789999999, 1789999999, NULL, NULL);
        """)
        return url
    }

    private func calls(_ url: URL) -> [CallRow] {
        CrushReader().read(file: url, context: LineContext(sourceFile: url.path, fallbackSessionId: "crush"))
            .compactMap { if case .call(let c) = $0 { return c.call } else { return nil } }
    }

    func testLatestReadingPerSession() throws {
        let workspace = try TempWorkspace()
        let rows = calls(try makeDatabase(in: workspace))
        XCTAssertEqual(rows.count, 3)

        let s1 = try XCTUnwrap(rows.first { $0.dedupeKey == "crush:s1" })
        XCTAssertEqual(s1.contextTokens, 42000)
        XCTAssertEqual(s1.input, 42000)          // no split on disk
        XCTAssertEqual(s1.cacheRead, 0)
        XCTAssertEqual(s1.cacheWrite, 0)
        XCTAssertEqual(s1.output, 800)
        XCTAssertEqual(s1.model, "claude-sonnet-4-5")   // newest assistant message
        XCTAssertEqual(s1.windowLimit, 200_000)
        XCTAssertEqual(s1.project, "proj")
        XCTAssertEqual(s1.ts, "2026-09-21T14:13:20.000Z")

        let s2 = try XCTUnwrap(rows.first { $0.dedupeKey == "crush:s2" })
        XCTAssertEqual(s2.sessionId, "s1")
        XCTAssertEqual(s2.agentId, "s2")
        XCTAssertNil(s2.windowLimit)             // no model known

        // Reset to 0 by a summary: no reading, so no occupancy.
        let s3 = try XCTUnwrap(rows.first { $0.dedupeKey == "crush:s3" })
        XCTAssertEqual(s3.confidence, Confidence.unmeasured.rawValue)
        XCTAssertNil(s3.windowLimit)
    }

    func testUpdatedInPlaceOnReingest() throws {
        let workspace = try TempWorkspace()
        let url = try makeDatabase(in: workspace)
        try workspace.ingestor.ingestFile(at: url)
        try SQLiteDatabase(path: url.path).execute("UPDATE sessions SET prompt_tokens = 50000, updated_at = 1790000500 WHERE id = 's1';")
        try workspace.ingestor.ingestFile(at: url)
        XCTAssertEqual(try workspace.store.callCount(), 3)
        XCTAssertEqual(try workspace.store.calls(sessionId: "s1").first?.contextTokens, 50000)
    }

    func testForeignSchemaGivesNothing() throws {
        let workspace = try TempWorkspace()
        let url = workspace.root.appendingPathComponent("crush.db")
        try SQLiteDatabase(path: url.path).execute("CREATE TABLE sessions (id TEXT);")
        XCTAssertTrue(calls(url).isEmpty)
    }

    func testProjectsJsonDiscovery() throws {
        let workspace = try TempWorkspace()
        let global = workspace.root.appendingPathComponent("global", isDirectory: true)
        try FileManager.default.createDirectory(at: global, withIntermediateDirectories: true)
        try #"{"projects":[{"path":"/p/a","data_dir":"/p/a/.crush","last_accessed":"2026-01-01T00:00:00Z"},{"path":"/p/b"},7]}"#
            .write(to: global.appendingPathComponent("projects.json"), atomically: true, encoding: .utf8)
        let dirs = CrushPaths.dataDirectories(environment: ["CRUSH_GLOBAL_DATA": global.path]).map(\.path)
        XCTAssertEqual(dirs, ["/p/a/.crush", "/p/b/.crush"])
        try "not json".write(to: global.appendingPathComponent("projects.json"), atomically: true, encoding: .utf8)
        XCTAssertTrue(CrushPaths.dataDirectories(environment: ["CRUSH_GLOBAL_DATA": global.path]).isEmpty)
    }

    func testOwnsAndCapabilities() {
        XCTAssertEqual(Harness.owning("/p/a/.crush/crush.db")?.id, "crush")
        XCTAssertNil(Harness.owning("/p/a/.crush/crush.json"))
        XCTAssertNotEqual(Harness.owning("/p/a/.crush/notcrush.db")?.id, "crush")
        XCTAssertEqual(Harness.crush.capabilities.occupancy, .latestOnly)
        XCTAssertFalse(Harness.crush.capabilities.cacheSplit)
    }
}

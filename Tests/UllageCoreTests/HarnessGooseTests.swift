import Foundation
import XCTest
@testable import UllageCore

/// Goose's `sessions.db`, synthesized with the schema from
/// `crates/goose/src/session/session_manager.rs` (schema v16).
final class HarnessGooseTests: XCTestCase {
    private func makeDatabase(in workspace: TempWorkspace, ledger: Bool = true) throws -> URL {
        let dir = workspace.root.appendingPathComponent("goose/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("sessions.db")
        let db = try SQLiteDatabase(path: url.path)
        try db.execute("""
        CREATE TABLE sessions (id TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '', working_dir TEXT NOT NULL,
            created_at TIMESTAMP, updated_at TIMESTAMP, total_tokens INTEGER, input_tokens INTEGER, output_tokens INTEGER,
            cache_read_tokens INTEGER, cache_write_tokens INTEGER, model_config_json TEXT, parent_session_id TEXT);
        INSERT INTO sessions VALUES ('20261004_1', '', '/Users/me/Code/app', '2026-10-04 10:00:00', '2026-10-04 10:05:00',
            11000, 10000, 300, 8000, 1500, '{"model_name":"claude-sonnet-4-5","temperature":null}', NULL);
        INSERT INTO sessions VALUES ('20261004_2', '', '/Users/me/Code/app', '2026-10-04 10:01:00', '2026-10-04 10:02:00',
            600, 500, 100, 0, 0, NULL, '20261004_1');
        """)
        guard ledger else { return url }
        try db.execute("""
        CREATE TABLE usage_ledger (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, created_timestamp INTEGER NOT NULL,
            model TEXT, input_tokens INTEGER, output_tokens INTEGER, total_tokens INTEGER, cache_read_tokens INTEGER,
            cache_write_tokens INTEGER, cost REAL, cost_source TEXT, is_compaction INTEGER DEFAULT 0);
        INSERT INTO usage_ledger VALUES (1, '20261004_1', 1790000000, NULL, 99999, 999, 0, 0, 0, NULL, 'carried_forward', 0);
        INSERT INTO usage_ledger VALUES (2, '20261004_1', 1790000100, 'claude-sonnet-4-5', 10000, 300, 10300, 8000, 1500, 0.01, 'estimated', 0);
        INSERT INTO usage_ledger VALUES (3, '20261004_2', 1790000150, 'mystery-model', 500, 100, 600, NULL, NULL, NULL, NULL, 0);
        INSERT INTO usage_ledger VALUES (4, '20261004_1', 1790000200, 'claude-sonnet-4-5', 12000, 200, 12200, 0, 0, NULL, NULL, 1);
        INSERT INTO usage_ledger VALUES (5, '20261004_1', 1790000300, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 0);
        """)
        return url
    }

    private func read(_ url: URL) -> [ParsedLine] {
        GooseReader().read(file: url, context: LineContext(sourceFile: url.path, fallbackSessionId: "x"))
    }

    func testLedgerSplitsWholePromptIntoFourCounters() throws {
        let workspace = try TempWorkspace()
        let lines = read(try makeDatabase(in: workspace))
        let calls = lines.compactMap { if case .call(let c) = $0 { return c.call } else { return nil } }
        XCTAssertEqual(calls.count, 2)   // carried_forward, compaction and the empty row are not calls

        let main = try XCTUnwrap(calls.first { $0.dedupeKey == "goose:20261004_1:2" })
        XCTAssertEqual(main.input, 500)          // 10000 - 8000 - 1500
        XCTAssertEqual(main.cacheRead, 8000)
        XCTAssertEqual(main.cacheWrite, 1500)
        XCTAssertEqual(main.output, 300)
        XCTAssertEqual(main.contextTokens, 10000)
        XCTAssertEqual(main.windowLimit, 200_000)
        XCTAssertEqual(main.vendor, "goose")
        XCTAssertEqual(main.project, "app")
        XCTAssertNil(main.agentId)
        XCTAssertEqual(main.ts, "2026-09-21T14:15:00.000Z")
        XCTAssertEqual(main.confidence, Confidence.exact.rawValue)

        // A child session is its own stream under the parent (rule 1), and
        // an unknown model gets no window rather than a guessed one (rule 3).
        let child = try XCTUnwrap(calls.first { $0.dedupeKey == "goose:20261004_2:3" })
        XCTAssertEqual(child.sessionId, "20261004_1")
        XCTAssertEqual(child.agentId, "20261004_2")
        XCTAssertNil(child.windowLimit)

        let events = lines.compactMap { if case .event(let e) = $0 { return e } else { return nil } }
        XCTAssertEqual(events.map(\.kind), [EventKind.compaction.rawValue])
    }

    func testOldDatabaseWithoutLedgerIsLatestOnly() throws {
        let workspace = try TempWorkspace()
        let calls = read(try makeDatabase(in: workspace, ledger: false))
            .compactMap { if case .call(let c) = $0 { return c.call } else { return nil } }
        let main = try XCTUnwrap(calls.first { $0.dedupeKey == "goose:20261004_1" })
        XCTAssertEqual(main.contextTokens, 10000)
        XCTAssertEqual(main.input, 500)
        XCTAssertEqual(main.model, "claude-sonnet-4-5")   // from model_config_json
        XCTAssertEqual(main.ts, "2026-10-04T10:05:00.000Z")
    }

    func testMissingOrForeignDatabaseGivesNothing() throws {
        let workspace = try TempWorkspace()
        XCTAssertTrue(read(workspace.root.appendingPathComponent("nope.db")).isEmpty)
        let other = workspace.root.appendingPathComponent("other.db")
        try SQLiteDatabase(path: other.path).execute("CREATE TABLE t (x INTEGER);")
        XCTAssertTrue(read(other).isEmpty)
    }

    func testReingestIsIdempotent() throws {
        let workspace = try TempWorkspace()
        let url = try makeDatabase(in: workspace)
        try workspace.ingestor.ingestFile(at: url)
        XCTAssertEqual(try workspace.store.callCount(), 2)
        try SQLiteDatabase(path: url.path).execute(
            "INSERT INTO usage_ledger VALUES (6, '20261004_1', 1790000400, 'claude-sonnet-4-5', 13000, 50, 13050, 12000, 0, NULL, NULL, 0);"
        )
        try workspace.ingestor.ingestFile(at: url)
        XCTAssertEqual(try workspace.store.callCount(), 3)
    }

    func testOwnsOnlyGooseDatabase() {
        XCTAssertEqual(Harness.owning("/Users/me/.local/share/goose/sessions/sessions.db")?.id, "goose")
        XCTAssertEqual(Harness.owning("/Users/me/.local/share/goose/sessions/sessions.db-wal")?.id, "goose")
        XCTAssertNotEqual(Harness.owning("/Users/me/other/sessions/sessions.db")?.id, "goose")
        XCTAssertEqual(Harness.owning("/Users/me/.local/share/goose/sessions/20250101.jsonl")?.id, "claude-code")
        XCTAssertEqual(
            GoosePaths.sessionsDirectory(environment: ["GOOSE_PATH_ROOT": "/tmp/g"]).path, "/tmp/g/data/sessions"
        )
        XCTAssertTrue(Harness.goose.capabilities.hasGauge)
    }
}

import Foundation
import XCTest
@testable import UllageCore

/// Zed's `threads.db`, synthesized with the schema from
/// `crates/agent/src/db.rs` (and the columns seen on a real Mac).
final class HarnessZedTests: XCTestCase {
    private func makeDatabase(in workspace: TempWorkspace) throws -> URL {
        let dir = workspace.root.appendingPathComponent("Zed/threads", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("threads.db")
        let db = try SQLiteDatabase(path: url.path)
        try db.execute("""
        CREATE TABLE threads (id TEXT PRIMARY KEY, summary TEXT NOT NULL, updated_at TEXT NOT NULL, data_type TEXT NOT NULL,
            data BLOB NOT NULL, parent_id TEXT, folder_paths TEXT, folder_paths_order TEXT, created_at TEXT);
        INSERT INTO threads VALUES ('t-zstd', 'title', '2026-10-04T12:00:00.123456789+00:00', 'zstd', X'28B52FFD00', NULL,
            '/Users/me/Code/app\n/Users/me/Code/lib', '0,1', NULL);
        INSERT INTO threads VALUES ('t-sub', 'sub', '2026-10-04T12:01:00+00:00', 'zstd', X'28B52FFD00', 't-zstd', NULL, NULL, NULL);
        INSERT INTO threads VALUES ('t-bad', 'bad', '2026-10-04T12:02:00+00:00', 'json', '{not json', NULL, NULL, NULL, NULL);
        """)
        let thread: [String: Any] = [
            "title": "t", "version": "0.3.0", "updated_at": "2026-10-04T13:00:00Z",
            "model": ["provider": "anthropic", "model": "claude-sonnet-4-5"],
            "messages": [
                ["User": ["id": "u1", "content": []]],
                ["Agent": ["content": []]],
                "Resume",
                ["User": ["id": "u2", "content": []]],
                ["User": ["id": "u3", "content": []]],
            ],
            "request_token_usage": [
                "u1": ["input_tokens": 12, "output_tokens": 400, "cache_creation_input_tokens": 9000, "cache_read_input_tokens": 0],
                "u2": ["input_tokens": 3, "output_tokens": 250, "cache_creation_input_tokens": 600, "cache_read_input_tokens": 9000],
                // Zed's synthesized overflow entry: not a measurement.
                "u3": ["input_tokens": 200_000],
            ],
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: thread), as: UTF8.self)
        try db.run(
            "INSERT INTO threads VALUES ('t-json', 't', '2026-10-04T13:00:00+00:00', 'json', ?1, NULL, '/Users/me/Code/app', '0', NULL);",
            [.text(json)]
        )
        return url
    }

    private func calls(_ url: URL) -> [CallRow] {
        ZedReader().read(file: url, context: LineContext(sourceFile: url.path, fallbackSessionId: "threads"))
            .compactMap { if case .call(let c) = $0 { return c.call } else { return nil } }
    }

    func testCompressedThreadsAreActivityOnly() throws {
        let workspace = try TempWorkspace()
        let rows = calls(try makeDatabase(in: workspace))
        let zstd = try XCTUnwrap(rows.first { $0.dedupeKey == "zed:t-zstd" })
        XCTAssertEqual(zstd.confidence, Confidence.unmeasured.rawValue)
        XCTAssertNil(zstd.windowLimit)
        XCTAssertNil(zstd.occupancy)
        XCTAssertEqual(zstd.contextTokens, 0)
        XCTAssertEqual(zstd.cwd, "/Users/me/Code/app")
        XCTAssertEqual(zstd.ts, "2026-10-04T12:00:00.123Z")

        let sub = try XCTUnwrap(rows.first { $0.dedupeKey == "zed:t-sub" })
        XCTAssertEqual(sub.sessionId, "t-zstd")
        XCTAssertEqual(sub.agentId, "t-sub")

        // Malformed JSON is not a crash; the thread is still activity.
        XCTAssertEqual(rows.first { $0.dedupeKey == "zed:t-bad" }?.confidence, Confidence.unmeasured.rawValue)
    }

    func testPlainJSONThreadIsReadPerRequest() throws {
        let workspace = try TempWorkspace()
        let rows = calls(try makeDatabase(in: workspace)).filter { $0.dedupeKey.hasPrefix("zed:t-json:") }
        XCTAssertEqual(rows.map(\.dedupeKey), ["zed:t-json:u1", "zed:t-json:u2"])   // u3 is synthesized
        let second = rows[1]
        XCTAssertEqual(second.input, 3)
        XCTAssertEqual(second.cacheRead, 9000)
        XCTAssertEqual(second.cacheWrite, 600)
        XCTAssertEqual(second.output, 250)
        XCTAssertEqual(second.contextTokens, 9603)
        XCTAssertEqual(second.model, "claude-sonnet-4-5")
        XCTAssertEqual(second.windowLimit, 200_000)
        XCTAssertEqual(second.confidence, Confidence.exact.rawValue)
    }

    func testReingestIsIdempotent() throws {
        let workspace = try TempWorkspace()
        let url = try makeDatabase(in: workspace)
        try workspace.ingestor.ingestFile(at: url)
        let first = try workspace.store.callCount()
        try SQLiteDatabase(path: url.path).execute("UPDATE threads SET updated_at = '2026-10-05T00:00:00+00:00' WHERE id = 't-zstd';")
        try workspace.ingestor.ingestFile(at: url)
        XCTAssertEqual(try workspace.store.callCount(), first)
    }

    func testOwnsAndCapabilities() {
        XCTAssertEqual(Harness.owning("/Users/me/Library/Application Support/Zed/threads/threads.db")?.id, "zed")
        XCTAssertEqual(Harness.owning("/home/me/.local/share/zed/threads/threads.db-wal")?.id, "zed")
        XCTAssertNotEqual(Harness.owning("/Users/me/other/threads/threads.db")?.id, "zed")
        XCTAssertFalse(Harness.zed.capabilities.hasGauge)
    }
}

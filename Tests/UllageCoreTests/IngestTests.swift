import Foundation
import XCTest
@testable import UllageCore

/// End-to-end through the database: the tests plan §11 asks for.
final class IngestTests: XCTestCase {
    func testFixtureParsesToExpectedRowsAndSums() throws {
        let workspace = try TempWorkspace()
        let url = try workspace.copyFixture("basic-session.jsonl")
        let stats = try workspace.ingestor.ingestFile(at: url)

        XCTAssertEqual(stats.callsUpserted, 5)       // four turns, one replayed message id
        XCTAssertEqual(stats.toolCallsUpserted, 3)
        XCTAssertEqual(stats.toolResultsMatched, 2)
        XCTAssertEqual(stats.toolResultsOrphaned, 0)
        XCTAssertEqual(stats.eventsInserted, 2)      // summary + compaction
        XCTAssertEqual(stats.malformedLines, 0)
        XCTAssertEqual(stats.partialTailBytes, 0)

        XCTAssertEqual(try workspace.store.callCount(), 4)
        XCTAssertEqual(try workspace.store.toolCallCount(), 3)

        let totals = try XCTUnwrap(try workspace.store.sessionTotals().first)
        XCTAssertEqual(totals.sessionId, "sess-abc123")
        XCTAssertEqual(totals.project, "proj")
        XCTAssertEqual(totals.calls, 4)
        XCTAssertEqual(totals.input, 5 + 8 + 3 + 10)
        XCTAssertEqual(totals.cacheWrite, 1_200 + 500 + 100 + 15_000)
        XCTAssertEqual(totals.cacheRead, 20_000 + 21_205 + 21_713 + 0)
        // Trap 2: the replayed message id carries the larger output count.
        XCTAssertEqual(totals.output, 100 + 250 + 90 + 60)
        XCTAssertEqual(totals.lastContextTokens, 15_010)
        XCTAssertEqual(totals.compactions, 1)
        XCTAssertEqual(totals.windowLimit, 200_000)
    }

    func testTurnIndexAndContextDelta() throws {
        let workspace = try TempWorkspace()
        try workspace.ingestor.ingestFile(at: try workspace.copyFixture("basic-session.jsonl"))

        let calls = try workspace.store.calls(sessionId: "sess-abc123")
        XCTAssertEqual(calls.map(\.dedupeKey), ["msg_001", "msg_002", "msg_003", "msg_004"])
        XCTAssertEqual(calls.map(\.turnIndex), [0, 1, 2, 3])
        XCTAssertEqual(calls.map(\.contextTokens), [21_205, 21_713, 21_816, 15_010])
        XCTAssertNil(calls[0].contextDelta)                  // first turn of the session
        XCTAssertEqual(calls[1].contextDelta, 508)
        XCTAssertEqual(calls[2].contextDelta, 103)
        XCTAssertNil(calls[3].contextDelta)                  // first turn after compaction
    }

    func testOccupancyIsLastTurnOverWindowLimit() throws {
        let workspace = try TempWorkspace()
        try workspace.ingestor.ingestFile(at: try workspace.copyFixture("basic-session.jsonl"))
        let latest = try XCTUnwrap(try workspace.store.latestCall())
        XCTAssertEqual(latest.dedupeKey, "msg_004")
        XCTAssertEqual(latest.contextTokens, 15_010)
        XCTAssertEqual(try XCTUnwrap(latest.occupancy), 15_010.0 / 200_000.0, accuracy: 0.0001)
    }

    /// The single most important test in the suite.
    func testIngestingTheSameFileTwiceChangesNothing() throws {
        let workspace = try TempWorkspace()
        let url = try workspace.copyFixture("basic-session.jsonl")
        try workspace.ingestor.ingestFile(at: url)

        let callsAfterFirst = try workspace.store.calls(sessionId: "sess-abc123")
        let toolsAfterFirst = try workspace.store.toolCalls(sessionId: "sess-abc123")
        let eventsAfterFirst = try workspace.store.eventCount()

        // Same process (cursor is at EOF) and a fresh one (cursor cleared).
        try workspace.ingestor.ingestFile(at: url)
        try workspace.store.database.run("DELETE FROM file_cursor;")
        let secondIngestor = Ingestor(store: workspace.store)
        try secondIngestor.ingestFile(at: url)

        XCTAssertEqual(try workspace.store.calls(sessionId: "sess-abc123"), callsAfterFirst)
        XCTAssertEqual(try workspace.store.toolCalls(sessionId: "sess-abc123"), toolsAfterFirst)
        XCTAssertEqual(try workspace.store.eventCount(), eventsAfterFirst)
    }

    func testToolResultJoinAcrossLinesAndMissingResults() throws {
        let workspace = try TempWorkspace()
        try workspace.ingestor.ingestFile(at: try workspace.copyFixture("basic-session.jsonl"))
        let tools = try workspace.store.toolCalls(sessionId: "sess-abc123")

        let read = try XCTUnwrap(tools.first { $0.id == "toolu_read1" })
        XCTAssertEqual(read.resultTokens, 10)
        XCTAssertEqual(read.isError, false)
        XCTAssertEqual(read.target, "/Users/dev/proj/main.swift")

        let mcp = try XCTUnwrap(tools.first { $0.id == "toolu_mcp1" })
        XCTAssertEqual(mcp.kind, "mcp")
        XCTAssertEqual(mcp.mcpServer, "github")
        XCTAssertEqual(mcp.resultTokens, 4)

        // The Task result never arrived: the row still exists, with a null result.
        let task = try XCTUnwrap(tools.first { $0.id == "toolu_task1" })
        XCTAssertNil(task.resultTokens)
        XCTAssertNil(task.isError)
    }

    /// A result whose invocation is not in the database (ingestion started
    /// mid-file) is counted and dropped, never blocked on.
    func testOrphanToolResultDoesNotStallIngestion() throws {
        let workspace = try TempWorkspace()
        let stats = try workspace.ingestor.ingestFile(at: try workspace.copyFixture("orphan-tool-result.jsonl"))
        XCTAssertEqual(stats.toolResultsOrphaned, 1)
        XCTAssertEqual(stats.toolResultsMatched, 0)
        XCTAssertEqual(stats.callsUpserted, 1)
        let tools = try workspace.store.toolCalls(sessionId: "sess-abc123")
        XCTAssertEqual(tools.map(\.name), ["Bash"])
        XCTAssertEqual(tools[0].target, "swift build")
    }

    /// A result that arrives in a *later* ingest run still finds its invocation,
    /// because the join is a write-back by primary key rather than in-memory state.
    func testToolResultArrivingInALaterRunStillJoins() throws {
        let workspace = try TempWorkspace()
        let lines = try Fixtures.lines("basic-session.jsonl")
        let name = "split.jsonl"
        try workspace.write(name, lines: Array(lines.prefix(3)))    // through the tool_use
        try workspace.ingestor.ingestFile(at: workspace.root.appendingPathComponent(name))
        XCTAssertNil(try workspace.store.toolCalls(sessionId: "sess-abc123").first?.resultTokens)

        try workspace.append(name, text: lines[3] + "\n")           // the tool_result
        let stats = try workspace.ingestor.ingestFile(at: workspace.root.appendingPathComponent(name))
        XCTAssertEqual(stats.toolResultsMatched, 1)
        XCTAssertEqual(try workspace.store.toolCalls(sessionId: "sess-abc123").first?.resultTokens, 10)
    }

    func testUnknownTypesAndMalformedLinesDoNotStopIngestion() throws {
        let workspace = try TempWorkspace()
        var warnings: [String] = []
        workspace.ingestor.onWarning = { warnings.append($0) }
        let stats = try workspace.ingestor.ingestFile(at: try workspace.copyFixture("unknown-types.jsonl"))

        XCTAssertEqual(stats.malformedLines, 1)
        XCTAssertEqual(stats.callsUpserted, 2)       // both assistant lines after the bad one
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(try workspace.store.callCount(), 2)
    }

    // MARK: - Cursor behaviour

    func testPartialTrailingLineIsNotIngestedUntilComplete() throws {
        let workspace = try TempWorkspace()
        let lines = try Fixtures.lines("basic-session.jsonl")
        let name = "partial.jsonl"
        let complete = Array(lines.prefix(3))
        let truncated = String(lines[3].prefix(lines[3].count / 2))

        // Three complete lines, then half of the fourth with no newline.
        try workspace.write(name, lines: complete)
        try workspace.append(name, text: truncated)
        let url = workspace.root.appendingPathComponent(name)

        let first = try workspace.ingestor.ingestFile(at: url)
        XCTAssertEqual(first.callsUpserted, 1)
        XCTAssertEqual(first.toolResultsMatched, 0)
        XCTAssertEqual(first.malformedLines, 0)          // a partial tail is normal, not an error
        XCTAssertEqual(first.partialTailBytes, truncated.utf8.count)

        let cursor = try XCTUnwrap(try workspace.store.cursor(forPath: url.path))
        let completeBytes = complete.joined(separator: "\n").utf8.count + 1
        XCTAssertEqual(Int(cursor.byteOffset), completeBytes)

        // Claude Code finishes writing the line.
        try workspace.append(name, text: String(lines[3].dropFirst(truncated.count)) + "\n")
        let second = try workspace.ingestor.ingestFile(at: url)
        XCTAssertEqual(second.toolResultsMatched, 1)
        XCTAssertEqual(try workspace.store.toolCalls(sessionId: "sess-abc123").first?.resultTokens, 10)
    }

    func testAppendingProducesNewRowsWithoutRereadingTheFile() throws {
        let workspace = try TempWorkspace()
        let lines = try Fixtures.lines("basic-session.jsonl")
        let name = "tail.jsonl"
        try workspace.write(name, lines: Array(lines.prefix(4)))
        let url = workspace.root.appendingPathComponent(name)
        let first = try workspace.ingestor.ingestFile(at: url)
        XCTAssertEqual(first.callsUpserted, 1)

        try workspace.append(name, text: lines[5] + "\n")
        let second = try workspace.ingestor.ingestFile(at: url)
        XCTAssertEqual(second.linesParsed, 1)            // only the appended line was read
        XCTAssertEqual(second.callsUpserted, 1)
        XCTAssertEqual(second.restartedFromZero, 0)
        XCTAssertEqual(try workspace.store.callCount(), 2)
    }

    func testTruncationRereadsFromZeroRatherThanStalling() throws {
        let workspace = try TempWorkspace()
        let lines = try Fixtures.lines("basic-session.jsonl")
        let name = "rotated.jsonl"
        try workspace.write(name, lines: Array(lines.prefix(6)))
        let url = workspace.root.appendingPathComponent(name)
        try workspace.ingestor.ingestFile(at: url)
        XCTAssertEqual(try workspace.store.callCount(), 2)

        // The file is replaced by a shorter one: size drops below our offset.
        try workspace.write(name, lines: Array(lines.prefix(3)))
        let stats = try workspace.ingestor.ingestFile(at: url)
        XCTAssertEqual(stats.restartedFromZero, 1)
        XCTAssertEqual(stats.callsUpserted, 1)
        // Re-reading is safe because of the dedupe key: no duplicate rows.
        XCTAssertEqual(try workspace.store.callCount(), 2)
    }

    func testUnchangedFileIsNotRereadOnTheSecondPass() throws {
        let workspace = try TempWorkspace()
        let url = try workspace.copyFixture("basic-session.jsonl")
        try workspace.ingestor.ingestFile(at: url)
        let second = try workspace.ingestor.ingestFile(at: url)
        XCTAssertEqual(second.bytesRead, 0)
        XCTAssertEqual(second.linesParsed, 0)
    }

    func testDirectoryIngestWalksEveryTranscript() throws {
        let workspace = try TempWorkspace()
        let nested = workspace.root.appendingPathComponent("-Users-dev-proj", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for name in ["basic-session.jsonl", "orphan-tool-result.jsonl", "unknown-types.jsonl"] {
            try FileManager.default.copyItem(
                at: Fixtures.url(name),
                to: nested.appendingPathComponent(name)
            )
        }
        // A non-transcript file in the tree must be ignored.
        try "not a transcript".write(
            to: nested.appendingPathComponent("notes.md"),
            atomically: true,
            encoding: .utf8
        )

        let stats = try workspace.ingestor.ingestDirectory(at: workspace.root)
        XCTAssertEqual(stats.filesScanned, 3)
        XCTAssertEqual(try workspace.store.callCount(), 4 + 1 + 2)
    }

    func testSessionIDFallsBackToTheFilenameStem() throws {
        let workspace = try TempWorkspace()
        // A summary line has no sessionId; the filename stem is the session id.
        try workspace.write("11111111-2222-3333-4444-555555555555.jsonl", lines: [
            #"{"type":"summary","summary":"resumed","leafUuid":"uuid-leaf-9"}"#
        ])
        let url = workspace.root.appendingPathComponent("11111111-2222-3333-4444-555555555555.jsonl")
        let stats = try workspace.ingestor.ingestFile(at: url)
        XCTAssertEqual(stats.eventsInserted, 1)
        let sessions = try workspace.store.database.query("SELECT session_id FROM event;") { $0.text(0) }
        XCTAssertEqual(sessions, ["11111111-2222-3333-4444-555555555555"])
    }

    func testSanitizedProjectDirectoryNaming() {
        XCTAssertEqual(ClaudePaths.sanitize(cwd: "/Users/dev/my.proj"), "-Users-dev-my-proj")
        let long = "/Users/dev/" + String(repeating: "a", count: 300)
        let sanitized = ClaudePaths.sanitize(cwd: long)
        XCTAssertTrue(sanitized.count > 200)
        XCTAssertTrue(sanitized.hasPrefix("-Users-dev-"))
        XCTAssertEqual(sanitized, ClaudePaths.sanitize(cwd: long))
    }

    func testConfigDirectoryHonoursTheEnvironmentOverride() {
        let overridden = ClaudePaths.projectsDirectories(environment: ["CLAUDE_CONFIG_DIR": "/tmp/cfg"])
        XCTAssertEqual(overridden.map(\.path), ["/tmp/cfg/projects"])
        let defaulted = ClaudePaths.projectsDirectories(environment: [:])
        XCTAssertEqual(defaulted.count, 1)
        XCTAssertTrue(defaulted[0].path.hasSuffix("/.claude/projects"))
    }
}

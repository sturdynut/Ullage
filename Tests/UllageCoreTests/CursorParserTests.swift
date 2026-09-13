import Foundation
import XCTest
@testable import UllageCore

/// Cursor is activity-only: content transcripts with no tokens, model, window,
/// or timestamps. Rows carry turns and tools, timed by the file, and must never
/// drive the menu bar gauge.
final class CursorParserTests: XCTestCase {
    private let context = LineContext(
        sourceFile: "/Users/dev/.cursor/projects/my-repo/agent-transcripts/abc/abc.jsonl",
        fallbackSessionId: "abc",
        fileModified: "2026-09-12T10:00:00.000Z"
    )

    private func line(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    func testAssistantTurnBecomesAnUnmeasuredCallWithTools() {
        let parser = CursorParser()
        _ = parser.parse(line: line(["role": "user", "message": ["content": [["type": "text", "text": "hi"]]]]), context: context)
        let out = parser.parse(line: line([
            "role": "assistant",
            "message": ["content": [
                ["type": "text", "text": "on it"],
                ["type": "tool_use", "id": "t1", "name": "Shell", "input": ["command": "ls"]],
                ["type": "tool_use", "id": "t2", "name": "Write", "input": ["path": "x"]],
            ]],
        ]), context: context)

        guard case .call(let parsed)? = out else { return XCTFail("expected a call") }
        let call = parsed.call
        XCTAssertEqual(call.vendor, Vendor.cursor)
        XCTAssertEqual(call.confidence, Confidence.unmeasured.rawValue)
        XCTAssertNil(call.windowLimit, "no window means no occupancy and no gauge")
        XCTAssertNil(call.occupancy)
        XCTAssertEqual(call.contextTokens, 0)
        XCTAssertNil(call.model)
        XCTAssertEqual(call.ts, "2026-09-12T10:00:00.000Z", "timed by the file, not the line")
        XCTAssertEqual(call.project, "repo", "trailing token of the slug my-repo")
        XCTAssertEqual(call.dedupeKey, "cursor:abc:0")
        XCTAssertEqual(parsed.toolCalls.map(\.name), ["Shell", "Write"])
        XCTAssertEqual(parsed.toolCalls[0].callId, "cursor:abc:0")
    }

    func testUserAndTurnEndedLinesProduceNothing() {
        let parser = CursorParser()
        XCTAssertNil(parser.parse(line: line(["role": "user", "message": ["content": []]]), context: context))
        XCTAssertNil(parser.parse(line: line(["type": "turn_ended", "status": "success"]), context: context))
    }

    func testTurnsAreNumberedInOrder() {
        let parser = CursorParser()
        let a = parser.parse(line: line(["role": "assistant", "message": ["content": []]]), context: context)
        let b = parser.parse(line: line(["role": "assistant", "message": ["content": []]]), context: context)
        if case .call(let first)? = a, case .call(let second)? = b {
            XCTAssertEqual(first.call.dedupeKey, "cursor:abc:0")
            XCTAssertEqual(second.call.dedupeKey, "cursor:abc:1")
        } else {
            XCTFail("expected two calls")
        }
    }

    func testFormatDetectionRoutesCursorPaths() {
        XCTAssertEqual(TranscriptFormat.detect(path: "/Users/x/.cursor/projects/p/agent-transcripts/i/i.jsonl"), .cursor)
        XCTAssertEqual(TranscriptFormat.detect(path: "/Users/x/.codex/sessions/2026/01/02/rollout-x.jsonl"), .codex)
        XCTAssertEqual(TranscriptFormat.detect(path: "/Users/x/.claude/projects/p/s.jsonl"), .claudeCode)
    }

    /// The gauge must skip window-less rows even when a Cursor row is newest.
    func testLatestCallSkipsWindowlessCursorRows() throws {
        let store = try Store.inMemory()
        try store.upsert(call: CallRow(
            dedupeKey: "claude-1", ts: "2026-09-12T09:00:00.000Z", sessionId: "c",
            model: "claude-opus-5", contextTokens: 100_000, windowLimit: 1_000_000, sourceFile: "f"))
        try store.upsert(call: CallRow(
            dedupeKey: "cursor:abc:0", ts: "2026-09-12T12:00:00.000Z", vendor: Vendor.cursor,
            sessionId: "abc", contextTokens: 0, windowLimit: nil,
            sourceFile: "g", confidence: Confidence.unmeasured.rawValue))
        // The Cursor row is newer, but the gauge takes the newest windowed row.
        XCTAssertEqual(try store.latestCall()?.dedupeKey, "claude-1")
        // Yet Cursor still shows up as a session.
        XCTAssertTrue(try store.recentSessions(limit: 10).contains { $0.sessionId == "abc" })
    }
}

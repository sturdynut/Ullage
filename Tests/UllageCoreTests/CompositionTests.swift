import Foundation
import XCTest
@testable import UllageCore

/// M7 — decomposing the window from turn-to-turn growth, and M6 — daily rollups.
final class CompositionTests: XCTestCase {
    private func call(_ turn: Int, at ts: String, context: Int, output: Int = 0, project: String = "proj") -> CallRow {
        CallRow(
            dedupeKey: "msg_\(turn)", ts: ts, sessionId: "s", project: project, model: "claude-opus-5",
            output: output, contextTokens: context, windowLimit: 1_000_000, turnIndex: turn, sourceFile: "s.jsonl"
        )
    }

    private func tool(_ id: String, call turn: Int, name: String, tokens: Int, kind: ToolKind = .builtin, server: String? = nil) -> ToolCallRow {
        ToolCallRow(
            id: id, callId: "msg_\(turn)", sessionId: "s", ts: "2026-09-12T10:0\(turn):30.000Z",
            name: name, kind: kind.rawValue, mcpServer: server, resultTokens: tokens, parserVersion: 2
        )
    }

    func testWindowDecomposesIntoBaselineToolsOutputAndOther() {
        let calls = [
            call(0, at: "2026-09-12T10:00:00.000Z", context: 40_000, output: 500),
            call(1, at: "2026-09-12T10:01:00.000Z", context: 52_000, output: 1_000),
            call(2, at: "2026-09-12T10:02:00.000Z", context: 70_000, output: 2_000),
        ]
        let tools = [
            tool("t1", call: 0, name: "Bash", tokens: 8_000),
            tool("t2", call: 1, name: "Read", tokens: 12_000),
            tool("t3", call: 1, name: "Bash", tokens: 3_000),
            tool("t4", call: 2, name: "Bash", tokens: 99_999),   // last turn's results are not in its own prompt
        ]
        let c = ContextComposition.build(sessionId: "s", calls: calls, toolCalls: tools, events: [])!
        XCTAssertEqual(c.contextTokens, 70_000)
        XCTAssertEqual(c.windowStartTurn, 0)
        XCTAssertEqual(c.baseline, 40_000)
        XCTAssertEqual(c.toolResults, 23_000)
        XCTAssertEqual(c.assistantOutput, 1_500)          // turns 0 and 1, not 2
        XCTAssertEqual(c.other, 70_000 - 40_000 - 23_000 - 1_500)
        XCTAssertFalse(c.estimatesOvershoot)
        XCTAssertEqual(c.tools.map(\.name), ["Read", "Bash"])
        XCTAssertEqual(c.tools[1].calls, 2)
        XCTAssertEqual(c.segments.map(\.name), ["Baseline", "Tool results", "Assistant output", "Other"])
        XCTAssertEqual(c.segments.map(\.tokens).reduce(0, +), 70_000)
    }

    func testCompactionRestartsTheWindowAtTheSummary() {
        let calls = [
            call(0, at: "2026-09-12T10:00:00.000Z", context: 40_000, output: 100),
            call(1, at: "2026-09-12T10:01:00.000Z", context: 900_000, output: 100),
            call(2, at: "2026-09-12T10:02:00.000Z", context: 120_000, output: 300),   // first prompt after compaction
            call(3, at: "2026-09-12T10:03:00.000Z", context: 130_000, output: 400),
        ]
        let tools = [tool("a", call: 1, name: "Bash", tokens: 500_000), tool("b", call: 2, name: "Read", tokens: 4_000)]
        let events = [EventRow(id: "e", sessionId: "s", ts: "2026-09-12T10:01:30.000Z", kind: "compaction")]
        let c = ContextComposition.build(sessionId: "s", calls: calls, toolCalls: tools, events: events)!
        XCTAssertEqual(c.windowStartTurn, 2)
        XCTAssertEqual(c.compactions, 1)
        XCTAssertEqual(c.baseline, 120_000)
        XCTAssertEqual(c.toolResults, 4_000, "pre-compaction results are gone from the window")
        XCTAssertEqual(c.assistantOutput, 300)
        XCTAssertEqual(c.other, 130_000 - 120_000 - 4_000 - 300)
    }

    /// One boundary is written as two lines a fraction of a second apart, so
    /// counting events reports twice as many compactions as happened — and
    /// disagrees with the chart, which marks the turn the window restarted at.
    func testPairedBoundaryLinesAreOneCompaction() {
        let calls = [
            call(0, at: "2026-09-12T10:00:00.000Z", context: 40_000, output: 100),
            call(1, at: "2026-09-12T10:01:00.000Z", context: 900_000, output: 100),
            call(2, at: "2026-09-12T10:02:00.000Z", context: 120_000, output: 300),
        ]
        let events = [
            EventRow(id: "boundary", sessionId: "s", ts: "2026-09-12T10:01:30.000Z", kind: "compaction"),
            EventRow(id: "summary", sessionId: "s", ts: "2026-09-12T10:01:30.339Z", kind: "compaction"),
        ]
        let c = ContextComposition.build(sessionId: "s", calls: calls, toolCalls: [], events: events)!
        XCTAssertEqual(c.compactions, 1)
        XCTAssertEqual(c.windowStartTurn, 2)
        // The chart counts the same way, and the popover shows both numbers.
        let history = ContextHistory.build(sessionId: "s", calls: calls, events: events)
        XCTAssertEqual(history.compactionTurns.count, c.compactions)
    }

    func testOvershootClampsOtherAndSaysSo() {
        let calls = [
            call(0, at: "2026-09-12T10:00:00.000Z", context: 40_000),
            call(1, at: "2026-09-12T10:01:00.000Z", context: 41_000),
        ]
        let tools = [tool("a", call: 0, name: "Read", tokens: 5_000)]   // over-estimated
        let c = ContextComposition.build(sessionId: "s", calls: calls, toolCalls: tools, events: [])!
        XCTAssertEqual(c.other, 0)
        XCTAssertTrue(c.estimatesOvershoot)
    }

    func testSingleTurnIsAllBaselineAndNoTurnsIsNil() {
        let c = ContextComposition.build(sessionId: "s", calls: [call(0, at: "2026-09-12T10:00:00.000Z", context: 33_000)], toolCalls: [], events: [])!
        XCTAssertEqual(c.baseline, 33_000)
        XCTAssertEqual(c.toolResults + c.assistantOutput + c.other, 0)
        XCTAssertNil(ContextComposition.build(sessionId: "s", calls: [], toolCalls: [], events: []))
    }

    func testEnvironmentHintsComeFromTheSnapshot() {
        let env = SessionEnvRow(sessionId: "s", capturedAt: "now", mcpServers: "[\"Neon\",\"Slack\"]", skills: "[\"design\"]", claudeMdBytes: 8_000)
        let c = ContextComposition.build(sessionId: "s", calls: [call(0, at: "2026-09-12T10:00:00.000Z", context: 1)], toolCalls: [], events: [], environment: env)!
        XCTAssertEqual(c.mcpServers, ["Neon", "Slack"])
        XCTAssertEqual(c.skills, ["design"])
        XCTAssertEqual(c.claudeMdTokensEstimate, 2_000)
    }

    func testDailyActivityGroupsByLocalDayAndProjectWithCountersApart() throws {
        let store = try Store.inMemory()
        // Midday UTC keeps the local date stable for any test-runner time zone.
        try store.upsert(call: CallRow(dedupeKey: "a", ts: "2026-09-10T12:00:00.000Z", sessionId: "s1", project: "alpha", input: 10, output: 20, cacheRead: 3_000, cacheWrite: 400, contextTokens: 50_000, sourceFile: "f"))
        try store.upsert(call: CallRow(dedupeKey: "b", ts: "2026-09-10T12:05:00.000Z", sessionId: "s2", project: "alpha", input: 1, output: 2, cacheRead: 5_000, cacheWrite: 600, contextTokens: 80_000, sourceFile: "f"))
        try store.upsert(call: CallRow(dedupeKey: "c", ts: "2026-09-11T12:00:00.000Z", sessionId: "s3", project: "beta", input: 7, output: 8, cacheRead: 9, cacheWrite: 10, contextTokens: 11, sourceFile: "f"))
        try store.upsert(call: CallRow(dedupeKey: "old", ts: "2026-08-01T12:00:00.000Z", sessionId: "s0", project: "alpha", contextTokens: 1, sourceFile: "f"))

        let rows = try store.dailyActivity(since: "2026-09-01T00:00:00.000Z")
        XCTAssertEqual(rows.map(\.id), ["2026-09-10|alpha", "2026-09-11|beta"])
        let alpha = rows[0]
        XCTAssertEqual(alpha.sessions, 2)
        XCTAssertEqual(alpha.calls, 2)
        XCTAssertEqual([alpha.input, alpha.output, alpha.cacheRead, alpha.cacheWrite], [11, 22, 8_000, 1_000])
        XCTAssertEqual(alpha.peakContextTokens, 80_000)

        let recent = try store.dailyActivity(days: 30, now: Timestamps.date(from: "2026-09-12T00:00:00.000Z")!)
        XCTAssertEqual(recent.count, 2)
    }
}

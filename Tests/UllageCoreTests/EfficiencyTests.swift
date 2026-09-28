import Foundation
import XCTest
@testable import UllageCore

/// Session efficiency: effort per turn, cache rebuilds and their causes, what
/// each turn re-sends, and tool results that are only along for the ride.
final class EfficiencyTests: XCTestCase {
    private func claude(_ extra: String) -> CallRow? {
        let line = #"{"type":"assistant","uuid":"u1","timestamp":"2026-09-01T10:00:00.000Z","sessionId":"s1","cwd":"/r",\#(extra)"message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":10,"cache_read_input_tokens":100,"cache_creation_input_tokens":5,"output_tokens":7}}}"#
        guard case .call(let parsed)? = ClaudeCodeParser.parse(line: Data(line.utf8),
                                                                 context: LineContext(sourceFile: "t.jsonl", fallbackSessionId: "s1")) else { return nil }
        return parsed.call
    }

    // MARK: - Effort

    func testClaudeEffortPrefersThePerTurnOverride() {
        XCTAssertEqual(claude(#""effort":"high","perTurnEffort":null,"#)?.effort, "high")
        XCTAssertEqual(claude(#""effort":"high","perTurnEffort":"medium","#)?.effort, "medium")
        XCTAssertNil(claude("")?.effort, "a line from before the field is unknown, not a default")
    }

    func testCodexEffortComesFromTurnContext() {
        let parser = CodexParser()
        let context = LineContext(sourceFile: "/x/rollout-abc.jsonl", fallbackSessionId: "file-stem")
        let lines: [[String: Any]] = [
            ["type": "session_meta", "ordinal": 0, "timestamp": "2026-09-12T10:00:00.000Z",
             "payload": ["session_id": "sess-1", "cwd": "/p"]],
            ["type": "turn_context", "ordinal": 1, "payload": ["model": "gpt-5.5", "effort": "high"]],
            ["type": "event_msg", "ordinal": 2, "timestamp": "2026-09-12T10:01:00.000Z",
             "payload": ["type": "token_count", "info": ["model_context_window": 258_400,
                "last_token_usage": ["input_tokens": 100, "cached_input_tokens": 0, "output_tokens": 5]]]],
        ]
        let calls = lines.compactMap { parser.parse(line: try! JSONSerialization.data(withJSONObject: $0), context: context) }
            .compactMap { line -> CallRow? in if case .call(let c) = line { return c.call } else { return nil } }
        XCTAssertEqual(calls.first?.effort, "high")
    }

    func testEffortSurvivesAReplayWithoutIt() throws {
        let store = try Store.inMemory()
        var call = CallRow(dedupeKey: "m", ts: "2026-09-01T10:00:00.000Z", sessionId: "s", contextTokens: 1, sourceFile: "t")
        call.effort = "max"
        try store.upsert(call: call)
        call.effort = nil
        try store.upsert(call: call)
        XCTAssertEqual(try store.call(dedupeKey: "m")?.effort, "max")
    }

    func testDailyActivityGroupsByEffort() throws {
        let store = try Store.inMemory()
        for (key, effort) in [("a", "high"), ("b", "high"), ("c", nil as String?)] {
            var call = CallRow(dedupeKey: key, ts: Timestamps.now(), sessionId: "s", contextTokens: 1, sourceFile: "t")
            call.effort = effort
            try store.upsert(call: call)
        }
        let rows = try store.dailyActivity(days: 1, groupedBy: .effort)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: rows.map { ($0.project, $0.calls) }), ["high": 2, "unknown": 1])
    }

    func testModelLine() {
        var state = MenuBarFormatter.state(for: nil)
        state.model = "claude-opus-5-5"
        XCTAssertEqual(state.modelLine, "claude-opus-5-5")
        state.effort = "high"
        XCTAssertEqual(state.modelLine, "claude-opus-5-5 · high")
    }
}

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

    // MARK: - Cache rebuilds

    private func turn(_ i: Int, minute: Int, context: Int, write: Int, model: String = "opus", effort: String? = "high") -> CallRow {
        var call = CallRow(dedupeKey: "m\(i)", ts: String(format: "2026-09-01T%02d:%02d:00.000Z", 10 + minute / 60, minute % 60),
                           sessionId: "s", model: model, cacheRead: context - write, cacheWrite: write,
                           contextTokens: context, turnIndex: i, sourceFile: "t")
        call.effort = effort
        return call
    }

    func testRebuildCausesInOrder() {
        let calls = [
            turn(0, minute: 0, context: 60_000, write: 60_000),            // first turn: always writes, never a rebuild
            turn(1, minute: 1, context: 62_000, write: 2_000),             // ordinary
            turn(2, minute: 2, context: 64_000, write: 64_000, model: "fable"),
            turn(3, minute: 3, context: 66_000, write: 66_000, model: "fable", effort: "max"),
            turn(4, minute: 90, context: 68_000, write: 68_000, model: "opus", effort: "low"),  // expiry wins over changes
            turn(5, minute: 91, context: 70_000, write: 70_000, model: "opus", effort: "low"),
            turn(6, minute: 92, context: 30_000, write: 30_000, model: "opus", effort: "low"),  // compacted: not a rebuild
            turn(7, minute: 93, context: 40_000, write: 40_000, model: "opus", effort: "low"),  // under the minimum
        ]
        let commands = [EventRow(id: "c", sessionId: "s", ts: "2026-09-01T11:30:30.000Z", kind: EventKind.command.rawValue,
                                 detail: SlashCommand(name: "fast", args: nil).detailJSON)]
        let rebuilds = CacheRebuilds.detect(calls: calls, commands: commands)
        XCTAssertEqual(rebuilds.map(\.turnIndex), [2, 3, 4, 5])
        XCTAssertEqual(rebuilds.map(\.cause), [.modelChanged, .effortChanged, .expired, .command])
        XCTAssertEqual(rebuilds.map(\.detail), ["opus → fable", "high → max", "idle 1h 27m", "/fast"])
        XCTAssertEqual(rebuilds.first?.cacheWrite, 64_000, "the measured write, not an estimate")
        XCTAssertEqual(rebuilds.filter(\.cause.isAvoidable).count, 3)
        XCTAssertEqual(CacheRebuilds.causeSummary(rebuilds), "expired ×1, model changed ×1, effort changed ×1, command ×1")
    }

    func testUnknownEffortIsNotAChange() {
        let calls = [turn(0, minute: 0, context: 60_000, write: 1_000, effort: nil),
                     turn(1, minute: 1, context: 61_000, write: 61_000, effort: "high")]
        XCTAssertEqual(CacheRebuilds.detect(calls: calls).first?.cause, .unknown)
    }

    func testHistoryCarriesRebuilds() throws {
        let store = try Store.inMemory()
        for call in [turn(0, minute: 0, context: 60_000, write: 60_000), turn(1, minute: 1, context: 61_000, write: 61_000, model: "fable")] {
            try store.upsert(call: call)
        }
        XCTAssertEqual(try store.contextHistory(sessionId: "s").rebuilds.map(\.cause), [.modelChanged])
    }

    // MARK: - What each turn re-sends

    func testResendAgainstTheFirstTurn() {
        var calls = [turn(0, minute: 0, context: 10_000, write: 10_000), turn(1, minute: 1, context: 380_000, write: 5_000)]
        calls[1].cacheRead = 370_000
        let history = ContextHistory.build(sessionId: "s", calls: calls, events: [])
        XCTAssertEqual(history.resend?.lastTokens, 380_000)
        XCTAssertEqual(history.resend?.multiple ?? 0, 38, accuracy: 0.001)
        XCTAssertEqual(history.resend?.cachedShare ?? 0, 370_000.0 / 380_000.0, accuracy: 0.0001)
        XCTAssertEqual(ContextHistory.multiple(38), "38×")
        XCTAssertEqual(ContextHistory.multiple(1.42), "1.4×")
        XCTAssertNil(ContextHistory.build(sessionId: "s", calls: [calls[0]], events: []).resend, "one turn has nothing to compare")
    }

    // MARK: - Along for the ride

    func testStaleResultsAndRepeatedReads() throws {
        let calls = (0...60).map { i in
            CallRow(dedupeKey: "m\(i)", ts: String(format: "2026-09-01T10:%02d:00.000Z", i % 60) + "", sessionId: "s",
                    contextTokens: 10_000 + i * 100, turnIndex: i, sourceFile: "t")
        }.enumerated().map { index, call -> CallRow in
            var copy = call
            copy.ts = Timestamps.string(from: Date(timeIntervalSince1970: 1_788_000_000 + Double(index) * 60))
            return copy
        }
        func tool(_ id: String, turn: Int, name: String, target: String, tokens: Int) -> ToolCallRow {
            ToolCallRow(id: id, callId: "m\(turn)", sessionId: "s", ts: calls[turn].ts, name: name, kind: "builtin",
                        target: target, resultTokens: tokens)
        }
        let tools = [
            tool("a", turn: 2, name: "Bash", target: "git log", tokens: 3_000),        // 58 turns ago: stale
            tool("b", turn: 5, name: "Read", target: "/r/Store.swift", tokens: 800),   // stale, and an earlier copy
            tool("c", turn: 40, name: "Read", target: "/r/Store.swift", tokens: 900),  // earlier copy
            tool("d", turn: 55, name: "Read", target: "/r/Store.swift", tokens: 950),  // the latest: not extra
            tool("e", turn: 56, name: "Read", target: "/r/Other.swift", tokens: 100),  // read once
        ]
        let c = try XCTUnwrap(ContextComposition.build(sessionId: "s", calls: calls, toolCalls: tools, events: []))
        XCTAssertEqual(c.staleToolResults, 3_800)
        XCTAssertEqual(c.repeatedReads, [.init(target: "/r/Store.swift", reads: 3, extraTokens: 1_700)])
        XCTAssertEqual(c.repeatedReadTokens, 1_700)
    }
}

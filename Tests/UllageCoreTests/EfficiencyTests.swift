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
        XCTAssertFalse(CacheRebuild.Cause.unknown.isAvoidable, "unexplained is not the same as caused")
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
            CallRow(dedupeKey: "m\(i)", ts: Timestamps.string(from: Date(timeIntervalSince1970: 1_788_000_000 + Double(i) * 60)),
                    sessionId: "s", contextTokens: 10_000 + i * 100, turnIndex: i, sourceFile: "t")
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

    func testBoundaryTurnsAndClearAreNotRebuilds() {
        // Context falls from 90k to a 60k baseline after /clear, and is re-cached
        // in full: exactly what clearing does, so never a rebuild.
        let calls = [turn(0, minute: 0, context: 90_000, write: 2_000),
                     turn(1, minute: 1, context: 60_000, write: 60_000),
                     turn(2, minute: 2, context: 62_000, write: 62_000)]
        let clear = [EventRow(id: "c", sessionId: "s", ts: "2026-09-01T10:00:30.000Z", kind: EventKind.command.rawValue,
                              detail: SlashCommand(name: "clear", args: nil).detailJSON)]
        XCTAssertEqual(CacheRebuilds.detect(calls: calls, commands: clear).map(\.turnIndex), [2],
                       "the turn after /clear is skipped; the one after that is a real (unknown) rebuild")
        XCTAssertEqual(CacheRebuilds.detect(calls: calls, boundaryTurns: [1]).map(\.turnIndex), [2],
                       "a compaction boundary is skipped the same way")
        XCTAssertEqual(CacheRebuilds.detect(calls: calls).map(\.turnIndex), [1, 2], "without either, both count")
    }

    func testChunkedReadsAreNotCopies() throws {
        func parsed(_ input: String) -> String? {
            let line = #"{"type":"assistant","uuid":"u","timestamp":"2026-09-01T10:00:00.000Z","sessionId":"s","message":{"id":"m","model":"x","usage":{"input_tokens":1},"content":[{"type":"tool_use","id":"t","name":"Read","input":\#(input)}]}}"#
            guard case .call(let call)? = ClaudeCodeParser.parse(line: Data(line.utf8),
                context: LineContext(sourceFile: "t.jsonl", fallbackSessionId: "s")) else { return nil }
            return call.toolCalls.first?.target
        }
        XCTAssertEqual(parsed(#"{"file_path":"/r/Big.swift","offset":1000,"limit":1000}"#), "/r/Big.swift@1000+1000")
        XCTAssertEqual(parsed(#"{"file_path":"/r/Big.swift","limit":200}"#), "/r/Big.swift@+200")
        XCTAssertEqual(parsed(#"{"file_path":"/r/Big.swift"}"#), "/r/Big.swift")
        XCTAssertEqual(ToolTargets.groupKey(tool: "Read", target: "/r/Big.swift@1000+1000"), "/r/Big.swift",
                       "grouped and named by the file, whatever the range")
        XCTAssertEqual(ToolTargets.rangeFree("/r/a@b.swift"), "/r/a@b.swift", "an @ in a name is not a range")

        let calls = (0...3).map { i in
            CallRow(dedupeKey: "m\(i)", ts: Timestamps.string(from: Date(timeIntervalSince1970: 1_788_000_000 + Double(i) * 60)),
                    sessionId: "s", contextTokens: 10_000, turnIndex: i, sourceFile: "t")
        }
        let chunks = (0..<3).map { i in
            ToolCallRow(id: "c\(i)", callId: "m\(i)", sessionId: "s", ts: calls[i].ts, name: "Read", kind: "builtin",
                        target: "/r/Big.swift@\(i * 1000)+1000", resultTokens: 900)
        }
        let c = try XCTUnwrap(ContextComposition.build(sessionId: "s", calls: calls, toolCalls: chunks, events: []))
        XCTAssertTrue(c.repeatedReads.isEmpty, "three different ranges of one file are not copies")
        XCTAssertEqual(c.tools.first?.targets.first?.calls, 3, "but they still group under the file")
    }

    // MARK: - An agent's collapsed line

    func testAgentSummaryShowsStatusOnlyAndNeverAnEmptyItem() {
        let agent = StreamFigures(status: .live, contextTokens: 1_000, windowLimit: 200_000, occupancy: 0.005,
                                  contextDelta: 10, lastActivity: nil, sessionId: nil,
                                  agentLine: "Explore · background", agentStatus: "background", isIdle: false)
        XCTAssertEqual(Readout.line(SessionInfo.summary(agent, history: nil)), "last turn +10 · background")
        var bare = agent
        bare.agentLine = ""
        bare.agentStatus = nil
        XCTAssertEqual(Readout.line(SessionInfo.summary(bare, history: nil)), "last turn +10")
        XCTAssertFalse(SessionInfo.rows(bare, history: nil).contains { $0.label == "Agent" }, "no empty Agent row")
    }
}

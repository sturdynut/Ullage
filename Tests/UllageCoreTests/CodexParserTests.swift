import Foundation
import XCTest
@testable import UllageCore

/// Codex rollout parsing: the token math, the exact window, tool attachment,
/// and compaction — driven straight through the parser so it runs anywhere.
final class CodexParserTests: XCTestCase {
    private let context = LineContext(sourceFile: "/x/rollout-abc.jsonl", fallbackSessionId: "file-stem")

    private func line(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    /// Feed a sequence, return every emitted ParsedLine.
    private func run(_ objects: [[String: Any]]) -> [ParsedLine] {
        let parser = CodexParser()
        return objects.compactMap { parser.parse(line: line($0), context: context) }
    }

    private func meta(session: String = "sess-1", cwd: String = "/Users/dev/proj") -> [String: Any] {
        ["type": "session_meta", "ordinal": 0, "timestamp": "2026-09-12T10:00:00.000Z",
         "payload": ["session_id": session, "cwd": cwd]]
    }
    private func turnContext(model: String = "gpt-5.5") -> [String: Any] {
        ["type": "turn_context", "ordinal": 1, "payload": ["model": model, "cwd": "/Users/dev/proj"]]
    }
    private func tokenCount(ordinal: Int, ts: String, input: Int, cached: Int, cacheWrite: Int = 0, output: Int, reasoning: Int = 0, window: Int = 258_400) -> [String: Any] {
        ["type": "event_msg", "ordinal": ordinal, "timestamp": ts,
         "payload": ["type": "token_count", "info": [
            "model_context_window": window,
            "last_token_usage": [
                "input_tokens": input, "cached_input_tokens": cached,
                "cache_write_input_tokens": cacheWrite, "output_tokens": output,
                "reasoning_output_tokens": reasoning,
                "total_tokens": input + output,
            ],
         ]]]
    }

    private func calls(_ lines: [ParsedLine]) -> [ParsedCall] {
        lines.compactMap { if case .call(let c) = $0 { return c } else { return nil } }
    }

    func testUsageLineBecomesAnExactCallWithTheReportedWindow() {
        let out = run([
            meta(), turnContext(),
            ["type": "event_msg", "ordinal": 2, "payload": ["type": "task_started", "model_context_window": 258_400]],
            tokenCount(ordinal: 3, ts: "2026-09-12T10:01:00.000Z", input: 1_000, cached: 600, output: 120),
        ])
        let parsed = calls(out)
        XCTAssertEqual(parsed.count, 1)
        let call = parsed[0].call
        XCTAssertEqual(call.vendor, Vendor.codex)
        XCTAssertEqual(call.confidence, Confidence.exact.rawValue)
        XCTAssertEqual(call.model, "gpt-5.5")
        XCTAssertEqual(call.sessionId, "sess-1")
        XCTAssertEqual(call.project, "proj")
        XCTAssertEqual(call.windowLimit, 258_400, "window comes from the event, not a lookup table")
        XCTAssertEqual(call.dedupeKey, "codex:sess-1:3")
    }

    func testInputTokensAreSplitSoTheFourCountersSumToThePrompt() {
        // Codex input_tokens is the whole prompt (cached included), unlike Claude.
        let out = run([meta(), turnContext(),
                       tokenCount(ordinal: 5, ts: "t", input: 1_000, cached: 600, cacheWrite: 50, output: 120, reasoning: 30)])
        let call = calls(out)[0].call
        XCTAssertEqual(call.cacheRead, 600)
        XCTAssertEqual(call.cacheWrite, 50)
        XCTAssertEqual(call.input, 350, "uncached remainder = 1000 - 600 - 50")
        XCTAssertEqual(call.output, 120)
        XCTAssertEqual(call.reasoning, 30)
        XCTAssertEqual(call.contextTokens, 1_000, "the whole prompt")
        XCTAssertEqual(call.input + call.cacheRead + call.cacheWrite, call.contextTokens)
    }

    func testFunctionCallAndOutputAttachToTheNextUsageCall() {
        let out = run([
            meta(), turnContext(),
            ["type": "response_item", "ordinal": 2, "timestamp": "t", "payload": [
                "type": "function_call", "call_id": "call_A", "name": "exec_command"]],
            ["type": "response_item", "ordinal": 3, "payload": [
                "type": "function_call_output", "call_id": "call_A",
                "output": ["output": String(repeating: "x", count: 400), "exit_code": 0]]],
            tokenCount(ordinal: 4, ts: "t", input: 500, cached: 0, output: 50),
        ])
        let parsed = calls(out)
        XCTAssertEqual(parsed.count, 1)
        let tools = parsed[0].toolCalls
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0].name, "exec_command")
        XCTAssertEqual(tools[0].callId, "codex:sess-1:4")
        XCTAssertEqual(tools[0].isError, false)
        XCTAssertGreaterThan(tools[0].resultTokens ?? 0, 0)
        XCTAssertEqual(tools[0].kind, ToolKind.builtin.rawValue)
    }

    func testCompactedLineIsACompactionEvent() {
        let out = run([meta(),
                       ["type": "compacted", "ordinal": 9, "timestamp": "2026-09-12T10:05:00.000Z", "payload": ["message": ""]]])
        guard case .event(let event)? = out.first else { return XCTFail("expected an event") }
        XCTAssertEqual(event.kind, EventKind.compaction.rawValue)
        XCTAssertEqual(event.sessionId, "sess-1")
        XCTAssertEqual(event.id, "codex:compaction:sess-1:9")
    }

    func testEmptyOrBookkeepingUsageProducesNoCall() {
        // No last_token_usage, and an all-zero usage: neither is a real turn.
        let out = run([meta(), turnContext(),
                       ["type": "event_msg", "ordinal": 2, "payload": ["type": "token_count", "info": ["model_context_window": 258_400]]],
                       tokenCount(ordinal: 3, ts: "t", input: 0, cached: 0, output: 0)])
        XCTAssertTrue(calls(out).isEmpty)
    }

    func testFormatDetectionRoutesByPath() {
        XCTAssertEqual(TranscriptFormat.detect(path: "/Users/x/.codex/sessions/2026/01/02/rollout-abc.jsonl"), .codex)
        XCTAssertEqual(TranscriptFormat.detect(path: "/Users/x/.claude/projects/p/s.jsonl"), .claudeCode)
        XCTAssertTrue(TranscriptFormat.codex.reingestsWholeFile)
        XCTAssertFalse(TranscriptFormat.claudeCode.reingestsWholeFile)
    }
}

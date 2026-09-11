import Foundation
import XCTest
@testable import UllageCore

/// Parser-level assertions: the formula, the classification, the fail-soft.
final class ParserTests: XCTestCase {
    private func parse(_ line: String, session: String = "sess-abc123") -> ParsedLine? {
        ClaudeCodeParser.parse(
            line: Data(line.utf8),
            context: LineContext(sourceFile: "fixture.jsonl", fallbackSessionId: session)
        )
    }

    func testContextTokensSumsAllThreePromptCounters() throws {
        let lines = try Fixtures.lines("basic-session.jsonl")
        guard case .call(let parsed)? = parse(lines[2]) else {
            return XCTFail("third line should parse as a call")
        }
        // 5 uncached + 1200 written to cache + 20000 read from cache.
        XCTAssertEqual(parsed.call.contextTokens, 21_205)
        XCTAssertEqual(parsed.call.input, 5)
        XCTAssertEqual(parsed.call.cacheWrite, 1_200)
        XCTAssertEqual(parsed.call.cacheRead, 20_000)
        XCTAssertEqual(parsed.call.output, 100)
        // input_tokens alone would have reported 5 — the trap the formula exists for.
        XCTAssertNotEqual(parsed.call.contextTokens, parsed.call.input)
    }

    func testCallCarriesIdentityAndProvenance() throws {
        let lines = try Fixtures.lines("basic-session.jsonl")
        guard case .call(let parsed)? = parse(lines[2]) else { return XCTFail("expected a call") }
        let call = parsed.call
        XCTAssertEqual(call.dedupeKey, "msg_001")
        XCTAssertEqual(call.sessionId, "sess-abc123")
        XCTAssertEqual(call.cwd, "/Users/dev/proj")
        XCTAssertEqual(call.project, "proj")
        XCTAssertEqual(call.model, "claude-sonnet-4-5-20250929")
        XCTAssertEqual(call.windowLimit, 200_000)
        XCTAssertEqual(call.vendor, "claude-code")
        XCTAssertEqual(call.confidence, "exact")
        XCTAssertEqual(call.uuid, "uuid-a1")
        XCTAssertEqual(call.parentUuid, "uuid-u1")
        XCTAssertEqual(call.stopReason, "tool_use")
        XCTAssertEqual(call.serviceTier, "standard")
        XCTAssertEqual(call.durationMs, 3_412)
        XCTAssertEqual(call.isSidechain, false)
        XCTAssertEqual(call.parserVersion, ClaudeCodeParser.version)
    }

    func testToolUseBlocksBecomeRows() throws {
        let lines = try Fixtures.lines("basic-session.jsonl")
        guard case .call(let parsed)? = parse(lines[5]) else { return XCTFail("expected a call") }
        XCTAssertEqual(parsed.toolCalls.count, 2)

        let mcp = try XCTUnwrap(parsed.toolCalls.first { $0.name == "mcp__github__create_issue" })
        XCTAssertEqual(mcp.kind, "mcp")
        XCTAssertEqual(mcp.mcpServer, "github")
        XCTAssertEqual(mcp.callId, "msg_002")

        let task = try XCTUnwrap(parsed.toolCalls.first { $0.name == "Task" })
        XCTAssertEqual(task.kind, "agent")
        XCTAssertEqual(task.target, "Explore")
        XCTAssertNil(task.resultTokens)
    }

    func testToolClassification() {
        XCTAssertEqual(ClaudeCodeParser.classify(toolName: "mcp__github__create_issue").kind, .mcp)
        XCTAssertEqual(ClaudeCodeParser.classify(toolName: "mcp__github__create_issue").server, "github")
        XCTAssertEqual(ClaudeCodeParser.classify(toolName: "mcp__linear-server__list").server, "linear-server")
        XCTAssertEqual(ClaudeCodeParser.classify(toolName: "Skill").kind, .skill)
        XCTAssertEqual(ClaudeCodeParser.classify(toolName: "Task").kind, .agent)
        XCTAssertEqual(ClaudeCodeParser.classify(toolName: "Read").kind, .builtin)
        XCTAssertNil(ClaudeCodeParser.classify(toolName: "Read").server)
    }

    func testToolResultsAreExtractedFromUserLines() throws {
        let lines = try Fixtures.lines("basic-session.jsonl")
        guard case .toolResults(let results)? = parse(lines[3]) else {
            return XCTFail("expected tool results")
        }
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].toolUseId, "toolu_read1")
        XCTAssertEqual(results[0].resultTokens, 10)  // 40 characters / 4
        XCTAssertFalse(results[0].isError)
    }

    func testPlainUserLineProducesNothing() throws {
        let lines = try Fixtures.lines("basic-session.jsonl")
        XCTAssertNil(parse(lines[1]))
    }

    func testUnknownLineTypeIsSkippedNotThrown() {
        XCTAssertNil(parse(#"{"type":"x-brand-new-type","sessionId":"s","payload":{"a":1}}"#))
        XCTAssertNil(parse(#"{"type":"file-history-snapshot","snapshot":{}}"#))
    }

    func testMalformedJSONIsSkipped() {
        XCTAssertNil(parse(#"{"type":"assistant","message":{"id":"msg_x""#))
        XCTAssertNil(parse("not json at all"))
        XCTAssertNil(parse(""))
    }

    func testAssistantWithoutUsageDefaultsCountersToZero() throws {
        let lines = try Fixtures.lines("unknown-types.jsonl")
        guard case .call(let parsed)? = parse(lines.last!) else { return XCTFail("expected a call") }
        XCTAssertEqual(parsed.call.dedupeKey, "msg_102")
        XCTAssertEqual(parsed.call.contextTokens, 0)
        XCTAssertEqual(parsed.call.input, 0)
        XCTAssertEqual(parsed.call.output, 0)
    }

    func testAssistantWithoutMessageIDIsDropped() {
        // No dedupe key means no safe insert; dropping beats double-counting.
        XCTAssertNil(parse(#"{"type":"assistant","message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":5}}}"#))
    }

    func testCompactionBoundaryBecomesAnEvent() throws {
        let lines = try Fixtures.lines("basic-session.jsonl")
        guard case .event(let event)? = parse(lines[9]) else { return XCTFail("expected an event") }
        XCTAssertEqual(event.kind, "compaction")
        XCTAssertEqual(event.sessionId, "sess-abc123")
        XCTAssertEqual(event.id, "compaction:uuid-c1")
        XCTAssertEqual(event.detail, #"{"preTokens":21816,"trigger":"auto"}"#)
    }

    func testSummaryLineFallsBackToTheFilenameSessionID() throws {
        let lines = try Fixtures.lines("basic-session.jsonl")
        guard case .event(let event)? = parse(lines[0], session: "from-filename") else {
            return XCTFail("expected an event")
        }
        XCTAssertEqual(event.kind, "summary")
        XCTAssertEqual(event.sessionId, "from-filename")
        XCTAssertEqual(event.id, "summary:uuid-leaf-1")
    }

    func testEventIDIsStableWithoutAnyUUID() {
        let line = #"{"type":"summary","summary":"no uuid here"}"#
        guard case .event(let first)? = parse(line), case .event(let second)? = parse(line) else {
            return XCTFail("expected events")
        }
        XCTAssertEqual(first.id, second.id)
    }

    func testTimestampNormalisation() {
        XCTAssertEqual(Timestamps.normalize("2025-09-01T12:00:04.000Z"), "2025-09-01T12:00:04.000Z")
        XCTAssertEqual(Timestamps.normalize("2025-09-01T12:00:04Z"), "2025-09-01T12:00:04.000Z")
        XCTAssertEqual(Timestamps.normalize("2025-09-01T14:00:04+02:00"), "2025-09-01T12:00:04.000Z")
        XCTAssertNil(Timestamps.normalize(nil))
    }

    func testTokenEstimateIgnoresStructuralLabels() {
        XCTAssertEqual(ClaudeCodeParser.estimateTokens(of: "0123456789"), 3)
        XCTAssertEqual(
            ClaudeCodeParser.estimateTokens(of: [["type": "text", "text": "issue created"]]),
            4  // 13 characters of payload, not 17 including the "text" label
        )
        XCTAssertEqual(ClaudeCodeParser.estimateTokens(of: nil), 0)
    }
}

final class WindowLimitTests: XCTestCase {
    func testLongestPrefixMatchResolvesPointReleases() {
        XCTAssertEqual(WindowLimits.limit(for: "claude-sonnet-4-5-20250929"), 200_000)
        XCTAssertEqual(WindowLimits.limit(for: "claude-opus-4-1-20250805"), 200_000)
        XCTAssertTrue(WindowLimits.isKnown("claude-sonnet-4-5-20250929"))
    }

    func testBracketedWindowSuffixWins() {
        XCTAssertEqual(WindowLimits.limit(for: "claude-sonnet-4-5-20250929[1m]"), 1_000_000)
        XCTAssertEqual(WindowLimits.limit(for: "claude-sonnet-4-5-20250929[200k]"), 200_000)
    }

    func testProviderPrefixesAreStripped() {
        XCTAssertEqual(WindowLimits.normalize("us.anthropic.claude-sonnet-4-5-v1:0"), "claude-sonnet-4-5")
        XCTAssertTrue(WindowLimits.isKnown("us.anthropic.claude-sonnet-4-5-v1:0"))
        XCTAssertTrue(WindowLimits.isKnown("anthropic/claude-opus-4-5"))
    }

    func testUnknownModelFallsBackAndSaysSo() {
        XCTAssertEqual(WindowLimits.limit(for: "some-future-model"), WindowLimits.fallback)
        XCTAssertFalse(WindowLimits.isKnown("some-future-model"))
        XCTAssertEqual(WindowLimits.limit(for: nil), WindowLimits.fallback)
        XCTAssertFalse(WindowLimits.isKnown(nil))
    }
}

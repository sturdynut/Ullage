import Foundation
import XCTest
@testable import UllageCore

/// Gemini CLI and Qwen Code, on fixtures synthesized to the writers' shapes
/// (gemini-cli `chatRecordingService.ts`, qwen-code `chatRecordingService.ts`
/// and `agent-transcript.ts`). No real transcript text.
final class HarnessGeminiTests: XCTestCase {
    private func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private func calls(_ lines: [ParsedLine]) -> [ParsedCall] {
        lines.compactMap { if case .call(let c) = $0 { return c } else { return nil } }
    }

    // MARK: - Gemini CLI

    private let geminiPath = "/Users/dev/.gemini/tmp/my-app/chats/session-2026-10-01T10-00-abcd1234.jsonl"

    private func geminiContext(_ path: String? = nil) -> LineContext {
        let path = path ?? geminiPath
        return LineContext(sourceFile: path, fallbackSessionId: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                           fileModified: "2026-10-01T10:05:00.000Z")
    }

    private func geminiMessage(_ id: String, tokens: [String: Any]?, toolCalls: [[String: Any]]? = nil, ts: String = "2026-10-01T10:01:00.000Z") -> [String: Any] {
        var m: [String: Any] = ["id": id, "timestamp": ts, "type": "gemini", "content": "", "model": "gemini-2.5-pro"]
        if let tokens { m["tokens"] = tokens }
        if let toolCalls { m["toolCalls"] = toolCalls }
        return m
    }

    private func geminiFile(_ records: [[String: Any]]) -> Data {
        Data((records.map(json).joined(separator: "\n") + "\n").utf8)
    }

    private let meta: [String: Any] = ["sessionId": "11111111-2222", "projectHash": "h", "startTime": "2026-10-01T10:00:00.000Z", "lastUpdated": "2026-10-01T10:00:00.000Z", "kind": "main"]

    func testGeminiSplitsCachedOutOfThePromptAndLastAppendWins() {
        let tokens: [String: Any] = ["input": 10_000, "output": 300, "cached": 8_000, "thoughts": 120, "tool": 50, "total": 10_470]
        let data = geminiFile([
            meta,
            ["id": "u1", "timestamp": "2026-10-01T10:00:30.000Z", "type": "user", "content": [["text": "x"]]],
            geminiMessage("g1", tokens: nil),            // appended before usage arrives
            geminiMessage("g1", tokens: tokens),         // appended again with usage
            ["$set": ["lastUpdated": "2026-10-01T10:01:01.000Z"]],
        ])
        let out = GeminiCLIReader().parse(data: data, context: geminiContext(), cwd: "/users/dev/my-app")
        let rows = calls(out)
        XCTAssertEqual(rows.count, 1, "one message id is one call, however often it was appended")
        let call = rows[0].call
        XCTAssertEqual(call.vendor, Vendor.geminiCLI)
        XCTAssertEqual(call.dedupeKey, "gemini-cli:11111111-2222:g1")
        XCTAssertEqual(call.sessionId, "11111111-2222")
        XCTAssertNil(call.agentId)
        XCTAssertEqual(call.input, 2_000, "promptTokenCount includes the cached part")
        XCTAssertEqual(call.cacheRead, 8_000)
        XCTAssertEqual(call.cacheWrite, 0)
        XCTAssertEqual(call.contextTokens, 10_000, "toolUsePromptTokenCount is outside the prompt")
        XCTAssertEqual(call.input + call.cacheRead + call.cacheWrite, call.contextTokens)
        XCTAssertEqual(call.output, 300, "thoughts never go into output")
        XCTAssertEqual(call.reasoning, 120)
        XCTAssertEqual(call.project, "my-app")
        XCTAssertEqual(call.ts, "2026-10-01T10:01:00.000Z")
        XCTAssertEqual(call.confidence, Confidence.exact.rawValue)
        XCTAssertEqual(call.windowLimit, WindowLimits.knownLimit(for: "gemini-2.5-pro"), "lookup only, never the fallback")
    }

    func testGeminiToolCallsPatchedResultsAndSubagentSpawn() {
        let toolCalls: [[String: Any]] = [
            ["id": "c1", "name": "read_file", "args": ["file_path": "/src/a.ts"], "status": "success", "timestamp": "2026-10-01T10:01:02.000Z"],
            ["id": "c2", "name": "mcp_github_list_issues", "args": [:], "status": "error", "timestamp": "2026-10-01T10:01:02.000Z"],
            ["id": "c3", "name": "invoke_agent", "args": ["agent_name": "codebase_investigator", "prompt": "p"], "status": "success",
             "timestamp": "2026-10-01T10:01:03.000Z", "agentId": "sub-1"],
            ["id": "c4", "name": "activate_skill", "args": ["name": "pdf"], "status": "success", "timestamp": "2026-10-01T10:01:03.000Z"],
        ]
        let data = geminiFile([
            meta,
            geminiMessage("g1", tokens: ["input": 100, "output": 10, "cached": 0], toolCalls: toolCalls),
            ["$patch": ["updates": [["id": "g1", "toolCalls": [["id": "c1", "result": [["functionResponse": ["id": "c1", "name": "read_file", "response": ["output": String(repeating: "a", count: 400)]]]]]]]]]],
        ])
        let out = GeminiCLIReader().parse(data: data, context: geminiContext(), cwd: nil)
        let tools = calls(out)[0].toolCalls
        XCTAssertEqual(tools.map(\.name), ["read_file", "mcp_github_list_issues", "invoke_agent", "activate_skill"])
        XCTAssertEqual(tools[0].id, "gemini-cli:11111111-2222:c1")
        XCTAssertEqual(tools[0].target, "/src/a.ts")
        XCTAssertEqual(tools[0].resultTokens, 100, "a length estimate of the patched functionResponse")
        XCTAssertEqual(tools[0].isError, false)
        XCTAssertEqual(tools[1].kind, ToolKind.mcp.rawValue)
        XCTAssertEqual(tools[1].mcpServer, "github")
        XCTAssertEqual(tools[1].isError, true)
        XCTAssertEqual(tools[2].kind, ToolKind.agent.rawValue)
        XCTAssertEqual(tools[3].kind, ToolKind.skill.rawValue)
        guard case .toolResults(let spawns)? = out.last else { return XCTFail("expected the spawn link last") }
        XCTAssertEqual(spawns.first?.agent?.agentId, "sub-1")
        XCTAssertEqual(spawns.first?.agent?.agentType, "codebase_investigator")
        XCTAssertEqual(spawns.first?.toolUseId, tools[2].id)
    }

    func testGeminiSubagentIsItsOwnStreamUnderTheParentSession() {
        let path = "/Users/dev/.gemini/tmp/my-app/chats/parent-session-id/sub-1.jsonl"
        let data = geminiFile([
            ["sessionId": "sub-1", "projectHash": "h", "kind": "subagent", "startTime": "2026-10-01T10:00:00.000Z"],
            geminiMessage("s1", tokens: ["input": 50, "output": 5, "cached": 0]),
        ])
        let call = calls(GeminiCLIReader().parse(data: data, context: geminiContext(path), cwd: nil))[0].call
        XCTAssertEqual(call.sessionId, "parent-session-id")
        XCTAssertEqual(call.agentId, "sub-1")
    }

    func testGeminiHistoryRewriteBecomesACompactionBeforeTheNextCall() {
        let records: [[String: Any]] = [
            meta,
            geminiMessage("g1", tokens: ["input": 900_000, "output": 10, "cached": 0]),
            ["$patch": ["removeIds": ["u0", "g1"], "orderIds": ["s1"]]],
            ["id": "s1", "timestamp": "2026-10-01T10:02:00.000Z", "type": "user", "content": [["text": "<state_snapshot>"]]],
            geminiMessage("g2", tokens: ["input": 20_000, "output": 10, "cached": 0], ts: "2026-10-01T10:03:00.000Z"),
        ]
        let out = GeminiCLIReader().parse(data: geminiFile(records), context: geminiContext(), cwd: nil)
        XCTAssertEqual(out.count, 3)
        guard case .event(let event) = out[1] else { return XCTFail("expected the boundary between the calls") }
        XCTAssertEqual(event.kind, EventKind.compaction.rawValue)
        XCTAssertEqual(event.id, "gemini-cli:compaction:11111111-2222:main:u0")
        XCTAssertEqual(calls(out).map(\.call.dedupeKey), ["gemini-cli:11111111-2222:g1", "gemini-cli:11111111-2222:g2"],
                       "a removed message's request still happened")

        // A file that ends on the rewrite leaves nothing pending.
        let trailing = GeminiCLIReader().parse(data: geminiFile(Array(records.prefix(3))), context: geminiContext(), cwd: nil)
        XCTAssertEqual(trailing.count, 1)
    }

    func testGeminiLegacyJSONAndMalformedLines() {
        let legacyPath = "/Users/dev/.gemini/tmp/my-app/chats/session-2025-07-01T10-00-abcd1234.json"
        var legacy = meta
        legacy["messages"] = [geminiMessage("g1", tokens: ["input": 70, "output": 7, "cached": 20])]
        let pretty = try! JSONSerialization.data(withJSONObject: legacy, options: [.prettyPrinted])
        let fromLegacy = calls(GeminiCLIReader().parse(data: pretty, context: geminiContext(legacyPath), cwd: nil))
        XCTAssertEqual(fromLegacy.map(\.call.dedupeKey), ["gemini-cli:11111111-2222:g1"],
                       "the same key the migrated .jsonl produces, so both files dedupe")
        XCTAssertEqual(fromLegacy.first?.call.input, 50)

        let broken = Data("{not json\n\(json(meta))\n[1,2]\n{\"id\":3}\n\(json(geminiMessage("g9", tokens: ["input": "x"])))\n\(json(geminiMessage("g2", tokens: ["input": 5, "output": 1])))\n".utf8)
        let rows = calls(GeminiCLIReader().parse(data: broken, context: geminiContext(), cwd: nil))
        XCTAssertEqual(rows.map(\.call.dedupeKey), ["gemini-cli:11111111-2222:g2"], "malformed and token-less records are skipped")
    }

    func testGeminiReReadIsIdempotentThroughTheIngestor() throws {
        let workspace = try TempWorkspace()
        let chats = workspace.root.appendingPathComponent(".gemini/tmp/my-app/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        try "/users/dev/my-app".write(to: chats.deletingLastPathComponent().appendingPathComponent(".project_root"), atomically: true, encoding: .utf8)
        let file = chats.appendingPathComponent("session-2026-10-01T10-00-abcd1234.jsonl")
        try geminiFile([meta, geminiMessage("g1", tokens: ["input": 100, "output": 1, "cached": 40])]).write(to: file)
        XCTAssertEqual(Harness.detect(path: file.path), .geminiCLI)

        try workspace.ingestor.ingestFile(at: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((json(geminiMessage("g2", tokens: ["input": 200, "output": 2, "cached": 150])) + "\n").utf8))
        try handle.close()
        try workspace.ingestor.ingestFile(at: file)
        try workspace.ingestor.ingestFile(at: file)

        XCTAssertEqual(try workspace.store.callCount(), 2)
        let rows = try workspace.store.calls(sessionId: "11111111-2222")
        XCTAssertEqual(rows.map(\.turnIndex), [0, 1])
        XCTAssertEqual(rows.last?.contextDelta, 100)
        XCTAssertEqual(rows.first?.project, "my-app", "cwd from the .project_root marker")
    }

    func testGeminiOwnsOnlyChatRecordings() {
        XCTAssertTrue(GeminiPaths.isGeminiTranscript(geminiPath))
        XCTAssertTrue(GeminiPaths.isGeminiTranscript("/Users/dev/.gemini/tmp/my-app/chats/session-2025-07-01T10-00-abcd1234.json"))
        XCTAssertTrue(GeminiPaths.isGeminiTranscript("/Users/dev/.gemini/tmp/my-app/chats/parent/sub.jsonl"))
        XCTAssertTrue(GeminiPaths.isGeminiTranscript("/Users/dev/.cache/.gemini/tmp/my-app/chats/session-x.jsonl"))
        XCTAssertFalse(GeminiPaths.isGeminiTranscript("/Users/dev/.gemini/tmp/my-app/logs.json"))
        XCTAssertFalse(GeminiPaths.isGeminiTranscript("/Users/dev/.gemini/tmp/my-app/chats/session-x.jsonl.tmp-123"))
        XCTAssertFalse(GeminiPaths.isGeminiTranscript("/Users/dev/.gemini/tmp/my-app/chats/notes.json"))
        XCTAssertFalse(GeminiPaths.isGeminiTranscript("/Users/dev/.gemini/antigravity/brain/x.jsonl"))
        XCTAssertFalse(GeminiPaths.isGeminiTranscript("/Users/dev/.claude/projects/-Users-dev-app/abc.jsonl"))
        XCTAssertEqual(Harness.detect(path: "/Users/dev/.claude/projects/-Users-dev-app/abc.jsonl"), .claudeCode)
        XCTAssertEqual(GeminiPaths.tmpDirectories(environment: ["GEMINI_CLI_HOME": "/x"]).map(\.path), ["/x/.gemini/tmp", "/x/.cache/.gemini/tmp"])
    }

    func testGeminiCapabilitiesAreHonest() {
        let caps = Harness.geminiCLI.capabilities
        XCTAssertFalse(caps.verifiedOnDisk, "read from source only; no Gemini CLI data on the Mac it was written on")
        XCTAssertEqual(caps.window, .lookup)
        XCTAssertTrue(caps.cacheSplit)
        XCTAssertNil(WindowLimits.knownLimit(for: "some-unknown-model"), "an unknown model gets no window, not a guess")
    }

    // MARK: - Qwen Code

    private let qwenPath = "/Users/dev/.qwen/projects/-Users-dev-app/chats/sess-1.jsonl"

    private func qwenContext(_ path: String? = nil) -> LineContext {
        LineContext(sourceFile: path ?? qwenPath, fallbackSessionId: "sess-1", fileModified: "2026-10-01T10:05:00.000Z")
    }

    private func qwenRecord(_ type: String, uuid: String, extra: [String: Any] = [:]) -> Data {
        var r: [String: Any] = ["uuid": uuid, "parentUuid": NSNull(), "sessionId": "sess-1", "timestamp": "2026-10-01T10:01:00.000Z",
                                "type": type, "cwd": "/Users/dev/app", "version": "1.0.0"]
        for (k, v) in extra { r[k] = v }
        return try! JSONSerialization.data(withJSONObject: r)
    }

    func testQwenSplitsCachedOutOfThePromptAndUsesTheReportedWindow() {
        let parser = QwenCodeParser()
        let out = parser.parse(line: qwenRecord("assistant", uuid: "a1", extra: [
            "model": "qwen3-coder-plus", "contextWindowSize": 1_000_000,
            "message": ["role": "model", "parts": [["text": "ok"], ["functionCall": ["id": "call_1", "name": "run_shell_command", "args": ["command": "ls"]]],
                                                   ["functionCall": ["id": "call_2", "name": "mcp__github__search", "args": ["query": "q"]]]]],
            "usageMetadata": ["promptTokenCount": 12_000, "cachedContentTokenCount": 11_000, "candidatesTokenCount": 40, "thoughtsTokenCount": 30, "totalTokenCount": 12_070],
        ]), context: qwenContext())
        guard case .call(let parsed)? = out else { return XCTFail("expected a call") }
        let call = parsed.call
        XCTAssertEqual(call.vendor, Vendor.qwenCode)
        XCTAssertEqual(call.dedupeKey, "qwen-code:sess-1:a1")
        XCTAssertEqual(call.input, 1_000)
        XCTAssertEqual(call.cacheRead, 11_000)
        XCTAssertEqual(call.cacheWrite, 0)
        XCTAssertEqual(call.contextTokens, 12_000)
        XCTAssertEqual(call.output, 40)
        XCTAssertNil(call.reasoning, "Qwen may have estimated it; not stored")
        XCTAssertEqual(call.windowLimit, 1_000_000)
        XCTAssertEqual(call.project, "app")
        XCTAssertEqual(parsed.toolCalls.map(\.target), ["ls", "q"])
        XCTAssertEqual(parsed.toolCalls[1].kind, ToolKind.mcp.rawValue)
        XCTAssertEqual(parsed.toolCalls[1].mcpServer, "github")

        guard case .toolResults(let results)? = parser.parse(line: qwenRecord("tool_result", uuid: "t1", extra: [
            "message": ["role": "user", "parts": [["functionResponse": ["id": "call_1", "name": "run_shell_command", "response": ["output": String(repeating: "b", count: 40)]]]]],
            "toolCallResult": ["callId": "call_1", "status": "error"],
        ]), context: qwenContext()) else { return XCTFail("expected a tool result") }
        XCTAssertEqual(results.first?.toolUseId, parsed.toolCalls[0].id)
        XCTAssertEqual(results.first?.resultTokens, 10)
        XCTAssertEqual(results.first?.isError, true)
    }

    func testQwenTotalOnlyUsageIsUnmeasuredAndForkCopiesAreSkipped() {
        let parser = QwenCodeParser()
        guard case .call(let parsed)? = parser.parse(line: qwenRecord("assistant", uuid: "a2", extra: [
            "model": "m", "contextWindowSize": 200_000,
            "usageMetadata": ["totalTokenCount": 500, "candidatesTokenCount": 20, "cachedContentTokenCount": 0],
        ]), context: qwenContext()) else { return XCTFail("expected a call") }
        XCTAssertEqual(parsed.call.confidence, Confidence.unmeasured.rawValue)
        XCTAssertNil(parsed.call.windowLimit)
        XCTAssertEqual(parsed.call.contextTokens, 0)

        XCTAssertNil(parser.parse(line: qwenRecord("assistant", uuid: "a3", extra: [
            "usageMetadata": ["promptTokenCount": 10], "forkedFrom": ["sessionId": "other", "messageUuid": "a3"],
        ]), context: qwenContext()))
        XCTAssertNil(parser.parse(line: Data("{oops".utf8), context: qwenContext()))
        XCTAssertNil(parser.parse(line: qwenRecord("user", uuid: "u1"), context: qwenContext()))
        XCTAssertNil(parser.parse(line: qwenRecord("assistant", uuid: "a4", extra: ["usageMetadata": "nope"]), context: qwenContext()))
    }

    func testQwenCompressionAndSubagentStream() throws {
        let parser = QwenCodeParser()
        guard case .event(let event)? = parser.parse(line: qwenRecord("system", uuid: "s1", extra: [
            "subtype": "chat_compression", "systemPayload": ["info": ["originalTokenCount": 100, "newTokenCount": 10], "compressedHistory": []],
        ]), context: qwenContext()) else { return XCTFail("expected a compaction") }
        XCTAssertEqual(event.kind, EventKind.compaction.rawValue)
        XCTAssertEqual(event.id, "qwen-code:compaction:sess-1:s1")

        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("qwen-\(UUID().uuidString)/.qwen/projects/-Users-dev-app/subagents/sess-1")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent().deletingLastPathComponent()) }
        try #"{"agentId":"explore-7f3c","agentType":"Explore","model":"qwen3-coder-plus"}"#.write(
            to: root.appendingPathComponent("agent-explore-7f3c.meta.json"), atomically: true, encoding: .utf8)
        let path = root.appendingPathComponent("agent-explore-7f3c.jsonl").path
        XCTAssertTrue(QwenPaths.isQwenTranscript(path))

        let sub = QwenCodeParser()
        let side: [String: Any] = ["agentId": "explore-7f3c", "agentName": "Explore", "isSidechain": true]
        guard case .call(let round)? = sub.parse(line: qwenRecord("assistant", uuid: "r1", extra: side.merging([
            "message": ["role": "model", "parts": [["text": "t"]]],
            "usageMetadata": ["promptTokenCount": 3_000, "cachedContentTokenCount": 0, "candidatesTokenCount": 9],
        ]) { a, _ in a }), context: qwenContext(path)) else { return XCTFail("expected a call") }
        XCTAssertEqual(round.call.sessionId, "sess-1")
        XCTAssertEqual(round.call.agentId, "explore-7f3c")
        XCTAssertEqual(round.call.agent, "Explore")
        XCTAssertEqual(round.call.model, "qwen3-coder-plus", "from the sidecar")

        guard case .call(let again)? = sub.parse(line: qwenRecord("assistant", uuid: "r2", extra: side.merging([
            "message": ["role": "model", "parts": [["functionCall": ["id": "c9", "name": "read_file", "args": ["absolute_path": "/a"]]]]],
        ]) { a, _ in a }), context: qwenContext(path)) else { return XCTFail("tool-call record re-emits its round") }
        XCTAssertEqual(again.call.dedupeKey, round.call.dedupeKey)
        XCTAssertEqual(again.toolCalls.map(\.target), ["/a"])
    }

    func testQwenOwnsOnlyItsTranscripts() {
        XCTAssertTrue(QwenPaths.isQwenTranscript(qwenPath))
        XCTAssertFalse(QwenPaths.isQwenTranscript("/Users/dev/.qwen/projects/-Users-dev-app/chats/sess-1.runtime.json"))
        XCTAssertFalse(QwenPaths.isQwenTranscript("/Users/dev/.qwen/projects/-Users-dev-app/chats/x/y.jsonl"))
        XCTAssertFalse(QwenPaths.isQwenTranscript("/Users/dev/.claude/projects/-Users-dev-app/abc.jsonl"))
        XCTAssertFalse(QwenPaths.isQwenTranscript("/Users/dev/.claude/projects/-Users-dev-app/abc/subagents/agent-1.jsonl"))
        XCTAssertTrue(QwenPaths.isQwenTranscript("/data/q/projects/p/chats/s.jsonl", environment: ["QWEN_RUNTIME_DIR": "/data/q"]))
        XCTAssertFalse(QwenPaths.isQwenTranscript("/data/q/projects/p/chats/s.jsonl", environment: [:]))
        XCTAssertEqual(Harness.detect(path: qwenPath), .qwenCode)
        XCTAssertEqual(Harness.detect(path: "/Users/dev/.claude/projects/-Users-dev-app/abc.jsonl"), .claudeCode)
    }

    func testQwenCapabilitiesAreHonest() {
        let caps = Harness.qwenCode.capabilities
        XCTAssertFalse(caps.verifiedOnDisk)
        XCTAssertEqual(caps.window, .reported)
        XCTAssertFalse(caps.effort)
        XCTAssertFalse(Harness.qwenCode.reingestsWholeFile, "self-contained lines are tailed")
        XCTAssertTrue(Harness.geminiCLI.reingestsWholeFile)
    }
}

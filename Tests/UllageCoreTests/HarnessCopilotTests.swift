import Foundation
import XCTest
@testable import UllageCore

/// Fixtures mirror the writers' shapes (VS Code `chatModel.ts` /
/// `objectMutationLog.ts`, Copilot Chat `chatDebugFileLoggerService.ts`,
/// Copilot SDK `session-events.ts`); no text is copied from real sessions.
final class HarnessCopilotTests: XCTestCase {
    private func json(_ object: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private func write(_ url: URL, _ lines: [String]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func calls(_ lines: [ParsedLine]) -> [ParsedCall] {
        lines.compactMap { if case .call(let c) = $0 { return c } else { return nil } }
    }

    // MARK: - Copilot CLI

    private let cliPath = "/Users/dev/.copilot/session-state/s-1/events.jsonl"
    private var cliContext: LineContext { LineContext(sourceFile: cliPath, fallbackSessionId: "events") }

    private func event(_ type: String, _ data: [String: Any], id: String = UUID().uuidString, agentId: String? = nil, ephemeral: Bool? = nil) -> Data {
        var root: [String: Any] = ["type": type, "data": data, "id": id, "timestamp": "2026-10-01T10:00:00.000Z", "parentId": NSNull()]
        if let agentId { root["agentId"] = agentId }
        if let ephemeral { root["ephemeral"] = ephemeral }
        return try! JSONSerialization.data(withJSONObject: root)
    }

    func testCLIMessageIsAnUnmeasuredRowWithOutputModelAndTools() {
        let parser = CopilotCLIParser()
        XCTAssertNil(parser.parse(line: event("session.start", [
            "sessionId": "s-1", "version": 1, "producer": "copilot-agent", "copilotVersion": "1.0.0",
            "startTime": "2026-10-01T10:00:00.000Z", "selectedModel": "claude-sonnet-4.5",
            "reasoningEffort": "high", "context": ["cwd": "/Users/dev/proj"],
        ]), context: cliContext))
        let out = parser.parse(line: event("assistant.message", [
            "messageId": "m1", "apiCallId": "call-1", "content": "", "outputTokens": 321,
            "toolRequests": [
                ["toolCallId": "t1", "name": "view", "arguments": ["path": "/Users/dev/proj/a.swift"]],
                ["toolCallId": "t2", "name": "github-get_issue", "mcpServerName": "github", "arguments": ["issue": 1]],
            ],
        ]), context: cliContext)
        guard case .call(let parsed)? = out else { return XCTFail("expected a call") }
        let call = parsed.call
        XCTAssertEqual(call.vendor, Vendor.copilotCLI)
        XCTAssertEqual(call.sessionId, "s-1")
        XCTAssertEqual(call.dedupeKey, "copilot-cli:s-1:call-1")
        XCTAssertEqual(call.confidence, Confidence.unmeasured.rawValue)
        XCTAssertEqual([call.input, call.cacheRead, call.cacheWrite, call.contextTokens], [0, 0, 0, 0])
        XCTAssertEqual(call.output, 321, "output tokens are measured and kept")
        XCTAssertNil(call.windowLimit)
        XCTAssertNil(call.occupancy)
        XCTAssertEqual(call.model, "claude-sonnet-4.5")
        XCTAssertEqual(call.effort, "high")
        XCTAssertEqual(call.project, "proj")
        XCTAssertNil(call.agentId)
        XCTAssertEqual(parsed.toolCalls.map(\.kind), ["builtin", "mcp"])
        XCTAssertEqual(parsed.toolCalls[1].mcpServer, "github")
        XCTAssertEqual(parsed.toolCalls[0].target, "/Users/dev/proj/a.swift")
    }

    func testCLIChunksOfOneCallShareAKeyAndSubagentsAreTheirOwnStream() {
        let parser = CopilotCLIParser()
        let a = parser.parse(line: event("assistant.message", ["messageId": "m1", "apiCallId": "c", "content": "", "chunkIndex": 0]), context: cliContext)
        let b = parser.parse(line: event("assistant.message", ["messageId": "m2", "apiCallId": "c", "content": "", "chunkIndex": 1, "outputTokens": 9]), context: cliContext)
        let sub = parser.parse(line: event("assistant.message", ["messageId": "m3", "content": "", "model": "gpt-5-mini"], agentId: "agent-7"), context: cliContext)
        guard case .call(let first)? = a, case .call(let second)? = b, case .call(let child)? = sub else { return XCTFail() }
        XCTAssertEqual(first.call.dedupeKey, second.call.dedupeKey)
        XCTAssertEqual(child.call.agentId, "agent-7")
        XCTAssertEqual(child.call.model, "gpt-5-mini")
        XCTAssertEqual(child.call.sessionId, "s-1", "session id from the directory when no session.start was seen")
    }

    func testCLITotalsEphemeralAndMalformedLinesProduceNothing() {
        let parser = CopilotCLIParser()
        XCTAssertNil(parser.parse(line: event("assistant.usage", ["model": "x", "inputTokens": 5], ephemeral: true), context: cliContext))
        XCTAssertNil(parser.parse(line: event("session.shutdown", [
            "modelMetrics": ["x": ["usage": ["inputTokens": 9_000_000, "outputTokens": 1, "cacheReadTokens": 8_000_000, "cacheWriteTokens": 0]]],
            "shutdownType": "routine", "sessionStartTime": 0, "totalApiDurationMs": 0, "codeChanges": [:],
        ]), context: cliContext), "session totals never become a call row")
        XCTAssertNil(parser.parse(line: Data("{not json".utf8), context: cliContext))
        XCTAssertNil(parser.parse(line: event("some.future_event", [:]), context: cliContext))
    }

    func testCLICompactionIsAnEvent() {
        let parser = CopilotCLIParser()
        let out = parser.parse(line: event("session.compaction_complete", [
            "success": true, "preCompactionTokens": 120_000, "postCompactionTokens": 9_000, "summaryContent": "secret",
        ], id: "e9"), context: cliContext)
        guard case .event(let row)? = out else { return XCTFail("expected an event") }
        XCTAssertEqual(row.kind, EventKind.compaction.rawValue)
        XCTAssertEqual(row.id, "copilot-cli:compaction:s-1:e9")
        XCTAssertFalse(row.detail?.contains("secret") ?? false, "summary text is not stored")
        XCTAssertNil(parser.parse(line: event("session.compaction_complete", ["success": false]), context: cliContext))
    }

    func testCLIOwnsOnlyItsEventLog() {
        XCTAssertTrue(CopilotCLIPaths.isEventLog(cliPath))
        XCTAssertFalse(CopilotCLIPaths.isEventLog("/Users/dev/.copilot/session-state/s-1/other.jsonl"))
        XCTAssertFalse(CopilotCLIPaths.isEventLog("/Users/dev/.claude/projects/p/events.jsonl"))
        XCTAssertEqual(Harness.owning(cliPath)?.id, Vendor.copilotCLI)
        XCTAssertEqual(Harness.owning("/Users/dev/.claude/projects/p/s.jsonl")?.id, Vendor.claudeCode)
        let roots = CopilotCLIPaths.sessionStateDirectories(environment: ["COPILOT_HOME": "/tmp/ch"])
        XCTAssertEqual(roots.map(\.path), ["/tmp/ch/session-state"])
    }

    func testCLIIngestIsIdempotent() throws {
        let workspace = try TempWorkspace()
        let file = workspace.root.appendingPathComponent("session-state/s-2/events.jsonl")
        try write(file, [
            json(["type": "session.start", "id": "1", "timestamp": "2026-10-01T10:00:00.000Z",
                  "data": ["sessionId": "s-2", "context": ["cwd": "/w/app"]]]),
            "garbage",
            json(["type": "assistant.message", "id": "2", "timestamp": "2026-10-01T10:00:01.000Z",
                  "data": ["messageId": "m", "apiCallId": "a", "content": "", "outputTokens": 4]]),
        ])
        try workspace.ingestor.ingestDirectory(at: workspace.root)
        let first = try workspace.store.calls(sessionId: "s-2")
        try workspace.ingestor.ingestDirectory(at: workspace.root)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(try workspace.store.calls(sessionId: "s-2"), first)
    }

    func testCLICapabilitiesAreActivityOnly() {
        let caps = Harness.copilotCLI.capabilities
        XCTAssertEqual(caps.occupancy, .none)
        XCTAssertFalse(caps.hasGauge)
        XCTAssertFalse(caps.verifiedOnDisk)
    }

    // MARK: - Copilot in VS Code

    private func request(_ id: String, ts: Double, extra: [String: Any] = [:]) -> [String: Any] {
        var r: [String: Any] = ["requestId": id, "timestamp": ts, "modelId": "copilot/gpt-4.1",
                                "message": ["text": "", "parts": []], "variableData": ["variables": []], "response": []]
        r.merge(extra) { $1 }
        return r
    }

    func testMutationLogIsReplayed() throws {
        let lines = [
            json(["kind": 0, "v": ["version": 3, "sessionId": "abc", "creationDate": 1, "requests": [request("r1", ts: 1_759_312_800_000)]]]),
            json(["kind": 2, "k": ["requests"], "v": [request("r2", ts: 1_759_312_900_000)]]),
            json(["kind": 1, "k": ["requests", 0, "promptTokens"], "v": 1000]),
            json(["kind": 1, "k": ["requests", 1, "promptTokens"], "v": 5]),
            "{broken",
            json(["kind": 3, "k": ["requests", 1, "promptTokens"]]),
            json(["kind": 2, "k": ["requests", 0, "response"], "v": [["kind": "markdownContent"]], "i": 0]),
        ]
        let doc = try XCTUnwrap(CopilotVSCodeReader.document(from: Data(lines.joined(separator: "\n").utf8), jsonl: true))
        let requests = try XCTUnwrap(doc["requests"] as? [[String: Any]])
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0]["promptTokens"] as? Int, 1000)
        XCTAssertNil(requests[1]["promptTokens"], "kind 3 deletes")
        XCTAssertEqual((requests[0]["response"] as? [Any])?.count, 1)
    }

    func testRequestReadingIsTheLatestCallsWholePrompt() {
        let file = URL(fileURLWithPath: "/nowhere/Code/User/workspaceStorage/h/chatSessions/abc.json")
        let doc: [String: Any] = ["sessionId": "abc", "requests": [
            request("r1", ts: 1_759_312_800_000, extra: [
                "promptTokens": 40_000, "completionTokens": 700,
                "contextUsage": ["currentTokens": 40_000, "tokenLimit": 128_000],
                "modelConfiguration": ["reasoningEffort": "medium"],
                "result": ["metadata": ["resolvedModel": "gpt-4.1-2025-04-14", "toolCallRounds": [
                    ["id": "round", "response": "", "toolInputRetry": 0,
                     "toolCalls": [["id": "tc1", "name": "read_file", "arguments": "{\"filePath\":\"/p/a.ts\"}"]]],
                ]]],
                "response": [
                    ["kind": "toolInvocationSerialized", "toolCallId": "tc1__vscode-3", "toolId": "copilot_readFile", "source": ["type": "internal"]],
                    ["kind": "toolInvocationSerialized", "toolCallId": "tc2", "toolId": "mcp_github_get_issue", "source": ["type": "mcp", "serverLabel": "GitHub"]],
                ],
            ]),
            request("r2", ts: 1_759_312_900_000, extra: ["promptTokens": 50_000]),
            request("r3", ts: 1_759_313_000_000),
        ]]
        let rows = calls(CopilotVSCodeReader.chatSession(doc, file: file, context: LineContext(sourceFile: file.path, fallbackSessionId: "abc")))
        XCTAssertEqual(rows.count, 3)
        let first = rows[0].call
        XCTAssertEqual(first.vendor, Vendor.copilotVSCode)
        XCTAssertEqual(first.dedupeKey, "copilot-vscode:abc:r1")
        XCTAssertEqual(first.ts, "2025-10-01T10:00:00.000Z")
        XCTAssertEqual(first.input, 40_000, "whole prompt, not split")
        XCTAssertEqual(first.cacheRead, 0)
        XCTAssertEqual(first.contextTokens, 40_000)
        XCTAssertEqual(first.output, 700)
        XCTAssertEqual(first.windowLimit, 128_000, "window only as VS Code reported it")
        XCTAssertEqual(first.model, "gpt-4.1-2025-04-14")
        XCTAssertEqual(first.effort, "medium")
        XCTAssertEqual(first.confidence, Confidence.exact.rawValue)
        XCTAssertEqual(rows[0].toolCalls.map(\.kind), ["builtin", "mcp"])
        XCTAssertEqual(rows[0].toolCalls[0].target, "/p/a.ts")
        XCTAssertEqual(rows[0].toolCalls[1].mcpServer, "GitHub")

        XCTAssertNil(rows[1].call.windowLimit, "no reported window, none looked up")
        XCTAssertEqual(rows[1].call.model, "gpt-4.1", "provider prefix stripped")

        XCTAssertEqual(rows[2].call.confidence, Confidence.unmeasured.rawValue, "no usage persisted")
        XCTAssertNil(rows[2].call.windowLimit)
        XCTAssertEqual(rows[2].call.contextTokens, 0)
    }

    func testCompactionFromResultSummary() {
        let file = URL(fileURLWithPath: "/nowhere/Code/User/globalStorage/emptyWindowChatSessions/e.json")
        let doc: [String: Any] = ["sessionId": "e", "requests": [
            request("r1", ts: 1_759_312_800_000, extra: ["result": ["metadata": ["summary": ["toolCallRoundId": "x", "text": "s"]]]]),
        ]]
        let out = CopilotVSCodeReader.chatSession(doc, file: file, context: LineContext(sourceFile: file.path, fallbackSessionId: "e"))
        XCTAssertTrue(out.contains { if case .event(let e) = $0 { return e.kind == "compaction" } else { return false } })
    }

    func testDebugLogGivesEveryCallWithCacheSplit() {
        let file = URL(fileURLWithPath: "/u/Code/User/workspaceStorage/h/GitHub.copilot-chat/debug-logs/sess/main.jsonl")
        let lines = [
            json(["v": 1, "ts": 1_759_312_800_000, "dur": 10, "sid": "sess", "type": "llm_request", "name": "chat:claude-sonnet-4.5",
                  "spanId": "s1", "status": "ok", "attrs": ["model": "claude-sonnet-4.5", "debugName": "panel/editAgent",
                                                            "inputTokens": 30_000, "cachedTokens": 28_000, "outputTokens": 200]]),
            json(["ts": 1_759_312_800_500, "dur": 5, "sid": "sess", "type": "tool_call", "name": "read_file",
                  "spanId": "t1", "status": "ok", "attrs": ["args": "{\"filePath\":\"/p/x\"}"]]),
            json(["ts": 1_759_312_801_000, "dur": 5, "sid": "sess", "type": "llm_request", "name": "chat:gpt-4o-mini",
                  "spanId": "s2", "status": "ok", "attrs": ["model": "gpt-4o-mini", "debugName": "title", "inputTokens": 900]]),
            json(["ts": 1_759_312_802_000, "dur": 5, "sid": "sess", "type": "llm_request", "name": "chat:x",
                  "spanId": "s3", "status": "error", "attrs": ["debugName": "panel/editAgent", "inputTokens": 31_000]]),
            "not json",
        ]
        let rows = calls(CopilotVSCodeReader.debugLog(Data(lines.joined(separator: "\n").utf8), file: file,
                                                      context: LineContext(sourceFile: file.path, fallbackSessionId: "main")))
        XCTAssertEqual(rows.count, 1, "helper and failed calls are not the conversation's context")
        let call = rows[0].call
        XCTAssertEqual(call.sessionId, "sess")
        XCTAssertNil(call.agentId)
        XCTAssertEqual(call.input, 2_000)
        XCTAssertEqual(call.cacheRead, 28_000)
        XCTAssertEqual(call.contextTokens, 30_000)
        XCTAssertEqual(call.output, 200)
        XCTAssertNil(call.windowLimit)
        XCTAssertEqual(rows[0].toolCalls.map(\.name), ["read_file"])
        XCTAssertEqual(rows[0].toolCalls[0].target, "/p/x")

        let child = URL(fileURLWithPath: "/u/Code/User/workspaceStorage/h/GitHub.copilot-chat/debug-logs/sess/runSubagent-kid.jsonl")
        let childRows = calls(CopilotVSCodeReader.debugLog(Data(json(["ts": 1, "dur": 1, "sid": "kid", "type": "llm_request", "name": "n",
            "spanId": "k1", "status": "ok", "attrs": ["debugName": "tool/runSubagent", "inputTokens": 10]]).utf8),
            file: child, context: LineContext(sourceFile: child.path, fallbackSessionId: "x")))
        XCTAssertEqual(childRows.first?.call.agentId, "kid", "a subagent is its own stream")
        XCTAssertEqual(childRows.first?.call.sessionId, "sess")
    }

    func testDebugLogReplacesRequestReadingsAndIngestIsIdempotent() throws {
        let workspace = try TempWorkspace()
        let hash = workspace.root.appendingPathComponent("Code/User/workspaceStorage/h1")
        try write(hash.appendingPathComponent("workspace.json"), [json(["folder": "file:///Users/dev/my%20app"])])
        let chat = hash.appendingPathComponent("chatSessions/sid.jsonl")
        try write(chat, [json(["kind": 0, "v": ["sessionId": "sid", "requests": [request("r1", ts: 1_759_312_800_000, extra: ["promptTokens": 10])]]])])

        try workspace.ingestor.ingestDirectory(at: workspace.root)
        let before = try workspace.store.calls(sessionId: "sid")
        XCTAssertEqual(before.map(\.dedupeKey), ["copilot-vscode:sid:r1"])
        XCTAssertEqual(before.first?.cwd, "/Users/dev/my app")
        XCTAssertEqual(before.first?.project, "my app")
        try workspace.ingestor.ingestDirectory(at: workspace.root)
        XCTAssertEqual(try workspace.store.calls(sessionId: "sid"), before)

        // With a debug log present, a fresh read of the chat emits no request rows.
        try write(hash.appendingPathComponent("GitHub.copilot-chat/debug-logs/sid/main.jsonl"), [
            json(["ts": 1_759_312_800_000, "dur": 1, "sid": "sid", "type": "llm_request", "name": "n", "spanId": "x",
                  "status": "ok", "attrs": ["inputTokens": 10, "debugName": "panel/agent"]]),
        ])
        let reread = CopilotVSCodeReader().read(file: chat, context: LineContext(sourceFile: chat.path, fallbackSessionId: "sid"))
        XCTAssertTrue(calls(reread).isEmpty)
    }

    func testVSCodeOwnsOnlyCopilotFiles() {
        let base = "/Users/dev/Library/Application Support"
        XCTAssertTrue(CopilotVSCodePaths.isCopilotFile("\(base)/Code/User/workspaceStorage/h/chatSessions/a.jsonl"))
        XCTAssertTrue(CopilotVSCodePaths.isCopilotFile("\(base)/Code - Insiders/User/workspaceStorage/h/chatSessions/a.json"))
        XCTAssertTrue(CopilotVSCodePaths.isCopilotFile("\(base)/Code/User/globalStorage/emptyWindowChatSessions/a.json"))
        XCTAssertTrue(CopilotVSCodePaths.isCopilotFile("\(base)/Code/User/globalStorage/github.copilot-chat/debug-logs/s/main.jsonl"))
        XCTAssertFalse(CopilotVSCodePaths.isCopilotFile("\(base)/Code/User/workspaceStorage/h/workspace.json"))
        XCTAssertFalse(CopilotVSCodePaths.isCopilotFile("\(base)/Code/User/workspaceStorage/h/chatEditingSessions/x/state.json"))
        XCTAssertFalse(CopilotVSCodePaths.isCopilotFile("\(base)/Cursor/User/workspaceStorage/h/chatSessions/a.json"), "a fork's files are not Copilot's")
        XCTAssertFalse(CopilotVSCodePaths.isCopilotFile("/Users/dev/.claude/projects/p/chatSessions/a.jsonl"))
        XCTAssertEqual(Harness.owning("\(base)/Code/User/workspaceStorage/h/chatSessions/a.jsonl")?.id, Vendor.copilotVSCode)
        XCTAssertNil(Harness.owning("\(base)/Code/User/workspaceStorage/h/workspace.json"))
        let portable = CopilotVSCodePaths.roots(environment: ["VSCODE_PORTABLE": "/p"]).map(\.path)
        XCTAssertTrue(portable.contains("/p/user-data/User/workspaceStorage"))
    }

    func testVSCodeCapabilitiesAreHonest() {
        let caps = Harness.copilotVSCode.capabilities
        XCTAssertEqual(caps.occupancy, .perRequest)
        XCTAssertEqual(caps.window, .reported)
        XCTAssertFalse(caps.cacheSplit)
        XCTAssertFalse(caps.verifiedOnDisk)
    }
}

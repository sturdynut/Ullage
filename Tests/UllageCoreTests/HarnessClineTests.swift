import Foundation
import XCTest
@testable import UllageCore

/// Cline, Roo Code and Kilo Code: one reader over `ui_messages.json`, plus
/// Cline 4.1's SDK `<id>.messages.json`. Fixtures are synthesized in the shape
/// the writers produce (see docs/harnesses/cline.md); no real task text.
final class HarnessClineTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ullage-cline-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // 2026-01-01T00:00:00Z, after both forks switched to total input.
    private let after: Double = 1_767_225_600_000
    // 2025-06-01, before.
    private let before: Double = 1_748_736_000_000

    private func apiReq(_ ts: Double, _ info: [String: Any], extra: [String: Any] = [:]) -> [String: Any] {
        var m: [String: Any] = ["ts": ts, "type": "say", "say": "api_req_started",
                                "text": String(decoding: try! JSONSerialization.data(withJSONObject: info), as: UTF8.self)]
        m.merge(extra) { $1 }
        return m
    }

    private func json(_ object: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    @discardableResult
    private func task(_ storage: String, id: String, ui: [Any], files: [String: Any] = [:]) throws -> URL {
        let dir = root.appendingPathComponent(storage).appendingPathComponent("tasks").appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, object) in files {
            try JSONSerialization.data(withJSONObject: object).write(to: dir.appendingPathComponent(name))
        }
        let file = dir.appendingPathComponent("ui_messages.json")
        try JSONSerialization.data(withJSONObject: ui).write(to: file)
        return file
    }

    private func read(_ file: URL, _ flavor: ClineFlavor) -> [ParsedLine] {
        ClineTaskReader(flavor: flavor).read(file: file, context: LineContext(sourceFile: file.path, fallbackSessionId: "x"))
    }

    private func calls(_ lines: [ParsedLine]) -> [ParsedCall] {
        lines.compactMap { if case .call(let c) = $0 { return c } else { return nil } }
    }

    private func events(_ lines: [ParsedLine]) -> [EventRow] {
        lines.compactMap { if case .event(let e) = $0 { return e } else { return nil } }
    }

    private func envDetails(model: String, cwd: String? = nil) -> String {
        var s = "<environment_details>\n# Current Mode\n<slug>code</slug>\n<model>\(model)</model>\n"
        if let cwd { s += "\n\n# Current Workspace Directory (\(cwd)) Files\n" }
        return s + "</environment_details>"
    }

    // MARK: Roo Code / Kilo Code

    func testRooTotalInputIsSplitBackIntoFourCounters() throws {
        let file = try task("rooveterinaryinc.roo-cline", id: "t1", ui: [
            ["ts": after - 10, "type": "say", "say": "text", "text": "x"],
            apiReq(after, ["apiProtocol": "anthropic", "tokensIn": 51_000, "tokensOut": 300, "cacheReads": 48_000, "cacheWrites": 2_000]),
        ], files: [
            "api_conversation_history.json": [["role": "user", "ts": after + 5,
                                               "content": [["type": "text", "text": envDetails(model: "claude-sonnet-4-5", cwd: "/Users/dev/proj")]]]],
        ])
        let parsed = calls(read(file, .rooCode))
        XCTAssertEqual(parsed.count, 1)
        let call = parsed[0].call
        XCTAssertEqual(call.vendor, Vendor.rooCode)
        XCTAssertEqual(call.sessionId, "t1")
        XCTAssertEqual(call.input, 1_000, "whole prompt minus cache reads and writes")
        XCTAssertEqual(call.cacheRead, 48_000)
        XCTAssertEqual(call.cacheWrite, 2_000)
        XCTAssertEqual(call.output, 300)
        XCTAssertEqual(call.contextTokens, 51_000)
        XCTAssertEqual(call.model, "claude-sonnet-4-5", "from the request's environment details")
        XCTAssertEqual(call.windowLimit, 200_000)
        XCTAssertEqual(call.cwd, "/Users/dev/proj")
        XCTAssertEqual(call.project, "proj")
        XCTAssertEqual(call.confidence, Confidence.exact.rawValue)
        XCTAssertEqual(call.dedupeKey, "roo-code:t1:\(Int64(after))")
        XCTAssertEqual(call.ts, "2026-01-01T00:00:00.000Z")
    }

    func testRooBeforeTheSwitchAnthropicInputWasTheRemainder() throws {
        let file = try task("rooveterinaryinc.roo-cline", id: "t2", ui: [
            apiReq(before, ["apiProtocol": "anthropic", "tokensIn": 60_000, "tokensOut": 10, "cacheReads": 40_000, "cacheWrites": 0]),
            apiReq(before + 1, ["apiProtocol": "openai", "tokensIn": 60_000, "tokensOut": 10, "cacheReads": 40_000]),
            // Below the cached count it cannot be a total, whatever the date.
            apiReq(after, ["apiProtocol": "anthropic", "tokensIn": 5, "tokensOut": 10, "cacheReads": 40_000]),
        ])
        let parsed = calls(read(file, .rooCode)).map(\.call)
        XCTAssertEqual(parsed.map(\.input), [60_000, 20_000, 5])
        XCTAssertEqual(parsed.map(\.contextTokens), [100_000, 60_000, 40_005])
    }

    func testUnknownModelHasNoWindowAndPlaceholdersAreSkipped() throws {
        let file = try task("kilocode.kilo-code", id: "k1", ui: [
            apiReq(after, ["apiProtocol": "openai"]),                       // in flight: no counts yet
            ["ts": after + 1, "type": "say", "say": "api_req_started", "text": "{not json"],
            "garbage",
            ["type": "say", "say": "api_req_started"],                       // no ts
            apiReq(after + 2, ["tokensIn": 900, "tokensOut": 5], extra: ["partial": true]),
            apiReq(after + 3, ["tokensIn": 1_000, "tokensOut": 5]),
        ], files: [
            "api_conversation_history.json": [["role": "user", "ts": after, "content": envDetails(model: "some-vendor/mystery-model")]],
        ])
        let parsed = calls(read(file, .kiloCode)).map(\.call)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].vendor, Vendor.kiloCode)
        XCTAssertEqual(parsed[0].model, "some-vendor/mystery-model")
        XCTAssertNil(parsed[0].windowLimit, "never a guessed window (rule 3)")
        XCTAssertNil(parsed[0].occupancy)
        XCTAssertEqual(parsed[0].contextTokens, 1_000)
    }

    func testMalformedDocumentReadsAsNothing() throws {
        let dir = root.appendingPathComponent("rooveterinaryinc.roo-cline/tasks/bad")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("ui_messages.json")
        try Data("{\"half\": ".utf8).write(to: file)
        XCTAssertEqual(read(file, .rooCode), [])
        try Data("{\"not\": \"an array\"}".utf8).write(to: file)
        XCTAssertEqual(read(file, .rooCode), [])
    }

    func testToolsAttachToTheirRequestAndCondenseIsACompaction() throws {
        let file = try task("rooveterinaryinc.roo-cline", id: "t3", ui: [
            apiReq(after, ["tokensIn": 10_000, "tokensOut": 50]),
            ["ts": after + 10, "type": "ask", "ask": "tool", "text": json(["tool": "readFile", "path": "src/a.ts"])],
            ["ts": after + 11, "type": "ask", "ask": "command", "text": "npm test"],
            ["ts": after + 12, "type": "ask", "ask": "use_mcp_server",
             "text": json(["type": "use_mcp_tool", "serverName": "github", "toolName": "list_issues"])],
            ["ts": after + 13, "type": "say", "say": "tool", "text": json(["tool": "newTask"]), "partial": true],
            apiReq(after + 100, ["tokensIn": 4_000, "tokensOut": 50]),
            ["ts": after + 101, "type": "say", "say": "condense_context",
             "contextCondense": ["cost": 0.01, "prevContextTokens": 90_000, "newContextTokens": 4_000, "summary": "s"]],
            apiReq(after + 200, ["tokensIn": 5_000, "tokensOut": 50]),
            ["ts": after + 201, "type": "say", "say": "text", "text": "done"],
            ["ts": after + 300, "type": "say", "say": "condense_context",
             "contextCondense": ["cost": 0.01, "prevContextTokens": 5_000, "newContextTokens": 1_000, "summary": "s"]],
        ])
        let lines = read(file, .rooCode)
        let parsed = calls(lines)
        XCTAssertEqual(parsed.count, 3)
        XCTAssertEqual(parsed[0].toolCalls.map(\.name), ["readFile", "command", "mcp__github__list_issues"])
        XCTAssertEqual(parsed[0].toolCalls.map(\.target), ["src/a.ts", "npm test", nil])
        XCTAssertEqual(parsed[0].toolCalls.map(\.kind), ["builtin", "builtin", "mcp"])
        XCTAssertEqual(parsed[0].toolCalls[2].mcpServer, "github")
        XCTAssertTrue(parsed[0].toolCalls.allSatisfy { $0.callId == parsed[0].call.dedupeKey })

        let compactions = events(lines)
        XCTAssertEqual(compactions.count, 2)
        // Automatic: inside the second request's setup, so before that call.
        XCTAssertEqual(compactions[0].ts, ClineTaskReader.iso(after + 99))
        XCTAssertFalse(compactions[0].detail?.contains("\"s\"") ?? true, "summary text is not kept")
        // Manual: after the third request had produced output.
        XCTAssertEqual(compactions[1].ts, ClineTaskReader.iso(after + 300))
        // The event precedes the call it affects, so ingest nulls that delta.
        guard case .event = lines[1] else { return XCTFail("compaction should come before the second call") }
    }

    // MARK: Cline (classic)

    func testClineRemainderByDefaultTotalForOpenAICompatibleProviders() throws {
        let storage = "saoudrizwan.claude-dev"
        let file = try task(storage, id: "c1", ui: [
            apiReq(after, ["tokensIn": 3, "tokensOut": 400, "cacheReads": 30_000, "cacheWrites": 1_000],
                   extra: ["modelInfo": ["modelId": "claude-opus-4-5", "providerId": "anthropic", "mode": "act"]]),
            ["ts": after + 5, "type": "say", "say": "tool", "text": json(["tool": "editedExistingFile", "path": "a.swift"])],
            apiReq(after + 10, ["tokensIn": 50_000, "tokensOut": 400, "cacheReads": 30_000, "cacheWrites": 0],
                   extra: ["modelInfo": ["modelId": "claude-opus-4-5", "providerId": "anthropic", "mode": "act"]]),
            apiReq(after + 20, ["tokensIn": 50_000, "tokensOut": 400, "cacheReads": 30_000],
                   extra: ["modelInfo": ["modelId": "gpt-x", "providerId": "openai", "mode": "act"]]),
        ])
        try JSONSerialization.data(withJSONObject: [["id": "c1", "cwdOnTaskInitialization": "/Users/dev/app"]])
            .write(to: root.appendingPathComponent(storage).appendingPathComponent("state/taskHistory.json").creatingParent())

        let parsed = calls(read(file, .cline))
        XCTAssertEqual(parsed.map(\.call.input), [3, 50_000, 20_000])
        XCTAssertEqual(parsed.map(\.call.contextTokens), [31_003, 80_000, 50_000])
        XCTAssertEqual(parsed[0].call.model, "claude-opus-4-5")
        XCTAssertEqual(parsed[0].call.windowLimit, 200_000)
        XCTAssertNil(parsed[2].call.windowLimit)
        XCTAssertEqual(parsed[0].call.cwd, "/Users/dev/app")
        XCTAssertEqual(parsed[0].toolCalls.map(\.target), ["a.swift"])
    }

    func testClineModelFromTaskMetadataAndTruncationIsACompaction() throws {
        let file = try task("saoudrizwan.claude-dev", id: "c2", ui: [
            apiReq(after, ["tokensIn": 100, "tokensOut": 1]),
            ["ts": after + 1, "type": "say", "say": "text", "text": "a"],
            apiReq(after + 10, ["tokensIn": 100, "tokensOut": 1]),
            // The range changes during the second request's setup.
            ["ts": after + 11, "type": "say", "say": "text", "text": "b", "conversationHistoryDeletedRange": [2, 9]],
            apiReq(after + 20, ["tokensIn": 100, "tokensOut": 1], extra: ["conversationHistoryDeletedRange": [2, 9]]),
        ], files: [
            "task_metadata.json": ["model_usage": [
                ["ts": after - 100, "model_id": "claude-sonnet-4-5", "model_provider_id": "anthropic", "mode": "act"],
                ["ts": after + 15, "model_id": "claude-opus-4-5", "model_provider_id": "anthropic", "mode": "act"],
            ]],
        ])
        let lines = read(file, .cline)
        XCTAssertEqual(calls(lines).map(\.call.model), ["claude-sonnet-4-5", "claude-opus-4-5", "claude-opus-4-5"])
        let compactions = events(lines)
        XCTAssertEqual(compactions.count, 1)
        XCTAssertEqual(compactions[0].ts, ClineTaskReader.iso(after + 9))
    }

    // MARK: Cline (SDK sessions)

    private func session(_ id: String, stem: String? = nil, payload: [String: Any], manifest: [String: Any]? = nil) throws -> URL {
        let dir = root.appendingPathComponent(".cline/data/sessions").appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let manifest {
            try JSONSerialization.data(withJSONObject: manifest).write(to: dir.appendingPathComponent("\(id).json"))
        }
        let file = dir.appendingPathComponent("\(stem ?? id).messages.json")
        try JSONSerialization.data(withJSONObject: payload).write(to: file)
        return file
    }

    func testSdkSessionMetricsSubagentsAndCompaction() throws {
        let main = try session("s1", payload: [
            "version": 1, "agent": "lead", "sessionId": "s1",
            "messages": [
                ["id": "u1", "role": "user", "content": [["type": "text", "text": "hi"]], "ts": after],
                ["id": "a1", "role": "assistant", "ts": after + 1,
                 "modelInfo": ["id": "claude-sonnet-4-5", "provider": "anthropic"],
                 "metrics": ["inputTokens": 52_000, "outputTokens": 200, "cacheReadTokens": 50_000, "cacheWriteTokens": 1_500],
                 "content": [["type": "tool_use", "id": "tu1", "name": "read_files", "input": ["files": [["path": "/p/a.ts"]]]],
                             ["type": "tool_use", "id": "tu2", "name": "github__list_issues", "input": [:]]]],
                ["id": "c1", "role": "user", "content": [["type": "text", "text": "Context summary"]],
                 "metadata": ["kind": "compaction_summary", "tokensBefore": 150_000, "generatedAt": after + 2, "summary": "s"]],
                ["id": "e1", "role": "assistant", "ts": after + 3, "metadata": ["displayOnly": true], "content": []],
                ["id": "a2", "role": "assistant", "ts": after + 4, "content": []],
            ],
        ], manifest: ["session_id": "s1", "model": "claude-sonnet-4-5", "cwd": "/Users/dev/site"])
        let reader = ClineSessionReader()
        let lines = reader.read(file: main, context: LineContext(sourceFile: main.path, fallbackSessionId: "s1"))
        let parsed = calls(lines)
        XCTAssertEqual(parsed.count, 2, "display-only error messages are not calls")
        let first = parsed[0].call
        XCTAssertEqual(first.vendor, Vendor.cline)
        XCTAssertNil(first.agentId)
        XCTAssertEqual(first.input, 500, "SDK inputTokens includes cache")
        XCTAssertEqual(first.contextTokens, 52_000)
        XCTAssertEqual(first.windowLimit, 200_000)
        XCTAssertEqual(first.cwd, "/Users/dev/site")
        XCTAssertEqual(parsed[0].toolCalls.map(\.kind), ["builtin", "mcp"])
        XCTAssertEqual(parsed[0].toolCalls.map(\.target), ["/p/a.ts", nil])
        XCTAssertEqual(parsed[0].toolCalls[1].mcpServer, "github")
        XCTAssertEqual(parsed[1].call.confidence, Confidence.unmeasured.rawValue, "no usage, no figure")
        XCTAssertNil(parsed[1].call.windowLimit)
        XCTAssertEqual(events(lines).map(\.kind), [EventKind.compaction.rawValue])

        let sub = try session("s1", stem: "agent7", payload: [
            "agent": "subagent", "sessionId": "s1__agent7",
            "messages": [["id": "a1", "role": "assistant", "ts": after + 5,
                          "metrics": ["inputTokens": 9_000, "outputTokens": 10]]],
        ])
        let subCall = calls(reader.read(file: sub, context: LineContext(sourceFile: sub.path, fallbackSessionId: "agent7")))[0].call
        XCTAssertEqual(subCall.sessionId, "s1")
        XCTAssertEqual(subCall.agentId, "agent7", "its own window (rule 1)")
        XCTAssertEqual(subCall.model, "claude-sonnet-4-5", "falls back to the manifest")
        XCTAssertNotEqual(subCall.dedupeKey, first.dedupeKey)
    }

    // MARK: Ownership and ingest

    func testOwnershipIsPrecise() {
        let support = "/Users/dev/Library/Application Support"
        XCTAssertEqual(Harness.owning("\(support)/Code/User/globalStorage/saoudrizwan.claude-dev/tasks/1/ui_messages.json")?.id, Vendor.cline)
        XCTAssertEqual(Harness.owning("\(support)/Cursor/User/globalStorage/rooveterinaryinc.roo-cline/tasks/1/ui_messages.json")?.id, Vendor.rooCode)
        XCTAssertEqual(Harness.owning("/home/dev/.config/VSCodium/User/globalStorage/kilocode.kilo-code/tasks/1/ui_messages.json")?.id, Vendor.kiloCode)
        XCTAssertEqual(Harness.owning("/Users/dev/.cline/data/tasks/1/ui_messages.json")?.id, Vendor.cline)
        XCTAssertEqual(Harness.owning("/Users/dev/.cline/data/sessions/s1/s1.messages.json")?.id, Vendor.cline)
        XCTAssertEqual(Harness.owning("/Users/dev/.vscode-mock/global-storage/tasks/1/ui_messages.json")?.id, Vendor.rooCode)
        // Siblings and look-alikes are not transcripts.
        XCTAssertNil(Harness.owning("\(support)/Code/User/globalStorage/saoudrizwan.claude-dev/tasks/1/api_conversation_history.json"))
        XCTAssertNil(Harness.owning("\(support)/Code/User/globalStorage/saoudrizwan.claude-dev/tasks/1/task_metadata.json"))
        XCTAssertNil(Harness.owning("/Users/dev/.cline/data/sessions/s1/s1.json"))
        XCTAssertNil(Harness.owning("/Users/dev/elsewhere/tasks/1/ui_messages.json"))
        XCTAssertNil(Harness.owning("\(support)/Code/User/globalStorage/saoudrizwan.claude-dev/ui_messages.json"))
        XCTAssertEqual(Harness.owning("/Users/dev/.claude/projects/p/s.jsonl")?.id, Vendor.claudeCode)
    }

    func testCapabilitiesAreHonest() {
        for harness in [Harness.cline, .rooCode, .kiloCode] {
            XCTAssertFalse(harness.capabilities.verifiedOnDisk, "no task data on the Mac this was written on")
            XCTAssertEqual(harness.capabilities.window, .lookup)
            XCTAssertTrue(harness.capabilities.cacheSplit)
            XCTAssertTrue(Harness.all.contains(harness))
        }
        XCTAssertTrue(Harness.cline.capabilities.subagents)
        XCTAssertFalse(Harness.rooCode.capabilities.subagents)
    }

    func testIngestIsIdempotentAcrossRewrites() throws {
        let workspace = try TempWorkspace()
        root = workspace.root
        var ui: [Any] = [apiReq(after, ["tokensIn": 10_000, "tokensOut": 5])]
        let file = try task("rooveterinaryinc.roo-cline", id: "t9", ui: ui)
        let first = try workspace.ingestor.ingestDirectory(at: workspace.root)
        XCTAssertEqual(first.callsUpserted, 1)

        // The extension rewrites the whole array with one more request.
        ui.append(apiReq(after + 50, ["tokensIn": 12_000, "tokensOut": 5]))
        try JSONSerialization.data(withJSONObject: ui).write(to: file)
        try workspace.ingestor.ingestFile(at: file)
        try workspace.ingestor.ingestFile(at: file)

        let rows = try workspace.store.calls(sessionId: "t9")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.turnIndex), [0, 1])
        XCTAssertEqual(rows.last?.contextDelta, 2_000)
    }
}

private extension URL {
    func creatingParent() throws -> URL {
        try FileManager.default.createDirectory(at: deletingLastPathComponent(), withIntermediateDirectories: true)
        return self
    }
}

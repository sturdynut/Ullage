import Foundation
import XCTest
@testable import UllageCore

/// Pi writes pi-ai `Usage` on every assistant entry, `input` already the
/// uncached remainder, in a tree of entries that branches within one file.
final class HarnessPiTests: XCTestCase {
    private func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private func usage(_ input: Int, _ output: Int, _ read: Int, _ write: Int, reasoning: Int? = nil) -> [String: Any] {
        var u: [String: Any] = ["input": input, "output": output, "cacheRead": read, "cacheWrite": write,
                                "totalTokens": input + output + read + write,
                                "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": 0]]
        if let reasoning { u["reasoning"] = reasoning }
        return u
    }

    private func header(id: String = "sess-uuid", ts: String = "2026-09-12T09:00:00.000Z", parent: String? = nil) -> String {
        var h: [String: Any] = ["type": "session", "version": 3, "id": id, "timestamp": ts, "cwd": "/Users/dev/repo"]
        if let parent { h["parentSession"] = parent }
        return json(h)
    }

    private func assistant(id: String, parent: String?, ts: String, model: String = "claude-sonnet-4-5",
                           usage: [String: Any], content: [[String: Any]] = []) -> String {
        json(["type": "message", "id": id, "parentId": parent ?? NSNull(), "timestamp": ts,
              "message": ["role": "assistant", "content": content, "api": "anthropic-messages", "provider": "anthropic",
                          "model": model, "usage": usage, "stopReason": "toolUse", "thinkingLevel": "high",
                          "timestamp": 1_757_667_605_000]])
    }

    private var session: [String] {
        [
            header(),
            json(["type": "model_change", "id": "a0", "parentId": NSNull(), "timestamp": "2026-09-12T09:00:00.500Z",
                  "provider": "anthropic", "modelId": "claude-sonnet-4-5"]),
            json(["type": "message", "id": "u1", "parentId": "a0", "timestamp": "2026-09-12T09:00:01.000Z",
                  "message": ["role": "user", "content": "hi", "timestamp": 1]]),
            assistant(id: "b1", parent: "u1", ts: "2026-09-12T09:00:05.000Z", usage: usage(10, 200, 30_000, 1_500, reasoning: 50),
                      content: [["type": "toolCall", "id": "call_1", "name": "bash", "arguments": ["command": "ls -la"]],
                                ["type": "toolCall", "id": "call_2", "name": "mcp__github__get_issue", "arguments": [:]]]),
            json(["type": "message", "id": "r1", "parentId": "b1", "timestamp": "2026-09-12T09:00:06.000Z",
                  "message": ["role": "toolResult", "toolCallId": "call_1", "toolName": "bash",
                              "content": [["type": "text", "text": String(repeating: "x", count: 400)]], "isError": true,
                              "timestamp": 2]]),
            // A branch from u1: another real request in the same file.
            assistant(id: "b2", parent: "u1", ts: "2026-09-12T09:01:00.000Z", usage: usage(5, 20, 29_000, 0)),
            json(["type": "compaction", "id": "k1", "parentId": "b2", "timestamp": "2026-09-12T09:02:00.000Z",
                  "summary": "s", "firstKeptEntryId": "b2", "tokensBefore": 31_000]),
            json(["type": "usage", "id": "w1", "parentId": "k1", "timestamp": "2026-09-12T09:03:00.000Z", "kind": "cache_warm",
                  "provider": "anthropic", "model": "claude-sonnet-4-5", "usage": usage(0, 0, 50_000, 0)]),
            "{broken",
            json(["type": "some_future_entry", "id": "z", "parentId": "k1", "timestamp": "2026-09-12T09:04:00.000Z"]),
        ]
    }

    private func ingest(_ lines: [String], name: String = "2026-09-12T09-00-00-000Z_sess-uuid.jsonl",
                        in workspace: TempWorkspace) throws -> URL {
        let dir = workspace.root.appendingPathComponent(".pi/agent/sessions/--Users-dev-repo--", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        _ = try workspace.ingestor.ingestFile(at: file)
        return file
    }

    func testUsageMapsToTheFourCountersAndBranchesAreEachARow() throws {
        let workspace = try TempWorkspace()
        let file = try ingest(session, in: workspace)
        XCTAssertEqual(Harness.owning(file.path)?.id, Vendor.pi)

        let calls = try workspace.store.calls(sessionId: "sess-uuid")
        XCTAssertEqual(calls.map(\.dedupeKey), ["pi:sess-uuid:b1", "pi:sess-uuid:b2"], "cache_warm usage is not a turn")
        let first = calls[0]
        XCTAssertEqual(first.vendor, Vendor.pi)
        XCTAssertEqual([first.input, first.output, first.cacheRead, first.cacheWrite], [10, 200, 30_000, 1_500])
        XCTAssertEqual(first.contextTokens, 31_510)
        XCTAssertEqual(first.reasoning, 50)
        XCTAssertEqual(first.output, 200, "reasoning stays inside output, as reported")
        XCTAssertEqual(first.windowLimit, 200_000)
        XCTAssertEqual(first.confidence, Confidence.exact.rawValue)
        XCTAssertEqual(first.effort, "high")
        XCTAssertEqual(first.cwd, "/Users/dev/repo")
        XCTAssertEqual(first.project, "repo")
        XCTAssertEqual(first.ts, "2026-09-12T09:00:05.000Z")

        let tools = try workspace.store.toolCalls(sessionId: "sess-uuid")
        XCTAssertEqual(tools.map(\.name).sorted(), ["bash", "mcp__github__get_issue"])
        let bash = tools.first { $0.name == "bash" }
        XCTAssertEqual(bash?.target, "ls -la")
        XCTAssertEqual(bash?.isError, true)
        XCTAssertEqual(bash?.resultTokens, 100, "a length estimate (~4 bytes/token)")
        XCTAssertEqual(tools.first { $0.name.hasPrefix("mcp") }?.mcpServer, "github")

        let compactions = try workspace.store.events(sessionId: "sess-uuid", kind: EventKind.compaction.rawValue)
        XCTAssertEqual(compactions.map(\.id), ["pi:compaction:sess-uuid:k1"])
    }

    func testReReadIsIdempotent() throws {
        let workspace = try TempWorkspace()
        let file = try ingest(session, in: workspace)
        try ((session + [assistant(id: "b3", parent: "k1", ts: "2026-09-12T09:05:00.000Z", usage: usage(1, 1, 5_000, 0))])
            .joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        _ = try workspace.ingestor.ingestFile(at: file)
        _ = try workspace.ingestor.ingestFile(at: file)
        XCTAssertEqual(try workspace.store.calls(sessionId: "sess-uuid").count, 3)
    }

    func testUnknownModelGetsNoWindow() {
        let parser = PiParser()
        let context = LineContext(sourceFile: "/x/.pi/agent/sessions/--x--/t_s.jsonl", fallbackSessionId: "t_s")
        _ = parser.parse(line: Data(header().utf8), context: context)
        let out = parser.parse(line: Data(assistant(id: "b1", parent: nil, ts: "2026-09-12T09:00:05.000Z",
                                                    model: "some-local-model", usage: usage(100, 1, 0, 0)).utf8), context: context)
        guard case .call(let parsed)? = out else { return XCTFail("expected a call") }
        XCTAssertNil(parsed.call.windowLimit, "never the fallback window for a model Ullage doesn't know")
        XCTAssertEqual(parsed.call.contextTokens, 100)
    }

    func testZeroUsageAndMalformedLinesProduceNothing() {
        let parser = PiParser()
        let context = LineContext(sourceFile: "/x/.pi/agent/sessions/--x--/2026_abc.jsonl", fallbackSessionId: "2026_abc")
        XCTAssertNil(parser.parse(line: Data("nope".utf8), context: context))
        let aborted = assistant(id: "b0", parent: nil, ts: "2026-09-12T09:00:05.000Z", usage: usage(0, 0, 0, 0))
        XCTAssertNil(parser.parse(line: Data(aborted.utf8), context: context))
        // Without a header the session id comes from the file name.
        let real = assistant(id: "b1", parent: nil, ts: "2026-09-12T09:00:05.000Z", usage: usage(1, 1, 1, 1))
        guard case .call(let parsed)? = parser.parse(line: Data(real.utf8), context: context) else { return XCTFail() }
        XCTAssertEqual(parsed.call.sessionId, "abc")
    }

    func testForkCopiesAreCountedOnceInTheirOriginalSession() throws {
        let workspace = try TempWorkspace()
        let parent = try ingest(session, in: workspace)
        let fork = [header(id: "fork-uuid", ts: "2026-09-12T10:00:00.000Z", parent: parent.path)]
            + session.dropFirst()
            + [assistant(id: "f1", parent: "k1", ts: "2026-09-12T10:00:10.000Z", usage: usage(2, 2, 6_000, 0))]
        _ = try ingest(Array(fork), name: "2026-09-12T10-00-00-000Z_fork-uuid.jsonl", in: workspace)
        XCTAssertEqual(try workspace.store.calls(sessionId: "fork-uuid").map(\.dedupeKey), ["pi:fork-uuid:f1"])
        XCTAssertEqual(try workspace.store.calls(sessionId: "sess-uuid").count, 2)
    }

    func testOwnsAndCapabilities() {
        XCTAssertTrue(PiPaths.isPiTranscript("/Users/dev/.pi/agent/sessions/--Users-dev-repo--/t_s.jsonl"))
        XCTAssertFalse(PiPaths.isPiTranscript("/Users/dev/.pi/agent/settings.json"))
        XCTAssertFalse(PiPaths.isPiTranscript("/Users/dev/.claude/projects/-repo/abc.jsonl"))
        XCTAssertEqual(PiPaths.sessionsDirectories(environment: ["PI_CODING_AGENT_DIR": "/tmp/pa"]).first?.path, "/tmp/pa/sessions")
        XCTAssertEqual(PiPaths.sessionsDirectories(environment: ["PI_CODING_AGENT_SESSION_DIR": "/tmp/ps", "PI_CODING_AGENT_DIR": "/tmp/pa"]).first?.path, "/tmp/ps")
        let caps = Harness.pi.capabilities
        XCTAssertTrue(caps.hasGauge)
        XCTAssertEqual(caps.window, .lookup)
        XCTAssertFalse(caps.verifiedOnDisk)
    }
}

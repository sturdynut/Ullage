import Foundation
import XCTest
@testable import UllageCore

/// Droid records no per-call tokens (only a session total in settings.json),
/// so its rows are activity only and never carry a window.
final class HarnessDroidTests: XCTestCase {
    private let path = "/Users/dev/.factory/sessions/-Users-dev-repo/3f2a.jsonl"
    private var context: LineContext {
        LineContext(sourceFile: path, fallbackSessionId: "3f2a", fileModified: "2026-09-12T10:00:00.000Z")
    }

    private func line(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    private let fixture: [[String: Any]] = [
        ["type": "session_start", "id": "sess-1", "title": "t", "cwd": "/Users/dev/repo"],
        ["type": "message", "id": "m1", "timestamp": "2026-09-12T09:00:00Z",
         "message": ["role": "user", "content": [["type": "text", "text": "x"]]]],
        ["type": "message", "id": "m2", "timestamp": "2026-09-12T09:00:05Z",
         "message": ["role": "assistant", "content": [
            ["type": "text", "text": "y"],
            ["type": "tool_use", "id": "tu1", "name": "Execute", "input": ["command": "swift build"]],
            ["type": "tool_use", "id": "tu2", "name": "mcp__github__get_issue", "input": [:]],
         ]]],
        ["type": "compaction_state", "id": "c1", "timestamp": "2026-09-12T09:10:00Z"],
    ]

    func testAssistantMessageIsAnUnmeasuredActivityRow() {
        let parser = DroidParser()
        let out = fixture.map { parser.parse(line: line($0), context: context) }
        XCTAssertNil(out[0]); XCTAssertNil(out[1])
        guard case .call(let parsed)? = out[2] else { return XCTFail("expected a call") }
        let call = parsed.call
        XCTAssertEqual(call.vendor, Vendor.droid)
        XCTAssertEqual(call.sessionId, "sess-1")
        XCTAssertEqual(call.cwd, "/Users/dev/repo")
        XCTAssertEqual(call.project, "repo")
        XCTAssertEqual(call.ts, "2026-09-12T09:00:05.000Z")
        XCTAssertEqual(call.dedupeKey, "droid:sess-1:m2")
        XCTAssertEqual(call.confidence, Confidence.unmeasured.rawValue)
        XCTAssertEqual([call.input, call.output, call.cacheRead, call.cacheWrite, call.contextTokens], [0, 0, 0, 0, 0])
        XCTAssertNil(call.windowLimit)
        XCTAssertNil(call.occupancy)
        XCTAssertNil(call.model)
        XCTAssertEqual(parsed.toolCalls.map(\.name), ["Execute", "mcp__github__get_issue"])
        XCTAssertEqual(parsed.toolCalls[0].target, "swift build")
        XCTAssertEqual(parsed.toolCalls[1].kind, ToolKind.mcp.rawValue)
        XCTAssertEqual(parsed.toolCalls[1].mcpServer, "github")

        guard case .event(let event)? = out[3] else { return XCTFail("expected compaction") }
        XCTAssertEqual(event.kind, EventKind.compaction.rawValue)
        XCTAssertEqual(event.id, "droid:compaction:sess-1:c1")
    }

    func testMalformedAndUnknownLinesAreSkipped() {
        let parser = DroidParser()
        XCTAssertNil(parser.parse(line: Data("{not json".utf8), context: context))
        XCTAssertNil(parser.parse(line: line(["type": "todo_state", "x": 1]), context: context))
        XCTAssertNil(parser.parse(line: line(["type": "message"]), context: context))
        XCTAssertNil(parser.parse(line: line(["type": "message", "message": "nope"]), context: context))
    }

    func testReingestIsIdempotent() throws {
        let workspace = try TempWorkspace()
        let dir = workspace.root.appendingPathComponent(".factory/sessions/-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let text = fixture.map { String(decoding: line($0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        let file = dir.appendingPathComponent("3f2a.jsonl")
        try text.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(Harness.owning(file.path)?.id, Vendor.droid)
        _ = try workspace.ingestor.ingestFile(at: file)
        try (text + "\n").write(to: file, atomically: true, encoding: .utf8)
        _ = try workspace.ingestor.ingestFile(at: file)
        XCTAssertEqual(try workspace.store.calls(sessionId: "sess-1").count, 1)
    }

    func testOwnsOnlyDroidSessions() {
        XCTAssertTrue(DroidPaths.isDroidTranscript(path))
        XCTAssertFalse(DroidPaths.isDroidTranscript("/Users/dev/.factory/sessions/-repo/3f2a.settings.json"))
        XCTAssertFalse(DroidPaths.isDroidTranscript("/Users/dev/.claude/projects/-repo/abc.jsonl"))
        XCTAssertFalse(DroidPaths.isDroidTranscript("/Users/dev/.factory/logs/x.jsonl"))
        XCTAssertEqual(Harness.owning("/Users/dev/.claude/projects/-repo/abc.jsonl")?.id, Vendor.claudeCode)
    }

    func testCapabilitiesAreHonest() {
        let caps = Harness.droid.capabilities
        XCTAssertFalse(caps.hasGauge)
        XCTAssertEqual(caps.occupancy, .none)
        XCTAssertFalse(caps.verifiedOnDisk)
        XCTAssertEqual(DroidPaths.sessionsDirectories(environment: ["FACTORY_DIR": "/tmp/f"]).first?.path, "/tmp/f/sessions")
    }
}

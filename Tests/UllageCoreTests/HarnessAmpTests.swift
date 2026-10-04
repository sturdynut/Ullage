import Foundation
import XCTest
@testable import UllageCore

/// Amp threads are whole JSON documents: ledger events per request, cache
/// counts on the billed message, a per-message fallback without a ledger.
final class HarnessAmpTests: XCTestCase {
    private let created = 1_757_667_600_000.0   // 2025-09-12T09:00:00Z

    private func thread(ledger: Bool = true, unjoined: Bool = false) -> [String: Any] {
        var t: [String: Any] = [
            "id": "T-abc",
            "created": created,
            "title": "t",
            "env": ["initial": ["trees": [["displayName": "repo", "uri": "file:///Users/dev/repo"]]]],
            "messages": [
                ["role": "user", "messageId": 0, "content": [["type": "text", "text": "x"]], "meta": ["sentAt": created]],
                ["role": "assistant", "messageId": 1, "content": [
                    ["type": "text", "text": "y"],
                    ["type": "tool_use", "id": "toolu_1", "name": "Bash", "complete": true, "input": ["cmd": "make", "cwd": "/Users/dev/repo"]],
                    ["type": "tool_use", "id": "toolu_2", "name": "edit_file", "complete": true, "input": ["path": "/Users/dev/repo/a.swift"]],
                 ], "usage": ["model": "claude-sonnet-4-5", "inputTokens": 10, "outputTokens": 178,
                              "cacheCreationInputTokens": 986, "cacheReadInputTokens": 11_372, "totalInputTokens": 12_368,
                              "timestamp": "2025-09-12T09:00:05.000Z"]],
                ["role": "user", "messageId": 2, "content": [
                    ["type": "tool_result", "toolUseID": "toolu_1", "run": ["status": "error", "result": ["output": String(repeating: "z", count: 400)]]],
                ]],
                ["role": "assistant", "messageId": 3, "content": [["type": "text", "text": "done"]],
                 "usage": ["model": "claude-sonnet-4-5", "inputTokens": 5, "outputTokens": 42,
                           "cacheCreationInputTokens": 0, "cacheReadInputTokens": 12_400,
                           "timestamp": "2025-09-12T09:00:20.000Z"]],
            ],
        ]
        if ledger {
            var events: [[String: Any]] = [
                ["id": "ev1", "timestamp": "2025-09-12T09:00:06.000Z", "model": "claude-sonnet-4-5",
                 "tokens": ["input": 10, "output": 178], "operationType": "inference", "fromMessageId": 0, "toMessageId": 1, "credits": 1.2],
                ["id": "ev2", "timestamp": "2025-09-12T09:00:21.000Z", "model": "claude-sonnet-4-5",
                 "tokens": ["input": 5, "output": 42], "toMessageId": 3],
            ]
            if unjoined {
                events.append(["id": "ev3", "timestamp": "2025-09-12T09:00:30.000Z", "model": "claude-haiku-4-5",
                               "tokens": ["input": 300, "output": 10]])
            }
            t["usageLedger"] = ["events": events]
        }
        return t
    }

    private func context(_ path: String = "/Users/dev/.local/share/amp/threads/T-abc.json") -> LineContext {
        LineContext(sourceFile: path, fallbackSessionId: "T-abc", fileModified: "2025-09-12T10:00:00.000Z")
    }

    private func calls(_ lines: [ParsedLine]) -> [ParsedCall] {
        lines.compactMap { if case .call(let c) = $0 { return c } else { return nil } }
    }

    func testLedgerEventsJoinCacheFromTheBilledMessage() {
        let out = AmpThreadReader.parse(thread: thread(), context: context())
        let rows = calls(out)
        XCTAssertEqual(rows.map(\.call.dedupeKey), ["amp:T-abc:m1", "amp:T-abc:m3"])
        let first = rows[0].call
        XCTAssertEqual(first.vendor, Vendor.amp)
        XCTAssertEqual([first.input, first.output, first.cacheRead, first.cacheWrite], [10, 178, 11_372, 986])
        XCTAssertEqual(first.contextTokens, 12_368, "equals Amp's own totalInputTokens")
        XCTAssertEqual(first.windowLimit, 200_000)
        XCTAssertEqual(first.confidence, Confidence.exact.rawValue)
        XCTAssertEqual(first.ts, "2025-09-12T09:00:06.000Z")
        XCTAssertEqual(first.cwd, "/Users/dev/repo")
        XCTAssertEqual(first.project, "repo")
        XCTAssertEqual(rows[0].toolCalls.map(\.target), ["make", "/Users/dev/repo/a.swift"])

        let results = out.compactMap { if case .toolResults(let r) = $0 { return r } else { return nil } }.flatMap { $0 }
        XCTAssertEqual(results.map(\.toolUseId), ["toolu_1"])
        XCTAssertEqual(results.first?.isError, true)
    }

    func testThreadWithoutLedgerUsesMessageUsageWithTheSameKeys() {
        let rows = calls(AmpThreadReader.parse(thread: thread(ledger: false), context: context()))
        XCTAssertEqual(rows.map(\.call.dedupeKey), ["amp:T-abc:m1", "amp:T-abc:m3"],
                       "same keys as the ledger path, so a thread that gains a ledger keeps its rows")
        XCTAssertEqual(rows[1].call.contextTokens, 12_405)
        XCTAssertEqual(rows[1].call.ts, "2025-09-12T09:00:20.000Z")
    }

    func testUnjoinedEventIsEstimatedWithNoWindow() {
        let rows = calls(AmpThreadReader.parse(thread: thread(unjoined: true), context: context()))
        let orphan = rows.first { $0.call.dedupeKey == "amp:T-abc:eev3" }?.call
        XCTAssertEqual(orphan?.confidence, Confidence.estimated.rawValue)
        XCTAssertNil(orphan?.windowLimit, "no cache counts means the prompt size is unknown")
        XCTAssertEqual(orphan?.cacheRead, 0)
    }

    func testMalformedDocumentsAreSkipped() throws {
        XCTAssertTrue(AmpThreadReader.parse(thread: ["id": "T-x", "messages": "nope", "usageLedger": 3], context: context()).isEmpty)
        XCTAssertTrue(AmpThreadReader.parse(thread: ["id": "T-x", "messages": [1, "a", ["role": "assistant"]]], context: context()).isEmpty)
        let workspace = try TempWorkspace()
        let dir = workspace.root.appendingPathComponent(".local/share/amp/threads", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("T-bad.json")
        try "{truncated".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(AmpThreadReader().read(file: file, context: context(file.path)), [])
    }

    func testReingestIsIdempotent() throws {
        let workspace = try TempWorkspace()
        let dir = workspace.root.appendingPathComponent(".local/share/amp/threads", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("T-abc.json")
        try JSONSerialization.data(withJSONObject: thread(ledger: false)).write(to: file)
        XCTAssertEqual(Harness.owning(file.path)?.id, Vendor.amp)
        _ = try workspace.ingestor.ingestFile(at: file)
        try JSONSerialization.data(withJSONObject: thread()).write(to: file)
        _ = try workspace.ingestor.ingestFile(at: file)
        _ = try workspace.ingestor.ingestFile(at: file)
        XCTAssertEqual(try workspace.store.calls(sessionId: "T-abc").count, 2)
        let bash = try workspace.store.toolCalls(sessionId: "T-abc").first { $0.name == "Bash" }
        XCTAssertEqual(bash?.isError, true)
        XCTAssertNotNil(bash?.resultTokens)
    }

    func testOwnsAndCapabilities() {
        XCTAssertTrue(AmpPaths.isAmpThread("/Users/dev/.local/share/amp/threads/T-1.json"))
        XCTAssertFalse(AmpPaths.isAmpThread("/Users/dev/.local/share/amp/settings.json"))
        XCTAssertFalse(AmpPaths.isAmpThread("/Users/dev/.local/share/amp/threads/T-1.jsonl"))
        XCTAssertFalse(AmpPaths.isAmpThread("/Users/dev/.claude/projects/x/threads/a.json"))
        XCTAssertEqual(AmpPaths.threadsDirectories(environment: ["AMP_DATA_DIR": "/a, /b"]).map(\.path), ["/a/threads", "/b/threads"])
        XCTAssertEqual(AmpPaths.threadsDirectories(environment: ["XDG_DATA_HOME": "/x"]).map(\.path), ["/x/amp/threads"])
        XCTAssertFalse(Harness.amp.capabilities.verifiedOnDisk)
        XCTAssertTrue(Harness.amp.capabilities.cacheSplit)
    }
}

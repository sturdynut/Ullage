import Foundation
import XCTest

@testable import UllageCore

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

final class SessionPlaybackTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: directory)
  }

  private func write(_ rows: [[String: Any]], to name: String = "session.jsonl") throws -> URL {
    let url = directory.appendingPathComponent(name)
    var data = Data()
    for row in rows {
      data.append(try JSONSerialization.data(withJSONObject: row))
      data.append(10)
    }
    try data.write(to: url)
    return url
  }

  private func claude(_ id: String = "m1") -> [String: Any] {
    [
      "type": "assistant", "sessionId": "s1", "timestamp": "2026-10-15T10:00:00Z",
      "message": [
        "id": id,
        "content": [
          ["type": "text", "text": "Recorded answer"],
          ["type": "tool_use", "id": id == "m1" ? "t1" : "t-\(id)", "name": "Read", "input": ["file_path": "/example"]]
        ],
        "usage": ["input_tokens": 3, "output_tokens": 2, "cache_read_input_tokens": 10]
      ]
    ]
  }
  func testClaudeCallsResultsAndUsageKeepRecordedContentsAndPartialLabel() throws {
    let url = try write([
      claude(),
      [
        "type": "user", "sessionId": "s1",
        "message": [
          "content": [
            ["type": "tool_result", "tool_use_id": "t1", "content": "Original file text"]
          ]
        ]
      ]
    ])
    let result = SessionPlaybackReader().read(
      sessionId: "s1", sources: [PlaybackSource(path: url.path, vendor: Vendor.claudeCode)])
    XCTAssertEqual(result.events.count, 4)
    XCTAssertEqual(
      result.events.first(where: { $0.kind == .toolResult })?.text, "Original file text")
    XCTAssertEqual(result.events.first(where: { $0.kind == .toolCall })?.toolCallId, "t1")
    XCTAssertTrue(result.events.first(where: { $0.kind == .toolCall })!.text.contains("/example"))
    XCTAssertEqual(result.events.first(where: { $0.kind == .usage })?.usage?.contextTokens, 13)
    XCTAssertTrue(
      result.events.allSatisfy {
        $0.source == .transcript && $0.completeness == .partial && $0.snapshot == nil
      })
  }
  func testCodexMetadataIdentityToolArgumentsResultsAndWholePromptUsage() throws {
    let url = try write([
      ["type": "session_meta", "payload": ["id": "s1"]],
      [
        "type": "response_item",
        "payload": [
          "type": "function_call", "call_id": "t1", "name": "exec_command",
          "arguments": "{\"cmd\":\"pwd\"}"
        ]
      ],
      [
        "type": "response_item",
        "payload": ["type": "function_call_output", "call_id": "t1", "output": "original result"]
      ],
      [
        "type": "event_msg",
        "payload": [
          "type": "token_count",
          "info": [
            "model_context_window": 200,
            "last_token_usage": [
              "input_tokens": 100, "cached_input_tokens": 60, "output_tokens": 5
            ]
          ]
        ]
      ]
    ])
    let source = PlaybackSource(path: url.path, vendor: Vendor.codex)
    let reader = SessionPlaybackReader()
    let result = reader.read(sessionId: "s1", sources: [source])
    XCTAssertEqual(result.events.count, 3)
    XCTAssertEqual(result.events.first(where: { $0.kind == .toolCall })?.text, "{\"cmd\":\"pwd\"}")
    XCTAssertEqual(result.events.first(where: { $0.kind == .toolResult })?.text, "original result")
    XCTAssertEqual(result.events.first(where: { $0.kind == .usage })?.usage?.input, 40)
    XCTAssertEqual(result.events.first(where: { $0.kind == .usage })?.usage?.contextTokens, 100)
    XCTAssertTrue(reader.read(sessionId: "different", sources: [source]).events.isEmpty)
  }
  func testAppendKeepsIdentitiesAndWaitsForPartialLineAndDeletionDropsCache() throws {
    let url = try write([claude()])
    let reader = SessionPlaybackReader()
    let source = PlaybackSource(path: url.path, vendor: Vendor.claudeCode)
    let before = reader.read(sessionId: "s1", sources: [source])
    let next = try JSONSerialization.data(withJSONObject: claude("m2"))
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: next.prefix(20))
    let partial = reader.read(sessionId: "s1", sources: [source])
    XCTAssertEqual(partial.events, before.events)
    XCTAssertEqual(partial.pendingLineCount, 1)
    try handle.write(contentsOf: next.dropFirst(20) + Data([10]))
    try handle.close()
    let after = reader.read(sessionId: "s1", sources: [source])
    XCTAssertEqual(
      Set(before.events.map(\.id)).intersection(after.events.map(\.id)).count, before.events.count)
    XCTAssertEqual(after.events.count, 6)
    try FileManager.default.removeItem(at: url)
    let deleted = reader.read(sessionId: "s1", sources: [source])
    XCTAssertTrue(deleted.events.isEmpty)
    XCTAssertTrue(deleted.notices.contains(where: { $0.contains("missing") }))
  }
  func testCapturedRequestJoinsOnlyMatchingSessionAndMessageAndLoadsLazily() throws {
    let transcript = try write([claude()])
    let request = try writeBody([
      "model": "claude", "messages": [["role": "user", "content": "Historical prompt"]]
    ])
    _ = try write(
      [
        ["session_id": "other", "message_id": "m1", "request_file": request.path],
        ["session_id": "s1", "message_id": "missing", "request_file": request.path],
        ["session_id": "s1", "message_id": "m1", "request_file": request.path]
      ], to: "index.jsonl")
    let reader = SessionPlaybackReader()
    let result = reader.read(
      sessionId: "s1", sources: [PlaybackSource(path: transcript.path, vendor: Vendor.claudeCode)],
      recordingDirectory: directory)
    let requests = result.events.filter { $0.kind == .request }
    XCTAssertEqual(requests.count, 1)
    XCTAssertNil(requests[0].snapshot?.body)
    XCTAssertEqual(requests[0].source, .capturedRequest)
    let loaded = reader.requestSnapshot(for: requests[0], recordingDirectory: directory)
    XCTAssertTrue(loaded?.body?.contains("Historical prompt") == true)
    XCTAssertEqual(loaded?.completeness, .redacted)
    try FileManager.default.removeItem(at: request)
    let missing = reader.requestSnapshot(for: requests[0], recordingDirectory: directory)
    XCTAssertNil(missing?.body)
    XCTAssertEqual(missing?.completeness, .partial)
    XCTAssertNotNil(missing?.notice)
  }

  private func writeBody(_ body: [String: Any], name: String = "one.request.json") throws -> URL {
    let url = directory.appendingPathComponent(name)
    try JSONSerialization.data(withJSONObject: body).write(to: url)
    return url
  }
  func testCaptureRejectsTraversalAndSymlinkEscapeAndRechecksAtSelection() throws {
    let transcript = try write([claude()])
    let outer = directory.deletingLastPathComponent().appendingPathComponent(
      UUID().uuidString + ".json")
    try Data("secret sentinel".utf8).write(to: outer)
    defer { try? FileManager.default.removeItem(at: outer) }
    let link = directory.appendingPathComponent("link.request.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outer)
    _ = try write(
      [
        ["session_id": "s1", "message_id": "m1", "request_file": "../" + outer.lastPathComponent],
        ["session_id": "s1", "message_id": "m1", "request_file": link.path]
      ], to: "index.jsonl")
    let reader = SessionPlaybackReader()
    let result = reader.read(
      sessionId: "s1", sources: [PlaybackSource(path: transcript.path, vendor: Vendor.claudeCode)],
      recordingDirectory: directory)
    XCTAssertFalse(result.events.contains(where: { $0.kind == .request }))
    XCTAssertTrue(result.notices.contains(where: { $0.contains("Rejected") }))
    let forged = PlaybackEvent(
      id: "fake", kind: .request, title: "",
      snapshot: PlaybackRequestSnapshot(sourcePath: link.path))
    let loaded = reader.requestSnapshot(for: forged, recordingDirectory: directory)
    XCTAssertNil(loaded?.body)
    XCTAssertTrue(loaded?.notice?.contains("outside") == true)
  }
  func testMalformedCaptureAndUnsupportedSourcesAreHonest() throws {
    let body = try writeBody(["unrelated": "not a request"])
    let event = PlaybackEvent(
      id: "test", kind: .request, title: "",
      snapshot: PlaybackRequestSnapshot(sourcePath: body.path))
    let reader = SessionPlaybackReader()
    let snapshot = reader.requestSnapshot(for: event, recordingDirectory: directory)
    XCTAssertNil(snapshot?.body)
    XCTAssertEqual(snapshot?.completeness, .partial)
    XCTAssertTrue(snapshot?.notice?.contains("unsupported") == true)
    let result = reader.read(
      sessionId: "s1", sources: [PlaybackSource(path: "/unused", vendor: Vendor.cursor)])
    XCTAssertTrue(result.events.isEmpty)
    XCTAssertTrue(result.notices.contains(where: { $0.contains("unavailable") }))
  }

}

extension SessionPlaybackTests {
  func testCounterOverflowDoesNotCrashOrInventContextTotal() throws {
    var row = claude()
    var message = try XCTUnwrap(row["message"] as? [String: Any])
    message["usage"] = ["input_tokens": Int.max, "cache_read_input_tokens": 1]
    row["message"] = message
    let url = try write([row])
    let result = SessionPlaybackReader().read(
      sessionId: "s1", sources: [PlaybackSource(path: url.path, vendor: Vendor.claudeCode)])
    XCTAssertNil(result.events.first(where: { $0.kind == .usage })?.usage?.contextTokens)
    let codex = try write(
      [
        ["type": "session_meta", "payload": ["id": "s1"]],
        [
          "type": "event_msg",
          "payload": [
            "type": "token_count",
            "info": [
              "last_token_usage": [
                "input_tokens": Int.max, "cached_input_tokens": Int.max,
                "cache_write_input_tokens": Int.max
              ]
            ]
          ]
        ]
      ], to: "codex.jsonl")
    let malformed = SessionPlaybackReader().read(
      sessionId: "s1", sources: [PlaybackSource(path: codex.path, vendor: Vendor.codex)])
    XCTAssertNil(malformed.events.first?.usage?.input)
  }
  func testCaptureFIFOIsRejectedWithoutBlocking() throws {
    let fifo = directory.appendingPathComponent("pipe.request.json")
    XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
    let event = PlaybackEvent(
      id: "test", kind: .request, title: "",
      snapshot: PlaybackRequestSnapshot(sourcePath: fifo.path))
    let loaded = SessionPlaybackReader().requestSnapshot(for: event, recordingDirectory: directory)
    XCTAssertNil(loaded?.body)
    XCTAssertNotNil(loaded?.notice)
  }
  func testMixedTimestampPrecisionAndOffsetsAreChronological() throws {
    var later = claude("later")
    later["timestamp"] = "2026-10-15T10:00:00.100Z"
    var earlier = claude("earlier")
    earlier["timestamp"] = "2026-10-15T03:00:00-07:00"
    let url = try write([later, earlier])
    let result = SessionPlaybackReader().read(
      sessionId: "s1", sources: [PlaybackSource(path: url.path, vendor: Vendor.claudeCode)])
    XCTAssertEqual(result.events.first?.messageId, "earlier")
    XCTAssertEqual(result.events.last?.messageId, "later")
  }
  func testReplacingSourceDoesNotReuseStaleSelectedEventIdentity() throws {
    let url = try write([claude()])
    let source = PlaybackSource(path: url.path, vendor: Vendor.claudeCode)
    let reader = SessionPlaybackReader()
    let original = reader.read(sessionId: "s1", sources: [source])
    try FileManager.default.removeItem(at: url)
    _ = try write([claude("replacement")])
    let replaced = reader.read(sessionId: "s1", sources: [source])
    XCTAssertTrue(Set(original.events.map(\.id)).isDisjoint(with: replaced.events.map(\.id)))
  }
  func testStreamingAssistantUpdatesPreserveRecordedBlocksAndOneUsage() throws {
    let url = try write([claude()])
    let source = PlaybackSource(path: url.path, vendor: Vendor.claudeCode)
    let reader = SessionPlaybackReader()
    let before = reader.read(sessionId: "s1", sources: [source])
    var update = claude()
    var message = try XCTUnwrap(update["message"] as? [String: Any])
    message["content"] = [["type": "text", "text": "Final recorded answer"]]
    update["message"] = message
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: JSONSerialization.data(withJSONObject: update) + Data([10]))
    try handle.close()
    let after = reader.read(sessionId: "s1", sources: [source])
    XCTAssertEqual(after.events.filter { $0.kind == .usage }.count, 1)
    XCTAssertTrue(after.events.contains { $0.text == "Final recorded answer" })
    XCTAssertTrue(after.events.contains { $0.kind == .toolCall && $0.toolCallId == "t1" })
    XCTAssertEqual(
      before.events.first(where: { $0.kind == .message })?.id,
      after.events.first(where: { $0.kind == .message })?.id)
  }
  func testLargePlaybackHasExplicitRollingHistoryOmissionNotice() throws {
    let rows: [[String: Any]] = (0..<10_005).map { index in
      ["type": "user", "sessionId": "s1", "message": ["content": "message \(index)"]]
    }
    let url = try write(rows)
    let reader = SessionPlaybackReader()
    let source = PlaybackSource(path: url.path, vendor: Vendor.claudeCode)
    let started = Date()
    let result = reader.read(sessionId: "s1", sources: [source])
    XCTAssertEqual(result.events.count, 10_000)
    XCTAssertTrue(
      result.notices.contains(where: { $0.contains("Earlier playback content omitted") }))
    XCTAssertEqual(reader.read(sessionId: "s1", sources: [source]).events.count, 10_000)
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    XCTAssertLessThan(
      Date().timeIntervalSince(started), 10, "10k short records should remain interactive")
  }
  func testSeparateStreamedToolBlocksAreRetainedAndUsageIsUpdatedOnce() throws {
    let rows: [[String: Any]] = [
      [
        "type": "assistant", "sessionId": "s1",
        "message": [
          "id": "m1",
          "content": [
            ["type": "text", "text": "First recorded text"]
          ]
        ]
      ],
      [
        "type": "assistant", "sessionId": "s1",
        "message": [
          "id": "m1",
          "content": [
            ["type": "tool_use", "id": "t1", "name": "Read", "input": ["file_path": "one"]]
          ],
          "usage": ["input_tokens": 10]
        ]
      ],
      [
        "type": "assistant", "sessionId": "s1",
        "message": [
          "id": "m1",
          "content": [
            ["type": "tool_use", "id": "t2", "name": "Read", "input": ["file_path": "two"]]
          ],
          "usage": ["input_tokens": 12]
        ]
      ]
    ]
    let url = try write(rows)
    let result = SessionPlaybackReader().read(
      sessionId: "s1", sources: [PlaybackSource(path: url.path, vendor: Vendor.claudeCode)])
    XCTAssertTrue(result.events.contains { $0.text == "First recorded text" })
    XCTAssertEqual(Set(result.events.compactMap(\.toolCallId)), ["t1", "t2"])
    XCTAssertEqual(result.events.filter { $0.kind == .usage }.count, 1)
    XCTAssertEqual(result.events.first(where: { $0.kind == .usage })?.usage?.contextTokens, 12)
  }
  func testStoreFindsOnlySelectedSessionSourcesAcrossAgents() throws {
    let store = try Store(path: directory.appendingPathComponent("test.db").path)
    try store.upsert(
      call: CallRow(
        dedupeKey: "a", ts: "t", sessionId: "s1", contextTokens: 1,
        sourceFile: "/main.jsonl"))
    try store.upsert(
      call: CallRow(
        dedupeKey: "b", ts: "t", agentId: "child", sessionId: "s1",
        contextTokens: 1, sourceFile: "/child.jsonl"))
    try store.upsert(
      call: CallRow(
        dedupeKey: "c", ts: "t", sessionId: "s2", contextTokens: 1,
        sourceFile: "/other.jsonl"))
    try store.upsert(
      call: CallRow(
        dedupeKey: "d", ts: "t", agentId: "child", sessionId: "s1",
        contextTokens: 1, sourceFile: "/main.jsonl"))
    XCTAssertEqual(
      try store.playbackSources(sessionId: "s1"),
      [
        PlaybackSource(path: "/child.jsonl", vendor: Vendor.claudeCode, agentId: "child"),
        PlaybackSource(path: "/main.jsonl", vendor: Vendor.claudeCode)
      ])
  }
  func testOversizedLineIsOmittedAndNextLineRecoversWithoutClaimingCompleteness() throws {
    let url = directory.appendingPathComponent("oversized.jsonl")
    var data = Data(repeating: 120, count: 16 * 1_024 * 1_024 + 1)
    data.append(10)
    data.append(try JSONSerialization.data(withJSONObject: claude()))
    data.append(10)
    try data.write(to: url)
    let result = SessionPlaybackReader().read(
      sessionId: "s1", sources: [PlaybackSource(path: url.path, vendor: Vendor.claudeCode)])
    XCTAssertEqual(result.events.count, 3)
    XCTAssertTrue(result.notices.contains { $0.contains("exceeding 16 MiB") })
    let bodyEvent = PlaybackEvent(
      id: "large", kind: .request, title: "",
      snapshot: PlaybackRequestSnapshot(sourcePath: url.path))
    let body = SessionPlaybackReader().requestSnapshot(
      for: bodyEvent, recordingDirectory: directory)
    XCTAssertNil(body?.body)
    XCTAssertEqual(body?.completeness, .partial)
    XCTAssertTrue(body?.notice?.contains("16 MiB") == true)
  }
}

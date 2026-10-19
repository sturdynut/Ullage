import Foundation
import XCTest

@testable import UllageCore

final class PlaybackCounterValidityTests: XCTestCase {
  func testAbsentCacheDefaultsToZeroButPresentInvalidCacheInvalidatesDerivedCounters() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("session.jsonl")
    for cache in [nil, -1, "invalid", NSNull()] as [Any?] {
      var claudeUsage: [String: Any] = ["input_tokens": 100]
      var codexUsage: [String: Any] = ["input_tokens": 100]
      if let cache {
        claudeUsage["cache_read_input_tokens"] = cache
        codexUsage["cached_input_tokens"] = cache
      }
      let claude: [String: Any] = [
        "sessionId": "s1", "type": "assistant",
        "message": ["id": "m1", "usage": claudeUsage]
      ]
      try line(claude).write(to: file)
      let claudeResult = SessionPlaybackReader().read(
        sessionId: "s1",
        sources: [
          PlaybackSource(path: file.path, vendor: Vendor.claudeCode)
        ])
      XCTAssertEqual(claudeResult.events.first?.usage?.contextTokens, cache == nil ? 100 : nil)
      let meta: [String: Any] = ["type": "session_meta", "payload": ["id": "s1"]]
      let codex: [String: Any] = [
        "type": "event_msg",
        "payload": [
          "type": "token_count",
          "info": ["last_token_usage": codexUsage]
        ]
      ]
      try (line(meta) + line(codex)).write(to: file)
      let codexResult = SessionPlaybackReader().read(
        sessionId: "s1",
        sources: [
          PlaybackSource(path: file.path, vendor: Vendor.codex)
        ])
      XCTAssertEqual(codexResult.events.first?.usage?.input, cache == nil ? 100 : nil)
      XCTAssertEqual(codexResult.events.first?.usage?.contextTokens, 100)
    }
  }

  private func line(_ value: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: value) + Data([10])
  }
}

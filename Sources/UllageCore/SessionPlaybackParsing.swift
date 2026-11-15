import Foundation

extension SessionPlaybackReader {
  func parse(
    _ root: [String: Any], source: PlaybackSource, sessionId: String,
    offset: UInt64, state: inout FileState
  ) -> [PlaybackEvent] {
    if source.vendor == Vendor.codex {
      return parseCodex(root, source: source, sessionId: sessionId, offset: offset, state: &state)
    }
    guard (root["sessionId"] as? String ?? sessionId) == sessionId else { return [] }
    let type = root["type"] as? String ?? ""
    let message = root["message"] as? [String: Any] ?? [:]
    let identity = root["uuid"] as? String ?? String(offset)
    let base = PlaybackEvent(
      id: "\(source.path):\(state.generation):\(identity)",
      timestamp: (root["timestamp"] as? String).map { Timestamps.normalize($0) ?? $0 },
      agentId: root["agentId"] as? String ?? source.agentId, kind: .message,
      title: type.capitalized, messageId: message["id"] as? String, sourcePath: source.path)
    if type == "assistant" || type == "user" {
      return claudeMessages(message, base: base, prefix: "\(source.path):\(state.generation)")
    }
    var event = base
    if type == "summary" || root["subtype"] as? String == "compact_boundary" {
      event.kind = .compaction
      event.title = "Compaction"
      event.text = render(root)
    } else if type == "attachment", let attachment = root["attachment"] as? [String: Any],
      (attachment["type"] as? String ?? "").contains("hook") {
      event.kind = .hook
      event.title = "Hook"
      event.text = render(attachment)
    } else {
      return []
    }
    return [event]
  }

  private func claudeMessages(_ message: [String: Any], base: PlaybackEvent, prefix: String)
    -> [PlaybackEvent] {
    var events: [PlaybackEvent] = []
    if let text = message["content"] as? String {
      var event = base
      event.text = text
      events.append(event)
    }
    for (index, block) in (message["content"] as? [[String: Any]] ?? []).enumerated() {
      var event = claudeBlock(block, base: base)
      event.id = "\(base.id):\(index)"
      if let tool = event.toolCallId { event.id = "\(prefix):\(event.kind.rawValue):\(tool)" }
      events.append(event)
    }
    if let usage = message["usage"] as? [String: Any] {
      var event = base
      event.id = "\(prefix):\(base.messageId ?? base.id):usage"
      event.kind = .usage
      event.title = "Request usage"
      event.text = render(usage)
      let input = nonnegative(usage["input_tokens"])
      let cached = nonnegative(usage["cache_read_input_tokens"])
      let written = nonnegative(usage["cache_creation_input_tokens"])
      event.usage = PlaybackUsage(
        input: input, output: nonnegative(usage["output_tokens"]),
        cacheRead: cached, cacheWrite: written,
        contextTokens: safeSum([
          input, absentOrNonnegative(usage["cache_read_input_tokens"]),
          absentOrNonnegative(usage["cache_creation_input_tokens"])
        ]))
      events.append(event)
    }
    return events
  }

  private func claudeBlock(_ block: [String: Any], base: PlaybackEvent) -> PlaybackEvent {
    var event = base
    let type = block["type"] as? String ?? ""
    switch type {
    case "tool_use":
      event.kind = .toolCall
      event.title = block["name"] as? String ?? "Tool call"
      event.text = render(block["input"])
      event.toolCallId = block["id"] as? String
    case "tool_result":
      event.kind = .toolResult
      event.title = "Tool result"
      event.text = render(block["content"])
      event.toolCallId = block["tool_use_id"] as? String
    default:
      if type != "text" { event.title = type.capitalized }
      event.text = block["text"] as? String ?? render(block)
    }
    return event
  }

  private func parseCodex(
    _ root: [String: Any], source: PlaybackSource, sessionId: String,
    offset: UInt64, state: inout FileState
  ) -> [PlaybackEvent] {
    let type = root["type"] as? String ?? ""
    let payload = root["payload"] as? [String: Any] ?? [:]
    if type == "session_meta" {
      state.sessionId = payload["session_id"] as? String ?? payload["id"] as? String
      return []
    }
    guard state.sessionId == sessionId else { return [] }
    var event = PlaybackEvent(
      id: "\(source.path):\(state.generation):\(offset)",
      timestamp: (root["timestamp"] as? String).map { Timestamps.normalize($0) ?? $0 },
      agentId: source.agentId, kind: .message, title: "Message",
      toolCallId: payload["call_id"] as? String, messageId: payload["id"] as? String,
      sourcePath: source.path)
    switch type {
    case "compacted":
      event.kind = .compaction
      event.title = "Compaction"
      event.text = render(payload)
    case "response_item":
      guard codexContent(payload, event: &event) else { return [] }
    case "event_msg":
      guard payload["type"] as? String == "token_count",
        let info = payload["info"] as? [String: Any],
        let counts = info["last_token_usage"] as? [String: Any]
      else { return [] }
      event.kind = .usage
      event.title = "Request usage"
      event.text = render(counts)
      event.usage = codexUsage(counts, info: info)
    default: return []
    }
    return [event]
  }

  private func codexContent(_ payload: [String: Any], event: inout PlaybackEvent) -> Bool {
    let type = payload["type"] as? String ?? ""
    switch type {
    case "function_call", "custom_tool_call", "local_shell_call", "web_search_call":
      event.kind = .toolCall
      event.title = payload["name"] as? String ?? type
      event.text = render(payload["arguments"] ?? payload["input"] ?? payload["action"] ?? payload)
    case "function_call_output", "custom_tool_call_output", "local_shell_call_output":
      event.kind = .toolResult
      event.title = "Tool result"
      event.text = render(payload["output"])
    case "message":
      event.title = (payload["role"] as? String ?? "Message").capitalized
      event.text = render(payload["content"])
    default: return false
    }
    return true
  }

  private func codexUsage(_ counts: [String: Any], info: [String: Any]) -> PlaybackUsage {
    let total = nonnegative(counts["input_tokens"])
    let cached = nonnegative(counts["cached_input_tokens"])
    let written = nonnegative(counts["cache_write_input_tokens"])
    let deductions = safeSum([
      absentOrNonnegative(counts["cached_input_tokens"]),
      absentOrNonnegative(counts["cache_write_input_tokens"])
    ])
    let uncached: Int? = total.flatMap { total in
      guard total >= 0, let deductions, deductions <= total else { return nil }
      return total - deductions
    }
    return PlaybackUsage(
      input: uncached, output: nonnegative(counts["output_tokens"]),
      cacheRead: cached, cacheWrite: written, contextTokens: total,
      windowLimit: nonnegative(info["model_context_window"]))
  }

  func render(_ value: Any?) -> String {
    if let text = value as? String { return text }
    guard let value, JSONSerialization.isValidJSONObject(value),
      let data = try? JSONSerialization.data(
        withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
      let text = String(data: data, encoding: .utf8)
    else { return "" }
    return text
  }

  private func nonnegative(_ value: Any?) -> Int? {
    guard let number = value as? Int, number >= 0 else { return nil }
    return number
  }

  private func absentOrNonnegative(_ value: Any?) -> Int? {
    value == nil ? 0 : nonnegative(value)
  }

  private func safeSum(_ values: [Int?]) -> Int? {
    var sum = 0
    for value in values {
      guard let value, value >= 0 else { return nil }
      let addition = sum.addingReportingOverflow(value)
      guard !addition.overflow else { return nil }
      sum = addition.partialValue
    }
    return sum
  }
}

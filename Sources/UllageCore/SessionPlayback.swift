import Foundation

public struct PlaybackSource: Equatable, Sendable {
  public var path: String
  public var vendor: String
  public var agentId: String?

  public init(path: String, vendor: String, agentId: String? = nil) {
    self.path = path
    self.vendor = vendor
    self.agentId = agentId
  }
}

public enum PlaybackEventKind: String, Sendable {
  case message = "Message"
  case toolCall = "Tool call"
  case toolResult = "Tool result"
  case usage = "Usage"
  case compaction = "Compaction"
  case hook = "Hook"
  case request = "Request"
}

public enum PlaybackContentSource: String, Sendable {
  case transcript = "Transcript"
  case capturedRequest = "Captured request"
}

public enum PlaybackCompleteness: String, Sendable {
  case partial = "Partial"
  case redacted = "Recorded request · thinking redacted"
}

public struct PlaybackUsage: Equatable, Sendable {
  public var input: Int?
  public var output: Int?
  public var cacheRead: Int?
  public var cacheWrite: Int?
  public var contextTokens: Int?
  public var windowLimit: Int?

  public init(
    input: Int? = nil, output: Int? = nil, cacheRead: Int? = nil,
    cacheWrite: Int? = nil, contextTokens: Int? = nil, windowLimit: Int? = nil
  ) {
    self.input = input
    self.output = output
    self.cacheRead = cacheRead
    self.cacheWrite = cacheWrite
    self.contextTokens = contextTokens
    self.windowLimit = windowLimit
  }
}

public struct PlaybackRequestSnapshot: Equatable, Sendable {
  public var sourcePath: String
  public var completeness: PlaybackCompleteness
  public var body: String?
  public var notice: String?

  public init(
    sourcePath: String, completeness: PlaybackCompleteness = .redacted,
    body: String? = nil, notice: String? = nil
  ) {
    self.sourcePath = sourcePath
    self.completeness = completeness
    self.body = body
    self.notice = notice
  }
}

public struct PlaybackEvent: Identifiable, Equatable, Sendable {
  public var id: String
  public var timestamp: String?
  public var agentId: String?
  public var kind: PlaybackEventKind
  public var title: String
  public var text: String
  public var toolCallId: String?
  public var messageId: String?
  public var source: PlaybackContentSource
  public var completeness: PlaybackCompleteness
  public var snapshot: PlaybackRequestSnapshot?
  public var usage: PlaybackUsage?
  public var sourcePath: String?

  public init(
    id: String, timestamp: String? = nil, agentId: String? = nil,
    kind: PlaybackEventKind, title: String, text: String = "",
    toolCallId: String? = nil, messageId: String? = nil,
    source: PlaybackContentSource = .transcript, completeness: PlaybackCompleteness = .partial,
    snapshot: PlaybackRequestSnapshot? = nil, usage: PlaybackUsage? = nil, sourcePath: String? = nil
  ) {
    self.id = id
    self.timestamp = timestamp
    self.agentId = agentId
    self.kind = kind
    self.title = title
    self.text = text
    self.toolCallId = toolCallId
    self.messageId = messageId
    self.source = source
    self.completeness = completeness
    self.snapshot = snapshot
    self.usage = usage
    self.sourcePath = sourcePath
  }
}

public struct SessionPlayback: Equatable, Sendable {
  public var events: [PlaybackEvent]
  public var notices: [String]
  public var pendingLineCount: Int

  public init(events: [PlaybackEvent] = [], notices: [String] = [], pendingLineCount: Int = 0) {
    self.events = events
    self.notices = notices
    self.pendingLineCount = pendingLineCount
  }
}

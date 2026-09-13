import Foundation

/// Everything the collector produces. Deliberately free of any UI import so the
/// module can be lifted into a separate daemon when vendor #3 arrives (plan §3).

public enum Vendor {
    public static let claudeCode = "claude-code"
    public static let codex = "codex"
}

/// How much to trust the token counters on a row.
///
/// Every Claude Code row is `.exact` — the numbers come from the API response.
/// The column exists so that when a vendor that only estimates (Cursor) shows
/// up, its figures cannot silently contaminate a total.
public enum Confidence: String {
    case exact
    case estimated
    case cumulative
}

/// One API call. Mirrors the `call` table.
public struct CallRow: Equatable {
    public var dedupeKey: String        // message.id
    public var ts: String               // ISO 8601, normalised to UTC
    public var vendor: String
    public var agent: String?           // subagent name; NULL for the main thread in v1
    public var sessionId: String
    public var project: String?         // basename of cwd
    public var cwd: String?
    public var model: String?
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    public var reasoning: Int?
    public var webSearch: Int?
    public var contextTokens: Int
    public var windowLimit: Int?
    public var turnIndex: Int?          // assigned at ingest, not present on disk
    public var contextDelta: Int?       // assigned at ingest, needs the previous turn
    public var serviceTier: String?
    public var stopReason: String?
    public var durationMs: Int?
    public var isSidechain: Bool?
    public var uuid: String?
    public var parentUuid: String?
    public var sourceFile: String
    public var confidence: String
    public var parserVersion: Int

    public init(
        dedupeKey: String,
        ts: String,
        vendor: String = Vendor.claudeCode,
        agent: String? = nil,
        sessionId: String,
        project: String? = nil,
        cwd: String? = nil,
        model: String? = nil,
        input: Int = 0,
        output: Int = 0,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        reasoning: Int? = nil,
        webSearch: Int? = nil,
        contextTokens: Int,
        windowLimit: Int? = nil,
        turnIndex: Int? = nil,
        contextDelta: Int? = nil,
        serviceTier: String? = nil,
        stopReason: String? = nil,
        durationMs: Int? = nil,
        isSidechain: Bool? = nil,
        uuid: String? = nil,
        parentUuid: String? = nil,
        sourceFile: String,
        confidence: String = Confidence.exact.rawValue,
        parserVersion: Int = ClaudeCodeParser.version
    ) {
        self.dedupeKey = dedupeKey
        self.ts = ts
        self.vendor = vendor
        self.agent = agent
        self.sessionId = sessionId
        self.project = project
        self.cwd = cwd
        self.model = model
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.reasoning = reasoning
        self.webSearch = webSearch
        self.contextTokens = contextTokens
        self.windowLimit = windowLimit
        self.turnIndex = turnIndex
        self.contextDelta = contextDelta
        self.serviceTier = serviceTier
        self.stopReason = stopReason
        self.durationMs = durationMs
        self.isSidechain = isSidechain
        self.uuid = uuid
        self.parentUuid = parentUuid
        self.sourceFile = sourceFile
        self.confidence = confidence
        self.parserVersion = parserVersion
    }

    /// Occupancy of the context window, 0...1+, or nil when the limit is unknown.
    public var occupancy: Double? {
        guard let windowLimit, windowLimit > 0 else { return nil }
        return Double(contextTokens) / Double(windowLimit)
    }
}

public enum ToolKind: String {
    case builtin
    case mcp
    case skill
    case agent
}

/// One `tool_use` block. Mirrors the `tool_call` table.
public struct ToolCallRow: Equatable {
    public var id: String               // tool_use block id
    public var callId: String           // call.dedupe_key
    public var sessionId: String
    public var ts: String
    public var name: String
    public var kind: String
    public var mcpServer: String?
    public var target: String?
    public var resultTokens: Int?       // always a length estimate, never a real count
    public var isError: Bool?
    public var parserVersion: Int

    public init(
        id: String,
        callId: String,
        sessionId: String,
        ts: String,
        name: String,
        kind: String,
        mcpServer: String? = nil,
        target: String? = nil,
        resultTokens: Int? = nil,
        isError: Bool? = nil,
        parserVersion: Int = ClaudeCodeParser.version
    ) {
        self.id = id
        self.callId = callId
        self.sessionId = sessionId
        self.ts = ts
        self.name = name
        self.kind = kind
        self.mcpServer = mcpServer
        self.target = target
        self.resultTokens = resultTokens
        self.isError = isError
        self.parserVersion = parserVersion
    }
}

public enum EventKind: String {
    case compaction
    case summary
    case clear
    case sessionStart = "session_start"
}

/// A timeline marker. Mirrors the `event` table.
///
/// Exists so occupancy charts do not look broken: when compaction fires,
/// `context_tokens` falls off a cliff between adjacent turns.
public struct EventRow: Equatable {
    public var id: String
    public var sessionId: String
    public var ts: String
    public var kind: String
    public var detail: String?          // raw JSON

    public init(id: String, sessionId: String, ts: String, kind: String, detail: String? = nil) {
        self.id = id
        self.sessionId = sessionId
        self.ts = ts
        self.kind = kind
        self.detail = detail
    }
}

/// Where ingestion of a file stopped. Mirrors the `file_cursor` table.
public struct FileCursor: Equatable {
    public var path: String
    public var inode: UInt64
    public var byteOffset: UInt64
    public var size: UInt64
    public var mtime: Double

    public init(path: String, inode: UInt64, byteOffset: UInt64, size: UInt64, mtime: Double) {
        self.path = path
        self.inode = inode
        self.byteOffset = byteOffset
        self.size = size
        self.mtime = mtime
    }
}

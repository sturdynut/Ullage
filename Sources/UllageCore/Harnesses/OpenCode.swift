import Foundation

extension Vendor {
    public static let opencode = "opencode"
}

/// Where OpenCode (sst/opencode) keeps its data. Since v1.2 everything lives in
/// one SQLite database, `$XDG_DATA_HOME/opencode/opencode.db` (XDG default
/// `~/.local/share`, on macOS too). `OPENCODE_DB` overrides the file: absolute,
/// or relative to the data directory. Builds on a non-release channel write
/// `opencode-<channel>.db` beside it. See docs/harnesses/opencode.md.
public enum OpenCodePaths {
    public static func dataDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let base: URL
        if let xdg = environment["XDG_DATA_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: ClaudePaths.expand(xdg), isDirectory: true)
        } else {
            base = ClaudePaths.homeDirectory().appendingPathComponent(".local/share", isDirectory: true)
        }
        return base.appendingPathComponent("opencode", isDirectory: true)
    }

    /// The database OpenCode writes, or nil for `OPENCODE_DB=:memory:`.
    public static func databaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let override = environment["OPENCODE_DB"], !override.isEmpty {
            if override == ":memory:" { return nil }
            let expanded = ClaudePaths.expand(override)
            if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded) }
            return dataDirectory(environment: environment).appendingPathComponent(expanded)
        }
        return dataDirectory(environment: environment).appendingPathComponent("opencode.db")
    }

    /// The directory holding the database. A directory, not the file: OpenCode
    /// writes through a WAL, and a write lands in `opencode.db-wal` first.
    public static func roots(environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        guard let db = databaseURL(environment: environment) else { return [] }
        return [db.deletingLastPathComponent()]
    }

    /// `…/opencode/opencode.db`, `…/opencode/opencode-<channel>.db`, or the
    /// exact `OPENCODE_DB` file. Never a `.jsonl`, never another tool's file.
    public static func isOpenCodeDatabase(
        _ path: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if let override = databaseURL(environment: environment), environment["OPENCODE_DB"] != nil,
           override.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path {
            return true
        }
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        guard url.deletingLastPathComponent().lastPathComponent == "opencode", name.hasSuffix(".db") else { return false }
        return name == "opencode.db" || (name.hasPrefix("opencode-") && name.count > "opencode-.db".count)
    }
}

/// Reads OpenCode's SQLite store (`session`, `message`, `part` tables) into
/// the common rows. Read-only; a missing, locked or reshaped database yields
/// nothing (rule 5).
///
/// One model call is one `step-finish` part: OpenCode writes one per LLM step
/// with that step's usage (`session/processor.ts`), and the assistant message's
/// own `tokens` is just the last step's copy. Messages with no step-finish but
/// non-zero tokens fall back to the message. Child sessions (`parent_id`) are
/// subagents: their calls carry the root session's id and the child's id as
/// `agentId` (rule 1).
///
/// Token semantics: OpenCode's stored `tokens.input` is already the uncached
/// remainder (`getUsage` subtracts cache read and write from the provider's
/// inclusive count), so the counters map one-to-one.
public struct OpenCodeReader: TranscriptDocumentReader {
    public static let version = 1

    /// Tools OpenCode ships. Anything else with an underscore is an MCP tool
    /// (`<server>_<tool>`, `mcp/catalog.ts` `toolName`).
    static let builtinTools: Set<String> = [
        "bash", "read", "write", "edit", "multiedit", "patch", "apply_patch", "glob", "grep", "list", "ls",
        "webfetch", "websearch", "codesearch", "lsp", "todowrite", "todoread", "question", "plan_enter",
        "plan_exit", "invalid", "batch", "execute",
    ]

    public init() {}

    public func read(file: URL, context: LineContext) -> [ParsedLine] {
        guard FileManager.default.fileExists(atPath: file.path),
              let db = try? SQLiteDatabase(path: file.path, readOnly: true) else { return [] }
        return read(database: db, sourceFile: context.sourceFile)
    }

    // MARK: - Rows

    private struct Session {
        var parentId: String?
        var directory: String?
        var title: String?
    }

    private struct Message {
        var id: String
        var sessionId: String
        var createdMs: Int
        var data: [String: Any]
    }

    private struct Part {
        var id: String
        var messageId: String
        var createdMs: Int
        var data: [String: Any]
    }

    private struct Item {
        var ms: Int
        var order: Int
        var line: ParsedLine
    }

    func read(database db: SQLiteDatabase, sourceFile: String) -> [ParsedLine] {
        guard let sessions = loadSessions(db), let messages = loadMessages(db), let parts = loadParts(db) else {
            return []
        }
        var partsByMessage: [String: [Part]] = [:]
        for part in parts { partsByMessage[part.messageId, default: []].append(part) }
        for key in partsByMessage.keys { partsByMessage[key]?.sort { $0.id < $1.id } }  // ids are ascending

        var items: [Item] = []
        func add(_ ms: Int, _ line: ParsedLine) { items.append(Item(ms: ms, order: items.count, line: line)) }

        for message in messages where JSONAccess.string(message.data, "role") == "assistant" {
            let data = message.data
            let (root, agentId) = stream(of: message.sessionId, sessions: sessions)
            let cwd = JSONAccess.string(JSONAccess.dict(data, "path"), "cwd") ?? sessions[message.sessionId]?.directory
            let model = JSONAccess.string(data, "modelID")
            let base = CallRow(
                dedupeKey: "",
                ts: "",
                vendor: Vendor.opencode,
                agent: agentId == nil ? nil : JSONAccess.string(data, "agent"),
                agentId: agentId,
                sessionId: root,
                project: cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
                cwd: cwd,
                model: model,
                effort: JSONAccess.string(data, "variant"),
                contextTokens: 0,
                windowLimit: WindowLimits.knownLimit(for: model),
                stopReason: JSONAccess.string(data, "finish"),
                uuid: message.id,
                parentUuid: JSONAccess.string(data, "parentID"),
                sourceFile: sourceFile,
                confidence: Confidence.exact.rawValue,
                parserVersion: Self.version
            )

            let messageParts = partsByMessage[message.id] ?? []
            let steps = messageParts.filter { JSONAccess.string($0.data, "type") == "step-finish" }
            var calls: [(key: String, ms: Int, call: CallRow)] = []
            if steps.isEmpty {
                let time = JSONAccess.dict(data, "time")
                let ms = JSONAccess.int(time, "completed") ?? JSONAccess.int(time, "created") ?? message.createdMs
                if let call = makeCall(base, tokens: JSONAccess.dict(data, "tokens"), key: "opencode:\(message.id)", ms: ms) {
                    calls.append(("opencode:\(message.id)", ms, call))
                }
            } else {
                for step in steps {
                    let key = "opencode:\(step.id)"
                    if let call = makeCall(base, tokens: JSONAccess.dict(step.data, "tokens"), key: key, ms: step.createdMs) {
                        calls.append((key, step.createdMs, call))
                    }
                }
            }
            guard !calls.isEmpty else { continue }

            // A tool part belongs to the step that finishes after it.
            var toolsByCall: [String: [ToolCallRow]] = [:]
            var spawns: [ToolResultObservation] = []
            var stepIndex = 0
            let stepKeys = steps.isEmpty ? [] : steps.map { "opencode:\($0.id)" }
            for part in messageParts {
                let type = JSONAccess.string(part.data, "type")
                if type == "step-finish" { stepIndex += 1; continue }
                guard type == "tool" else { continue }
                let callKey: String
                if steps.isEmpty {
                    callKey = calls[0].key
                } else {
                    callKey = stepKeys[min(stepIndex, stepKeys.count - 1)]
                }
                guard calls.contains(where: { $0.key == callKey }) else { continue }
                guard let (row, spawn) = toolRow(part, callKey: callKey, session: root) else { continue }
                toolsByCall[callKey, default: []].append(row)
                if let spawn { spawns.append(spawn) }
            }
            for entry in calls {
                add(entry.ms, .call(ParsedCall(call: entry.call, toolCalls: toolsByCall[entry.key] ?? [], claudeVersion: nil)))
            }
            if !spawns.isEmpty { add(calls[calls.count - 1].ms, .toolResults(spawns)) }

            // A finished summary message is the compaction: everything after it
            // starts from the summary. Marked just after the summary's own call
            // so the cliff lands on the next turn, not this one.
            if JSONAccess.bool(data, "summary") == true, JSONAccess.string(data, "finish") != nil,
               data["error"] == nil {
                let lastMs = calls.map(\.ms).max() ?? message.createdMs
                let completed = JSONAccess.int(JSONAccess.dict(data, "time"), "completed") ?? lastMs
                let ms = max(completed, lastMs + 1)
                add(ms, .event(EventRow(
                    id: "opencode:compaction:\(message.id)",
                    sessionId: root,
                    agentId: agentId,
                    ts: iso(ms),
                    kind: EventKind.compaction.rawValue,
                    detail: compactionDetail(parentId: JSONAccess.string(data, "parentID"), partsByMessage: partsByMessage)
                )))
            }
        }

        return items.sorted { ($0.ms, $0.order) < ($1.ms, $1.order) }.map(\.line)
    }

    private func makeCall(_ base: CallRow, tokens: [String: Any]?, key: String, ms: Int) -> CallRow? {
        guard let tokens else { return nil }
        let cache = JSONAccess.dict(tokens, "cache")
        let input = max(0, JSONAccess.intOrZero(tokens, "input"))
        let output = max(0, JSONAccess.intOrZero(tokens, "output"))
        let cacheRead = max(0, JSONAccess.intOrZero(cache, "read"))
        let cacheWrite = max(0, JSONAccess.intOrZero(cache, "write"))
        // An aborted or failed step records zeros: no request to measure.
        guard input + cacheRead + cacheWrite > 0 || output > 0 else { return nil }
        var call = base
        call.dedupeKey = key
        call.ts = iso(ms)
        call.input = input
        call.output = output
        call.cacheRead = cacheRead
        call.cacheWrite = cacheWrite
        call.reasoning = JSONAccess.int(tokens, "reasoning")
        call.contextTokens = input + cacheRead + cacheWrite
        return call
    }

    private func toolRow(_ part: Part, callKey: String, session: String) -> (ToolCallRow, ToolResultObservation?)? {
        guard let name = JSONAccess.string(part.data, "tool") else { return nil }
        let state = JSONAccess.dict(part.data, "state")
        let status = JSONAccess.string(state, "status")
        let input = JSONAccess.dict(state, "input")
        let resultTokens: Int? = switch status {
        case "completed": ClaudeCodeParser.estimateTokens(of: state?["output"])
        case "error": ClaudeCodeParser.estimateTokens(of: state?["error"])
        default: nil
        }
        let isError: Bool? = status == "error" ? true : (status == "completed" ? false : nil)
        let startMs = JSONAccess.int(JSONAccess.dict(state, "time"), "start") ?? part.createdMs
        let (kind, server) = Self.classify(toolName: name)
        let row = ToolCallRow(
            id: "opencode:\(part.id)",
            callId: callKey,
            sessionId: session,
            ts: iso(startMs),
            name: name,
            kind: kind.rawValue,
            mcpServer: server,
            target: Self.target(forTool: name, input: input),
            resultTokens: resultTokens,
            isError: isError,
            parserVersion: Self.version
        )
        // `task` names the child session it ran (`tool/task.ts` metadata) —
        // the exact edge from this call to the subagent's own window.
        var spawn: ToolResultObservation?
        if kind == .agent, let child = JSONAccess.string(JSONAccess.dict(state, "metadata"), "sessionId") {
            let model = JSONAccess.dict(JSONAccess.dict(state, "metadata"), "model")
            spawn = ToolResultObservation(
                toolUseId: row.id,
                resultTokens: resultTokens ?? 0,
                isError: isError ?? false,
                agent: AgentSpawnInfo(
                    agentId: child,
                    sessionId: session,
                    agentType: JSONAccess.string(input, "subagent_type"),
                    status: status,
                    model: JSONAccess.string(model, "modelID")
                )
            )
        }
        return (row, spawn)
    }

    static func classify(toolName: String) -> (kind: ToolKind, server: String?) {
        switch toolName {
        case "task": return (.agent, nil)
        case "skill": return (.skill, nil)
        default: break
        }
        if builtinTools.contains(toolName) { return (.builtin, nil) }
        // `<server>_<tool>`, both sanitized to [A-Za-z0-9_-]. A server whose
        // own name has an underscore is cut at the first one.
        if let underscore = toolName.firstIndex(of: "_"), underscore != toolName.startIndex {
            return (.mcp, String(toolName[..<underscore]))
        }
        return (.builtin, nil)
    }

    static func target(forTool name: String, input: [String: Any]?) -> String? {
        guard let input else { return nil }
        let keys: [String]
        switch name {
        case "read", "write", "edit", "multiedit", "patch", "lsp": keys = ["filePath", "path"]
        case "bash": keys = ["command", "description"]
        case "task": keys = ["description", "subagent_type"]
        case "skill": keys = ["name"]
        case "glob", "grep": keys = ["pattern", "path"]
        case "webfetch", "websearch", "codesearch": keys = ["url", "query"]
        default: keys = ["filePath", "path", "command", "query", "url", "pattern", "name"]
        }
        for key in keys {
            if let value = JSONAccess.string(input, key) { return String(value.prefix(ClaudeCodeParser.targetLimit)) }
        }
        return nil
    }

    private func compactionDetail(parentId: String?, partsByMessage: [String: [Part]]) -> String? {
        guard let parentId,
              let part = partsByMessage[parentId]?.first(where: { JSONAccess.string($0.data, "type") == "compaction" })
        else { return nil }
        var detail: [String: Any] = [:]
        if let auto = JSONAccess.bool(part.data, "auto") { detail["auto"] = auto }
        if let overflow = JSONAccess.bool(part.data, "overflow") { detail["overflow"] = overflow }
        return detail.isEmpty ? nil : JSONAccess.jsonString(detail)
    }

    /// The root session and, for a child session, the child as agent.
    private func stream(of sessionId: String, sessions: [String: Session]) -> (String, String?) {
        var current = sessionId
        var seen: Set<String> = [current]
        while let parent = sessions[current]?.parentId, !parent.isEmpty, seen.insert(parent).inserted {
            current = parent
        }
        return current == sessionId ? (sessionId, nil) : (current, sessionId)
    }

    private func iso(_ ms: Int) -> String {
        Timestamps.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    // MARK: - Queries (nil when the schema is not one we know)

    private func columns(_ db: SQLiteDatabase, _ table: String) -> Set<String> {
        Set((try? db.query("PRAGMA table_info(\(table));") { $0.text(1) }) ?? [])
    }

    private func loadSessions(_ db: SQLiteDatabase) -> [String: Session]? {
        let cols = columns(db, "session")
        guard cols.contains("id") else { return nil }
        func col(_ name: String) -> String { cols.contains(name) ? name : "NULL" }
        let sql = "SELECT id, \(col("parent_id")), \(col("directory")), \(col("title")) FROM session;"
        guard let rows = try? db.query(sql, row: { row in
            (row.text(0), Session(parentId: row.optionalText(1), directory: row.optionalText(2), title: row.optionalText(3)))
        }) else { return nil }
        return Dictionary(rows, uniquingKeysWith: { first, _ in first })
    }

    private func loadMessages(_ db: SQLiteDatabase) -> [Message]? {
        let cols = columns(db, "message")
        guard cols.isSuperset(of: ["id", "session_id", "time_created", "data"]) else { return nil }
        let filtered = "SELECT id, session_id, time_created, data FROM message WHERE json_extract(data, '$.role') = 'assistant' ORDER BY time_created, id;"
        let all = "SELECT id, session_id, time_created, data FROM message ORDER BY time_created, id;"
        let map: (SQLiteStatement) -> Message? = { row in
            guard let data = Self.json(row.text(3)) else { return nil }
            return Message(id: row.text(0), sessionId: row.text(1), createdMs: row.int(2), data: data)
        }
        guard let rows = (try? db.query(filtered, row: map)) ?? (try? db.query(all, row: map)) else { return nil }
        return rows.compactMap { $0 }
    }

    private func loadParts(_ db: SQLiteDatabase) -> [Part]? {
        let cols = columns(db, "part")
        guard cols.isSuperset(of: ["id", "message_id", "time_created", "data"]) else { return nil }
        // Text and reasoning parts can be large and are never needed.
        let filtered = "SELECT id, message_id, time_created, data FROM part WHERE json_extract(data, '$.type') IN ('step-finish', 'tool', 'compaction');"
        let all = "SELECT id, message_id, time_created, data FROM part;"
        let map: (SQLiteStatement) -> Part? = { row in
            guard let data = Self.json(row.text(3)) else { return nil }
            return Part(id: row.text(0), messageId: row.text(1), createdMs: row.int(2), data: data)
        }
        guard let rows = (try? db.query(filtered, row: map)) ?? (try? db.query(all, row: map)) else { return nil }
        return rows.compactMap { $0 }
    }

    private static func json(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
}

extension Harness {
    public static let opencode = Harness(
        id: Vendor.opencode, name: "OpenCode",
        capabilities: .init(
            occupancy: .everyCall, window: .lookup, cacheSplit: true, subagents: true, toolResults: true,
            compaction: true, effort: true,
            notes: [
                "OpenCode runs many providers; only models Ullage knows get a window, the rest show tokens without a gauge.",
                "Sessions from before OpenCode 1.2 are read once OpenCode has moved them into its database.",
            ]
        ),
        roots: { OpenCodePaths.roots(environment: $0) },
        owns: { OpenCodePaths.isOpenCodeDatabase($0) },
        reading: .document({ OpenCodeReader() })
    )
}

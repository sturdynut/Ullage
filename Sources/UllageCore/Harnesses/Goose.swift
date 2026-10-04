import Foundation

extension Vendor {
    public static let goose = "goose"
}

/// Where Goose (block/goose) keeps its session database.
///
/// `Paths::data_dir()` uses etcetera's `choose_app_strategy`, which is XDG on
/// macOS as well as Linux: `$XDG_DATA_HOME/goose` or `~/.local/share/goose`.
/// `GOOSE_PATH_ROOT` (absolute) replaces all of it with `<root>/data`.
public enum GoosePaths {
    public static func sessionsDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let root = environment["GOOSE_PATH_ROOT"], root.hasPrefix("/") {
            return URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("data/sessions", isDirectory: true)
        }
        let base = environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ClaudePaths.expand($0), isDirectory: true) }
            ?? ClaudePaths.homeDirectory().appendingPathComponent(".local/share", isDirectory: true)
        return base.appendingPathComponent("goose/sessions", isDirectory: true)
    }

    /// `…/goose/sessions/sessions.db`, or the same file under `GOOSE_PATH_ROOT`.
    public static func isGooseDatabase(_ path: String) -> Bool {
        guard path.hasSuffix("/sessions/sessions.db") else { return false }
        if path.hasSuffix("/goose/sessions/sessions.db") { return true }
        let root = ProcessInfo.processInfo.environment["GOOSE_PATH_ROOT"] ?? ""
        return root.hasPrefix("/") && path == URL(fileURLWithPath: root).appendingPathComponent("data/sessions/sessions.db").path
    }
}

/// Reads Goose's `sessions.db` (SQLite, read-only).
///
/// `usage_ledger` holds one row per provider response with the model and the
/// four counters. Goose's `input_tokens` is the *whole* prompt, cache included
/// (`token_usage.rs`: "the cache fields are breakdown subsets of it"), so it is
/// split back like Codex: `input = total - cache_read - cache_write`.
///
/// Databases from before the ledger only have the session row's latest
/// turn (`sessions.input_tokens` …), overwritten in place; those become one
/// row per session, keyed by the session, updated as it changes.
public struct GooseReader: TranscriptDocumentReader {
    public static let version = 1

    public init() {}

    struct SessionInfo {
        var cwd: String?
        var parent: String?
        var model: String?
    }

    public func read(file: URL, context: LineContext) -> [ParsedLine] {
        guard FileManager.default.fileExists(atPath: file.path),
              let db = try? SQLiteDatabase(path: file.path, readOnly: true) else { return [] }
        let sessionColumns = Set((try? db.query("PRAGMA table_info(sessions);") { $0.text(1) }) ?? [])
        guard sessionColumns.contains("id") else { return [] }
        func col(_ name: String) -> String { sessionColumns.contains(name) ? name : "NULL" }

        var sessions: [String: SessionInfo] = [:]
        _ = try? db.query("SELECT id, \(col("working_dir")), \(col("parent_session_id")), \(col("model_config_json")) FROM sessions;") { row in
            let model = row.optionalText(3).flatMap { JSONAccess.string(Self.object($0), "model_name") }
            sessions[row.text(0)] = SessionInfo(cwd: row.optionalText(1), parent: row.optionalText(2).flatMap { $0.isEmpty ? nil : $0 }, model: model)
        }

        let ledgerColumns = Set((try? db.query("PRAGMA table_info(usage_ledger);") { $0.text(1) }) ?? [])
        if ledgerColumns.contains("session_id"), ledgerColumns.contains("input_tokens") {
            return readLedger(db, columns: ledgerColumns, sessions: sessions, context: context)
        }
        return readLatest(db, columns: sessionColumns, sessions: sessions, context: context)
    }

    private func readLedger(_ db: SQLiteDatabase, columns: Set<String>, sessions: [String: SessionInfo], context: LineContext) -> [ParsedLine] {
        func col(_ name: String) -> String { columns.contains(name) ? name : "NULL" }
        let sql = """
        SELECT id, session_id, \(col("created_timestamp")), \(col("model")), input_tokens, \(col("output_tokens")),
               \(col("cache_read_tokens")), \(col("cache_write_tokens")), \(col("cost_source")), \(col("is_compaction"))
        FROM usage_ledger ORDER BY id;
        """
        let rows = (try? db.query(sql) { row -> ParsedLine? in
            let id = row.int(0)
            let rawSession = row.text(1)
            guard !rawSession.isEmpty else { return nil }
            // A carried_forward row is Goose backfilling totals recorded before
            // the ledger existed: a sum of many calls, not a call.
            if row.optionalText(8) == "carried_forward" { return nil }
            let info = sessions[rawSession] ?? SessionInfo()
            let ts = row.optionalInt(2).map { Timestamps.string(from: Date(timeIntervalSince1970: TimeInterval($0))) }
                ?? context.fileModified ?? ""
            let (session, agent) = Self.stream(rawSession, info)
            if row.optionalInt(9) == 1 {
                return .event(EventRow(id: "goose:\(rawSession):compaction:\(id)", sessionId: session, agentId: agent,
                                       ts: ts, kind: EventKind.compaction.rawValue))
            }
            let model = row.optionalText(3) ?? info.model
            return Self.call(
                dedupeKey: "goose:\(rawSession):\(id)", ts: ts, session: session, agent: agent, info: info, model: model,
                total: row.optionalInt(4), output: row.optionalInt(5), cacheRead: row.optionalInt(6),
                cacheWrite: row.optionalInt(7), sourceFile: context.sourceFile
            )
        }) ?? []
        return rows.compactMap { $0 }
    }

    private func readLatest(_ db: SQLiteDatabase, columns: Set<String>, sessions: [String: SessionInfo], context: LineContext) -> [ParsedLine] {
        guard columns.contains("input_tokens") else { return [] }
        func col(_ name: String) -> String { columns.contains(name) ? name : "NULL" }
        let sql = "SELECT id, \(col("updated_at")), input_tokens, \(col("output_tokens")), \(col("cache_read_tokens")), \(col("cache_write_tokens")) FROM sessions;"
        let rows = (try? db.query(sql) { row -> ParsedLine? in
            let rawSession = row.text(0)
            let info = sessions[rawSession] ?? SessionInfo()
            let (session, agent) = Self.stream(rawSession, info)
            // SQLite's CURRENT_TIMESTAMP: "YYYY-MM-DD HH:MM:SS", UTC.
            let ts = row.optionalText(1).flatMap { Timestamps.normalize($0.replacingOccurrences(of: " ", with: "T") + "Z") }
                ?? context.fileModified ?? ""
            return Self.call(
                dedupeKey: "goose:\(rawSession)", ts: ts, session: session, agent: agent, info: info, model: info.model,
                total: row.optionalInt(2), output: row.optionalInt(3), cacheRead: row.optionalInt(4),
                cacheWrite: row.optionalInt(5), sourceFile: context.sourceFile
            )
        }) ?? []
        return rows.compactMap { $0 }
    }

    /// A child session (subagent) is its own stream under its parent (rule 1).
    static func stream(_ id: String, _ info: SessionInfo) -> (session: String, agent: String?) {
        if let parent = info.parent, parent != id { return (parent, id) }
        return (id, nil)
    }

    static func call(
        dedupeKey: String, ts: String, session: String, agent: String?, info: SessionInfo, model: String?,
        total: Int?, output: Int?, cacheRead: Int?, cacheWrite: Int?, sourceFile: String
    ) -> ParsedLine? {
        let total = max(0, total ?? 0)
        let output = max(0, output ?? 0)
        guard total > 0 || output > 0 else { return nil }
        let cacheRead = max(0, cacheRead ?? 0)
        let cacheWrite = max(0, cacheWrite ?? 0)
        let input = max(0, total - cacheRead - cacheWrite)
        let call = CallRow(
            dedupeKey: dedupeKey, ts: ts, vendor: Vendor.goose, agentId: agent, sessionId: session,
            project: info.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }, cwd: info.cwd, model: model,
            input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite,
            contextTokens: input + cacheRead + cacheWrite,
            windowLimit: WindowLimits.knownLimit(for: model),
            sourceFile: sourceFile, confidence: Confidence.exact.rawValue, parserVersion: version
        )
        return .call(ParsedCall(call: call, toolCalls: [], claudeVersion: nil))
    }

    static func object(_ json: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }
}

extension Harness {
    public static let goose = Harness(
        id: Vendor.goose, name: "Goose",
        capabilities: .init(
            occupancy: .everyCall, window: .lookup, cacheSplit: true, compaction: true,
            notes: [
                "Goose keeps no context window on disk, so the window is looked up from the model and unknown models get none.",
                "Ledger times are whole seconds, and tool calls are not read.",
                "Databases older than Goose's usage ledger keep only each session's latest turn.",
            ]
        ),
        roots: { [GoosePaths.sessionsDirectory(environment: $0)] },
        owns: GoosePaths.isGooseDatabase,
        reading: .document { GooseReader() }
    )
}

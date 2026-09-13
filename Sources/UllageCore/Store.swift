import Foundation

/// The database. Schema is plan §7 verbatim; the reads are the two the CLI and
/// the eventual menu bar need.
public final class Store {
    public let database: SQLiteDatabase
    public let path: String

    public static let schemaVersion = 1

    public init(path: String) throws {
        self.path = path
        if path != ":memory:" {
            let directory = (path as NSString).deletingLastPathComponent
            if !directory.isEmpty {
                try FileManager.default.createDirectory(
                    atPath: directory,
                    withIntermediateDirectories: true
                )
            }
        }
        self.database = try SQLiteDatabase(path: path)
        try database.execute("PRAGMA journal_mode=WAL;")
        try database.execute("PRAGMA synchronous=NORMAL;")
        try database.execute("PRAGMA foreign_keys=ON;")
        try migrate()
    }

    public static func inMemory() throws -> Store { try Store(path: ":memory:") }

    // MARK: - Schema

    func migrate() throws {
        let current = try database.query("PRAGMA user_version;") { $0.int(0) }.first ?? 0
        if current < 1 {
            try database.execute(Store.schemaV1)
            try database.execute("PRAGMA user_version=1;")
        }
    }

    static let schemaV1 = """
    CREATE TABLE IF NOT EXISTS call (
      dedupe_key       TEXT PRIMARY KEY,
      ts               TEXT NOT NULL,
      vendor           TEXT NOT NULL,
      agent            TEXT,
      session_id       TEXT NOT NULL,
      project          TEXT,
      cwd              TEXT,
      model            TEXT,
      input            INTEGER NOT NULL DEFAULT 0,
      output           INTEGER NOT NULL DEFAULT 0,
      cache_read       INTEGER NOT NULL DEFAULT 0,
      cache_write      INTEGER NOT NULL DEFAULT 0,
      reasoning        INTEGER,
      web_search       INTEGER,
      context_tokens   INTEGER NOT NULL,
      window_limit     INTEGER,
      turn_index       INTEGER,
      context_delta    INTEGER,
      service_tier     TEXT,
      stop_reason      TEXT,
      duration_ms      INTEGER,
      is_sidechain     INTEGER,
      uuid             TEXT,
      parent_uuid      TEXT,
      source_file      TEXT NOT NULL,
      confidence       TEXT NOT NULL,
      parser_version   INTEGER NOT NULL
    );

    CREATE INDEX IF NOT EXISTS call_ts      ON call(ts);
    CREATE INDEX IF NOT EXISTS call_session ON call(session_id, ts);

    CREATE TABLE IF NOT EXISTS tool_call (
      id             TEXT PRIMARY KEY,
      call_id        TEXT NOT NULL REFERENCES call(dedupe_key),
      session_id     TEXT NOT NULL,
      ts             TEXT NOT NULL,
      name           TEXT NOT NULL,
      kind           TEXT NOT NULL,
      mcp_server     TEXT,
      target         TEXT,
      result_tokens  INTEGER,
      is_error       INTEGER,
      parser_version INTEGER NOT NULL
    );

    CREATE INDEX IF NOT EXISTS tool_call_session ON tool_call(session_id, ts);
    CREATE INDEX IF NOT EXISTS tool_call_name    ON tool_call(name);

    CREATE TABLE IF NOT EXISTS event (
      id           TEXT PRIMARY KEY,
      session_id   TEXT NOT NULL,
      ts           TEXT NOT NULL,
      kind         TEXT NOT NULL,
      detail       TEXT
    );

    CREATE INDEX IF NOT EXISTS event_session ON event(session_id, ts);

    CREATE TABLE IF NOT EXISTS session_env (
      session_id      TEXT PRIMARY KEY,
      captured_at     TEXT NOT NULL,
      claude_version  TEXT,
      mcp_servers     TEXT,
      skills          TEXT,
      claude_md_hash  TEXT,
      claude_md_bytes INTEGER,
      claude_md_body  TEXT
    );

    CREATE TABLE IF NOT EXISTS file_cursor (
      path         TEXT PRIMARY KEY,
      inode        INTEGER NOT NULL,
      byte_offset  INTEGER NOT NULL,
      size         INTEGER NOT NULL,
      mtime        REAL NOT NULL
    );
    """

    // MARK: - Writes

    /// Upsert on `dedupe_key`. JSONL is append-only and forked sessions replay
    /// parent events; without this we would double-count.
    ///
    /// `output_tokens` is a mid-stream snapshot (plan §9 trap 2) and the same
    /// message.id can reappear with a larger value, so output takes the max of
    /// what we have and what arrived. Everything else is last-write-wins. No
    /// correction factor is applied anywhere — we store what was reported.
    public func upsert(call: CallRow) throws {
        let sql = """
        INSERT INTO call (
          dedupe_key, ts, vendor, agent, session_id, project, cwd, model,
          input, output, cache_read, cache_write, reasoning, web_search,
          context_tokens, window_limit, turn_index, context_delta,
          service_tier, stop_reason, duration_ms, is_sidechain,
          uuid, parent_uuid, source_file, confidence, parser_version
        ) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24,?25,?26,?27)
        ON CONFLICT(dedupe_key) DO UPDATE SET
          ts = excluded.ts,
          vendor = excluded.vendor,
          agent = excluded.agent,
          session_id = excluded.session_id,
          project = excluded.project,
          cwd = excluded.cwd,
          model = excluded.model,
          input = excluded.input,
          output = MAX(excluded.output, call.output),
          cache_read = excluded.cache_read,
          cache_write = excluded.cache_write,
          reasoning = excluded.reasoning,
          web_search = excluded.web_search,
          context_tokens = excluded.context_tokens,
          window_limit = excluded.window_limit,
          turn_index = COALESCE(excluded.turn_index, call.turn_index),
          context_delta = COALESCE(excluded.context_delta, call.context_delta),
          service_tier = excluded.service_tier,
          stop_reason = excluded.stop_reason,
          duration_ms = excluded.duration_ms,
          is_sidechain = excluded.is_sidechain,
          uuid = excluded.uuid,
          parent_uuid = excluded.parent_uuid,
          source_file = excluded.source_file,
          confidence = excluded.confidence,
          parser_version = excluded.parser_version;
        """
        try database.run(sql, [
            .text(call.dedupeKey),
            .text(call.ts),
            .text(call.vendor),
            .string(call.agent),
            .text(call.sessionId),
            .string(call.project),
            .string(call.cwd),
            .string(call.model),
            .integer(Int64(call.input)),
            .integer(Int64(call.output)),
            .integer(Int64(call.cacheRead)),
            .integer(Int64(call.cacheWrite)),
            .int(call.reasoning),
            .int(call.webSearch),
            .integer(Int64(call.contextTokens)),
            .int(call.windowLimit),
            .int(call.turnIndex),
            .int(call.contextDelta),
            .string(call.serviceTier),
            .string(call.stopReason),
            .int(call.durationMs),
            .bool(call.isSidechain),
            .string(call.uuid),
            .string(call.parentUuid),
            .text(call.sourceFile),
            .text(call.confidence),
            .integer(Int64(call.parserVersion)),
        ])
    }

    /// A replayed `tool_use` block must not clobber a `result_tokens` we already
    /// joined on, so the result columns are only overwritten when non-null.
    public func upsert(toolCall: ToolCallRow) throws {
        let sql = """
        INSERT INTO tool_call (
          id, call_id, session_id, ts, name, kind, mcp_server, target,
          result_tokens, is_error, parser_version
        ) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)
        ON CONFLICT(id) DO UPDATE SET
          call_id = excluded.call_id,
          session_id = excluded.session_id,
          ts = excluded.ts,
          name = excluded.name,
          kind = excluded.kind,
          mcp_server = excluded.mcp_server,
          target = excluded.target,
          result_tokens = COALESCE(excluded.result_tokens, tool_call.result_tokens),
          is_error = COALESCE(excluded.is_error, tool_call.is_error),
          parser_version = excluded.parser_version;
        """
        try database.run(sql, [
            .text(toolCall.id),
            .text(toolCall.callId),
            .text(toolCall.sessionId),
            .text(toolCall.ts),
            .text(toolCall.name),
            .text(toolCall.kind),
            .string(toolCall.mcpServer),
            .string(toolCall.target),
            .int(toolCall.resultTokens),
            .bool(toolCall.isError),
            .integer(Int64(toolCall.parserVersion)),
        ])
    }

    /// Join the result back onto its invocation. Returns false when the
    /// `tool_use` is not in the database — normal when ingestion starts mid-file.
    @discardableResult
    public func applyToolResult(_ result: ToolResultObservation) throws -> Bool {
        let changes = try database.run(
            """
            UPDATE tool_call SET result_tokens = ?2, is_error = ?3 WHERE id = ?1;
            """,
            [
                .text(result.toolUseId),
                .integer(Int64(result.resultTokens)),
                .integer(result.isError ? 1 : 0),
            ]
        )
        return changes > 0
    }

    @discardableResult
    public func insert(event: EventRow) throws -> Bool {
        let changes = try database.run(
            """
            INSERT INTO event (id, session_id, ts, kind, detail)
            VALUES (?1,?2,?3,?4,?5)
            ON CONFLICT(id) DO NOTHING;
            """,
            [
                .text(event.id),
                .text(event.sessionId),
                .text(event.ts),
                .text(event.kind),
                .string(event.detail),
            ]
        )
        return changes > 0
    }

    /// Snapshot on first sight of a session. Last write wins: a later ingest of
    /// the same session refreshes the capture rather than keeping a stale one.
    public func upsert(sessionEnv: SessionEnvRow) throws {
        try database.run(
            """
            INSERT INTO session_env (
              session_id, captured_at, claude_version, mcp_servers, skills,
              claude_md_hash, claude_md_bytes, claude_md_body
            ) VALUES (?1,?2,?3,?4,?5,?6,?7,?8)
            ON CONFLICT(session_id) DO UPDATE SET
              captured_at = excluded.captured_at,
              claude_version = COALESCE(excluded.claude_version, session_env.claude_version),
              mcp_servers = excluded.mcp_servers,
              skills = excluded.skills,
              claude_md_hash = excluded.claude_md_hash,
              claude_md_bytes = excluded.claude_md_bytes,
              claude_md_body = excluded.claude_md_body;
            """,
            [
                .text(sessionEnv.sessionId),
                .text(sessionEnv.capturedAt),
                .string(sessionEnv.claudeVersion),
                .string(sessionEnv.mcpServers),
                .string(sessionEnv.skills),
                .string(sessionEnv.claudeMdHash),
                .int(sessionEnv.claudeMdBytes),
                .string(sessionEnv.claudeMdBody),
            ]
        )
    }

    public func sessionEnv(sessionId: String) throws -> SessionEnvRow? {
        try database.query(
            """
            SELECT session_id, captured_at, claude_version, mcp_servers, skills,
                   claude_md_hash, claude_md_bytes, claude_md_body
            FROM session_env WHERE session_id = ?1;
            """,
            [.text(sessionId)]
        ) { row in
            SessionEnvRow(
                sessionId: row.text(0),
                capturedAt: row.text(1),
                claudeVersion: row.optionalText(2),
                mcpServers: row.optionalText(3),
                skills: row.optionalText(4),
                claudeMdHash: row.optionalText(5),
                claudeMdBytes: row.optionalInt(6),
                claudeMdBody: row.optionalText(7)
            )
        }.first
    }

    public func hasSessionEnv(sessionId: String) throws -> Bool {
        try database.query(
            "SELECT 1 FROM session_env WHERE session_id = ?1;", [.text(sessionId)]
        ) { _ in true }.first ?? false
    }

    public func sessionEnvCount() throws -> Int {
        try database.query("SELECT COUNT(*) FROM session_env;") { $0.int(0) }.first ?? 0
    }

    /// Sessions with rows but no environment snapshot — what a backfill still owes.
    public func sessionsMissingEnv() throws -> [String] {
        try database.query(
            """
            SELECT DISTINCT c.session_id FROM call c
            LEFT JOIN session_env e ON e.session_id = c.session_id
            WHERE e.session_id IS NULL;
            """
        ) { $0.text(0) }
    }

    public func upsert(cursor: FileCursor) throws {
        try database.run(
            """
            INSERT INTO file_cursor (path, inode, byte_offset, size, mtime)
            VALUES (?1,?2,?3,?4,?5)
            ON CONFLICT(path) DO UPDATE SET
              inode = excluded.inode,
              byte_offset = excluded.byte_offset,
              size = excluded.size,
              mtime = excluded.mtime;
            """,
            [
                .text(cursor.path),
                .uint(cursor.inode),
                .uint(cursor.byteOffset),
                .uint(cursor.size),
                .real(cursor.mtime),
            ]
        )
    }

    // MARK: - Reads

    public func cursor(forPath path: String) throws -> FileCursor? {
        try database.query(
            "SELECT path, inode, byte_offset, size, mtime FROM file_cursor WHERE path = ?1;",
            [.text(path)]
        ) { row in
            FileCursor(
                path: row.text(0),
                inode: UInt64(bitPattern: Int64(row.int(1))),
                byteOffset: UInt64(bitPattern: Int64(row.int(2))),
                size: UInt64(bitPattern: Int64(row.int(3))),
                mtime: row.double(4)
            )
        }.first
    }

    public func turnIndex(forDedupeKey key: String) throws -> Int? {
        try database.query(
            "SELECT turn_index FROM call WHERE dedupe_key = ?1;",
            [.text(key)]
        ) { $0.optionalInt(0) }.first ?? nil
    }

    public func maxTurnIndex(sessionId: String) throws -> Int? {
        try database.query(
            "SELECT MAX(turn_index) FROM call WHERE session_id = ?1;",
            [.text(sessionId)]
        ) { $0.optionalInt(0) }.first ?? nil
    }

    public func contextTokens(sessionId: String, turnIndex: Int) throws -> Int? {
        try database.query(
            "SELECT context_tokens FROM call WHERE session_id = ?1 AND turn_index = ?2;",
            [.text(sessionId), .integer(Int64(turnIndex))]
        ) { $0.int(0) }.first
    }

    public func callCount() throws -> Int {
        try database.query("SELECT COUNT(*) FROM call;") { $0.int(0) }.first ?? 0
    }

    public func toolCallCount() throws -> Int {
        try database.query("SELECT COUNT(*) FROM tool_call;") { $0.int(0) }.first ?? 0
    }

    public func eventCount() throws -> Int {
        try database.query("SELECT COUNT(*) FROM event;") { $0.int(0) }.first ?? 0
    }

    public func call(dedupeKey: String) throws -> CallRow? {
        try database.query(Store.callColumns + " FROM call WHERE dedupe_key = ?1;", [.text(dedupeKey)]) {
            Store.callRow(from: $0)
        }.first
    }

    public func calls(sessionId: String) throws -> [CallRow] {
        try database.query(
            Store.callColumns + " FROM call WHERE session_id = ?1 ORDER BY turn_index, ts;",
            [.text(sessionId)]
        ) { Store.callRow(from: $0) }
    }

    public func toolCalls(sessionId: String) throws -> [ToolCallRow] {
        try database.query(
            """
            SELECT id, call_id, session_id, ts, name, kind, mcp_server, target,
                   result_tokens, is_error, parser_version
            FROM tool_call WHERE session_id = ?1 ORDER BY ts, id;
            """,
            [.text(sessionId)]
        ) { row in
            ToolCallRow(
                id: row.text(0),
                callId: row.text(1),
                sessionId: row.text(2),
                ts: row.text(3),
                name: row.text(4),
                kind: row.text(5),
                mcpServer: row.optionalText(6),
                target: row.optionalText(7),
                resultTokens: row.optionalInt(8),
                isError: row.optionalBool(9),
                parserVersion: row.int(10)
            )
        }
    }

    /// The single row that drives the whole v1 UI (plan §8.3).
    public func latestCall() throws -> CallRow? {
        // Only rows with a known window drive the menu bar gauge: a Cursor row
        // (no window, no occupancy) must not hijack the live percentage.
        try database.query(
            Store.callColumns + """
             FROM call
             WHERE window_limit IS NOT NULL
               AND ts = (SELECT MAX(ts) FROM call WHERE window_limit IS NOT NULL)
             LIMIT 1;
            """
        ) { Store.callRow(from: $0) }.first
    }

    /// Newest call in one session — the pinned-session counterpart of `latestCall()`.
    public func latestCall(sessionId: String) throws -> CallRow? {
        try database.query(
            Store.callColumns + " FROM call WHERE session_id = ?1 ORDER BY ts DESC, turn_index DESC LIMIT 1;",
            [.text(sessionId)]
        ) { Store.callRow(from: $0) }.first
    }

    /// Sessions by most recent turn, one row each, for the picker. Cheap on
    /// purpose: it runs on every refresh, unlike `sessionTotals()`.
    public func recentSessions(limit: Int) throws -> [SessionSummary] {
        let sql = """
        SELECT c.session_id, c.project, c.model, c.ts, c.context_tokens, c.window_limit,
               (SELECT COUNT(*) FROM call n WHERE n.session_id = c.session_id)
        FROM call c
        WHERE c.ts = (SELECT MAX(m.ts) FROM call m WHERE m.session_id = c.session_id)
        GROUP BY c.session_id
        ORDER BY c.ts DESC
        LIMIT ?1;
        """
        return try database.query(sql, [.integer(Int64(limit))]) { row in
            SessionSummary(
                sessionId: row.text(0),
                project: row.optionalText(1),
                model: row.optionalText(2),
                lastTs: row.text(3),
                lastContextTokens: row.int(4),
                windowLimit: row.optionalInt(5),
                calls: row.int(6)
            )
        }
    }

    public func events(sessionId: String, kind: String? = nil) throws -> [EventRow] {
        var sql = "SELECT id, session_id, ts, kind, detail FROM event WHERE session_id = ?1"
        var bindings: [SQLiteValue] = [.text(sessionId)]
        if let kind {
            sql += " AND kind = ?2"
            bindings.append(.text(kind))
        }
        sql += " ORDER BY ts, id;"
        return try database.query(sql, bindings) { row in
            EventRow(
                id: row.text(0),
                sessionId: row.text(1),
                ts: row.text(2),
                kind: row.text(3),
                detail: row.optionalText(4)
            )
        }
    }

    /// Context per turn with compaction markers — the chart's whole input.
    public func contextHistory(sessionId: String) throws -> ContextHistory {
        ContextHistory.build(
            sessionId: sessionId,
            calls: try calls(sessionId: sessionId),
            events: try events(sessionId: sessionId, kind: EventKind.compaction.rawValue)
        )
    }

    /// The current window's make-up for one session (M7). Nil without turns.
    public func composition(sessionId: String) throws -> ContextComposition? {
        ContextComposition.build(
            sessionId: sessionId,
            calls: try calls(sessionId: sessionId),
            toolCalls: try toolCalls(sessionId: sessionId),
            events: try events(sessionId: sessionId, kind: EventKind.compaction.rawValue),
            environment: try sessionEnv(sessionId: sessionId)
        )
    }

    /// Activity per local day and project since `since` (a normalised UTC
    /// timestamp), oldest day first (M6).
    public func dailyActivity(since: String) throws -> [DailyActivity] {
        let sql = """
        SELECT date(ts, 'localtime') AS day, COALESCE(project, '—') AS project,
               COUNT(DISTINCT session_id), COUNT(*),
               SUM(input), SUM(output), SUM(cache_read), SUM(cache_write), MAX(context_tokens)
        FROM call
        WHERE ts >= ?1
        GROUP BY day, project
        ORDER BY day, project;
        """
        return try database.query(sql, [.text(since)]) { row in
            DailyActivity(
                day: row.text(0),
                project: row.text(1),
                sessions: row.int(2),
                calls: row.int(3),
                input: row.int(4),
                output: row.int(5),
                cacheRead: row.int(6),
                cacheWrite: row.int(7),
                peakContextTokens: row.int(8)
            )
        }
    }

    public func dailyActivity(days: Int, now: Date = Date()) throws -> [DailyActivity] {
        try dailyActivity(since: Timestamps.string(from: now.addingTimeInterval(-Double(days) * 86_400)))
    }

    public struct SessionTotals: Identifiable {
        public var id: String { sessionId }
        public var sessionId: String
        public var project: String?
        public var model: String?
        public var calls: Int
        public var input: Int
        public var output: Int
        public var cacheRead: Int
        public var cacheWrite: Int
        public var lastContextTokens: Int
        public var windowLimit: Int?
        public var firstTs: String
        public var lastTs: String
        public var toolCalls: Int
        public var compactions: Int

        public var occupancy: Double? {
            guard let windowLimit, windowLimit > 0 else { return nil }
            return Double(lastContextTokens) / Double(windowLimit)
        }
    }

    /// Per-session rollup for the ingest CLI. The occupancy figure is the *last*
    /// turn's context, not a sum — summing prompt counters across turns counts
    /// the same cached prefix once per turn.
    public func sessionTotals() throws -> [SessionTotals] {
        let sql = """
        SELECT
          c.session_id,
          MAX(c.project),
          (SELECT model FROM call m WHERE m.session_id = c.session_id ORDER BY m.ts DESC, m.turn_index DESC LIMIT 1),
          COUNT(*),
          SUM(c.input), SUM(c.output), SUM(c.cache_read), SUM(c.cache_write),
          (SELECT context_tokens FROM call l WHERE l.session_id = c.session_id ORDER BY l.ts DESC, l.turn_index DESC LIMIT 1),
          (SELECT window_limit FROM call l WHERE l.session_id = c.session_id ORDER BY l.ts DESC, l.turn_index DESC LIMIT 1),
          MIN(c.ts), MAX(c.ts),
          (SELECT COUNT(*) FROM tool_call t WHERE t.session_id = c.session_id),
          (SELECT COUNT(*) FROM event e WHERE e.session_id = c.session_id AND e.kind = 'compaction')
        FROM call c
        GROUP BY c.session_id
        ORDER BY MAX(c.ts) DESC;
        """
        return try database.query(sql) { row in
            SessionTotals(
                sessionId: row.text(0),
                project: row.optionalText(1),
                model: row.optionalText(2),
                calls: row.int(3),
                input: row.int(4),
                output: row.int(5),
                cacheRead: row.int(6),
                cacheWrite: row.int(7),
                lastContextTokens: row.optionalInt(8) ?? 0,
                windowLimit: row.optionalInt(9),
                firstTs: row.text(10),
                lastTs: row.text(11),
                toolCalls: row.int(12),
                compactions: row.int(13)
            )
        }
    }

    static let callColumns = """
    SELECT dedupe_key, ts, vendor, agent, session_id, project, cwd, model,
           input, output, cache_read, cache_write, reasoning, web_search,
           context_tokens, window_limit, turn_index, context_delta,
           service_tier, stop_reason, duration_ms, is_sidechain,
           uuid, parent_uuid, source_file, confidence, parser_version
    """

    static func callRow(from row: SQLiteStatement) -> CallRow {
        CallRow(
            dedupeKey: row.text(0),
            ts: row.text(1),
            vendor: row.text(2),
            agent: row.optionalText(3),
            sessionId: row.text(4),
            project: row.optionalText(5),
            cwd: row.optionalText(6),
            model: row.optionalText(7),
            input: row.int(8),
            output: row.int(9),
            cacheRead: row.int(10),
            cacheWrite: row.int(11),
            reasoning: row.optionalInt(12),
            webSearch: row.optionalInt(13),
            contextTokens: row.int(14),
            windowLimit: row.optionalInt(15),
            turnIndex: row.optionalInt(16),
            contextDelta: row.optionalInt(17),
            serviceTier: row.optionalText(18),
            stopReason: row.optionalText(19),
            durationMs: row.optionalInt(20),
            isSidechain: row.optionalBool(21),
            uuid: row.optionalText(22),
            parentUuid: row.optionalText(23),
            sourceFile: row.text(24),
            confidence: row.text(25),
            parserVersion: row.int(26)
        )
    }
}

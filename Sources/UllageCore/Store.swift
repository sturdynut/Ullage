import Foundation

/// The database. Schema is plan §7 verbatim; the reads are the two the CLI and
/// the eventual menu bar need.
public final class Store {
    public let database: SQLiteDatabase
    public let path: String

    public static let schemaVersion = 3

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
        if current < 2 {
            // Column adds are checked rather than blind: `ALTER TABLE … ADD
            // COLUMN` fails on a column that already exists, and a migration
            // that half-applied once would then fail on every open forever.
            try addColumnIfMissing(table: "call", column: "agent_id", type: "TEXT")
            try addColumnIfMissing(table: "event", column: "agent_id", type: "TEXT")
            try database.execute(Store.schemaV2)
            if current > 0 { try repairAgentStreams() }
            try database.execute("PRAGMA user_version=2;")
        }
        if current < 3 {
            try database.execute(Store.schemaV3)
            try database.execute("PRAGMA user_version=3;")
        }
    }

    func addColumnIfMissing(table: String, column: String, type: String) throws {
        let existing = try database.query("PRAGMA table_info(\(table));") { $0.text(1) }
        guard !existing.contains(column) else { return }
        try database.execute("ALTER TABLE \(table) ADD COLUMN \(column) \(type);")
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

    /// v2 — a subagent is its own context stream.
    ///
    /// `call.agent_id` is the stream key: turn index, context delta and
    /// occupancy are per (session, agent), never per session alone. The `agent`
    /// table is the spawn tree, assembled from the child's transcript and
    /// sidecar plus the parent's result; `spawn_tool_call_id` is the edge, and
    /// which *agent* that was is derived on read.
    static let schemaV2 = """
    CREATE INDEX IF NOT EXISTS call_stream ON call(session_id, agent_id, ts);

    CREATE TABLE IF NOT EXISTS agent (
      agent_id           TEXT PRIMARY KEY,
      session_id         TEXT NOT NULL,
      spawn_tool_call_id TEXT,
      agent_type         TEXT,
      label              TEXT,
      resolved_model     TEXT,
      status             TEXT,
      reported_tool_uses INTEGER,
      duration_ms        INTEGER,
      first_ts           TEXT,
      last_ts            TEXT,
      parser_version     INTEGER NOT NULL
    );

    CREATE INDEX IF NOT EXISTS agent_session ON agent(session_id, first_ts);
    CREATE INDEX IF NOT EXISTS agent_spawn   ON agent(spawn_tool_call_id);
    """

    /// Rows written before v2 have no `agent_id`, and their turn numbering
    /// interleaves every agent of a session into one counter — which is what
    /// made a parent's chart read as a sawtooth of unrelated windows.
    ///
    /// The path is enough to recover the identity (`…/subagents/agent-<id>.jsonl`)
    /// and the numbering is ours to redo, so both are fixed in place. Only the
    /// spawn tree needs the transcripts again, and the cursors for exactly those
    /// files are rewound at the end so the next ingest picks it up.
    func repairAgentStreams() throws {
        try database.transaction { try repairAgentStreamsInTransaction() }
    }

    private func repairAgentStreamsInTransaction() throws {
        let paths = try database.query(
            "SELECT DISTINCT source_file FROM call WHERE is_sidechain = 1 AND agent_id IS NULL;"
        ) { $0.text(0) }
        for path in paths {
            guard let agentId = Store.agentId(fromTranscriptPath: path) else { continue }
            try database.run(
                "UPDATE call SET agent_id = ?2 WHERE source_file = ?1 AND agent_id IS NULL;",
                [.text(path), .text(agentId)]
            )
        }
        let sessions = try database.query(
            "SELECT DISTINCT session_id FROM call WHERE agent_id IS NOT NULL;"
        ) { $0.text(0) }
        for sessionId in sessions {
            try renumberStreams(sessionId: sessionId)
            // The spawn tree lives in lines these files were already read past:
            // the `Agent` tool's description, and the result that names the
            // child it ran. Rewinding the cursors is the only way to recover
            // them, and re-ingest is idempotent — a dedupe key already in the
            // database keeps the turn index just assigned to it.
            let files = try database.query(
                "SELECT DISTINCT source_file FROM call WHERE session_id = ?1;",
                [.text(sessionId)]
            ) { $0.text(0) }
            for path in files {
                try database.run("DELETE FROM file_cursor WHERE path = ?1;", [.text(path)])
            }
        }
    }

    /// `…/<session>/subagents/agent-<agentId>.jsonl` — the only place a
    /// pre-v2 row records which agent wrote it.
    static func agentId(fromTranscriptPath path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard url.deletingLastPathComponent().lastPathComponent == "subagents" else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("agent-") else { return nil }
        let id = String(name.dropFirst("agent-".count))
        return id.isEmpty ? nil : id
    }

    /// Re-derives turn index and context delta for every stream of one session
    /// from the rows already stored, with the same rules the ingestor applies:
    /// numbering starts at zero per stream, and a delta across a compaction
    /// boundary is NULL because the two prompts are not the same window.
    public func renumberStreams(sessionId: String) throws {
        let calls = try calls(sessionId: sessionId, scope: .all)
        guard !calls.isEmpty else { return }
        let boundaries = try events(sessionId: sessionId, kind: EventKind.compaction.rawValue, scope: .all)
            .map { ($0.agentId ?? "", $0.ts) }

        var streams: [String: [CallRow]] = [:]
        for call in calls { streams[call.agentId ?? "", default: []].append(call) }

        for (stream, rows) in streams {
            var pending = boundaries.filter { $0.0 == stream }.map(\.1).sorted()
            var previous: Int?
            // Already ordered by (ts, turn_index) by the query: re-sorting on ts
            // alone would reshuffle rows that share a timestamp.
            for (index, row) in rows.enumerated() {
                var crossedBoundary = false
                while let next = pending.first, next <= row.ts {
                    pending.removeFirst()
                    crossedBoundary = true
                }
                let delta = (crossedBoundary || index == 0) ? nil : previous.map { row.contextTokens - $0 }
                try database.run(
                    "UPDATE call SET turn_index = ?2, context_delta = ?3 WHERE dedupe_key = ?1;",
                    [.text(row.dedupeKey), .integer(Int64(index)), .int(delta)]
                )
                previous = row.contextTokens
            }
        }
    }

    /// v3 — how far the OpenTelemetry export has read, per endpoint.
    ///
    /// Metrics are cumulative and idempotent, so they need no cursor; spans are
    /// not, and re-sending a month of them on every run would be both slow and
    /// wrong.
    static let schemaV3 = """
    CREATE TABLE IF NOT EXISTS otlp_cursor (
      endpoint  TEXT PRIMARY KEY,
      last_ts   TEXT NOT NULL,
      updated_at TEXT NOT NULL
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
          dedupe_key, ts, vendor, agent, agent_id, session_id, project, cwd, model,
          input, output, cache_read, cache_write, reasoning, web_search,
          context_tokens, window_limit, turn_index, context_delta,
          service_tier, stop_reason, duration_ms, is_sidechain,
          uuid, parent_uuid, source_file, confidence, parser_version
        ) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24,?25,?26,?27,?28)
        ON CONFLICT(dedupe_key) DO UPDATE SET
          ts = excluded.ts,
          vendor = excluded.vendor,
          agent = excluded.agent,
          agent_id = excluded.agent_id,
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
            .string(call.agentId),
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
            INSERT INTO event (id, session_id, agent_id, ts, kind, detail)
            VALUES (?1,?2,?3,?4,?5,?6)
            ON CONFLICT(id) DO NOTHING;
            """,
            [
                .text(event.id),
                .text(event.sessionId),
                .string(event.agentId),
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

    /// Both sides of an agent row land here, in either order, and neither may
    /// erase what the other knew: the child's transcript supplies identity and
    /// timestamps, the parent's result supplies the outcome.
    public func upsert(agent: AgentRow) throws {
        try database.run(
            """
            INSERT INTO agent (
              agent_id, session_id, spawn_tool_call_id, agent_type, label,
              resolved_model, status, reported_tool_uses, duration_ms, first_ts, last_ts,
              parser_version
            ) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)
            ON CONFLICT(agent_id) DO UPDATE SET
              -- The agent's own transcript decides where it is filed: it lives
              -- in that session's `subagents/` directory. A forked session
              -- replays the spawn under a different id, so the parent side of
              -- the row only supplies a session when nothing else has.
              session_id = CASE WHEN excluded.first_ts IS NOT NULL
                                THEN excluded.session_id ELSE agent.session_id END,
              spawn_tool_call_id = COALESCE(excluded.spawn_tool_call_id, agent.spawn_tool_call_id),
              agent_type = COALESCE(excluded.agent_type, agent.agent_type),
              label = COALESCE(excluded.label, agent.label),
              resolved_model = COALESCE(excluded.resolved_model, agent.resolved_model),
              status = COALESCE(excluded.status, agent.status),
              reported_tool_uses = COALESCE(excluded.reported_tool_uses, agent.reported_tool_uses),
              duration_ms = COALESCE(excluded.duration_ms, agent.duration_ms),
              first_ts = MIN(COALESCE(excluded.first_ts, agent.first_ts),
                             COALESCE(agent.first_ts, excluded.first_ts)),
              last_ts  = MAX(COALESCE(excluded.last_ts, agent.last_ts),
                             COALESCE(agent.last_ts, excluded.last_ts)),
              parser_version = excluded.parser_version;
            """,
            [
                .text(agent.agentId),
                .text(agent.sessionId),
                .string(agent.spawnToolCallId),
                .string(agent.agentType),
                .string(agent.label),
                .string(agent.resolvedModel),
                .string(agent.status),
                .int(agent.reportedToolUses),
                .int(agent.durationMs),
                .string(agent.firstTs),
                .string(agent.lastTs),
                .integer(Int64(agent.parserVersion)),
            ]
        )
    }

    /// The parent's side of the row: how the run ended. The spawning `tool_use`
    /// is recorded here too, which is what places the agent in the tree.
    ///
    /// Returns false when that `tool_use` is not in the database — normal when a
    /// file is read from mid-stream, and the reason the tree resolves the parent
    /// *agent* on read rather than storing it now.
    @discardableResult
    public func recordAgentSpawn(
        toolUseId: String,
        info: AgentSpawnInfo,
        sessionFallback: String
    ) throws -> Bool {
        try upsert(agent: AgentRow(
            agentId: info.agentId,
            sessionId: sessionFallback,
            spawnToolCallId: toolUseId,
            agentType: info.agentType,
            resolvedModel: info.model,
            status: info.status,
            reportedToolUses: info.reportedToolUses,
            durationMs: info.durationMs
        ))
        return try database.query(
            "SELECT 1 FROM tool_call WHERE id = ?1;", [.text(toolUseId)]
        ) { _ in true }.first ?? false
    }

    /// The child's side: seen on every turn the agent records, so identity and
    /// span survive even when the parent's transcript does not. The sidecar
    /// beside that transcript supplies the name and the spawn it came from.
    public func upsertAgent(fromCall call: CallRow, metadata: AgentMetadata? = nil) throws {
        guard let agentId = call.agentId else { return }
        try upsert(agent: AgentRow(
            agentId: agentId,
            sessionId: call.sessionId,
            spawnToolCallId: metadata?.toolUseId,
            agentType: call.agent ?? metadata?.agentType,
            label: metadata?.label,
            firstTs: call.ts,
            lastTs: call.ts,
            parserVersion: call.parserVersion
        ))
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

    public func maxTurnIndex(sessionId: String, agentId: String? = nil) throws -> Int? {
        let (clause, bindings) = Store.scopeSQL(agentId, index: 2)
        return try database.query(
            "SELECT MAX(turn_index) FROM call WHERE session_id = ?1" + clause + ";",
            [.text(sessionId)] + bindings
        ) { $0.optionalInt(0) }.first ?? nil
    }

    public func contextTokens(sessionId: String, agentId: String? = nil, turnIndex: Int) throws -> Int? {
        let (clause, bindings) = Store.scopeSQL(agentId, index: 3)
        return try database.query(
            "SELECT context_tokens FROM call WHERE session_id = ?1 AND turn_index = ?2" + clause + ";",
            [.text(sessionId), .integer(Int64(turnIndex))] + bindings
        ) { $0.int(0) }.first
    }

    /// One stream of a session, as a SQL fragment. `nil` is the main thread and
    /// is a filter, not an absence: without it a subagent's rows join the
    /// parent's series and the chart plots two windows as one line.
    static func scopeSQL(_ agentId: String?, index: Int, column: String = "agent_id") -> (String, [SQLiteValue]) {
        guard let agentId else { return (" AND \(column) IS NULL", []) }
        return (" AND \(column) = ?\(index)", [.text(agentId)])
    }

    static func scopeSQL(_ scope: AgentScope, index: Int, column: String = "agent_id") -> (String, [SQLiteValue]) {
        switch scope {
        case .all: return ("", [])
        case .mainThread: return scopeSQL(nil, index: index, column: column)
        case .agent(let id): return scopeSQL(id, index: index, column: column)
        }
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

    /// One stream's turns, in order. `.all` is ordered by time instead of by
    /// turn index, because turn indexes only order rows within a stream.
    public func calls(sessionId: String, scope: AgentScope = .mainThread) throws -> [CallRow] {
        let (clause, bindings) = Store.scopeSQL(scope, index: 2)
        let order = scope == .all ? "ts, turn_index" : "turn_index, ts"
        return try database.query(
            Store.callColumns + " FROM call WHERE session_id = ?1" + clause + " ORDER BY \(order);",
            [.text(sessionId)] + bindings
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
        // (no window, no occupancy) must not hijack the live percentage, and a
        // subagent's window is not the session's window however recently it
        // spoke — the popover's tree is where agents get their own numbers.
        try database.query(
            Store.callColumns + """
             FROM call
             WHERE window_limit IS NOT NULL AND agent_id IS NULL
               AND ts = (SELECT MAX(ts) FROM call WHERE window_limit IS NOT NULL AND agent_id IS NULL)
             LIMIT 1;
            """
        ) { Store.callRow(from: $0) }.first
    }

    /// Newest call in one session — the pinned-session counterpart of `latestCall()`.
    public func latestCall(sessionId: String, scope: AgentScope = .mainThread) throws -> CallRow? {
        let (clause, bindings) = Store.scopeSQL(scope, index: 2)
        return try database.query(
            Store.callColumns + " FROM call WHERE session_id = ?1" + clause
                + " ORDER BY ts DESC, turn_index DESC LIMIT 1;",
            [.text(sessionId)] + bindings
        ) { Store.callRow(from: $0) }.first
    }

    /// Sessions by most recent turn, one row each, for the picker. Cheap on
    /// purpose: it runs on every refresh, unlike `sessionTotals()`.
    /// Context and model come from the main thread — that is the session's own
    /// window — while the timestamp spans every stream, so a session whose
    /// agents are still working stays at the top of the list where it belongs.
    public func recentSessions(limit: Int) throws -> [SessionSummary] {
        let sql = """
        SELECT s.session_id,
               (SELECT project FROM call p WHERE p.session_id = s.session_id
                 ORDER BY p.ts DESC LIMIT 1),
               (SELECT model FROM call m WHERE m.session_id = s.session_id AND m.agent_id IS NULL
                 ORDER BY m.ts DESC, m.turn_index DESC LIMIT 1),
               s.last_ts,
               (SELECT context_tokens FROM call l WHERE l.session_id = s.session_id AND l.agent_id IS NULL
                 ORDER BY l.ts DESC, l.turn_index DESC LIMIT 1),
               (SELECT window_limit FROM call l WHERE l.session_id = s.session_id AND l.agent_id IS NULL
                 ORDER BY l.ts DESC, l.turn_index DESC LIMIT 1),
               (SELECT COUNT(*) FROM call n WHERE n.session_id = s.session_id AND n.agent_id IS NULL),
               (SELECT COUNT(*) FROM agent a WHERE a.session_id = s.session_id)
        FROM (SELECT session_id, MAX(ts) AS last_ts FROM call GROUP BY session_id) s
        ORDER BY s.last_ts DESC
        LIMIT ?1;
        """
        return try database.query(sql, [.integer(Int64(limit))]) { row in
            SessionSummary(
                sessionId: row.text(0),
                project: row.optionalText(1),
                model: row.optionalText(2),
                lastTs: row.text(3),
                lastContextTokens: row.optionalInt(4) ?? 0,
                windowLimit: row.optionalInt(5),
                calls: row.int(6),
                agents: row.int(7)
            )
        }
    }

    /// The spawn tree for one session, joined to the turns each agent recorded.
    ///
    /// The label is the description the parent wrote when it spawned the agent,
    /// read back off the `tool_call` row rather than stored twice.
    public func agents(sessionId: String) throws -> [AgentSummary] {
        let sql = """
        SELECT a.agent_id, a.session_id,
               -- The parent is whichever stream made the spawning call: NULL is
               -- the main thread. Derived, so ingest order cannot strand it.
               (SELECT c.agent_id FROM tool_call t JOIN call c ON c.dedupe_key = t.call_id
                 WHERE t.id = a.spawn_tool_call_id),
               a.agent_type,
               COALESCE((SELECT c.model FROM call c WHERE c.agent_id = a.agent_id
                          ORDER BY c.ts DESC, c.turn_index DESC LIMIT 1), a.resolved_model),
               a.status,
               COALESCE(a.label, (SELECT t.target FROM tool_call t WHERE t.id = a.spawn_tool_call_id)),
               (SELECT COUNT(*) FROM call c WHERE c.agent_id = a.agent_id),
               (SELECT c.context_tokens FROM call c WHERE c.agent_id = a.agent_id
                 ORDER BY c.ts DESC, c.turn_index DESC LIMIT 1),
               (SELECT c.window_limit FROM call c WHERE c.agent_id = a.agent_id
                 ORDER BY c.ts DESC, c.turn_index DESC LIMIT 1),
               (SELECT MAX(c.context_tokens) FROM call c WHERE c.agent_id = a.agent_id),
               (SELECT COUNT(*) FROM tool_call t JOIN call c ON c.dedupe_key = t.call_id
                 WHERE c.agent_id = a.agent_id),
               a.reported_tool_uses, a.duration_ms, a.first_ts, a.last_ts
        FROM agent a
        WHERE a.session_id = ?1
        ORDER BY a.first_ts, a.agent_id;
        """
        return try database.query(sql, [.text(sessionId)]) { row in
            AgentSummary(
                agentId: row.text(0),
                sessionId: row.text(1),
                parentAgentId: row.optionalText(2),
                agentType: row.optionalText(3),
                label: row.optionalText(6),
                model: row.optionalText(4),
                status: row.optionalText(5),
                calls: row.int(7),
                lastContextTokens: row.optionalInt(8),
                windowLimit: row.optionalInt(9),
                peakContextTokens: row.optionalInt(10),
                toolCalls: row.int(11),
                reportedToolUses: row.optionalInt(12),
                durationMs: row.optionalInt(13),
                firstTs: row.optionalText(14),
                lastTs: row.optionalText(15)
            )
        }
    }

    // MARK: - OpenTelemetry export

    /// Per-stream totals, cumulative over everything on disk.
    ///
    /// `since` selects which streams are *included* — those active since then —
    /// and never truncates their totals: a counter that goes down because the
    /// export window moved would be worse than no counter.
    public func telemetryStreams(since: String? = nil) throws -> [StreamTotals] {
        var sql = """
        SELECT c.session_id, c.agent_id, MAX(c.agent), MAX(c.project), MAX(c.vendor),
               (SELECT m.model FROM call m
                 WHERE m.session_id = c.session_id AND m.agent_id IS c.agent_id AND m.model IS NOT NULL
                 ORDER BY m.ts DESC, m.turn_index DESC LIMIT 1),
               MAX(c.confidence),
               SUM(c.input), SUM(c.output), SUM(c.cache_read), SUM(c.cache_write), COUNT(*),
               (SELECT l.context_tokens FROM call l
                 WHERE l.session_id = c.session_id AND l.agent_id IS c.agent_id
                 ORDER BY l.ts DESC, l.turn_index DESC LIMIT 1),
               (SELECT l.window_limit FROM call l
                 WHERE l.session_id = c.session_id AND l.agent_id IS c.agent_id
                 ORDER BY l.ts DESC, l.turn_index DESC LIMIT 1),
               MAX(c.context_tokens),
               (SELECT COUNT(*) FROM tool_call t JOIN call x ON x.dedupe_key = t.call_id
                 WHERE x.session_id = c.session_id AND x.agent_id IS c.agent_id),
               (SELECT COALESCE(SUM(t.result_tokens), 0) FROM tool_call t JOIN call x ON x.dedupe_key = t.call_id
                 WHERE x.session_id = c.session_id AND x.agent_id IS c.agent_id),
               (SELECT COUNT(*) FROM event e
                 WHERE e.session_id = c.session_id AND e.agent_id IS c.agent_id
                   AND e.kind = 'compaction'),
               MIN(c.ts), MAX(c.ts)
        FROM call c
        GROUP BY c.session_id, c.agent_id
        """
        var bindings: [SQLiteValue] = []
        if let since {
            sql += "\nHAVING MAX(c.ts) >= ?1"
            bindings.append(.text(since))
        }
        sql += "\nORDER BY MAX(c.ts) DESC;"

        return try database.query(sql, bindings) { row in
            StreamTotals(
                sessionId: row.text(0),
                agentId: row.optionalText(1),
                agentType: row.optionalText(2),
                project: row.optionalText(3),
                vendor: row.text(4),
                model: row.optionalText(5),
                confidence: row.text(6),
                input: row.int(7),
                output: row.int(8),
                cacheRead: row.int(9),
                cacheWrite: row.int(10),
                turns: row.int(11),
                lastContextTokens: row.optionalInt(12),
                windowLimit: row.optionalInt(13),
                peakContextTokens: row.optionalInt(14),
                toolCalls: row.int(15),
                toolResultTokens: row.int(16),
                compactions: row.int(17),
                firstTs: row.text(18),
                lastTs: row.text(19)
            )
        }
    }

    /// Sessions with a turn in the window, oldest first so spans arrive in the
    /// order they happened.
    public func sessionsActive(since: String?) throws -> [String] {
        var sql = "SELECT session_id, MIN(ts) AS first_ts FROM call"
        var bindings: [SQLiteValue] = []
        if let since {
            sql += " WHERE ts >= ?1"
            bindings.append(.text(since))
        }
        sql += " GROUP BY session_id ORDER BY first_ts;"
        return try database.query(sql, bindings) { $0.text(0) }
    }

    /// Which turn spawned which agent — the edge that makes the trace a tree.
    public func agentSpawnCalls(sessionId: String) throws -> [String: String] {
        let rows = try database.query(
            """
            SELECT a.agent_id, t.call_id
            FROM agent a JOIN tool_call t ON t.id = a.spawn_tool_call_id
            WHERE a.session_id = ?1;
            """,
            [.text(sessionId)]
        ) { ($0.text(0), $0.text(1)) }
        return Dictionary(rows, uniquingKeysWith: { first, _ in first })
    }

    /// Everything one session's trace is built from. `since` limits the turns,
    /// not the agents: an agent whose spawning turn fell outside the window
    /// still hangs off the session rather than vanishing.
    public func sessionTrace(sessionId: String, since: String? = nil) throws -> SessionTrace {
        var sql = Store.callColumns + " FROM call WHERE session_id = ?1"
        var bindings: [SQLiteValue] = [.text(sessionId)]
        if let since {
            sql += " AND ts >= ?2"
            bindings.append(.text(since))
        }
        sql += " ORDER BY ts, turn_index;"
        let calls = try database.query(sql, bindings) { Store.callRow(from: $0) }
        let newest = calls.last
        return SessionTrace(
            sessionId: sessionId,
            project: newest?.project,
            vendor: newest?.vendor ?? Vendor.claudeCode,
            calls: calls,
            agents: try agents(sessionId: sessionId),
            compactions: try events(sessionId: sessionId, kind: EventKind.compaction.rawValue, scope: .all),
            spawnCalls: try agentSpawnCalls(sessionId: sessionId)
        )
    }

    public func exportCursor(endpoint: String) throws -> String? {
        try database.query(
            "SELECT last_ts FROM otlp_cursor WHERE endpoint = ?1;", [.text(endpoint)]
        ) { $0.text(0) }.first
    }

    public func setExportCursor(endpoint: String, lastTs: String) throws {
        try database.run(
            """
            INSERT INTO otlp_cursor (endpoint, last_ts, updated_at) VALUES (?1, ?2, ?3)
            ON CONFLICT(endpoint) DO UPDATE SET last_ts = excluded.last_ts, updated_at = excluded.updated_at;
            """,
            [.text(endpoint), .text(lastTs), .text(Timestamps.now())]
        )
    }

    public func agentTree(sessionId: String) throws -> AgentTree {
        AgentTree.build(sessionId: sessionId, agents: try agents(sessionId: sessionId))
    }

    public func agentCount() throws -> Int {
        try database.query("SELECT COUNT(*) FROM agent;") { $0.int(0) }.first ?? 0
    }

    public func events(
        sessionId: String,
        kind: String? = nil,
        scope: AgentScope = .mainThread
    ) throws -> [EventRow] {
        var sql = "SELECT id, session_id, agent_id, ts, kind, detail FROM event WHERE session_id = ?1"
        var bindings: [SQLiteValue] = [.text(sessionId)]
        if let kind {
            sql += " AND kind = ?2"
            bindings.append(.text(kind))
        }
        let (clause, scopeBindings) = Store.scopeSQL(scope, index: bindings.count + 1)
        sql += clause + " ORDER BY ts, id;"
        bindings += scopeBindings
        return try database.query(sql, bindings) { row in
            EventRow(
                id: row.text(0),
                sessionId: row.text(1),
                agentId: row.optionalText(2),
                ts: row.text(3),
                kind: row.text(4),
                detail: row.optionalText(5)
            )
        }
    }

    /// Context per turn with compaction markers — the chart's whole input.
    public func contextHistory(sessionId: String, scope: AgentScope = .mainThread) throws -> ContextHistory {
        ContextHistory.build(
            sessionId: sessionId,
            calls: try calls(sessionId: sessionId, scope: scope),
            events: try events(sessionId: sessionId, kind: EventKind.compaction.rawValue, scope: scope)
        )
    }

    /// The current window's make-up for one session (M7). Nil without turns.
    public func composition(sessionId: String, scope: AgentScope = .mainThread) throws -> ContextComposition? {
        ContextComposition.build(
            sessionId: sessionId,
            calls: try calls(sessionId: sessionId, scope: scope),
            // Unscoped on purpose: tool rows are selected by the call that made
            // them, which already belongs to exactly one stream.
            toolCalls: try toolCalls(sessionId: sessionId),
            events: try events(sessionId: sessionId, kind: EventKind.compaction.rawValue, scope: scope),
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
        /// Subagents this session spawned. Their turns are counted in `calls`
        /// and the token sums — they are real API calls — but never in the
        /// occupancy, which is the main thread's own window.
        public var agents: Int

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
          (SELECT model FROM call m WHERE m.session_id = c.session_id AND m.agent_id IS NULL ORDER BY m.ts DESC, m.turn_index DESC LIMIT 1),
          COUNT(*),
          SUM(c.input), SUM(c.output), SUM(c.cache_read), SUM(c.cache_write),
          (SELECT context_tokens FROM call l WHERE l.session_id = c.session_id AND l.agent_id IS NULL ORDER BY l.ts DESC, l.turn_index DESC LIMIT 1),
          (SELECT window_limit FROM call l WHERE l.session_id = c.session_id AND l.agent_id IS NULL ORDER BY l.ts DESC, l.turn_index DESC LIMIT 1),
          MIN(c.ts), MAX(c.ts),
          (SELECT COUNT(*) FROM tool_call t WHERE t.session_id = c.session_id),
          (SELECT COUNT(*) FROM event e WHERE e.session_id = c.session_id AND e.kind = 'compaction'),
          (SELECT COUNT(*) FROM agent a WHERE a.session_id = c.session_id)
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
                compactions: row.int(13),
                agents: row.int(14)
            )
        }
    }

    static let callColumns = """
    SELECT dedupe_key, ts, vendor, agent, agent_id, session_id, project, cwd, model,
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
            agentId: row.optionalText(4),
            sessionId: row.text(5),
            project: row.optionalText(6),
            cwd: row.optionalText(7),
            model: row.optionalText(8),
            input: row.int(9),
            output: row.int(10),
            cacheRead: row.int(11),
            cacheWrite: row.int(12),
            reasoning: row.optionalInt(13),
            webSearch: row.optionalInt(14),
            contextTokens: row.int(15),
            windowLimit: row.optionalInt(16),
            turnIndex: row.optionalInt(17),
            contextDelta: row.optionalInt(18),
            serviceTier: row.optionalText(19),
            stopReason: row.optionalText(20),
            durationMs: row.optionalInt(21),
            isSidechain: row.optionalBool(22),
            uuid: row.optionalText(23),
            parentUuid: row.optionalText(24),
            sourceFile: row.text(25),
            confidence: row.text(26),
            parserVersion: row.int(27)
        )
    }
}

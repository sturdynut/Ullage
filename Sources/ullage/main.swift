import Foundation
import UllageCore

// Debug CLI for the collector (plan §10, M2). No UI: a menu bar showing a wrong
// number is harder to debug than a CLI printing one.

// Line-buffered so `ullage watch | tee` shows turns as they happen rather than
// in 4KB bursts.
setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
ullage — Claude Code telemetry collector (debug CLI)

USAGE
  ullage ingest [path ...]   Ingest transcripts (default: ~/.claude/projects)
  ullage backfill [path ...] Ingest everything and report what is still missing
  ullage watch [path ...]    Tail transcripts live, printing the menu bar title
  ullage sessions            Per-session totals, grouped by project
  ullage agents <session>    The subagent tree for a session, with each one's window
  ullage latest              The single row that drives the menu bar
  ullage env <session>       The configuration snapshot for a session
  ullage history [--days N]  Activity per day and project (default: 30 days)
  ullage composition <sess>  What a session's context window is made of
  ullage otlp                Export everything measured to an OTLP collector
  ullage info                Resolved paths and row counts

OPTIONS
  --db <path>       Database file (default: $ULLAGE_DB or the app support path)
  --days <n>        Window for `history`, and for `otlp` spans
  --endpoint <url>  OTLP collector base URL, e.g. http://localhost:4318
  --dry-run         Print the OTLP payloads instead of sending them
  --metrics-only    Export metrics but no spans
  --traces-only     Export spans but no metrics
  --all             Export every span on disk, not just the window
  --verbose         Report malformed lines and skipped files
  -h, --help        This text

ENVIRONMENT
  CLAUDE_CONFIG_DIR              Overrides ~/.claude
  ULLAGE_DB                      Overrides the default database location
  OTEL_EXPORTER_OTLP_ENDPOINT    Collector base URL for `otlp`
  OTEL_EXPORTER_OTLP_HEADERS     key=value,key2=value2 sent with every request
"""

struct Options {
    var command = "help"
    var paths: [String] = []
    var databasePath: String = ClaudePaths.defaultDatabaseURL().path
    var verbose = false
    var days = 30
    var endpoint: String?
    var dryRun = false
    var metricsOnly = false
    var tracesOnly = false
    var everything = false
    /// `--days` was given explicitly, so it wins over the export cursor.
    var daysWasSet = false
}

func parseArguments(_ arguments: [String]) -> Options {
    var options = Options()
    var rest = arguments
    var positional: [String] = []
    while !rest.isEmpty {
        let argument = rest.removeFirst()
        switch argument {
        case "--db":
            if let value = rest.first { options.databasePath = (value as NSString).expandingTildeInPath; rest.removeFirst() }
        case "--verbose", "-v":
            options.verbose = true
        case "--days":
            if let value = rest.first, let days = Int(value) {
                options.days = days
                options.daysWasSet = true
                rest.removeFirst()
            }
        case "--endpoint":
            if let value = rest.first { options.endpoint = value; rest.removeFirst() }
        case "--dry-run":
            options.dryRun = true
        case "--metrics-only":
            options.metricsOnly = true
        case "--traces-only":
            options.tracesOnly = true
        case "--all":
            options.everything = true
        case "-h", "--help", "help":
            positional.append("help")
        default:
            positional.append(argument)
        }
    }
    if let command = positional.first {
        options.command = command
        options.paths = Array(positional.dropFirst())
    }
    return options
}

func thousands(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.groupingSeparator = ","
    return formatter.string(from: NSNumber(value: value)) ?? String(value)
}

/// Same rounding as the menu bar: floored, so 99.6% never reads as full.
func percent(_ fraction: Double?) -> String {
    guard let fraction else { return "?%" }
    return MenuBarFormatter.percentage(fraction)
}

/// Human-scale age. 30 minutes is the idle threshold the menu bar will use, so
/// minutes matter near zero and days matter far from it.
func relative(_ seconds: TimeInterval) -> String {
    switch seconds {
    case ..<90: return String(format: "%.0fs ago", seconds)
    case ..<5_400: return String(format: "%.0f min ago", seconds / 60)
    case ..<172_800: return String(format: "%.1f hours ago", seconds / 3_600)
    default: return String(format: "%.1f days ago", seconds / 86_400)
    }
}

/// Left-aligned, truncated with a marker so a clipped name never reads as a
/// complete one.
func pad(_ text: String, _ width: Int) -> String {
    // `>=` and a trailing space: a value that exactly fills the column, or is
    // clipped to fill it, would otherwise run straight into the next column.
    if text.count >= width { return String(text.prefix(width - 2)) + "… " }
    return text + String(repeating: " ", count: width - text.count)
}

/// Right-aligned and never truncated: clipping a number produces a different,
/// plausible-looking number, which is the one thing this project must not do.
/// An oversized value pushes the rest of the row instead.
func padLeft(_ text: String, _ width: Int) -> String {
    guard text.count < width else { return " " + text }
    return String(repeating: " ", count: width - text.count) + text
}

func transcriptPaths(under url: URL) -> [String] {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
    guard isDirectory.boolValue else { return url.pathExtension == "jsonl" ? [url.path] : [] }
    guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { return [] }
    return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }.map(\.path)
}

func report(_ stats: IngestStats) {
    print("""
    files      \(stats.filesScanned) scanned, \(stats.filesSkipped) skipped, \(stats.restartedFromZero) re-read from zero
    bytes      \(thousands(stats.bytesRead)) (\(stats.partialTailBytes) held back as a partial line)
    lines      \(stats.linesParsed) parsed, \(stats.linesSkipped) skipped, \(stats.malformedLines) malformed
    calls      \(stats.callsUpserted) upserted
    tools      \(stats.toolCallsUpserted) invocations, \(stats.toolResultsMatched) results joined, \(stats.toolResultsOrphaned) unmatched
    events     \(stats.eventsInserted) inserted
    agents     \(stats.agentsSeen) subagents, \(stats.agentSpawnsLinked) spawns linked to a parent turn
    sessions   \(stats.sessionEnvSnapshots) environment snapshots captured
    """)
}

func printSessions(_ store: Store) throws {
    let totals = try store.sessionTotals()
    guard !totals.isEmpty else {
        print("No sessions in the database yet. Run: ullage ingest")
        return
    }
    // Grouped by project, most recently active project first: a session id is
    // not a name, and neither is an agent's — the project is the one label the
    // person reading this already knows.
    var lastActivity: [String: String] = [:]
    for row in totals {
        let project = row.project ?? "—"
        lastActivity[project] = max(lastActivity[project] ?? "", row.lastTs)
    }
    let grouped = totals.sorted { left, right in
        let leftProject = left.project ?? "—", rightProject = right.project ?? "—"
        if leftProject != rightProject {
            let leftLast = lastActivity[leftProject] ?? "", rightLast = lastActivity[rightProject] ?? ""
            return leftLast != rightLast ? leftLast > rightLast : leftProject < rightProject
        }
        return left.lastTs > right.lastTs
    }

    print(pad("PROJECT", 22) + pad("SESSION", 10) + padLeft("CALLS", 6) + padLeft("TOOLS", 6)
        + padLeft("AGENTS", 7)
        + padLeft("CONTEXT", 10) + padLeft("OCC", 6) + padLeft("IN", 10) + padLeft("OUT", 10)
        + padLeft("CACHE R", 16) + padLeft("CACHE W", 12) + "  LAST")
    var lastProject = ""
    for totals in grouped {
        let project = totals.project ?? "—"
        let line = pad(project == lastProject ? "" : project, 22)
            + pad(String(totals.sessionId.prefix(8)), 10)
            + padLeft(String(totals.calls), 6)
            + padLeft(String(totals.toolCalls), 6)
            + padLeft(totals.agents > 0 ? String(totals.agents) : "—", 7)
            + padLeft(thousands(totals.lastContextTokens), 10)
            + padLeft(percent(totals.occupancy), 6)
            + padLeft(thousands(totals.input), 10)
            + padLeft(thousands(totals.output), 10)
            + padLeft(thousands(totals.cacheRead), 16)
            + padLeft(thousands(totals.cacheWrite), 12)
            + "  " + totals.lastTs
        print(line + (totals.compactions > 0 ? "  ⟲\(totals.compactions)" : ""))
        lastProject = project
    }
    print("""

    CONTEXT is the last turn's prompt tokens, not a sum: the cached prefix is
    re-sent every turn, so summing prompt counters across turns is meaningless.
    It is the main thread's window; each agent has its own — see `ullage agents`.
    OUT is a mid-stream snapshot and undercounts (plan §9 trap 2).
    """)
}

func printHistory(_ store: Store, days: Int) throws {
    let rows = try store.dailyActivity(days: days)
    guard !rows.isEmpty else {
        print("No activity in the last \(days) days.")
        return
    }
    print(pad("DAY", 12) + pad("PROJECT", 22) + padLeft("SESSIONS", 9) + padLeft("CALLS", 7)
        + padLeft("IN", 10) + padLeft("OUT", 10) + padLeft("CACHE R", 16) + padLeft("CACHE W", 12) + padLeft("PEAK CTX", 10))
    var lastDay = ""
    for row in rows {
        print(pad(row.day == lastDay ? "" : row.day, 12) + pad(row.project, 22)
            + padLeft(String(row.sessions), 9) + padLeft(String(row.calls), 7)
            + padLeft(thousands(row.input), 10) + padLeft(thousands(row.output), 10)
            + padLeft(thousands(row.cacheRead), 16) + padLeft(thousands(row.cacheWrite), 12)
            + padLeft(thousands(row.peakContextTokens), 10))
        lastDay = row.day
    }
    print("""

    Days are local time. The four token counters stay separate on purpose:
    CACHE R dwarfs the others and a single total would just be a cache-read number.
    """)
}

func printComposition(_ store: Store, sessionPrefix: String) throws {
    let matches = try store.recentSessions(limit: 10_000).map(\.sessionId).filter { $0.hasPrefix(sessionPrefix) }
    guard let sessionId = matches.first else {
        print("no session starting with \(sessionPrefix)")
        return
    }
    guard let c = try store.composition(sessionId: sessionId) else {
        print("no turns recorded for \(sessionId)")
        return
    }
    func line(_ name: String, _ tokens: Int, _ note: String) -> String {
        pad(name, 18) + padLeft(thousands(tokens), 10) + padLeft(percent(c.share(tokens)), 6) + "   " + note
    }
    let baselineNotes = [
        "system prompt, tool schemas, skills",
        c.claudeMdTokensEstimate.map { "CLAUDE.md ~\(thousands($0))" },
        c.mcpServers.isEmpty ? nil : "\(c.mcpServers.count) MCP servers",
        c.windowStartTurn == 0 ? "opening prompt" : "compaction summary",
    ].compactMap { $0 }.joined(separator: ", ")
    print("""
    session      \(c.sessionId)
    window       \(thousands(c.contextTokens)) / \(c.windowLimit.map(thousands) ?? "?")  \(percent(c.occupancy))   turns \(c.windowStartTurn)–\(c.lastTurn)\(c.compactions > 0 ? "  ⟲\(c.compactions)" : "")

    \(line(ContextComposition.baselineName, c.baseline, baselineNotes))
    \(line(ContextComposition.toolResultsName, c.toolResults, "estimated from result length"))
    \(line(ContextComposition.assistantOutputName, c.assistantOutput, "reported output; undercounts"))
    \(line(ContextComposition.otherName, c.other, c.estimatesOvershoot ? "estimates overshoot the window" : "prompts, thinking, tool inputs, estimate error"))
    """)
    if !c.tools.isEmpty {
        print(pad("TOOL", 44) + padLeft("CALLS", 7) + padLeft("RESULT TOKENS", 15))
        for tool in c.tools.prefix(15) {
            print(pad(tool.name, 44) + padLeft(String(tool.calls), 7) + padLeft(thousands(tool.resultTokens), 15))
        }
        if c.tools.count > 15 { print("… and \(c.tools.count - 15) more") }
    }
}

/// The tree the menu bar's popover draws, in text: who spawned whom, and how
/// full each one's own window got.
func printAgents(_ store: Store, sessionPrefix: String) throws {
    let matches = try store.sessionTotals().filter { $0.sessionId.hasPrefix(sessionPrefix) }
    guard let session = matches.first else {
        print("no session starting with \(sessionPrefix)")
        return
    }
    let tree = try store.agentTree(sessionId: session.sessionId)
    print("""
    session    \(session.sessionId)
    project    \(session.project ?? "—")
    """)
    print("")
    print(pad("AGENT", 42) + pad("TYPE", 19) + padLeft("TURNS", 6) + padLeft("CONTEXT", 10)
        + padLeft("OCC", 6) + padLeft("PEAK", 10) + padLeft("TOOLS", 6) + "  STATUS")

    // The main thread is the root of the tree it spawned, and its window is the
    // one the menu bar shows.
    print(pad("main thread", 42) + pad(session.model ?? "—", 19)
        + padLeft(String(session.calls - tree.flattened.reduce(0) { $0 + $1.agent.calls }), 6)
        + padLeft(thousands(session.lastContextTokens), 10)
        + padLeft(percent(session.occupancy), 6)
        + padLeft("", 10) + padLeft(String(session.toolCalls), 6))

    guard !tree.isEmpty else {
        print("")
        print("No subagents in this session.")
        return
    }
    for node in tree.flattened {
        let agent = node.agent
        let indent = String(repeating: "  ", count: node.depth + 1)
        print(pad(indent + agent.displayName, 42)
            + pad(agent.agentType ?? "—", 19)
            + padLeft(String(agent.calls), 6)
            + padLeft(agent.lastContextTokens.map(thousands) ?? "—", 10)
            + padLeft(percent(agent.occupancy), 6)
            + padLeft(agent.peakContextTokens.map(thousands) ?? "—", 10)
            + padLeft(String(agent.toolCalls), 6)
            + "  " + (agent.statusLabel ?? "completed"))
    }
    print("""

    Each agent's occupancy is its own window, never the session's: a subagent
    starts from an empty context and is named by the agent that spawned it.
    AGENT is that name — the description the parent wrote — falling back to the
    agent type when the spawn is not on disk.
    """)
}

func printLatest(_ store: Store) throws {
    guard let call = try store.latestCall() else {
        print("No calls in the database yet. Run: ullage ingest")
        return
    }
    let age = Timestamps.date(from: call.ts).map { Date().timeIntervalSince($0) }
    print("""
    session    \(call.sessionId)
    project    \(call.project ?? "—")
    model      \(call.model ?? "—")\(WindowLimits.isKnown(call.model) ? "" : "  (window assumed)")
    context    \(thousands(call.contextTokens)) / \(call.windowLimit.map(thousands) ?? "?")  \(percent(call.occupancy))
    delta      \(call.contextDelta.map { ($0 >= 0 ? "+" : "") + thousands($0) } ?? "—")
    turn       \(call.turnIndex.map(String.init) ?? "—")
    ts         \(call.ts)\(age.map { "  (" + relative($0) + ")" } ?? "")
    """)
}

func warnAboutRetention() {
    guard let warning = Retention.warning(for: Retention.status()) else { return }
    FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
}

func targetURLs(_ options: Options) -> [URL] {
    options.paths.isEmpty
        ? TranscriptSources.roots()
        : options.paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
}

func ingest(_ ingestor: Ingestor, targets: [URL]) throws -> IngestStats {
    var stats = IngestStats()
    for target in targets {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) else {
            FileHandle.standardError.write(Data("warning: no such path: \(target.path)\n".utf8))
            continue
        }
        stats = stats + (isDirectory.boolValue
            ? try ingestor.ingestDirectory(at: target)
            : try ingestor.ingestFile(at: target))
    }
    return stats
}

/// What the menu bar would be showing right now.
func menuBarLine(_ store: Store) throws -> String {
    let state = MenuBarFormatter.state(for: try store.latestCall())
    let detail = [
        state.project,
        state.contextTokens.map { "\(thousands($0)) ctx" },
        state.contextDelta.map { ($0 >= 0 ? "+" : "") + thousands($0) },
        state.sessionId.map { String($0.prefix(8)) },
    ].compactMap { $0 }.joined(separator: "  ")
    let title = state.isIdle ? "\(state.title) idle" : state.title
    return "[\(Timestamps.now())] \(pad(title, 10)) \(detail)"
}

let options = parseArguments(Array(CommandLine.arguments.dropFirst()))

do {
    switch options.command {
    case "ingest":
        let store = try Store(path: options.databasePath)
        let ingestor = Ingestor(store: store)
        if options.verbose { ingestor.onWarning = { FileHandle.standardError.write(Data(("warning: " + $0 + "\n").utf8)) } }
        report(try ingest(ingestor, targets: targetURLs(options)))
        print("")
        try printSessions(store)

    case "backfill":
        // Time-sensitive: every day without this is a day of history that has
        // already aged out of ~/.claude and cannot be recovered.
        warnAboutRetention()
        let store = try Store(path: options.databasePath)
        let ingestor = Ingestor(store: store)
        if options.verbose { ingestor.onWarning = { FileHandle.standardError.write(Data(("warning: " + $0 + "\n").utf8)) } }
        let targets = targetURLs(options)
        report(try ingest(ingestor, targets: targets))

        let transcripts = targets.flatMap { transcriptPaths(under: $0) }
        let ingested = try store.database.query("SELECT COUNT(DISTINCT source_file) FROM call;") { $0.int(0) }.first ?? 0
        let missingEnv = try store.sessionsMissingEnv()
        print("")
        print("""
        transcripts on disk       \(transcripts.count)
        transcripts with rows     \(ingested)
        sessions in database      \(try store.sessionTotals().count)
        subagents in database     \(try store.agentCount())
        environment snapshots     \(try store.sessionEnvCount())\(missingEnv.isEmpty ? "" : "  (\(missingEnv.count) sessions without one)")
        """)
        if transcripts.count != ingested {
            print("")
            print("Transcripts without rows are normal: a file with no assistant entries has")
            print("nothing to record. Re-run with --verbose to see anything that failed to parse.")
        }

    case "watch":
        warnAboutRetention()
        let store = try Store(path: options.databasePath)
        let ingestor = Ingestor(store: store)
        if options.verbose { ingestor.onWarning = { FileHandle.standardError.write(Data(("warning: " + $0 + "\n").utf8)) } }
        let readStore = try Store(path: options.databasePath)   // WAL: writer plus reader
        let tailer = SessionTailer(ingestor: ingestor)
        let targets = targetURLs(options)
        tailer.onError = { FileHandle.standardError.write(Data("error: \($0)\n".utf8)) }
        tailer.onIngest = { stats in
            guard stats.callsUpserted > 0 else { return }
            if let line = try? menuBarLine(readStore) { print(line) }
        }
        try tailer.start(roots: targets)
        print("watching \(targets.map(\.path).joined(separator: ", "))  (ctrl-c to stop)")
        print(try menuBarLine(readStore))
        // dispatchMain() never returns, so nothing here is "used" again and ARC
        // would be within its rights to tear the tailer down — which stops the
        // watch without stopping the process.
        withExtendedLifetime((tailer, readStore)) { dispatchMain() }

    case "env":
        let store = try Store(path: options.databasePath)
        guard let needle = options.paths.first else {
            print("usage: ullage env <session-id or prefix>")
            break
        }
        let sessions = try store.sessionTotals().map(\.sessionId).filter { $0.hasPrefix(needle) }
        guard let sessionId = sessions.first else {
            print("no session starting with \(needle)")
            break
        }
        guard let env = try store.sessionEnv(sessionId: sessionId) else {
            print("no environment snapshot for \(sessionId)")
            break
        }
        print("""
        session        \(env.sessionId)
        captured at    \(env.capturedAt)
        claude version \(env.claudeVersion ?? "—")
        mcp servers    \(env.mcpServers ?? "—")
        skills         \(env.skills ?? "—")
        CLAUDE.md      \(env.claudeMdBytes.map { "\(thousands($0)) bytes" } ?? "—")  \(env.claudeMdHash?.prefix(12) ?? "")
        """)

    case "sessions":
        try printSessions(Store(path: options.databasePath))

    case "agents":
        guard let needle = options.paths.first else {
            print("usage: ullage agents <session-id or prefix>")
            break
        }
        try printAgents(Store(path: options.databasePath), sessionPrefix: needle)

    case "latest":
        try printLatest(Store(path: options.databasePath))

    case "history":
        try printHistory(Store(path: options.databasePath), days: options.days)

    case "composition":
        guard let needle = options.paths.first else {
            print("usage: ullage composition <session-id or prefix>")
            break
        }
        try printComposition(Store(path: options.databasePath), sessionPrefix: needle)

    case "otlp":
        let store = try Store(path: options.databasePath)
        var endpoint = OTLPEndpoint.fromEnvironment()
        if let raw = options.endpoint {
            guard let url = URL(string: raw) else {
                FileHandle.standardError.write(Data("error: not a URL: \(raw)\n".utf8))
                exit(1)
            }
            endpoint.base = url
        }
        let destination = endpoint.metricsURL?.absoluteString ?? "(dry run)"
        if !options.dryRun, endpoint.base == nil, endpoint.metricsURL == nil {
            FileHandle.standardError.write(Data("error: \(OTLPError.noEndpoint)\n".utf8))
            exit(1)
        }

        // Spans are not idempotent, so the default window is wherever the last
        // successful export to this endpoint got to. `--days` and `--all`
        // override it; a first run without either sends the last `--days`.
        let cursorKey = endpoint.tracesURL?.absoluteString ?? "dry-run"
        let windowStart = Timestamps.string(from: Date().addingTimeInterval(-Double(options.days) * 86_400))
        var since: String? = windowStart
        if options.everything {
            since = nil
        } else if !options.daysWasSet, let stored = try store.exportCursor(endpoint: cursorKey) {
            since = stored
        }

        let exporter = OTLPExporter(
            store: store,
            endpoint: endpoint,
            resource: OTLPResource(serviceVersion: "parser-v\(ClaudeCodeParser.version)")
        )
        let summary = try exporter.export(
            metrics: !options.tracesOnly,
            traces: !options.metricsOnly,
            since: since,
            dryRun: options.dryRun,
            onPayload: options.dryRun ? { _, body in print(String(decoding: body, as: UTF8.self)) } : nil
        )
        if !options.dryRun, let lastTs = summary.lastTs {
            try store.setExportCursor(endpoint: cursorKey, lastTs: lastTs)
        }
        let bytes = summary.metricsBytes + summary.traceBytes
        print("""
        endpoint   \(options.dryRun ? "dry run — nothing sent" : destination)
        metrics    \(summary.metricPoints) data points over \(summary.streams) streams
        traces     \(summary.spans) spans over \(summary.sessions) sessions\(since.map { " since \($0)" } ?? " (all history)")
        payload    \(thousands(bytes)) bytes in \(summary.requests == 0 ? "no" : String(summary.requests)) request\(summary.requests == 1 ? "" : "s")
        cursor     \(summary.lastTs ?? "unchanged")\(options.dryRun ? "  (not recorded: dry run)" : "")
        """)
        print("")
        print("""
        The four token counters travel as separate series (ullage.tokens, by
        ullage.token.type) and are never summed. gen_ai.usage.input_tokens carries
        the whole prompt — input + cache_read + cache_write — because that is what
        the convention means by it. Rows from a harness that reports no tokens
        export activity only.
        """)

    case "info":
        let store = try Store(path: options.databasePath)
        print("""
        database   \(options.databasePath)
        sources    \(TranscriptSources.roots().map(\.path).joined(separator: ", "))
        parser     v\(ClaudeCodeParser.version)
        retention  \(Retention.status())
        rows       \(try store.callCount()) calls, \(try store.toolCallCount()) tool calls, \(try store.eventCount()) events, \(try store.agentCount()) agents, \(try store.sessionEnvCount()) env snapshots
        menu bar   \(try menuBarLine(store))
        """)
        warnAboutRetention()

    default:
        print(usage)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}

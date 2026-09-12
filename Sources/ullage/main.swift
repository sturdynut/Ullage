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
  ullage sessions            Per-session totals from the database
  ullage latest              The single row that drives the menu bar
  ullage env <session>       The configuration snapshot for a session
  ullage info                Resolved paths and row counts

OPTIONS
  --db <path>    Database file (default: $ULLAGE_DB or the app support path)
  --verbose      Report malformed lines and skipped files
  -h, --help     This text

ENVIRONMENT
  CLAUDE_CONFIG_DIR   Overrides ~/.claude
  ULLAGE_DB           Overrides the default database location
"""

struct Options {
    var command = "help"
    var paths: [String] = []
    var databasePath: String = ClaudePaths.defaultDatabaseURL().path
    var verbose = false
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
    if text.count > width { return String(text.prefix(width - 1)) + "…" }
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
    sessions   \(stats.sessionEnvSnapshots) environment snapshots captured
    """)
}

func printSessions(_ store: Store) throws {
    let totals = try store.sessionTotals()
    guard !totals.isEmpty else {
        print("No sessions in the database yet. Run: ullage ingest")
        return
    }
    print(pad("PROJECT", 22) + pad("SESSION", 10) + padLeft("CALLS", 6) + padLeft("TOOLS", 6)
        + padLeft("CONTEXT", 10) + padLeft("OCC", 6) + padLeft("IN", 10) + padLeft("OUT", 10)
        + padLeft("CACHE R", 16) + padLeft("CACHE W", 12) + "  LAST")
    for totals in totals {
        let line = pad(totals.project ?? "—", 22)
            + pad(String(totals.sessionId.prefix(8)), 10)
            + padLeft(String(totals.calls), 6)
            + padLeft(String(totals.toolCalls), 6)
            + padLeft(thousands(totals.lastContextTokens), 10)
            + padLeft(percent(totals.occupancy), 6)
            + padLeft(thousands(totals.input), 10)
            + padLeft(thousands(totals.output), 10)
            + padLeft(thousands(totals.cacheRead), 16)
            + padLeft(thousands(totals.cacheWrite), 12)
            + "  " + totals.lastTs
        print(line + (totals.compactions > 0 ? "  ⟲\(totals.compactions)" : ""))
    }
    print("""

    CONTEXT is the last turn's prompt tokens, not a sum: the cached prefix is
    re-sent every turn, so summing prompt counters across turns is meaningless.
    OUT is a mid-stream snapshot and undercounts (plan §9 trap 2).
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
        ? ClaudePaths.projectsDirectories()
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

    case "latest":
        try printLatest(Store(path: options.databasePath))

    case "info":
        let store = try Store(path: options.databasePath)
        print("""
        database   \(options.databasePath)
        projects   \(ClaudePaths.projectsDirectories().map(\.path).joined(separator: ", "))
        parser     v\(ClaudeCodeParser.version)
        retention  \(Retention.status())
        rows       \(try store.callCount()) calls, \(try store.toolCallCount()) tool calls, \(try store.eventCount()) events, \(try store.sessionEnvCount()) env snapshots
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

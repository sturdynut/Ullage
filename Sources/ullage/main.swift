import Foundation
import UllageCore

// Debug CLI for the collector (plan §10, M2). No UI: a menu bar showing a wrong
// number is harder to debug than a CLI printing one.

let usage = """
ullage — Claude Code telemetry collector (debug CLI)

USAGE
  ullage ingest [path ...]   Ingest transcripts (default: ~/.claude/projects)
  ullage sessions            Per-session totals from the database
  ullage latest              The single row that drives the menu bar
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

func percent(_ fraction: Double?) -> String {
    guard let fraction else { return "  ?%" }
    return String(format: "%3.0f%%", fraction * 100)
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

func report(_ stats: IngestStats) {
    print("""
    files      \(stats.filesScanned) scanned, \(stats.filesSkipped) skipped, \(stats.restartedFromZero) re-read from zero
    bytes      \(thousands(stats.bytesRead)) (\(stats.partialTailBytes) held back as a partial line)
    lines      \(stats.linesParsed) parsed, \(stats.linesSkipped) skipped, \(stats.malformedLines) malformed
    calls      \(stats.callsUpserted) upserted
    tools      \(stats.toolCallsUpserted) invocations, \(stats.toolResultsMatched) results joined, \(stats.toolResultsOrphaned) unmatched
    events     \(stats.eventsInserted) inserted
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

let options = parseArguments(Array(CommandLine.arguments.dropFirst()))

do {
    switch options.command {
    case "ingest":
        let store = try Store(path: options.databasePath)
        let ingestor = Ingestor(store: store)
        if options.verbose { ingestor.onWarning = { FileHandle.standardError.write(Data(("warning: " + $0 + "\n").utf8)) } }

        let targets: [URL] = options.paths.isEmpty
            ? ClaudePaths.projectsDirectories()
            : options.paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }

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
        report(stats)
        print("")
        try printSessions(store)

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
        rows       \(try store.callCount()) calls, \(try store.toolCallCount()) tool calls, \(try store.eventCount()) events
        """)

    default:
        print(usage)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}

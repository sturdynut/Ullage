import Foundation

/// A per-file transcript parser. Reference type because some formats (Codex)
/// carry state across lines within a file.
public protocol TranscriptLineParser: AnyObject {
    func parse(line: Data, context: LineContext) -> ParsedLine?
}

/// Reads a whole store at once: a JSON document rewritten in place (Cline's
/// `ui_messages.json`), or a SQLite database (OpenCode). Called again whenever
/// the file or its `-wal` changes; dedupe keys make that idempotent. Never
/// throws for content — a malformed record is skipped (rule 5).
public protocol TranscriptDocumentReader {
    func read(file: URL, context: LineContext) -> [ParsedLine]
}

/// One coding agent Ullage can read: where its files are, how to read them,
/// and what they record. Everything downstream works from `Harness.all`, and
/// asks `capabilities` rather than checking which harness it is — adding a
/// harness is adding one of these, not branching anywhere else.
public struct Harness: @unchecked Sendable, Equatable, Identifiable {
    public enum Reading {
        /// JSONL. `tail` reads appends from a byte cursor (self-contained
        /// lines); otherwise the file is re-read from zero on every change.
        case lines(tail: Bool, parser: () -> TranscriptLineParser)
        case document(() -> TranscriptDocumentReader)
    }

    /// Stored as `call.vendor`.
    public let id: String
    public let name: String
    public let capabilities: HarnessCapabilities
    /// Directories (or single files) to sweep and watch.
    public let roots: ([String: String]) -> [URL]
    /// True when `path` is one of this harness's transcript files.
    public let owns: (String) -> Bool
    public let reading: Reading

    public init(
        id: String, name: String, capabilities: HarnessCapabilities,
        roots: @escaping ([String: String]) -> [URL],
        owns: @escaping (String) -> Bool,
        reading: Reading
    ) {
        self.id = id
        self.name = name
        self.capabilities = capabilities
        self.roots = roots
        self.owns = owns
        self.reading = reading
    }

    public static func == (a: Harness, b: Harness) -> Bool { a.id == b.id }

    /// Every harness Ullage reads. Claude Code is last: it is the fallback
    /// for any `.jsonl` no other harness claims (tests and `ullage ingest`
    /// point it at arbitrary folders).
    public static let all: [Harness] = registered + [.claudeCode]

    /// Everything but Claude Code, in the order they are tried.
    static var registered: [Harness] {
        [.codex, .cursor] + HarnessRegistry.extra
    }

    /// The harness that owns `path`, or nil when it is no transcript at all.
    /// A SQLite `-wal`/`-shm` resolves to its database.
    public static func owning(_ path: String) -> Harness? {
        let path = databasePath(path)
        if let harness = registered.first(where: { $0.owns(path) }) { return harness }
        // Another harness's data folder can hold its own logs or users' git
        // checkouts; a `.jsonl` there is never a Claude session.
        guard path.hasSuffix(".jsonl"), !otherRoots.contains(where: { path.hasPrefix($0) }) else { return nil }
        return .claudeCode
    }

    /// Every non-Claude harness's root, as a folder prefix, unless it is also
    /// inside Claude's own (an override pointing both at one folder).
    static let otherRoots: [String] = {
        let claude = Harness.claudeCode.roots(ProcessInfo.processInfo.environment).map { $0.standardizedFileURL.path + "/" }
        return registered.flatMap { $0.roots(ProcessInfo.processInfo.environment) }
            .map { $0.standardizedFileURL.path + "/" }
            .filter { root in !claude.contains { root.hasPrefix($0) || $0.hasPrefix(root) } }
    }()

    /// `x.db-wal` → `x.db`: a write to a database lands in its WAL first.
    public static func databasePath(_ path: String) -> String {
        for suffix in ["-wal", "-shm", "-journal"] where path.hasSuffix(suffix) {
            return String(path.dropLast(suffix.count))
        }
        return path
    }

    public static func detect(path: String) -> Harness { owning(path) ?? .claudeCode }

    public static func named(_ vendor: String?) -> Harness? { all.first { $0.id == vendor } }

    /// Display name for a stored vendor, never empty.
    public static func displayName(_ vendor: String?) -> String {
        named(vendor)?.name ?? vendor ?? "Unknown"
    }

    public static func roots(environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        var seen = Set<String>()
        return ([Harness.claudeCode] + registered).flatMap { $0.roots(environment) }
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    // Compatibility with the format-centric API.
    public var reingestsWholeFile: Bool {
        if case .lines(let tail, _) = reading { return !tail }
        return true
    }

    public func makeParser() -> TranscriptLineParser {
        if case .lines(_, let parser) = reading { return parser() }
        preconditionFailure("\(id) is read as a document")
    }
}

public typealias TranscriptFormat = Harness

/// Where harnesses beyond the first three register; one line each.
enum HarnessRegistry {
    static let extra: [Harness] = [.opencode, .droid, .pi, .amp, .geminiCLI, .qwenCode, .copilotVSCode, .copilotCLI, .zed, .aider, .goose, .crush]
}

/// What a harness writes down, so each part of Ullage can say plainly when a
/// figure isn't available rather than show nothing, or something made up.
public struct HarnessCapabilities: Sendable, Equatable {
    public enum Occupancy: String, Sendable {
        /// Prompt tokens for every model call.
        case everyCall
        /// One reading per user request (the last call of its loop).
        case perRequest
        /// Only the latest turn of a session, overwritten in place.
        case latestOnly
        /// Rounded or otherwise approximate figures; never a gauge.
        case approximate
        /// No token counts at all.
        case none
    }

    public enum Window: String, Sendable {
        /// The harness writes the window beside each turn (Codex).
        case reported
        /// Looked up from the model (`WindowLimits`); unknown models get none.
        case lookup
        case none
    }

    public var occupancy: Occupancy
    public var window: Window
    /// Cache reads and writes reported apart from fresh input.
    public var cacheSplit: Bool
    public var model: Bool
    public var timestamps: Bool
    public var subagents: Bool
    /// Tool results with sizes, for the Context breakdown.
    public var toolResults: Bool
    public var compaction: Bool
    public var effort: Bool
    public var planLimits: Bool
    /// Hooks, MCP servers and plugins, for Context tools.
    public var contextTools: Bool
    /// The format was read off real files on a Mac, not only from the
    /// harness's source code or docs.
    public var verifiedOnDisk: Bool
    /// Anything else a reader should know, one sentence each.
    public var notes: [String]

    public init(
        occupancy: Occupancy, window: Window, cacheSplit: Bool, model: Bool = true, timestamps: Bool = true,
        subagents: Bool = false, toolResults: Bool = false, compaction: Bool = false, effort: Bool = false,
        planLimits: Bool = false, contextTools: Bool = false, verifiedOnDisk: Bool = false, notes: [String] = []
    ) {
        self.occupancy = occupancy
        self.window = window
        self.cacheSplit = cacheSplit
        self.model = model
        self.timestamps = timestamps
        self.subagents = subagents
        self.toolResults = toolResults
        self.compaction = compaction
        self.effort = effort
        self.planLimits = planLimits
        self.contextTools = contextTools
        self.verifiedOnDisk = verifiedOnDisk
        self.notes = notes
    }

    public var hasGauge: Bool {
        [.everyCall, .perRequest, .latestOnly].contains(occupancy) && window != .none
    }
}

// MARK: - The original three

extension Harness {
    public static let claudeCode = Harness(
        id: Vendor.claudeCode, name: "Claude Code",
        capabilities: .init(occupancy: .everyCall, window: .lookup, cacheSplit: true, subagents: true, toolResults: true,
                            compaction: true, effort: true, planLimits: true, contextTools: true, verifiedOnDisk: true),
        roots: { ClaudePaths.projectsDirectories(environment: $0) },
        owns: { $0.hasSuffix(".jsonl") },
        reading: .lines(tail: true, parser: { ClaudeCodeLineParser() })
    )

    public static let codex = Harness(
        id: Vendor.codex, name: "Codex",
        capabilities: .init(occupancy: .everyCall, window: .reported, cacheSplit: true, toolResults: true,
                            compaction: true, effort: true, planLimits: true, verifiedOnDisk: true,
                            notes: ["Codex reports cached input but not cache writes."]),
        roots: { CodexPaths.sessionsDirectories(environment: $0) },
        owns: CodexPaths.isCodexTranscript,
        reading: .lines(tail: false, parser: { CodexParser() })
    )

    public static let cursor = Harness(
        id: Vendor.cursor, name: "Cursor",
        capabilities: .init(occupancy: .none, window: .none, cacheSplit: false, model: false, timestamps: false,
                            verifiedOnDisk: true,
                            notes: ["Cursor keeps usage on its servers; its local transcripts hold only the conversation."]),
        roots: { CursorPaths.projectsDirectories(environment: $0) },
        owns: CursorPaths.isCursorTranscript,
        reading: .lines(tail: false, parser: { CursorParser() })
    )
}

/// Stateless adapter over the Claude Code parser so every line format shares
/// one ingest loop.
public final class ClaudeCodeLineParser: TranscriptLineParser {
    public init() {}
    public func parse(line: Data, context: LineContext) -> ParsedLine? {
        ClaudeCodeParser.parse(line: line, context: context)
    }
}

public enum TranscriptSources {
    public static func roots(environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        Harness.roots(environment: environment)
    }
}

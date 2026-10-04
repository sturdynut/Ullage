import Foundation

extension Vendor {
    public static let crush = "crush"
}

/// Where Crush (charmbracelet/crush) keeps its databases.
///
/// Each project has its own `<project>/.crush/crush.db` (the data directory is
/// configurable). Crush records every project it runs in, with its data
/// directory, in `projects.json` beside its global data file:
/// `$CRUSH_GLOBAL_DATA`, else `$XDG_DATA_HOME/crush`, else
/// `~/.local/share/crush` (`internal/config/load.go`, `internal/projects/projects.go`).
public enum CrushPaths {
    public static func globalDataDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let dir = environment["CRUSH_GLOBAL_DATA"], !dir.isEmpty {
            return URL(fileURLWithPath: ClaudePaths.expand(dir), isDirectory: true)
        }
        if let xdg = environment["XDG_DATA_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: ClaudePaths.expand(xdg), isDirectory: true).appendingPathComponent("crush", isDirectory: true)
        }
        return ClaudePaths.homeDirectory().appendingPathComponent(".local/share/crush", isDirectory: true)
    }

    /// Each registered project's data directory (the folder holding
    /// `crush.db`). Missing or malformed `projects.json` gives none.
    public static func dataDirectories(environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        let file = globalDataDirectory(environment: environment).appendingPathComponent("projects.json")
        guard let data = try? Data(contentsOf: file),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let projects = JSONAccess.list(root, "projects") else { return [] }
        return projects.compactMap { item in
            guard let project = item as? [String: Any] else { return nil }
            if let dir = JSONAccess.string(project, "data_dir"), dir.hasPrefix("/") {
                return URL(fileURLWithPath: dir, isDirectory: true)
            }
            return JSONAccess.string(project, "path").map {
                URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(".crush", isDirectory: true)
            }
        }
    }

    public static func isCrushDatabase(_ path: String) -> Bool { path.hasSuffix("/crush.db") }
}

/// Reads a Crush `crush.db` (SQLite, read-only).
///
/// Crush keeps no per-call usage. `sessions.prompt_tokens` is overwritten
/// after every step with that step's `input + cache_read + cache_write`
/// (`internal/agent/agent.go` `contextTokens`), so it is the session's
/// *latest* context, without the split. One row per session, keyed by the
/// session, updated in place.
public struct CrushReader: TranscriptDocumentReader {
    public static let version = 1

    public init() {}

    public func read(file: URL, context: LineContext) -> [ParsedLine] {
        guard FileManager.default.fileExists(atPath: file.path),
              let db = try? SQLiteDatabase(path: file.path, readOnly: true) else { return [] }
        let columns = Set((try? db.query("PRAGMA table_info(sessions);") { $0.text(1) }) ?? [])
        guard ["id", "prompt_tokens", "completion_tokens", "updated_at"].allSatisfy(columns.contains) else { return [] }
        let parent = columns.contains("parent_session_id") ? "s.parent_session_id" : "NULL"
        let messageColumns = Set((try? db.query("PRAGMA table_info(messages);") { $0.text(1) }) ?? [])
        // The model of the newest assistant message: the one that produced
        // the latest reading.
        let model = messageColumns.isSuperset(of: ["model", "session_id", "role", "created_at"])
            ? "(SELECT m.model FROM messages m WHERE m.session_id = s.id AND m.role = 'assistant' AND m.model IS NOT NULL ORDER BY m.created_at DESC LIMIT 1)"
            : "NULL"
        let sql = "SELECT s.id, \(parent), s.prompt_tokens, s.completion_tokens, s.updated_at, \(model) FROM sessions s;"

        let cwd = Self.projectDirectory(of: file)
        let rows = (try? db.query(sql) { row -> ParsedLine? in
            let id = row.text(0)
            guard !id.isEmpty else { return nil }
            let parentId = row.optionalText(1).flatMap { $0.isEmpty || $0 == id ? nil : $0 }
            let prompt = max(0, row.int(2))
            let output = max(0, row.int(3))
            let model = row.optionalText(5).flatMap { $0.isEmpty ? nil : $0 }
            let ts = Timestamps.string(from: Date(timeIntervalSince1970: TimeInterval(row.int(4))))
            // After a summary Crush sets prompt_tokens to 0: no reading yet.
            let measured = prompt > 0
            let call = CallRow(
                dedupeKey: "crush:\(id)", ts: ts, vendor: Vendor.crush, agentId: parentId == nil ? nil : id,
                sessionId: parentId ?? id, project: cwd.map { URL(fileURLWithPath: $0).lastPathComponent }, cwd: cwd,
                model: model,
                // The split is not stored: the whole prompt goes in `input`,
                // which is what `contextTokens` sums to either way.
                input: prompt, output: output, cacheRead: 0, cacheWrite: 0,
                contextTokens: prompt,
                windowLimit: measured ? WindowLimits.knownLimit(for: model) : nil,
                sourceFile: context.sourceFile,
                confidence: (measured ? Confidence.exact : .unmeasured).rawValue,
                parserVersion: Self.version
            )
            return .call(ParsedCall(call: call, toolCalls: [], claudeVersion: nil))
        }) ?? []
        return rows.compactMap { $0 }
    }

    /// `<project>/.crush/crush.db` → `<project>`. A custom data directory says
    /// nothing reliable about the project, so it gets none.
    static func projectDirectory(of file: URL) -> String? {
        let dir = file.deletingLastPathComponent()
        guard dir.lastPathComponent == ".crush" else { return nil }
        return dir.deletingLastPathComponent().path
    }
}

extension Harness {
    public static let crush = Harness(
        id: Vendor.crush, name: "Crush",
        capabilities: .init(
            occupancy: .latestOnly, window: .lookup, cacheSplit: false,
            notes: [
                "Crush keeps only each session's latest context, so a session is one reading that moves, not a chart.",
                "Cache reads and writes are folded into the prompt figure, so cache is not shown apart.",
                "When a provider reports no usage, Crush stores its own estimate in the same column, and the two can't be told apart.",
                "Projects are found through Crush's projects.json; a project Crush never registered is not seen.",
            ]
        ),
        roots: { CrushPaths.dataDirectories(environment: $0) },
        owns: CrushPaths.isCrushDatabase,
        reading: .document { CrushReader() }
    )
}

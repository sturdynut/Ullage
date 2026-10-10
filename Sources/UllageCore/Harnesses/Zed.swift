import Foundation

extension Vendor {
    public static let zed = "zed"
}

/// Where Zed's agent panel keeps its threads: `<data_dir>/threads/threads.db`,
/// with `data_dir` = `~/Library/Application Support/Zed` on macOS and
/// `$FLATPAK_XDG_DATA_HOME|$XDG_DATA_HOME|~/.local/share` + `/zed` on Linux
/// (`crates/paths/src/paths.rs` `data_dir`). `ZED_DATA_DIR` here points
/// Ullage at another data directory (Zed's own `--user-data-dir`).
public enum ZedPaths {
    public static func threadsDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let dir = environment["ZED_DATA_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: ClaudePaths.expand(dir), isDirectory: true).appendingPathComponent("threads", isDirectory: true)
        }
        #if os(macOS)
        return ClaudePaths.homeDirectory().appendingPathComponent("Library/Application Support/Zed/threads", isDirectory: true)
        #else
        let base = (environment["FLATPAK_XDG_DATA_HOME"] ?? environment["XDG_DATA_HOME"]).flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: ClaudePaths.expand($0), isDirectory: true)
        } ?? ClaudePaths.homeDirectory().appendingPathComponent(".local/share", isDirectory: true)
        return base.appendingPathComponent("zed/threads", isDirectory: true)
        #endif
    }

    public static func isZedDatabase(_ path: String) -> Bool {
        path.hasSuffix("/threads/threads.db")
            && (path.contains("/Zed/") || path.contains("/zed/") || path.contains("/Zed Preview/") || path.contains("/Zed Nightly/"))
    }
}

/// Reads Zed's `threads.db` (SQLite, read-only).
///
/// Each row is one thread; `data` is the whole thread as JSON, and Zed has
/// written it **zstd-compressed** (`data_type = 'zstd'`) since the table
/// existed (`crates/agent/src/db.rs` `save_thread`). Foundation has no zstd,
/// so for those rows only the uncompressed columns are readable: one
/// activity row per thread, unmeasured. Rows stored as plain JSON
/// (`data_type = 'json'`) are read fully: `request_token_usage` holds the
/// last request's usage for each user message, Anthropic-shaped (four
/// disjoint counters), which is one reading per request.
public struct ZedReader: TranscriptDocumentReader {
    public static let version = 1

    public init() {}

    public func read(file: URL, context: LineContext) -> [ParsedLine] {
        guard FileManager.default.fileExists(atPath: file.path),
              let db = try? SQLiteDatabase(path: file.path, readOnly: true) else { return [] }
        let columns = Set((try? db.query("PRAGMA table_info(threads);") { $0.text(1) }) ?? [])
        guard ["id", "updated_at", "data_type", "data"].allSatisfy(columns.contains) else { return [] }
        func col(_ name: String) -> String { columns.contains(name) ? name : "NULL" }
        // `data` is only fetched when it is JSON; a zstd blob is never read.
        let sql = """
        SELECT id, \(col("parent_id")), \(col("folder_paths")), updated_at, data_type,
               CASE WHEN data_type = 'json' THEN data END
        FROM threads;
        """
        let rows = (try? db.query(sql) { row -> [ParsedLine] in
            let id = row.text(0)
            guard !id.isEmpty else { return [] }
            let parent = row.optionalText(1).flatMap { $0.isEmpty || $0 == id ? nil : $0 }
            let thread = Thread(
                id: id,
                session: parent ?? id,
                agent: parent == nil ? nil : id,
                cwd: row.optionalText(2).flatMap { $0.split(separator: "\n").first.map(String.init) },
                ts: Self.timestamp(row.text(3)) ?? context.fileModified ?? "",
                sourceFile: context.sourceFile
            )
            if row.text(4) == "json", let json = row.optionalText(5),
               let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
               let measured = Self.requests(in: object, thread: thread) {
                return measured
            }
            return [Self.activity(thread)]
        }) ?? []
        return rows.flatMap { $0 }
    }

    struct Thread {
        var id: String
        var session: String
        var agent: String?
        var cwd: String?
        var ts: String
        var sourceFile: String
        var project: String? { cwd.map { URL(fileURLWithPath: $0).lastPathComponent } }
    }

    /// One unmeasured row per thread: it existed and when it last changed.
    static func activity(_ thread: Thread) -> ParsedLine {
        .call(ParsedCall(call: CallRow(
            dedupeKey: "zed:\(thread.id)", ts: thread.ts, vendor: Vendor.zed, agentId: thread.agent,
            sessionId: thread.session, project: thread.project, cwd: thread.cwd, model: nil,
            contextTokens: 0, windowLimit: nil, sourceFile: thread.sourceFile,
            confidence: Confidence.unmeasured.rawValue, parserVersion: version
        ), toolCalls: [], claudeVersion: nil))
    }

    /// Per-request rows from a plain-JSON thread, in message order. Nil when
    /// the thread records no usage at all (then it is activity only).
    static func requests(in object: [String: Any], thread: Thread) -> [ParsedLine]? {
        guard let usage = JSONAccess.dict(object, "request_token_usage"), !usage.isEmpty else { return nil }
        let modelInfo = JSONAccess.dict(object, "model")
        let model = JSONAccess.string(modelInfo, "model")
        let window = WindowLimits.knownLimit(for: model)
        var lines: [ParsedLine] = []
        for message in JSONAccess.list(object, "messages") ?? [] {
            guard let user = JSONAccess.dict(message as? [String: Any], "User"),
                  let messageId = JSONAccess.string(user, "id"),
                  let counters = JSONAccess.dict(usage, messageId) else { continue }
            let input = JSONAccess.intOrZero(counters, "input_tokens")
            let output = JSONAccess.intOrZero(counters, "output_tokens")
            let cacheWrite = JSONAccess.intOrZero(counters, "cache_creation_input_tokens")
            let cacheRead = JSONAccess.intOrZero(counters, "cache_read_input_tokens")
            // A request that overflowed the window gets a synthesized entry
            // (`mark_token_limit_exceeded`): input set to the model's maximum,
            // nothing else. It is Zed's placeholder, not a measurement.
            guard output > 0 || cacheRead > 0 || cacheWrite > 0 else { continue }
            let call = CallRow(
                dedupeKey: "zed:\(thread.id):\(messageId)", ts: thread.ts, vendor: Vendor.zed, agentId: thread.agent,
                sessionId: thread.session, project: thread.project, cwd: thread.cwd, model: model,
                input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite,
                contextTokens: input + cacheRead + cacheWrite, windowLimit: window,
                sourceFile: thread.sourceFile, confidence: Confidence.exact.rawValue, parserVersion: version
            )
            lines.append(.call(ParsedCall(call: call, toolCalls: [], claudeVersion: nil)))
        }
        return lines.isEmpty ? nil : lines
    }

    /// Zed writes `to_rfc3339()`: `2025-10-04T12:00:00.123456789+00:00`.
    /// Fractions beyond milliseconds are dropped before parsing.
    static func timestamp(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        var text = raw
        if let dot = text.firstIndex(of: ".") {
            let digits = text[text.index(after: dot)...].prefix { $0.isNumber }
            let end = text.index(dot, offsetBy: digits.count + 1)
            text = String(text[..<dot]) + "." + String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
                + String(text[end...])
        }
        guard let date = Timestamps.date(from: text) else { return nil }
        return Timestamps.string(from: date)
    }
}

extension Harness {
    public static let zed = Harness(
        id: Vendor.zed, name: "Zed",
        capabilities: .init(
            occupancy: .none, window: .none, cacheSplit: false, model: false,
            subagents: true,
            notes: [
                "Zed stores each thread zstd-compressed, which Ullage can't decompress without a dependency, so a thread shows as activity only: when it changed, no tokens.",
                "A thread stored as plain JSON is read in full: one reading per request, with cache split and the model's window.",
                "Zed records no time per message, so a thread's rows all carry its last update time.",
            ]
        ),
        roots: { [ZedPaths.threadsDirectory(environment: $0)] },
        owns: ZedPaths.isZedDatabase,
        reading: .document { ZedReader() }
    )
}

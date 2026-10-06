import Foundation

/// One row of a token saver's own bookkeeping: what it says a command's
/// output was before and after it got to it.
///
/// These are *claims*, never measurements. rtk counts bytes ÷ 4; Tokenade does
/// not say. Ullage never sees the pre-shrink output, so it cannot check them —
/// it only matches them to sessions and shows them labelled as the tool's own.
/// They never enter a token counter, occupancy or composition.
public struct LedgerEntry: Equatable {
    public var saver: TokenSaver
    public var ts: Date
    public var cwd: String?
    public var command: String?
    public var beforeTokens: Int?
    public var afterTokens: Int?
    public var savedTokens: Int
    /// Stable within its ledger (`rtk:812`), so one entry matched to two
    /// overlapping sessions is still counted once over a range.
    public var id: String
    /// Set when the ledger itself names the session and the Bash call it
    /// was for (rtk's `hook_decisions`): matched exactly, not by time.
    public var sessionId: String?
    public var toolUseId: String?

    public init(
        saver: TokenSaver, ts: Date, cwd: String?, command: String?,
        beforeTokens: Int?, afterTokens: Int?, savedTokens: Int,
        id: String? = nil, sessionId: String? = nil, toolUseId: String? = nil
    ) {
        self.id = id ?? "\(saver.rawValue):\(ts.timeIntervalSince1970):\(command ?? ""):\(savedTokens)"
        self.sessionId = sessionId
        self.toolUseId = toolUseId
        self.saver = saver
        self.ts = ts
        self.cwd = cwd
        self.command = command
        self.beforeTokens = beforeTokens
        self.afterTokens = afterTokens
        self.savedTokens = savedTokens
    }
}

public enum SaverLedgers {
    /// Reads one kind of ledger. A tool's descriptor names its reader in
    /// `claims.reader`; a ledger format Ullage has no reader for is simply
    /// not shown — claims are optional, transcripts are the facts.
    public typealias Reader = @Sendable (_ since: Date?, _ environment: [String: String]) -> [LedgerEntry]

    /// The ledger formats Ullage can read, by the name descriptors use.
    public static let readers: [String: Reader] = [
        "rtk-history": { since, environment in rtkEntries(at: rtkDatabaseURL(environment: environment), since: since) },
        "tokenade-gain": { since, environment in tokenadeEntries(at: tokenadeLedgerURL(environment: environment), since: since) },
        "headroom-proxy": { since, environment in headroomEntries(at: headroomSavingsURL(environment: environment), since: since) },
    ]

    /// Every registered tool's ledger, from its default place.
    public static func load(
        since: Date? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [LedgerEntry] {
        TokenSaver.allCases.flatMap { tool -> [LedgerEntry] in
            guard let name = tool.descriptor.claims?.reader, let reader = readers[name] else { return [] }
            return reader(since, environment).map { entry in
                var entry = entry
                entry.saver = tool
                return entry
            }
        }
    }

    // MARK: - Paths

    /// rtk keeps `history.db` in the platform data directory (Rust's `dirs`):
    /// `~/Library/Application Support/rtk` on macOS, `$XDG_DATA_HOME/rtk` or
    /// `~/.local/share/rtk` elsewhere. `RTK_DB_PATH` overrides.
    public static func rtkDatabaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["RTK_DB_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: ClaudePaths.expand(override))
        }
        let home = ClaudePaths.homeDirectory()
        #if os(macOS)
        return home.appendingPathComponent("Library/Application Support/rtk/history.db")
        #else
        let base = environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: ClaudePaths.expand($0), isDirectory: true) }
            ?? home.appendingPathComponent(".local/share", isDirectory: true)
        return base.appendingPathComponent("rtk/history.db")
        #endif
    }

    public static func tokenadeLedgerURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["TOKENADE_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: ClaudePaths.expand(override)).appendingPathComponent("gain.jsonl")
        }
        return ClaudePaths.homeDirectory().appendingPathComponent(".tokenade/gain.jsonl")
    }

    /// Headroom's workspace: `$HEADROOM_WORKSPACE_DIR`, else `~/.headroom`
    /// (`headroom/paths.py`).
    public static func headroomSavingsURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let workspace = environment["HEADROOM_WORKSPACE_DIR"].map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ClaudePaths.expand($0), isDirectory: true) }
            ?? ClaudePaths.homeDirectory().appendingPathComponent(".headroom", isDirectory: true)
        return workspace.appendingPathComponent("proxy_savings.json")
    }

    // MARK: - rtk

    /// rtk's `commands` table: `timestamp, original_cmd, rtk_cmd, input_tokens,
    /// output_tokens, saved_tokens, project_path`, one row per rtk command
    /// run. Opened read-only; a missing file, a locked one or a changed schema
    /// all read as no entries.
    ///
    /// Newer rtk also writes `hook_decisions`: one row per Bash call its hook
    /// saw, with Claude Code's `session_id` and `tool_use_id`. A command row
    /// is attributed to the latest rewrite at or before it (within
    /// `rtkCommandWindow`) whose rewritten command runs `rtk <verb>`, so the
    /// claim lands on the exact Bash call instead of a time window. The
    /// command's own `project_path` is where it ran, after any `cd`, so it
    /// can't be required to match the session's.
    public static func rtkEntries(at url: URL, since: Date? = nil) -> [LedgerEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        // rtk keeps it in WAL mode. While rtk is running, a read-only
        // connection works; when it isn't, there is no `-shm` and the open
        // fails, but then there is no `-wal` either and the main file is
        // the whole database, so it is read as immutable. A read that lands
        // mid-write is retried rather than read as empty.
        for attempt in 0..<3 {
            if let entries = try? readRtk(at: url, since: since, immutable: false) { return entries }
            if !FileManager.default.fileExists(atPath: url.path + "-wal"),
               let entries = try? readRtk(at: url, since: since, immutable: true) { return entries }
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.15) }
        }
        return []
    }

    /// How long after a rewrite its commands may still be logged: a command
    /// is logged when it finishes.
    static let rtkCommandWindow: TimeInterval = 600

    struct RtkDecision {
        var ts: Date
        var sessionId: String
        var toolUseId: String
        var rewritten: String
    }

    static func readRtk(at url: URL, since: Date?, immutable: Bool) throws -> [LedgerEntry] {
        let database = try SQLiteDatabase(path: url.path, readOnly: true, immutable: immutable)
        let columns = try database.query("PRAGMA table_info(commands);") { $0.text(1) }
        guard columns.contains("timestamp"), columns.contains("saved_tokens") else { return [] }
        func column(_ name: String) -> String { columns.contains(name) ? name : "NULL" }
        let sql = """
        SELECT timestamp, \(column("original_cmd")), \(column("input_tokens")),
               \(column("output_tokens")), saved_tokens, \(column("project_path")), rowid, \(column("rtk_cmd"))
        FROM commands ORDER BY timestamp;
        """
        let rows = try database.query(sql) { row -> (LedgerEntry, String?)? in
            guard let ts = lenientDate(row.text(0)) else { return nil }
            if let since, ts < since { return nil }
            let path = row.optionalText(5).flatMap { $0.isEmpty ? nil : $0 }
            let entry = LedgerEntry(
                saver: .rtk, ts: ts, cwd: path, command: row.optionalText(1),
                beforeTokens: row.optionalInt(2), afterTokens: row.optionalInt(3),
                savedTokens: max(0, row.int(4)), id: "rtk:\(row.int(6))"
            )
            return (entry, row.optionalText(7))
        }.compactMap { $0 }
        var entries = rows.map(\.0)

        let decisionColumns = try database.query("PRAGMA table_info(hook_decisions);") { $0.text(1) }
        guard ["timestamp", "session_id", "tool_use_id", "rewritten_cmd"].allSatisfy(decisionColumns.contains) else { return entries }
        let decisions = try database.query(
            """
            SELECT timestamp, session_id, tool_use_id, rewritten_cmd FROM hook_decisions
            WHERE rewritten_cmd IS NOT NULL AND rewritten_cmd != '' ORDER BY timestamp;
            """
        ) { row -> RtkDecision? in
            guard let ts = lenientDate(row.text(0)) else { return nil }
            return RtkDecision(ts: ts, sessionId: row.text(1), toolUseId: row.text(2), rewritten: row.text(3))
        }.compactMap { $0 }
        attribute(&entries, verbs: rows.map { rtkVerb($0.1) ?? originalVerb($0.0.command) }, to: decisions)
        return entries
    }

    /// The command rtk ran it as: `rtk read` for a `cat`, `rtk:toml swift
    /// build` for a filter. The word after the `rtk` token, which is what
    /// the hook's rewrite says too.
    static func rtkVerb(_ rtkCommand: String?) -> String? {
        let words = (rtkCommand ?? "").split(separator: " ")
        guard let first = words.first, first == "rtk" || first.hasPrefix("rtk:"), words.count > 1 else { return nil }
        return String(words[1])
    }

    static func originalVerb(_ command: String?) -> String? {
        let verb = SaverReport.commandKey(command).split(separator: " ").first.map(String.init)
        return verb == "(unknown)" ? nil : verb
    }

    /// Gives each command row the session and Bash call of the rewrite that
    /// ran it: a rewrite stamped at or before the command (the hook decides
    /// before the command runs; rtk logs it when it ends), within
    /// `rtkCommandWindow`, that runs `rtk <verb>` — preferring one whose text
    /// holds the command's first argument, then the latest — and that has
    /// not already been given as many such commands as it runs. Decisions
    /// are sorted by time; rows are walked in time order.
    static func attribute(_ entries: inout [LedgerEntry], verbs: [String?], to decisions: [RtkDecision]) {
        guard !decisions.isEmpty else { return }
        var used: [Int: [String: Int]] = [:]
        for index in entries.indices.sorted(by: { entries[$0].ts < entries[$1].ts }) {
            let entry = entries[index]
            guard let verb = verbs[index] else { continue }
            let from = entry.ts.addingTimeInterval(-rtkCommandWindow)
            // Decisions in [from, entry.ts], newest first.
            var high = decisions.count
            var low = 0
            while low < high {
                let mid = (low + high) / 2
                if decisions[mid].ts <= entry.ts { low = mid + 1 } else { high = mid }
            }
            let argument = firstArgument(entry.command)
            var best: Int?
            var index2 = low - 1
            while index2 >= 0, decisions[index2].ts >= from {
                let decision = decisions[index2]
                let runsHere = occurrences(of: verb, in: decision.rewritten)
                if runsHere > (used[index2]?[verb] ?? 0) {
                    if let argument, decision.rewritten.contains(argument) { best = index2; break }
                    if best == nil { best = index2 }
                }
                index2 -= 1
            }
            guard let owner = best else { continue }
            used[owner, default: [:]][verb, default: 0] += 1
            entries[index].sessionId = decisions[owner].sessionId
            entries[index].toolUseId = decisions[owner].toolUseId
        }
    }

    /// The first word after the verb that isn't a flag, unquoted: `packages`
    /// in `ls packages`. Nil when there is none worth matching on.
    static func firstArgument(_ command: String?) -> String? {
        let words = (command ?? "").split(separator: " ").dropFirst()
        guard let word = words.first(where: { !$0.hasPrefix("-") }) else { return nil }
        let bare = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return bare.count >= 2 ? bare : nil
    }

    /// How many times a rewrite runs `rtk <verb>`.
    static func occurrences(of verb: String, in rewritten: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: runsPattern(verb)) else { return 0 }
        return regex.numberOfMatches(in: rewritten, range: NSRange(rewritten.startIndex..., in: rewritten))
    }

    static func runsPattern(_ verb: String) -> String {
        #"(^|[\s;&|(])rtk "# + NSRegularExpression.escapedPattern(for: verb) + #"(?=$|[\s;&|)])"#
    }

    /// `rtk grep` appears as a command in `cd x && rtk grep -n …`: at the
    /// start, or after a separator or space, and followed by a word break.
    static func runs(_ verb: String, in rewritten: String) -> Bool {
        occurrences(of: verb, in: rewritten) > 0
    }

    // MARK: - Headroom

    /// `proxy_savings.json`: a running total appended whenever a proxied
    /// request saved anything (`headroom/proxy/savings_tracker.py`), so each
    /// step is one request's claim. Its input total also grows on requests
    /// that saved nothing, so no per-request "after" can be read from it.
    /// The first point counts from zero unless the history has been trimmed.
    public static func headroomEntries(at url: URL, since: Date? = nil) -> [LedgerEntry] {
        guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
        return headroomEntries(json: data, since: since)
    }

    /// Headroom keeps at most this many points, or a year of them.
    static let headroomHistoryCap = 5000

    static func headroomEntries(json data: Data, since: Date?) -> [LedgerEntry] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let history = object["history"] as? [[String: Any]] else { return [] }
        let points = history.compactMap { point -> (ts: Date, total: Int)? in
            guard let raw = point["timestamp"] as? String, let ts = lenientDate(raw),
                  let total = int(point["total_tokens_saved"]) else { return nil }
            return (ts, total)
        }.sorted { $0.ts < $1.ts }
        guard let first = points.first, let last = points.last else { return [] }
        let trimmed = points.count >= headroomHistoryCap || last.ts.timeIntervalSince(first.ts) > 364 * 86_400
        var entries: [LedgerEntry] = []
        var previous = trimmed ? first.total : 0
        for point in points.dropFirst(trimmed ? 1 : 0) {
            defer { previous = point.total }
            let saved = point.total - previous
            guard saved > 0, since.map({ point.ts >= $0 }) ?? true else { continue }
            entries.append(LedgerEntry(
                saver: .headroom, ts: point.ts, cwd: nil, command: "proxied request",
                beforeTokens: nil, afterTokens: nil, savedTokens: saved,
                id: "headroom:\(Int(point.ts.timeIntervalSince1970 * 1000)):\(point.total)"
            ))
        }
        return entries
    }

    // MARK: - Tokenade

    /// `~/.tokenade/gain.jsonl`. The format is not documented, so it is read
    /// like a transcript: each line an object, the usual spellings of each
    /// field tried, a line without a timestamp and a saving skipped.
    public static func tokenadeEntries(at url: URL, since: Date? = nil) -> [LedgerEntry] {
        guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
        return tokenadeEntries(jsonl: data, since: since)
    }

    static func tokenadeEntries(jsonl data: Data, since: Date?) -> [LedgerEntry] {
        var entries: [LedgerEntry] = []
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            let tsValue = first(object, ["ts", "timestamp", "time", "at", "date"])
            let ts: Date?
            if let text = tsValue as? String {
                ts = lenientDate(text)
            } else if let number = (tsValue as? NSNumber)?.doubleValue {
                // Seconds or milliseconds since the epoch.
                ts = Date(timeIntervalSince1970: number > 1e12 ? number / 1000 : number)
            } else {
                ts = nil
            }
            guard let ts else { continue }
            if let since, ts < since { continue }
            let before = int(first(object, ["before", "input_tokens", "tokens_before", "original_tokens", "raw_tokens"]))
            let after = int(first(object, ["after", "output_tokens", "tokens_after", "compressed_tokens", "filtered_tokens"]))
            guard let saved = int(first(object, ["saved", "saved_tokens", "tokens_saved", "gain", "savings"]))
                ?? before.flatMap({ b in after.map { b - $0 } }) else { continue }
            entries.append(LedgerEntry(
                saver: .tokenade, ts: ts,
                cwd: first(object, ["cwd", "project", "project_path", "dir", "path"]) as? String,
                command: first(object, ["command", "cmd", "op", "operation", "tool"]) as? String,
                beforeTokens: before, afterTokens: after, savedTokens: max(0, saved)
            ))
        }
        return entries
    }

    private static func first(_ object: [String: Any], _ keys: [String]) -> Any? {
        for key in keys { if let value = object[key], !(value is NSNull) { return value } }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    // MARK: - Timestamps

    /// RFC 3339 with any number of fractional digits (rtk writes nanoseconds,
    /// which `ISO8601DateFormatter` refuses), with `Z` or an offset, or SQLite's
    /// `YYYY-MM-DD HH:MM:SS` in UTC.
    public static func lenientDate(_ raw: String) -> Date? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.count >= 19, text[text.index(text.startIndex, offsetBy: 10)] == " " {
            text = text.replacingOccurrences(of: " ", with: "T", options: [], range: text.index(text.startIndex, offsetBy: 10)..<text.index(text.startIndex, offsetBy: 11))
        }
        // Trim the fraction to milliseconds.
        if let dot = text.firstIndex(of: "."), dot > text.index(text.startIndex, offsetBy: 18) {
            var end = text.index(after: dot)
            while end < text.endIndex, text[end].isNumber { end = text.index(after: end) }
            let digits = text[text.index(after: dot)..<end]
            let millis = String((digits + "000").prefix(3))
            text = String(text[..<dot]) + "." + millis + String(text[end...])
        }
        // No zone at all: SQLite's CURRENT_TIMESTAMP is UTC.
        let timePart = text.count > 10 ? String(text.dropFirst(11)) : ""
        if !timePart.contains("Z"), !timePart.contains("+"), !timePart.contains("-") { text += "Z" }
        return Timestamps.date(from: text)
    }
}

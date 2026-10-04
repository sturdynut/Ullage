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

    public init(
        saver: TokenSaver, ts: Date, cwd: String?, command: String?,
        beforeTokens: Int?, afterTokens: Int?, savedTokens: Int
    ) {
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

    // MARK: - rtk

    /// rtk's `commands` table: `timestamp, original_cmd, rtk_cmd, input_tokens,
    /// output_tokens, saved_tokens, project_path`. Opened read-only; a missing
    /// file, a locked one or a changed schema all read as no entries.
    public static func rtkEntries(at url: URL, since: Date? = nil) -> [LedgerEntry] {
        guard FileManager.default.fileExists(atPath: url.path),
              let database = try? SQLiteDatabase(path: url.path, readOnly: true) else { return [] }
        let columns = (try? database.query("PRAGMA table_info(commands);") { $0.text(1) }) ?? []
        guard columns.contains("timestamp"), columns.contains("saved_tokens") else { return [] }
        func column(_ name: String) -> String { columns.contains(name) ? name : "NULL" }
        let sql = """
        SELECT timestamp, \(column("original_cmd")), \(column("input_tokens")),
               \(column("output_tokens")), saved_tokens, \(column("project_path"))
        FROM commands ORDER BY timestamp;
        """
        let rows = (try? database.query(sql) { row -> LedgerEntry? in
            guard let ts = lenientDate(row.text(0)) else { return nil }
            if let since, ts < since { return nil }
            let path = row.optionalText(5).flatMap { $0.isEmpty ? nil : $0 }
            return LedgerEntry(
                saver: .rtk, ts: ts, cwd: path, command: row.optionalText(1),
                beforeTokens: row.optionalInt(2), afterTokens: row.optionalInt(3),
                savedTokens: max(0, row.int(4))
            )
        }) ?? []
        return rows.compactMap { $0 }
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

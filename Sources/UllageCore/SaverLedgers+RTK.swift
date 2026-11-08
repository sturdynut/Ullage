import Foundation

extension SaverLedgers {
    /// How long after a rewrite its commands may still be logged: a command
    /// is logged when it finishes.
    static let rtkCommandWindow: TimeInterval = 600

    struct RtkDecision {
        var timestamp: Date
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
            guard let timestamp = lenientDate(row.text(0)) else { return nil }
            if let since, timestamp < since { return nil }
            let path = row.optionalText(5).flatMap { $0.isEmpty ? nil : $0 }
            let entry = LedgerEntry(
                saver: .rtk, ts: timestamp, cwd: path, command: row.optionalText(1),
                beforeTokens: row.optionalInt(2), afterTokens: row.optionalInt(3),
                savedTokens: max(0, row.int(4)), id: "rtk:\(row.int(6))"
            )
            return (entry, row.optionalText(7))
        }.compactMap { $0 }
        var entries = rows.map(\.0)

        let decisionColumns = try database.query("PRAGMA table_info(hook_decisions);") { $0.text(1) }
        let required = ["timestamp", "session_id", "tool_use_id", "rewritten_cmd"]
        guard required.allSatisfy(decisionColumns.contains) else { return entries }
        let decisions = try database.query(
            """
            SELECT timestamp, session_id, tool_use_id, rewritten_cmd FROM hook_decisions
            WHERE rewritten_cmd IS NOT NULL AND rewritten_cmd != '' ORDER BY timestamp;
            """
        ) { row -> RtkDecision? in
            guard let timestamp = lenientDate(row.text(0)) else { return nil }
            return RtkDecision(timestamp: timestamp, sessionId: row.text(1),
                               toolUseId: row.text(2), rewritten: row.text(3))
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
        var matches = RtkMatches(verbs: verbs)
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
                if decisions[mid].timestamp <= entry.ts { low = mid + 1 } else { high = mid }
            }
            let argument = firstArgument(entry.command)
            var best: Int?
            var index2 = low - 1
            while index2 >= 0, decisions[index2].timestamp >= from {
                let decision = decisions[index2]
                let runsHere = matches.count(verb: verb, decision: index2, rewritten: decision.rewritten)
                if runsHere > (used[index2]?[verb] ?? 0) {
                    if let argument,
                       matches.contains(argument: argument, decision: index2, rewritten: decision.rewritten) {
                        best = index2
                        break
                    }
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

    private struct RtkMatches {
        let patterns: [String: NSRegularExpression]
        var counts: [Int: [String: Int]] = [:]
        var arguments: [Int: Set<String>] = [:]

        init(verbs: [String?]) {
            patterns = Dictionary(uniqueKeysWithValues: Set(verbs.compactMap { $0 }).compactMap { verb in
                (try? NSRegularExpression(pattern: runsPattern(verb))).map { (verb, $0) }
            })
        }

        mutating func count(verb: String, decision: Int, rewritten: String) -> Int {
            if let cached = counts[decision]?[verb] { return cached }
            let range = NSRange(rewritten.startIndex..., in: rewritten)
            let count = patterns[verb]?.numberOfMatches(in: rewritten, range: range) ?? 0
            counts[decision, default: [:]][verb] = count
            return count
        }

        mutating func contains(argument: String, decision: Int, rewritten: String) -> Bool {
            if arguments[decision] == nil { arguments[decision] = Set(commandWords(in: rewritten)) }
            return arguments[decision]?.contains(argument) == true
        }
    }

    private static let commandWordPattern = try? NSRegularExpression(
        pattern: #"(?:[^\s;&|()'"\\]|\\.|'[^']*'|"(?:[^"\\]|\\.)*")+"#
    )

    private static func commandWords(in command: String) -> [String] {
        let range = NSRange(command.startIndex..., in: command)
        return commandWordPattern?.matches(in: command, range: range).map {
            let word = (command as NSString).substring(with: $0.range)
            guard let quote = word.first, quote == "'" || quote == "\"", word.last == quote else { return word }
            return String(word.dropFirst().dropLast())
        } ?? []
    }

    /// The first word after the verb that isn't a flag, unquoted: `packages`
    /// in `ls packages`. Nil when there is none worth matching on.
    static func firstArgument(_ command: String?) -> String? {
        let words = commandWords(in: command ?? "").dropFirst()
        guard let word = words.first(where: { !$0.hasPrefix("-") }), word.count >= 2 else { return nil }
        return word
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
}

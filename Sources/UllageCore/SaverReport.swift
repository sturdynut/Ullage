import Foundation

/// What one token saver did in one session, from the transcript's own record.
///
/// Every count here is a fact read off disk: a hook ran, a command was
/// rewritten, an MCP tool was called. The one figure that is not — `ledger` —
/// is the saver's own claim, carried separately and labelled by `TokenSaver.savingSource`.
public struct SaverUsage: Equatable {
    public var saver: TokenSaver
    /// Hook runs whose command belongs to this saver.
    public var hookRuns: Int = 0
    /// PreToolUse runs that replaced the model's command with another.
    public var rewrites: Int = 0
    /// Runs that exited non-zero or said the saver is missing.
    public var failedRuns: Int = 0
    /// What the most recent failure said, trimmed.
    public var failureMessage: String?
    /// Named in the session's MCP config when Ullage snapshotted it.
    public var mcpConfigured = false
    public var mcpCalls = 0
    /// Length estimate of what its MCP tools returned (~4 bytes/token, rule 6).
    public var mcpResultTokens = 0
    /// Bash calls that ran its command (`codegraph explore …`).
    public var bashRuns = 0
    /// Bash calls from its first hook run on: the ones it could have
    /// rewritten. Claude Code records a hook only when it changed something,
    /// so the calls it let through leave no trace of their own; counting from
    /// its first run keeps a session it was installed partway into fair.
    public var bashCallsSeen = 0
    /// Bytes its hooks added to the context (claude-mem's SessionStart memory).
    public var injectedBytes = 0
    /// Skill-tool calls and slash commands (caveman).
    public var invocations = 0
    public var ledger: LedgerMatch?
    /// The ledger rows behind `ledger`, so a range can count each once and
    /// place each on the Bash call it names.
    public var ledgerEntries: [LedgerEntry] = []

    public init(saver: TokenSaver) { self.saver = saver }

    /// Left any trace of running in this session. A ledger row counts when
    /// it names this session or was matched to one of its turns; a row
    /// matched only by folder and time could be another session's.
    public var ran: Bool {
        hookRuns > 0 || mcpCalls > 0 || invocations > 0 || bashRuns > 0
            || ledgerEntries.contains { $0.sessionId != nil || $0.cwd == nil }
    }
    /// Loaded but never used: configured MCP server with no calls.
    public var idle: Bool { !ran && mcpConfigured }
    /// Every run failed — installed in config, missing on disk.
    public var broken: Bool { hookRuns > 0 && failedRuns == hookRuns }
}

/// A saver's ledger rows matched to one session: same directory, inside the
/// session's time span. A claim, never added to any measured total.
public struct LedgerMatch: Equatable {
    public struct Group: Equatable {
        public var command: String
        public var entries: Int
        public var beforeTokens: Int?
        public var afterTokens: Int?
        public var savedTokens: Int
    }

    public var entries: Int
    public var savedTokens: Int
    public var beforeTokens: Int?
    public var afterTokens: Int?
    /// Largest saving first.
    public var groups: [Group]

    /// Share of the pre-shrink size that was removed, when both sides are known.
    public var reduction: Double? {
        guard let beforeTokens, beforeTokens > 0 else { return nil }
        return Double(savedTokens) / Double(beforeTokens)
    }
}

public struct SaverSessionReport: Equatable {
    public var sessionId: String
    public var cwd: String?
    public var bashCalls: Int
    /// One per saver, in `TokenSaver.allCases` order, so rows never swap.
    public var usages: [SaverUsage]
    /// Bash calls that went through two output filters' hooks. Each tool
    /// claims the whole saving on those, so the two ledgers overlap.
    public var doubleHookedCalls: Int
    /// The output filters those doubled calls went through.
    public var overlapping: [TokenSaver] = []

    public func usage(_ saver: TokenSaver) -> SaverUsage {
        usages.first { $0.saver == saver } ?? SaverUsage(saver: saver)
    }

    /// Anything worth a row: ran, idle, or broken.
    public var visible: [SaverUsage] { usages.filter { $0.ran || $0.idle } }
}

public enum SaverReport {
    /// Slack either side of the session's turns when matching a ledger: a hook
    /// fires before the tool it rewrites, and the turn is stamped after.
    public static let ledgerSlack: TimeInterval = 120
    /// A proxy's row is stamped when the request went through, a few seconds
    /// either side of the turn Claude Code recorded for it.
    public static let requestSlack: TimeInterval = 30

    public static func build(
        sessionId: String,
        calls: [CallRow],
        toolCalls: [ToolCallRow],
        events: [EventRow],
        sessionEnv: SessionEnvRow?,
        ledger: [LedgerEntry]
    ) -> SaverSessionReport {
        var usages = Dictionary(uniqueKeysWithValues: TokenSaver.allCases.map { ($0, SaverUsage(saver: $0)) })
        var hookedBy: [String: Set<TokenSaver>] = [:]
        var firstRun: [TokenSaver: String] = [:]

        for event in events where event.kind == EventKind.hook.rawValue {
            guard let run = HookRun(detail: event.detail),
                  let saver = TokenSaver.saver(forHookCommand: run.command) else { continue }
            usages[saver]?.hookRuns += 1
            if run.hookEvent == "PreToolUse", firstRun[saver].map({ event.ts < $0 }) ?? true { firstRun[saver] = event.ts }
            if let rewrite = run.rewrittenCommand, !rewrite.isEmpty {
                usages[saver]?.rewrites += 1
            }
            if run.failed {
                usages[saver]?.failedRuns += 1
                usages[saver]?.failureMessage = run.stderr.map { String($0.prefix(160)) } ?? "exited \(run.exitCode ?? -1)"
            }
            if let injected = run.injectedBytes, !run.failed {
                usages[saver]?.injectedBytes += injected
            }
            if let toolUseId = run.toolUseId, run.hookEvent == "PreToolUse" {
                hookedBy[toolUseId, default: []].insert(saver)
            }
        }
        for event in events where event.kind == EventKind.command.rawValue {
            guard let command = SlashCommand(detail: event.detail) else { continue }
            for saver in TokenSaver.allCases where saver.matches(skillOrCommand: command.name) {
                usages[saver]?.invocations += 1
            }
        }
        for tool in toolCalls {
            if tool.kind == ToolKind.skill.rawValue, let target = tool.target {
                for saver in TokenSaver.allCases where saver.matches(skillOrCommand: target) {
                    usages[saver]?.invocations += 1
                }
            }
            if let server = tool.mcpServer {
                for saver in TokenSaver.allCases where saver.matches(mcpServer: server) {
                    usages[saver]?.mcpCalls += 1
                    usages[saver]?.mcpResultTokens += tool.resultTokens ?? 0
                }
            }
            if tool.name == "Bash", let command = tool.target {
                for saver in TokenSaver.allCases where saver.matches(bashCommand: command) {
                    usages[saver]?.bashRuns += 1
                    usages[saver]?.mcpResultTokens += tool.resultTokens ?? 0
                }
            }
        }
        if let servers = decodeNames(sessionEnv?.mcpServers) {
            for saver in TokenSaver.allCases where servers.contains(where: saver.matches(mcpServer:)) {
                usages[saver]?.mcpConfigured = true
            }
        }

        let cwd = calls.first { $0.agentId == nil && $0.cwd != nil }?.cwd ?? calls.first { $0.cwd != nil }?.cwd
        for saver in TokenSaver.allCases where saver.descriptor.claims != nil {
            let matched = match(ledger.filter { $0.saver == saver }, sessionId: sessionId, cwd: cwd, calls: calls)
            if !matched.isEmpty {
                usages[saver]?.ledger = summarize(matched)
                usages[saver]?.ledgerEntries = matched
            }
        }

        let bashCalls = toolCalls.filter { $0.name == "Bash" }
        for (saver, since) in firstRun {
            usages[saver]?.bashCallsSeen = bashCalls.filter { $0.ts >= since }.count
        }
        let bashIds = Set(bashCalls.map(\.id))
        let doubledBy = hookedBy.filter { bashIds.contains($0.key) }
            .mapValues { $0.filter { $0.kind == .outputFilter } }
            .filter { $0.value.count >= 2 }
        let overlapping = Set(doubledBy.values.flatMap { $0 })

        return SaverSessionReport(
            sessionId: sessionId,
            cwd: cwd,
            bashCalls: bashIds.count,
            usages: TokenSaver.allCases.compactMap { usages[$0] },
            doubleHookedCalls: doubledBy.count,
            overlapping: TokenSaver.allCases.filter(overlapping.contains)
        )
    }

    /// A ledger's rows that belong to this session, by the best evidence each
    /// row carries: the session it names; else the session's folder and time
    /// span; else, with neither (a proxy), a turn of this session within
    /// `requestSlack` of it.
    static func match(_ entries: [LedgerEntry], sessionId: String, cwd: String?, calls: [CallRow]) -> [LedgerEntry] {
        guard !entries.isEmpty, let firstTs = calls.lazy.map(\.ts).min(), let lastTs = calls.lazy.map(\.ts).max(),
              let start = Timestamps.date(from: firstTs), let end = Timestamps.date(from: lastTs) else {
            return entries.filter { $0.sessionId == sessionId }
        }
        let from = start.addingTimeInterval(-ledgerSlack), to = end.addingTimeInterval(ledgerSlack)
        var turnTimes: [Date]?
        return entries.filter { entry in
            if let named = entry.sessionId { return named == sessionId }
            guard entry.ts >= from, entry.ts <= to else { return false }
            if let path = entry.cwd { return cwd.map { samePlace(path, $0) } ?? false }
            if turnTimes == nil { turnTimes = calls.compactMap { Timestamps.date(from: $0.ts) }.sorted() }
            return nearest(entry.ts, in: turnTimes ?? []).map { abs($0.timeIntervalSince(entry.ts)) <= requestSlack } ?? false
        }
    }

    /// The closest of sorted dates to `date`.
    static func nearest(_ date: Date, in sorted: [Date]) -> Date? {
        var low = 0, high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < date { low = mid + 1 } else { high = mid }
        }
        let candidates = [low - 1, low].filter { sorted.indices.contains($0) }.map { sorted[$0] }
        return candidates.min { abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date)) }
    }

    /// A ledger path matches the session's directory, or one is inside the
    /// other (rtk may record the repo root, the session a subdirectory).
    static func samePlace(_ ledgerPath: String?, _ cwd: String) -> Bool {
        guard let ledgerPath else { return false }
        let a = normalize(ledgerPath), b = normalize(cwd)
        return a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }

    private static func normalize(_ path: String) -> String {
        var standardized = (ClaudePaths.expand(path) as NSString).standardizingPath
        while standardized.count > 1, standardized.hasSuffix("/") { standardized.removeLast() }
        return standardized
    }

    static func summarize(_ entries: [LedgerEntry]) -> LedgerMatch {
        func sum(_ values: [Int?]) -> Int? {
            values.contains(where: { $0 == nil }) ? nil : values.reduce(0) { $0 + ($1 ?? 0) }
        }
        let grouped = Dictionary(grouping: entries) { commandKey($0.command) }
        let groups = grouped.map { key, rows in
            LedgerMatch.Group(
                command: key,
                entries: rows.count,
                beforeTokens: sum(rows.map(\.beforeTokens)),
                afterTokens: sum(rows.map(\.afterTokens)),
                savedTokens: rows.reduce(0) { $0 + $1.savedTokens }
            )
        }.sorted { ($0.savedTokens, $1.command) > ($1.savedTokens, $0.command) }
        return LedgerMatch(
            entries: entries.count,
            savedTokens: entries.reduce(0) { $0 + $1.savedTokens },
            beforeTokens: sum(entries.map(\.beforeTokens)),
            afterTokens: sum(entries.map(\.afterTokens)),
            groups: groups
        )
    }

    /// `git status --short` → `git status`; `ls -la` → `ls`. The verb and, for
    /// tools that have them, the subcommand.
    static func commandKey(_ command: String?) -> String {
        guard let command else { return "(unknown)" }
        var words = command.split(separator: " ").map(String.init).filter { !$0.contains("=") || $0.hasPrefix("-") }
        if words.first == "rtk" { words.removeFirst() }
        guard let verb = words.first.map({ ($0 as NSString).lastPathComponent }) else { return "(unknown)" }
        if let sub = words.dropFirst().first, !sub.hasPrefix("-"), !sub.contains("/"), !sub.contains("."),
           ["git", "cargo", "npm", "pnpm", "yarn", "go", "swift", "docker", "kubectl", "gh", "terraform", "pip", "uv"].contains(verb) {
            return verb + " " + sub
        }
        return verb
    }

    static func decodeNames(_ json: String?) -> [String]? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String]
    }
}

// MARK: - Reply style: output with and without

/// Median output tokens per main-thread turn, split by whether caveman was on.
///
/// Both halves are measured (`output`, exact rows only), but they are
/// different turns doing different work, so this is a comparison and is
/// labelled one. Output includes thinking where the harness counts it there,
/// which caveman does not shorten; the figure understates its effect on the
/// visible reply rather than overstating it.
public struct OutputComparison: Equatable {
    public var withMedian: Int
    public var withTurns: Int
    public var withSessions: Int
    public var withoutMedian: Int
    public var withoutTurns: Int
    public var withoutSessions: Int

    /// Below this many turns on either side, there is no comparison to show.
    public static let minimumTurns = 20

    public struct Turn: Equatable {
        public var sessionId: String
        public var ts: String
        public var output: Int
        public init(sessionId: String, ts: String, output: Int) {
            self.sessionId = sessionId
            self.ts = ts
            self.output = output
        }
    }

    /// A moment caveman was switched on or off in a session.
    public struct Signal: Equatable {
        public var sessionId: String
        public var ts: String
        public var on: Bool
        public init(sessionId: String, ts: String, on: Bool) {
            self.sessionId = sessionId
            self.ts = ts
            self.on = on
        }
    }

    /// Turns take the state of the latest signal at or before them in their own
    /// session; a turn before any signal is "without".
    public static func build(turns: [Turn], signals: [Signal]) -> OutputComparison? {
        let bySession = Dictionary(grouping: signals, by: \.sessionId).mapValues { $0.sorted { $0.ts < $1.ts } }
        var with: [Int] = [], without: [Int] = []
        var withSessions = Set<String>(), withoutSessions = Set<String>()
        for turn in turns {
            let on = bySession[turn.sessionId]?.last(where: { $0.ts <= turn.ts })?.on ?? false
            if on {
                with.append(turn.output)
                withSessions.insert(turn.sessionId)
            } else {
                without.append(turn.output)
                withoutSessions.insert(turn.sessionId)
            }
        }
        guard with.count >= minimumTurns, without.count >= minimumTurns else { return nil }
        return OutputComparison(
            withMedian: median(with), withTurns: with.count, withSessions: withSessions.count,
            withoutMedian: median(without), withoutTurns: without.count, withoutSessions: withoutSessions.count
        )
    }

    static func median(_ values: [Int]) -> Int {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// A reply-style tool's on/off moments from hook runs, slash commands
    /// and skill calls.
    public static func signals(for tool: TokenSaver, events: [EventRow], toolCalls: [ToolCallRow]) -> [Signal] {
        var signals: [Signal] = []
        for event in events {
            if event.kind == EventKind.hook.rawValue,
               let run = HookRun(detail: event.detail), tool.matches(hookCommand: run.command), !run.failed {
                signals.append(Signal(sessionId: event.sessionId, ts: event.ts, on: true))
            } else if event.kind == EventKind.command.rawValue,
                      let command = SlashCommand(detail: event.detail), tool.matches(skillOrCommand: command.name) {
                let args = command.args?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
                let off = ["off", "stop", "normal", "disable"].contains(args)
                signals.append(Signal(sessionId: event.sessionId, ts: event.ts, on: !off))
            }
        }
        for call in toolCalls where call.kind == ToolKind.skill.rawValue {
            if let target = call.target, tool.matches(skillOrCommand: target) {
                signals.append(Signal(sessionId: call.sessionId, ts: call.ts, on: true))
            }
        }
        return signals
    }
}

// MARK: - Store reads

extension Store {
    /// Every tool's ledger, with each row that names neither a session nor a
    /// folder (a proxy's) given to the one session whose turn is nearest to
    /// it, across all sessions, within `SaverReport.requestSlack`. Matched per
    /// session instead, one request would count in every session that had a
    /// turn in those seconds.
    public func ledger(since: Date? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) -> [LedgerEntry] {
        place(SaverLedgers.load(since: since, environment: environment))
    }

    public func place(_ entries: [LedgerEntry]) -> [LedgerEntry] {
        entries.map { entry in
            guard entry.sessionId == nil, entry.cwd == nil else { return entry }
            let slack = SaverReport.requestSlack
            let rows = (try? database.query(
                "SELECT session_id, ts FROM call WHERE ts >= ?1 AND ts <= ?2;",
                [.text(Timestamps.string(from: entry.ts.addingTimeInterval(-slack))),
                 .text(Timestamps.string(from: entry.ts.addingTimeInterval(slack)))]
            ) { ($0.text(0), $0.text(1)) }) ?? []
            let nearest = rows.compactMap { row in Timestamps.date(from: row.1).map { (row.0, abs($0.timeIntervalSince(entry.ts))) } }
                .min { ($0.1, $0.0) < ($1.1, $1.0) }
            var placed = entry
            placed.sessionId = nearest?.0
            return placed
        }
    }

    public func saverReport(sessionId: String, ledger: [LedgerEntry]) throws -> SaverSessionReport {
        let events = try self.events(sessionId: sessionId, kind: EventKind.hook.rawValue, scope: .all)
            + self.events(sessionId: sessionId, kind: EventKind.command.rawValue, scope: .all)
        return SaverReport.build(
            sessionId: sessionId,
            calls: try calls(sessionId: sessionId, scope: .all),
            toolCalls: try toolCalls(sessionId: sessionId),
            events: events,
            sessionEnv: try sessionEnv(sessionId: sessionId),
            ledger: ledger
        )
    }

    /// Every reply-style tool's on-vs-off comparison in one directory, for
    /// those with enough turns each way.
    public func outputComparisons(cwd: String, since: String) throws -> [TokenSaver: OutputComparison] {
        var result: [TokenSaver: OutputComparison] = [:]
        for tool in TokenSaver.allCases where tool.kind == .replyStyle {
            result[tool] = try outputComparison(cwd: cwd, since: since, tool: tool)
        }
        return result
    }

    /// A reply-style tool on vs off across one directory's main-thread turns
    /// since a date.
    public func outputComparison(cwd: String, since: String, tool: TokenSaver) throws -> OutputComparison? {
        let turns = try database.query(
            """
            SELECT session_id, ts, output FROM call
            WHERE cwd = ?1 AND ts >= ?2 AND agent_id IS NULL AND confidence = 'exact';
            """,
            [.text(cwd), .text(since)]
        ) { OutputComparison.Turn(sessionId: $0.text(0), ts: $0.text(1), output: $0.int(2)) }
        guard !turns.isEmpty else { return nil }
        let sessions = "SELECT DISTINCT session_id FROM call WHERE cwd = ?1 AND ts >= ?2"
        let events = try database.query(
            """
            SELECT id, session_id, agent_id, ts, kind, detail FROM event
            WHERE kind IN ('hook', 'command') AND agent_id IS NULL AND session_id IN (\(sessions));
            """,
            [.text(cwd), .text(since)]
        ) { EventRow(id: $0.text(0), sessionId: $0.text(1), agentId: $0.optionalText(2),
                     ts: $0.text(3), kind: $0.text(4), detail: $0.optionalText(5)) }
        let skills = try database.query(
            """
            SELECT id, call_id, session_id, ts, name, kind, target FROM tool_call
            WHERE kind = 'skill' AND session_id IN (\(sessions));
            """,
            [.text(cwd), .text(since)]
        ) { ToolCallRow(id: $0.text(0), callId: $0.text(1), sessionId: $0.text(2), ts: $0.text(3),
                        name: $0.text(4), kind: $0.text(5), target: $0.optionalText(6)) }
        return OutputComparison.build(turns: turns, signals: OutputComparison.signals(for: tool, events: events, toolCalls: skills))
    }
}

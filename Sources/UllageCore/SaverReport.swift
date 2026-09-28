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
    /// Skill-tool calls and slash commands (caveman).
    public var invocations = 0
    public var ledger: LedgerMatch?

    public init(saver: TokenSaver) { self.saver = saver }

    /// Left any trace of running in this session.
    public var ran: Bool { hookRuns > 0 || mcpCalls > 0 || invocations > 0 }
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
    /// Bash calls that went through both rtk's and Tokenade's hooks. Each
    /// tool claims the whole saving on those, so the two ledgers overlap.
    public var doubleHookedCalls: Int

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

        for event in events where event.kind == EventKind.hook.rawValue {
            guard let run = HookRun(detail: event.detail),
                  let saver = TokenSaver.saver(forHookCommand: run.command) else { continue }
            usages[saver]?.hookRuns += 1
            if let rewrite = run.rewrittenCommand, !rewrite.isEmpty {
                usages[saver]?.rewrites += 1
            }
            if run.failed {
                usages[saver]?.failedRuns += 1
                usages[saver]?.failureMessage = run.stderr.map { String($0.prefix(160)) } ?? "exited \(run.exitCode ?? -1)"
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
                }
            }
        }
        if let servers = decodeNames(sessionEnv?.mcpServers) {
            for saver in TokenSaver.allCases where servers.contains(where: saver.matches(mcpServer:)) {
                usages[saver]?.mcpConfigured = true
            }
        }

        let cwd = calls.first { $0.agentId == nil && $0.cwd != nil }?.cwd ?? calls.first { $0.cwd != nil }?.cwd
        let dates = calls.compactMap { Timestamps.date(from: $0.ts) }
        if let cwd, let start = dates.min(), let end = dates.max() {
            let from = start.addingTimeInterval(-ledgerSlack)
            let to = end.addingTimeInterval(ledgerSlack)
            for saver in [TokenSaver.rtk, .tokenade] {
                let matched = ledger.filter {
                    $0.saver == saver && $0.ts >= from && $0.ts <= to && samePlace($0.cwd, cwd)
                }
                if !matched.isEmpty { usages[saver]?.ledger = summarize(matched) }
            }
        }

        let bashIds = Set(toolCalls.filter { $0.name == "Bash" }.map(\.id))
        let doubled = hookedBy.filter { bashIds.contains($0.key) && $0.value.isSuperset(of: [.rtk, .tokenade]) }.count

        return SaverSessionReport(
            sessionId: sessionId,
            cwd: cwd,
            bashCalls: bashIds.count,
            usages: TokenSaver.allCases.compactMap { usages[$0] },
            doubleHookedCalls: doubled
        )
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

// MARK: - caveman: output with and without

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

    /// caveman's on/off moments from hook runs, slash commands and skill calls.
    public static func signals(events: [EventRow], toolCalls: [ToolCallRow]) -> [Signal] {
        var signals: [Signal] = []
        for event in events {
            if event.kind == EventKind.hook.rawValue,
               let run = HookRun(detail: event.detail), TokenSaver.caveman.matches(hookCommand: run.command), !run.failed {
                signals.append(Signal(sessionId: event.sessionId, ts: event.ts, on: true))
            } else if event.kind == EventKind.command.rawValue,
                      let command = SlashCommand(detail: event.detail), TokenSaver.caveman.matches(skillOrCommand: command.name) {
                let args = command.args?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
                let off = ["off", "stop", "normal", "disable"].contains(args)
                signals.append(Signal(sessionId: event.sessionId, ts: event.ts, on: !off))
            }
        }
        for tool in toolCalls where tool.kind == ToolKind.skill.rawValue {
            if let target = tool.target, TokenSaver.caveman.matches(skillOrCommand: target) {
                signals.append(Signal(sessionId: tool.sessionId, ts: tool.ts, on: true))
            }
        }
        return signals
    }
}

// MARK: - Store reads

extension Store {
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

    /// caveman on vs off across one directory's main-thread turns since a date.
    public func outputComparison(cwd: String, since: String) throws -> OutputComparison? {
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
        return OutputComparison.build(turns: turns, signals: OutputComparison.signals(events: events, toolCalls: skills))
    }
}

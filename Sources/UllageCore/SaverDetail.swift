import Foundation

/// One saver over a span of time, for the Token savers window.
///
/// The transcript facts (runs, rewrites, failures, calls, sessions) are summed
/// across the sessions in range — every one a count read off disk. The ledger
/// is the per-session matches merged, so it only ever covers work that
/// happened inside a Claude Code session, and it stays a labelled claim.
public enum SaverRange: String, CaseIterable, Identifiable {
    case session = "This session"
    case week = "7 days"
    case month = "30 days"

    public var id: String { rawValue }

    public var days: Int? {
        switch self {
        case .session: return nil
        case .week: return 7
        case .month: return 30
        }
    }
}

public struct SaverDetail: Equatable {
    public struct TurnOutput: Equatable, Identifiable {
        public var turn: Int
        public var output: Int
        /// caveman was on for this turn.
        public var on: Bool
        public var id: Int { turn }
    }

    public var saver: TokenSaver
    public var range: SaverRange
    /// Sessions looked at, and those this saver left a trace in.
    public var sessions: Int
    public var sessionsUsed: Int
    /// Loaded (an MCP server in the snapshot) and never called.
    public var sessionsIdle: Int
    public var hookRuns: Int
    public var rewrites: Int
    public var failedRuns: Int
    public var failureMessage: String?
    public var mcpCalls: Int
    /// Length estimate of what its MCP tools or Bash command returned.
    public var resultTokens: Int = 0
    public var bashRuns: Int = 0
    /// Bytes its hooks injected into the context, summed over sessions.
    public var injectedBytes: Int = 0
    /// Sessions it injected into, for an average per session.
    public var sessionsInjected: Int = 0
    public var invocations: Int
    public var bashCalls: Int
    public var doubleHookedCalls: Int
    public var ledger: LedgerMatch?
    /// Reply-style tools: measured output with and without, in `comparisonFolder`.
    public var comparison: OutputComparison?
    public var comparisonFolder: String?
    /// caveman: the shown session's main-thread replies, in order.
    public var turns: [TurnOutput]
    /// The claim placed on the Bash calls it names, and carried forward.
    public var carried: CarriedClaim?
    /// With vs without in `comparisonFolder`: the first prompt (cost) and the
    /// kind's own benefit metric, each only when both sides have enough.
    public var comparisons: [SaverComparison] = []
    /// The ledger rows behind `ledger`, each once, for the per-day charts.
    public var ledgerEntries: [LedgerEntry] = []
    /// Prompts each placed Bash call's result stayed in, by tool_use id.
    public var prompts: [String: Int] = [:]
    /// Cost and benefit, graded.
    public var value: SaverValue { SaverValue.build(self) }

    public static func build(
        saver: TokenSaver,
        range: SaverRange,
        reports: [SaverSessionReport],
        comparison: OutputComparison? = nil,
        comparisonFolder: String? = nil,
        turns: [TurnOutput] = [],
        comparisons: [SaverComparison] = [],
        placements: [String: CarriedClaim.Placement] = [:]
    ) -> SaverDetail {
        let usages = reports.map { $0.usage(saver) }
        let matches = usages.compactMap(\.ledger)
        // A row matched to two overlapping sessions is still one claim.
        var seen = Set<String>()
        let entries = usages.flatMap(\.ledgerEntries).filter { seen.insert($0.id).inserted }
        let ledger = entries.isEmpty ? (matches.isEmpty ? nil : LedgerMatch.merged(matches)) : SaverReport.summarize(entries)
        var detail = SaverDetail(
            saver: saver,
            range: range,
            sessions: reports.count,
            sessionsUsed: usages.filter(\.ran).count,
            sessionsIdle: usages.filter(\.idle).count,
            hookRuns: usages.reduce(0) { $0 + $1.hookRuns },
            rewrites: usages.reduce(0) { $0 + $1.rewrites },
            failedRuns: usages.reduce(0) { $0 + $1.failedRuns },
            failureMessage: usages.last(where: { $0.failureMessage != nil })?.failureMessage,
            mcpCalls: usages.reduce(0) { $0 + $1.mcpCalls },
            resultTokens: usages.reduce(0) { $0 + $1.mcpResultTokens },
            bashRuns: usages.reduce(0) { $0 + $1.bashRuns },
            injectedBytes: usages.reduce(0) { $0 + $1.injectedBytes },
            sessionsInjected: usages.filter { $0.injectedBytes > 0 }.count,
            invocations: usages.reduce(0) { $0 + $1.invocations },
            bashCalls: reports.reduce(0) { $0 + $1.bashCalls },
            doubleHookedCalls: reports.reduce(0) { $0 + $1.doubleHookedCalls },
            ledger: ledger,
            comparison: comparison,
            comparisonFolder: comparisonFolder,
            turns: turns
        )
        detail.comparisons = comparisons
        detail.ledgerEntries = entries
        if saver.descriptor.claims?.perRequest != true {
            detail.carried = CarriedClaim.build(entries: entries, placements: placements)
            for id in entries.compactMap(\.toolUseId) { detail.prompts[id] = placements[id]?.prompts }
        }
        return detail
    }

    /// caveman's on/off per reply, from the same signals as the comparison.
    public static func turns(calls: [CallRow], signals: [OutputComparison.Signal]) -> [TurnOutput] {
        let sorted = signals.sorted { $0.ts < $1.ts }
        return calls.compactMap { call in
            guard let turn = call.turnIndex else { return nil }
            let on = sorted.last(where: { $0.sessionId == call.sessionId && $0.ts <= call.ts })?.on ?? false
            return TurnOutput(turn: turn, output: call.output, on: on)
        }
    }
}

extension LedgerMatch {
    /// Several sessions' matches as one: groups with the same command add up,
    /// and a before/after total is only known if every part of it was.
    public static func merged(_ matches: [LedgerMatch]) -> LedgerMatch {
        func add(_ a: Int?, _ b: Int?) -> Int? { a.flatMap { x in b.map { x + $0 } } }
        var groups: [String: Group] = [:]
        for group in matches.flatMap(\.groups) {
            if var existing = groups[group.command] {
                existing.entries += group.entries
                existing.savedTokens += group.savedTokens
                existing.beforeTokens = add(existing.beforeTokens, group.beforeTokens)
                existing.afterTokens = add(existing.afterTokens, group.afterTokens)
                groups[group.command] = existing
            } else {
                groups[group.command] = group
            }
        }
        return LedgerMatch(
            entries: matches.reduce(0) { $0 + $1.entries },
            savedTokens: matches.reduce(0) { $0 + $1.savedTokens },
            beforeTokens: matches.map(\.beforeTokens).reduce(Optional(0)) { add($0, $1) },
            afterTokens: matches.map(\.afterTokens).reduce(Optional(0)) { add($0, $1) },
            groups: groups.values.sorted { ($0.savedTokens, $1.command) > ($1.savedTokens, $0.command) }
        )
    }
}

extension Store {
    /// Everything the Token savers window shows for one saver. `sessionId` is
    /// the session the popover is showing; it anchors "This session" and the
    /// folder the comparisons are drawn from.
    public func saverDetail(
        _ saver: TokenSaver, range: SaverRange, sessionId: String?, ledger: [LedgerEntry], now: Date = Date()
    ) throws -> SaverDetail {
        try saverDetails([saver], range: range, sessionId: sessionId, ledger: ledger, now: now)[0]
    }

    /// Several savers' details from one pass over the sessions: every
    /// session's report is built once and shared.
    public func saverDetails(
        _ savers: [TokenSaver] = TokenSaver.allCases, range: SaverRange, sessionId: String?,
        ledger: [LedgerEntry], now: Date = Date()
    ) throws -> [SaverDetail] {
        var reportCache: [String: SaverSessionReport] = [:]
        func report(_ id: String) throws -> SaverSessionReport {
            if let cached = reportCache[id] { return cached }
            let built = try saverReport(sessionId: id, ledger: ledger)
            reportCache[id] = built
            return built
        }
        let sessionIds: [String]
        if let days = range.days {
            sessionIds = try sessionsActive(since: Timestamps.string(from: now.addingTimeInterval(-Double(days) * 86_400)))
        } else {
            sessionIds = sessionId.map { [$0] } ?? []
        }
        let reports = try sessionIds.map(report)

        // Comparisons come from the shown session's folder, over the range
        // (30 days for a single session, which can't be compared with itself).
        let mainCalls = try sessionId.map { try calls(sessionId: $0, scope: .mainThread) } ?? []
        let folder = mainCalls.first(where: { $0.cwd != nil })?.cwd
        // Another harness's sessions have other prompts entirely.
        let vendor = mainCalls.first?.vendor
        let since = Timestamps.string(from: now.addingTimeInterval(-Double(range.days ?? 30) * 86_400))
        var local = ComparisonSamples(), everywhere: ComparisonSamples?
        if let folder {
            local = try comparisonSamples(cwd: folder, vendor: vendor, since: since)
            for id in local.sessions { _ = try report(id) }
        }
        // The folder first; every folder only for a metric it is too thin for.
        func compare(_ metric: SaverComparison.Metric, _ values: KeyPath<ComparisonSamples, [String: Int]>,
                     by with: (String) -> Bool) throws -> SaverComparison? {
            if let found = local.split(metric, local[keyPath: values], by: with, scope: .folder) { return found }
            guard sessionId != nil else { return nil }
            if everywhere == nil {
                everywhere = try comparisonSamples(cwd: nil, vendor: vendor, since: since)
                for id in everywhere?.sessions ?? [] { _ = try report(id) }
            }
            guard let all = everywhere else { return nil }
            return all.split(metric, all[keyPath: values], by: with, scope: .everywhere)
        }

        var placementCache: [String: CarriedClaim.Placement] = [:]
        return try savers.map { saver in
            var comparisons: [SaverComparison] = []
            var output: OutputComparison?
            var turns: [SaverDetail.TurnOutput] = []
            if sessionId != nil {
                let usage = { (id: String) in reportCache[id]?.usage(saver) ?? SaverUsage(saver: saver) }
                if saver.kind == .replyStyle, let folder {
                    output = try outputComparison(cwd: folder, since: since, tool: saver)
                    if let output { comparisons.append(SaverComparison(output)) }
                }
                if saver.kind == .codeSearch, let reads = try compare(.readsPerSession, \.reads, by: { usage($0).ran }) {
                    comparisons.append(reads)
                }
                if saver.kind == .memory, let explore = try compare(.exploreBeforeEdit, \.explore, by: { usage($0).injectedBytes > 0 }) {
                    comparisons.append(explore)
                }
                if let first = try compare(.firstPrompt, \.firstPrompt, by: { usage($0).ran || usage($0).idle }) {
                    comparisons.append(first)
                }
            }
            if saver.kind == .replyStyle, let sessionId {
                let events = try self.events(sessionId: sessionId, kind: EventKind.hook.rawValue)
                    + self.events(sessionId: sessionId, kind: EventKind.command.rawValue)
                let signals = OutputComparison.signals(for: saver, events: events, toolCalls: try toolCalls(sessionId: sessionId))
                turns = SaverDetail.turns(calls: mainCalls, signals: signals)
            }
            let ids = reports.flatMap { $0.usage(saver).ledgerEntries.compactMap(\.toolUseId) }
                .filter { placementCache[$0] == nil }
            if !ids.isEmpty { placementCache.merge(try placements(toolUseIds: ids)) { a, _ in a } }
            return SaverDetail.build(saver: saver, range: range, reports: reports,
                                     comparison: output, comparisonFolder: folder, turns: turns,
                                     comparisons: comparisons, placements: placementCache)
        }
    }

    /// Per-session figures for one folder's sessions since a date, read once
    /// and split per tool.
    struct ComparisonSamples {
        var sessions: [String] = []
        var firstPrompt: [String: Int] = [:]
        var reads: [String: Int] = [:]
        var explore: [String: Int] = [:]
        /// When each session's first turn was, to keep both sides to one period.
        var started: [String: String] = [:]

        func split(_ metric: SaverComparison.Metric, _ values: [String: Int], by with: (String) -> Bool,
                   scope: SaverComparison.Scope) -> SaverComparison? {
            var on: [String] = [], off: [String] = []
            for id in sessions where values[id] != nil {
                if with(id) { on.append(id) } else { off.append(id) }
            }
            // Only the period both sides have sessions in: a tool installed
            // last week would otherwise be compared with older Claude Code
            // versions, whose system prompts differ by more than any tool.
            let onStarts = on.compactMap { started[$0] }, offStarts = off.compactMap { started[$0] }
            if let a = onStarts.min(), let b = offStarts.min(), let c = onStarts.max(), let d = offStarts.max() {
                let from = max(a, b), to = min(c, d)
                let inPeriod = { (id: String) in started[id].map { $0 >= from && $0 <= to } ?? false }
                on = on.filter(inPeriod)
                off = off.filter(inPeriod)
            }
            let sample = { (id: String) in SaverComparison.Sample(sessionId: id, value: values[id] ?? 0) }
            return SaverComparison.build(metric, with: on.map(sample), without: off.map(sample), scope: scope)
        }
    }

    /// Main-thread sessions of `vendor` in `cwd` (nil: every folder) since `since`: the
    /// first prompt (exact rows only), what Read returned over the session,
    /// and what exploring returned before the first edit (sessions with no
    /// edit have none).
    func comparisonSamples(cwd: String?, vendor: String?, since: String) throws -> ComparisonSamples {
        var samples = ComparisonSamples()
        let inFolder = """
            SELECT DISTINCT session_id FROM call
            WHERE (?1 IS NULL OR cwd = ?1) AND (?3 IS NULL OR vendor = ?3) AND ts >= ?2 AND agent_id IS NULL
            """
        let bindings: [SQLiteValue] = [cwd.map { .text($0) } ?? .null, .text(since), vendor.map { .text($0) } ?? .null]
        samples.sessions = try database.query(inFolder + " ORDER BY session_id;", bindings) { $0.text(0) }
        guard !samples.sessions.isEmpty else { return samples }
        for (id, ts) in try database.query(
            "SELECT session_id, MIN(ts) FROM call WHERE session_id IN (\(inFolder)) GROUP BY session_id;",
            bindings) { ($0.text(0), $0.text(1)) } {
            samples.started[id] = ts
        }
        for (id, tokens) in try database.query(
            """
            SELECT session_id, context_tokens FROM call
            WHERE agent_id IS NULL AND turn_index = 0 AND confidence = 'exact' AND session_id IN (\(inFolder));
            """, bindings) { ($0.text(0), $0.int(1)) } {
            samples.firstPrompt[id] = tokens
        }
        for id in samples.sessions { samples.reads[id] = 0 }
        for (id, tokens) in try database.query(
            """
            SELECT session_id, COALESCE(SUM(result_tokens), 0) FROM tool_call
            WHERE name = 'Read' AND session_id IN (\(inFolder)) GROUP BY session_id;
            """, bindings) { ($0.text(0), $0.int(1)) } {
            samples.reads[id] = tokens
        }
        let rows = try database.query(
            """
            SELECT t.session_id, t.name, COALESCE(t.result_tokens, 0) FROM tool_call t
            JOIN call c ON c.dedupe_key = t.call_id
            WHERE c.agent_id IS NULL AND t.session_id IN (\(inFolder))
            ORDER BY t.session_id, t.ts, t.id;
            """, bindings) { ($0.text(0), $0.text(1), $0.int(2)) }
        var explored: [String: Int] = [:]
        var edited = Set<String>()
        for (id, name, tokens) in rows where !edited.contains(id) {
            if Self.editTools.contains(name) {
                edited.insert(id)
                samples.explore[id] = explored[id] ?? 0
            } else if Self.exploreTools.contains(name) {
                explored[id, default: 0] += tokens
            }
        }
        return samples
    }

    /// The first index whose element satisfies a predicate that is false then
    /// true along a sorted array; `count` when none does.
    static func firstIndex(in sorted: [String], where isPast: (String) -> Bool) -> Int {
        var low = 0, high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if isPast(sorted[mid]) { high = mid } else { low = mid + 1 }
        }
        return low
    }

    static let editTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]
    static let exploreTools: Set<String> = ["Read", "Grep", "Glob", "Bash"]

    /// Where each Bash call sits: how many later prompts in its stream carried
    /// its result before a compaction, and what reached the model.
    func placements(toolUseIds: [String]) throws -> [String: CarriedClaim.Placement] {
        var result: [String: CarriedClaim.Placement] = [:]
        var streams: [String: (calls: [String], boundaries: [String])] = [:]
        for chunk in stride(from: 0, to: toolUseIds.count, by: 500).map({ Array(toolUseIds[$0..<min($0 + 500, toolUseIds.count)]) }) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = try database.query(
                """
                SELECT t.id, t.result_tokens, t.target, c.session_id, COALESCE(c.agent_id, ''), c.ts
                FROM tool_call t JOIN call c ON c.dedupe_key = t.call_id WHERE t.id IN (\(marks));
                """, chunk.map { .text($0) }
            ) { ($0.text(0), $0.optionalInt(1), $0.optionalText(2), $0.text(3), $0.text(4), $0.text(5)) }
            for (id, resultTokens, target, session, agent, ts) in rows {
                let key = session + "\u{1}" + agent
                if streams[key] == nil {
                    let calls = try database.query(
                        "SELECT ts FROM call WHERE session_id = ?1 AND COALESCE(agent_id, '') = ?2 ORDER BY ts;",
                        [.text(session), .text(agent)]) { $0.text(0) }
                    let boundaries = try database.query(
                        "SELECT ts FROM event WHERE session_id = ?1 AND COALESCE(agent_id, '') = ?2 AND kind = 'compaction' ORDER BY ts;",
                        [.text(session), .text(agent)]) { $0.text(0) }
                    streams[key] = (calls, boundaries)
                }
                guard let stream = streams[key] else { continue }
                // Both sorted: the calls strictly after this one, up to the
                // first compaction after it.
                let first = Self.firstIndex(in: stream.calls) { $0 > ts }
                let end = stream.boundaries.first { $0 > ts }
                let last = end.map { e in Self.firstIndex(in: stream.calls) { $0 >= e } } ?? stream.calls.count
                let prompts = max(0, last - first)
                result[id] = CarriedClaim.Placement(prompts: prompts, resultTokens: resultTokens, command: target)
            }
        }
        return result
    }
}

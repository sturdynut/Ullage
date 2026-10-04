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

    public static func build(
        saver: TokenSaver,
        range: SaverRange,
        reports: [SaverSessionReport],
        comparison: OutputComparison? = nil,
        comparisonFolder: String? = nil,
        turns: [TurnOutput] = []
    ) -> SaverDetail {
        let usages = reports.map { $0.usage(saver) }
        let matches = usages.compactMap(\.ledger)
        return SaverDetail(
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
            ledger: matches.isEmpty ? nil : LedgerMatch.merged(matches),
            comparison: comparison,
            comparisonFolder: comparisonFolder,
            turns: turns
        )
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
    /// the session the popover is showing; it anchors "This session" and
    /// caveman's folder and per-reply chart.
    public func saverDetail(
        _ saver: TokenSaver, range: SaverRange, sessionId: String?, ledger: [LedgerEntry], now: Date = Date()
    ) throws -> SaverDetail {
        let sessionIds: [String]
        if let days = range.days {
            sessionIds = try sessionsActive(since: Timestamps.string(from: now.addingTimeInterval(-Double(days) * 86_400)))
        } else {
            sessionIds = sessionId.map { [$0] } ?? []
        }
        let reports = try sessionIds.map { try saverReport(sessionId: $0, ledger: ledger) }

        var comparison: OutputComparison?
        var folder: String?
        var turns: [SaverDetail.TurnOutput] = []
        if saver.kind == .replyStyle, let sessionId {
            let calls = try calls(sessionId: sessionId, scope: .mainThread)
            folder = calls.first(where: { $0.cwd != nil })?.cwd
            if let folder {
                let days = Double(range.days ?? 30)
                comparison = try outputComparison(cwd: folder, since: Timestamps.string(from: now.addingTimeInterval(-days * 86_400)), tool: saver)
            }
            let events = try self.events(sessionId: sessionId, kind: EventKind.hook.rawValue)
                + self.events(sessionId: sessionId, kind: EventKind.command.rawValue)
            let signals = OutputComparison.signals(for: saver, events: events, toolCalls: try toolCalls(sessionId: sessionId))
            turns = SaverDetail.turns(calls: calls, signals: signals)
        }
        return SaverDetail.build(saver: saver, range: range, reports: reports,
                                 comparison: comparison, comparisonFolder: folder, turns: turns)
    }
}

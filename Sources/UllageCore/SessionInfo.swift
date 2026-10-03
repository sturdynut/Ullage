import Foundation

/// The words the popover and the phone page both put around one stream's
/// numbers: the headline, the Session information section, and the collapsed
/// lines of composition and plan limits. Here, not in either view, because a
/// second copy of a display rule is a second place for it to be wrong.
public struct StreamFigures: Equatable {
    public var status: MenuBarState.Status
    public var contextTokens: Int?
    public var windowLimit: Int?
    public var occupancy: Double?
    public var contextDelta: Int?
    public var lastActivity: Date?
    /// The session id, or nil when the stream is an agent's.
    public var sessionId: String?
    /// An agent's type and status, shown instead of the session id.
    public var agentLine: String?
    /// The agent's status alone ("background", …), for the one-line summary;
    /// nil when it completed normally.
    public var agentStatus: String?
    /// Idle and the session's own (an agent is never called idle here).
    public var isIdle: Bool

    public init(
        status: MenuBarState.Status, contextTokens: Int?, windowLimit: Int?, occupancy: Double?,
        contextDelta: Int?, lastActivity: Date?, sessionId: String?, agentLine: String? = nil,
        agentStatus: String? = nil, isIdle: Bool
    ) {
        self.status = status
        self.contextTokens = contextTokens
        self.windowLimit = windowLimit
        self.occupancy = occupancy
        self.contextDelta = contextDelta
        self.lastActivity = lastActivity
        self.sessionId = sessionId
        self.agentLine = agentLine
        self.agentStatus = agentStatus
        self.isIdle = isIdle
    }

    /// The session's own figures, straight from the menu bar's state.
    public init(state: MenuBarState) {
        self.init(status: state.status, contextTokens: state.contextTokens, windowLimit: state.windowLimit,
                  occupancy: state.occupancy, contextDelta: state.contextDelta, lastActivity: state.lastActivity,
                  sessionId: state.sessionId, isIdle: state.isIdle)
    }

    /// The headline: room left in the window, the thing the app is named for.
    public var headroom: String {
        guard let windowLimit, let contextTokens else { return "—" }
        return TokenFormat.compact(max(0, windowLimit - contextTokens))
    }

    /// The bar's own arithmetic.
    public var exactLine: String {
        guard status != .empty else { return "nothing ingested yet" }
        guard let contextTokens else { return "no turns recorded" }
        guard let windowLimit else { return "\(contextTokens.formatted()) tokens · no window reported" }
        return "\(contextTokens.formatted()) / \(windowLimit.formatted())"
    }

    public var usedLine: String? {
        guard let occupancy, status != .empty else { return nil }
        return MenuBarFormatter.percentage(occupancy) + " used"
    }
}

public enum SessionInfo {
    public struct Row: Equatable, Codable {
        public var label: String
        public var value: String
    }

    /// The expanded Session information table.
    public static func rows(_ figures: StreamFigures, history: ContextHistory?) -> [Row] {
        guard figures.status != .empty else { return [] }
        var rows: [Row] = []
        if let tokens = figures.contextTokens, figures.windowLimit == nil {
            rows.append(Row(label: "Context", value: tokens.formatted() + "  (no window reported)"))
        }
        if let delta = figures.contextDelta {
            rows.append(Row(label: "Last turn", value: (delta >= 0 ? "+" : "") + delta.formatted()))
        }
        if let history {
            let compactions = history.compactionTurns.count
            rows.append(Row(label: "Turns", value: history.points.count.formatted()
                + (compactions == 0 ? "" : " · \(compactions) compaction\(compactions == 1 ? "" : "s")")))
            if let resend = history.resend {
                rows.append(Row(label: "Re-sent per turn", value: resend.lastTokens.formatted()
                    + (resend.multiple.map { " · \(ContextHistory.multiple($0)) turn 1" } ?? "")
                    + " · " + MenuBarFormatter.percentage(resend.cachedShare) + " cached"))
            }
            if !history.rebuilds.isEmpty {
                rows.append(Row(label: "Cache rebuilt",
                                value: "\(history.rebuilds.count)× · " + CacheRebuilds.causeSummary(history.rebuilds)))
            }
        }
        if let agentLine = figures.agentLine, !agentLine.isEmpty {
            rows.append(Row(label: "Agent", value: agentLine))
        } else if let session = figures.sessionId {
            rows.append(Row(label: "Session", value: String(session.prefix(8))))
        }
        if let last = figures.lastActivity {
            rows.append(Row(label: figures.isIdle ? "Idle since" : "Last turn at",
                            value: last.formatted(date: .omitted, time: .standard)))
        }
        return rows
    }

    /// The collapsed line: problems first, and the time gives way to them so
    /// the line fits (ReadoutWidthTests).
    public static func summary(_ figures: StreamFigures, history: ContextHistory?) -> [Readout] {
        var parts: [Readout] = []
        if let delta = figures.contextDelta { parts.append(Readout("last turn", (delta >= 0 ? "+" : "") + delta.formatted())) }
        if let history {
            parts.append(Readout("turns", history.points.count.formatted()))
            if !history.compactionTurns.isEmpty { parts.append(Readout("compacted", "\(history.compactionTurns.count)×")) }
            let avoidable = history.rebuilds.filter(\.cause.isAvoidable)
            if !avoidable.isEmpty { parts.insert(Readout("re-cached", "\(avoidable.count)×", warning: true), at: 0) }
        }
        // Status alone, as before: the type is in the expanded table, and the
        // line has a width to keep (ReadoutWidthTests).
        if let status = figures.agentStatus, !status.isEmpty, figures.sessionId == nil { parts.append(Readout(status)) }
        if let last = figures.lastActivity, !parts.contains(where: \.isWarning) {
            parts.append(Readout(figures.isIdle ? "idle" : "at", last.formatted(date: .omitted, time: .shortened)))
        }
        return parts
    }

    /// The caption under the chart when nothing is hovered.
    public static func chartCaption(windowLimit: Int?, history: ContextHistory?) -> String? {
        guard let limit = windowLimit, let last = history?.points.last else { return nil }
        return TokenFormat.compact(max(0, limit - last.contextTokens)) + " left"
            + (history?.resend?.multiple.map { " · each turn re-sends \(TokenFormat.compact(last.contextTokens)), \(ContextHistory.multiple($0)) the first" }
               ?? " in the window")
    }
}

extension ContextComposition {
    /// Short name for the collapsed line: "Tool results" does not fit four-up.
    public static func shortName(_ segment: String) -> String {
        segment == toolResultsName ? "Tools" : segment
    }

    /// The collapsed line: the four totals, `≈` on the estimates.
    public var summary: [Readout] {
        segments.map { Readout(Self.shortName($0.name), (Self.isEstimate(segment: $0.name) ? "≈" : "") + TokenFormat.compact($0.tokens)) }
    }

    /// What each segment is, for a tooltip or a footnote.
    public static func note(for segment: String) -> String {
        switch segment {
        case baselineName:
            return "Rides every turn: system prompt, tool schemas, skills, CLAUDE.md, and the opening prompt — or the summary, after a compaction."
        case toolResultsName:
            return "Estimated from the length of what each tool returned (~4 bytes per token), never a counted figure."
        case assistantOutputName:
            return "Output tokens as reported. They are a mid-stream snapshot and undercount."
        default:
            return "Prompts, thinking, tool inputs, and the error in the two estimates above."
        }
    }
}

extension PlanLimitFormatter {
    /// The collapsed line: each harness by its tightest limit.
    public static func summary(_ limits: [PlanLimitDisplay]) -> [Readout] {
        summaries(limits).map { summary in
            let limit = summary.binding
            return Readout("\(summary.vendorName) \(shortLabel(limit.label))",
                           (limit.remainingFraction.map { MenuBarFormatter.percentage($0) } ?? "—") + " left",
                           warning: limit.isWarning, muted: limit.isStale)
        }
    }

    /// An expanded row's caption: reset and age first, then what Ullage saw.
    public static func detailCaption(for limit: PlanLimitDisplay, usage: Store.WindowUsage?, now: Date = Date()) -> String {
        var parts = [caption(for: limit, now: now)]
            .filter { !$0.isEmpty }
            .map { $0.replacingOccurrences(of: #"^\d+% left · "#, with: "", options: .regularExpression) }
            .filter { !$0.hasSuffix("% left") }
        if let usage, usage.calls > 0 {
            parts.append("\(usage.calls.formatted()) turns · \(TokenFormat.compact(usage.output)) out here")
        }
        return parts.joined(separator: " · ")
    }
}

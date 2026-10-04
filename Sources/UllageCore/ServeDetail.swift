import Foundation

/// Everything the popover shows for one session, as plain data for the phone
/// page: the headline, the chart, and every section with its one collapsed
/// line and its full contents. Built from the same Core rules the popover
/// draws (`SessionInfo`, `SaverPanel`, `PlanLimitFormatter`, `AgentTree`), so
/// the two cannot drift; the page only lays it out.
public struct ServeDetail: Codable, Equatable {
    public struct Chart: Codable, Equatable {
        /// `[turn, contextTokens]` pairs, in order.
        public var points: [[Int]]
        public var windowLimit: Int?
        public var compactions: [Int]
        public var rebuilds: [Rebuild]
        public var caption: String?
    }

    public struct Rebuild: Codable, Equatable {
        public var turn: Int
        public var contextTokens: Int
        public var cacheWrite: Int
        public var cause: String
        public var detail: String?
        public var avoidable: Bool
    }

    public struct Row: Codable, Equatable {
        public var label: String
        public var value: String?
        public var detail: String?
        public var warning: Bool = false
        public var muted: Bool = false
        /// Indent level in a tree (agents).
        public var depth: Int = 0
        /// 0…1 for a small bar under the row (plan limits).
        public var bar: Double?
    }

    public struct Group: Codable, Equatable {
        public var heading: String?
        public var rows: [Row]
    }

    /// One composition segment, for the proportion bar and its legend.
    public struct Share: Codable, Equatable {
        public var key: String          // baseline | tools | output | other
        public var name: String
        public var tokens: Int
        public var estimate: Bool
    }

    public struct Saver: Codable, Equatable {
        public var id: String
        public var name: String
        public var switchState: String  // on | off | not installed
        public var canSwitch: Bool
        public var isInstalled: Bool
        public var metric: String
        public var metricCaption: String
        public var metricWarning: Bool
        public var line: String
        public var note: String?
        public var pending: String?
        public var canUndo: Bool
    }

    public struct Section: Codable, Equatable {
        public var id: String
        public var title: String
        public var summary: [Readout]
        /// Colour keys for the summary items (composition only).
        public var dots: [String]?
        public var shares: [Share]?
        public var warning: String?
        public var groups: [Group] = []
        public var savers: [Saver]?
        public var installable: [Installable]?
        public var legend: [String]?
    }

    public struct Installable: Codable, Equatable {
        public var id: String
        public var name: String
        public var shrinks: String
    }

    public var sessionId: String
    /// True when this is the session the menu bar is following.
    public var isLatest: Bool
    public var status: String
    public var project: String?
    public var path: String?
    public var modelLine: String?
    public var modelWindowIsAssumed: Bool
    /// Open in Claude (Remote Control) or Open in Codex (the app's thread).
    public var link: SessionLink?
    public var headroom: String
    public var exactLine: String
    public var usedLine: String?
    /// Why there's no gauge, for a harness that can't have one.
    public var notice: String?
    public var occupancy: Double?
    public var peakOccupancy: Double?
    public var chart: Chart?
    public var sections: [Section]
}

extension ServeDetail {
    /// What this session's harness doesn't record, one row each.
    static func harnessSection(_ support: HarnessSupport) -> Section {
        let missing = support.gaps.filter { !$0.available }.count
        var section = Section(
            id: "harness", title: support.title,
            summary: [missing > 0 ? Readout("not recorded", "\(missing)") : Readout("partly recorded", "\(support.gaps.count)")],
            groups: [Group(heading: nil, rows: support.gaps.map { Row(label: $0.label, value: $0.detail ?? "") })]
        )
        section.legend = support.unverifiedNote.map { [$0] }
        return section
    }
}

extension ServeDetail {
    public static func build(
        store: Store, sessionId: String, isLatest: Bool, savers: SaverControl?, now: Date = Date()
    ) throws -> ServeDetail? {
        guard let call = try store.latestCall(sessionId: sessionId) else { return nil }
        let state = MenuBarFormatter.state(for: call, now: now)
        let figures = StreamFigures(state: state)
        let history = try store.contextHistory(sessionId: sessionId)
        let composition = try store.composition(sessionId: sessionId)
        let tree = try store.agentTree(sessionId: sessionId)

        var sections: [Section] = []
        if let composition { sections.append(compositionSection(composition)) }
        sections.append(Section(id: "session", title: "Session information",
                                summary: SessionInfo.summary(figures, history: history),
                                groups: [Group(heading: nil, rows: SessionInfo.rows(figures, history: history)
                                    .map { Row(label: $0.label, value: $0.value) })]))
        if !tree.isEmpty { sections.append(agentsSection(tree, state: state, history: history)) }
        if let savers { sections.append(saversSection(try savers.panel(store: store, sessionId: sessionId, now: now))) }
        let support = HarnessSupport(vendor: call.vendor)
        if !support.gaps.isEmpty { sections.append(harnessSection(support)) }
        let limits = PlanLimitFormatter.displays(for: try store.planLimits(), now: now)
        if !limits.isEmpty { sections.append(try limitsSection(limits, store: store, now: now)) }

        let peak = state.windowLimit.flatMap { limit in limit > 0 ? Double(history.peakContextTokens) / Double(limit) : nil }
        return ServeDetail(
            sessionId: sessionId,
            isLatest: isLatest,
            status: ServeSnapshot.name(of: state.status),
            project: state.project,
            path: MenuBarFormatter.displayPath(state.cwd),
            modelLine: state.modelLine,
            modelWindowIsAssumed: state.modelWindowIsAssumed,
            link: try store.sessionLink(sessionId: sessionId),
            headroom: figures.headroom,
            exactLine: figures.exactLine,
            usedLine: figures.usedLine,
            notice: figures.gaugeNotice,
            occupancy: state.occupancy,
            peakOccupancy: peak,
            chart: Chart(
                points: history.points.map { [$0.turnIndex, $0.contextTokens] },
                windowLimit: history.windowLimit,
                compactions: history.compactionTurns,
                rebuilds: history.rebuilds.map {
                    Rebuild(turn: $0.turnIndex, contextTokens: $0.contextTokens, cacheWrite: $0.cacheWrite,
                            cause: $0.cause.rawValue, detail: $0.detail, avoidable: $0.cause.isAvoidable)
                },
                caption: SessionInfo.chartCaption(windowLimit: state.windowLimit, history: history)
            ),
            sections: sections
        )
    }

    static func key(_ segment: String) -> String {
        switch segment {
        case ContextComposition.baselineName: return "baseline"
        case ContextComposition.toolResultsName: return "tools"
        case ContextComposition.assistantOutputName: return "output"
        default: return "other"
        }
    }

    static func compositionSection(_ c: ContextComposition) -> Section {
        let approx = { (tokens: Int) in "≈" + TokenFormat.compact(tokens) }
        var groups: [Group] = []
        var caption = "turns \(c.windowStartTurn)–\(c.lastTurn)"
        if c.compactions > 0 { caption += " · after \(c.compactions) compaction\(c.compactions == 1 ? "" : "s")" }
        groups.append(Group(heading: caption, rows: c.segments.map { segment in
            Row(label: segment.name,
                value: (ContextComposition.isEstimate(segment: segment.name) ? "≈" : "") + TokenFormat.compact(segment.tokens)
                    + " · " + MenuBarFormatter.percentage(c.share(segment.tokens)),
                detail: ContextComposition.note(for: segment.name))
        }))
        var baseline = [Row(label: "System prompt + tool schemas", value: "not separable on disk")]
        if let md = c.claudeMdTokensEstimate, md > 0 { baseline.append(Row(label: "CLAUDE.md", value: approx(md) + " tokens")) }
        if !c.mcpServers.isEmpty { baseline.append(Row(label: "MCP servers", value: c.mcpServers.joined(separator: ", "))) }
        if !c.skills.isEmpty {
            baseline.append(Row(label: "Skills", value: "\(c.skills.count): " + c.skills.prefix(6).joined(separator: ", ")
                                + (c.skills.count > 6 ? "…" : "")))
        }
        baseline.append(Row(label: c.windowStartTurn == 0 ? "Opening prompt" : "Compaction summary"))
        groups.append(Group(heading: "Baseline — rides every turn (\(TokenFormat.compact(c.baseline)))", rows: baseline))
        if !c.tools.isEmpty {
            var rows = c.tools.prefix(10).map { Row(label: $0.name, value: "\($0.calls)× · " + approx($0.resultTokens)) }
            if c.tools.count > 10 { rows.append(Row(label: "and \(c.tools.count - 10) more", muted: true)) }
            groups.append(Group(heading: "Tool results in the window (\(approx(c.toolResults)), estimated)", rows: rows))
        }
        let called = ToolTargets.mostCalled(c)
        if !called.isEmpty {
            groups.append(Group(heading: "Called most in the window", rows: called.map {
                Row(label: $0.tool + " " + $0.displayName, value: "×\($0.target.calls)")
            }))
        }
        if c.staleToolResults > 0 || !c.repeatedReads.isEmpty {
            var rows: [Row] = []
            if c.staleToolResults > 0 {
                rows.append(Row(label: "Results from \(ContextComposition.staleAfterTurns)+ turns ago", value: approx(c.staleToolResults),
                                detail: "\(ContextComposition.staleAfterTurns) is a rule of thumb, not a measured cut-off."))
            }
            rows += c.repeatedReads.prefix(4).map {
                Row(label: "Read \(ToolTargets.shortPath($0.target)) ×\($0.reads)", value: approx($0.extraTokens),
                    detail: "Every earlier copy is still in the window.")
            }
            groups.append(Group(heading: "Along for the ride", rows: rows))
        }
        return Section(id: "composition", title: "Context", summary: c.summary,
                       dots: c.segments.map { key($0.name) },
                       shares: c.segments.map { Share(key: key($0.name), name: $0.name, tokens: $0.tokens,
                                                      estimate: ContextComposition.isEstimate(segment: $0.name)) },
                       warning: c.estimatesOvershoot ? "The estimates add up to more than the window holds; shares are approximate." : nil,
                       groups: groups)
    }

    static func agentsSection(_ tree: AgentTree, state: MenuBarState, history: ContextHistory) -> Section {
        var rows = [Row(label: "Main thread",
                        value: state.occupancy.map(MenuBarFormatter.percentage),
                        detail: [state.modelLine, "\(history.points.count) turn\(history.points.count == 1 ? "" : "s")"]
                            .compactMap { $0 }.joined(separator: " · "))]
        for node in tree.flattened {
            let agent = node.agent
            rows.append(Row(
                label: agent.displayName,
                value: agent.occupancy.map(MenuBarFormatter.percentage),
                detail: [agent.agentType, agent.calls == 1 ? "1 turn" : "\(agent.calls) turns",
                         agent.toolCalls > 0 ? "\(agent.toolCalls) tools" : nil, agent.statusLabel]
                    .compactMap { $0 }.joined(separator: " · "),
                warning: (agent.occupancy ?? 0) >= MenuBarFormatter.warningThreshold,
                depth: node.depth + 1
            ))
        }
        return Section(id: "agents", title: "Agents", summary: tree.summary, groups: [Group(heading: nil, rows: rows)])
    }

    static func saversSection(_ panel: SaverPanel) -> Section {
        Section(
            id: "savers", title: "Token savers", summary: panel.summary,
            warning: panel.warning,
            groups: panel.pendingInstalls.isEmpty ? [] : [Group(heading: nil, rows: panel.pendingInstalls.map { Row(label: $0) })],
            savers: panel.rows.map {
                Saver(id: $0.saver.rawValue, name: $0.saver.displayName, switchState: $0.switchState.rawValue,
                      canSwitch: $0.canSwitch, isInstalled: $0.isInstalled, metric: $0.metric,
                      metricCaption: $0.metricCaption, metricWarning: $0.metricTone == .warning, line: $0.line,
                      note: $0.note, pending: $0.pending, canUndo: $0.canUndo)
            },
            installable: panel.installable.map { Installable(id: $0.rawValue, name: $0.displayName, shrinks: $0.shrinks) },
            legend: panel.legend
        )
    }

    static func limitsSection(_ limits: [PlanLimitDisplay], store: Store, now: Date) throws -> Section {
        var rows: [Row] = []
        for limit in limits {
            let usage = try limit.windowStart.map { try store.windowUsage(vendor: limit.vendor, since: Timestamps.string(from: $0)) }
            rows.append(Row(label: limit.vendorName + " " + limit.label,
                            value: (limit.remainingFraction.map { MenuBarFormatter.percentage($0) } ?? "—") + " left",
                            detail: PlanLimitFormatter.detailCaption(for: limit, usage: usage, now: now),
                            warning: limit.isWarning, muted: limit.isStale, bar: limit.usedFraction))
        }
        return Section(id: "limits", title: "Plan limits", summary: PlanLimitFormatter.summary(limits),
                       groups: [Group(heading: nil, rows: rows)])
    }
}

#if os(macOS)
import AppKit
import SwiftUI
import UllageCore

/// M5/M8 — the popover behind the menu bar title: which project and session,
/// which of its agents, how full that one's window is, and how it got there.
struct PopoverContent: View {
    @ObservedObject var model: MenuBarModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            toolbar
            header
            if let tree = model.agents, !tree.isEmpty {
                SectionRule("Agents") { agentsTrailing }
                AgentTreeView(
                    tree: tree,
                    mainThreadDetail: mainThreadDetail,
                    mainThreadOccupancy: model.state.occupancy,
                    focus: model.focus,
                    onSelect: { model.focus(on: $0) }
                )
            }
            if let history = model.history {
                SectionRule("Context per turn", scope: scopeName)
                ContextChart(history: history, showsIdleCaption: false)
                    .frame(height: 84)
            }
            if let composition = model.composition {
                SectionRule("What the window holds", scope: scopeName) {
                    if composition.estimatesOvershoot { overshootBadge }
                }
                CompositionView(composition: composition, showsTitle: false)
            }
            if model.state.status != .empty {
                SectionRule("Details", scope: scopeName)
            }
            stats
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
            actions
                .padding(.top, 2)
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { model.popoverDidOpen() }
        .onDisappear { model.popoverDidClose() }
    }

    // MARK: Scope

    /// Selecting an agent rescopes the chart, the breakdown and the stats —
    /// three blocks that used to change meaning without changing a word. Each
    /// one's section rule now carries the agent's name, so the scope is stated
    /// on top of the numbers it governs, in the accent colour that means "the
    /// stream you are looking at", and it survives collapsing the tree.
    ///
    /// Nil on the main thread: the header already names the session, and a
    /// caption on every block repeating it is noise.
    private var scopeName: String? { model.focusedAgent?.displayName }

    /// The agent count, and the way back out of one.
    @ViewBuilder
    private var agentsTrailing: some View {
        HStack(spacing: 6) {
            if model.focusedAgent != nil {
                Button { model.focus(on: .mainThread) } label: {
                    Text("back to main thread")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.4)
                        .textCase(.uppercase)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            } else if let tree = model.agents {
                Text("\(tree.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .fixedSize()
    }

    private var overshootBadge: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 9))
            .foregroundStyle(Color.orange)
            .help("The estimated parts add up to more than the window holds, so the shares below are approximate and Other is clamped at zero.")
    }

    /// The main-thread row's second line, in the same shape as an agent's:
    /// what is answering, then how much it has done.
    private var mainThreadDetail: String {
        [
            model.state.model,
            model.history.map { "\($0.points.count) turn\($0.points.count == 1 ? "" : "s")" },
        ].compactMap { $0 }.joined(separator: " · ")
    }

    /// Every control the popover has, in one strip at the top: which session to
    /// follow, and the app's own housekeeping. Nothing between the answer and
    /// the evidence below it.
    private var toolbar: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            sessionMenu
            overflowMenu
        }
        .frame(height: 14)
    }

    // MARK: Header

    /// The headline is the room left, not the percentage.
    ///
    /// The menu bar item you just clicked already showed the percentage; saying
    /// it again at 26pt spends the largest type on the screen repeating the
    /// control that opened it. Ullage is the empty space at the top of a barrel,
    /// and until now the app never showed it. The percentage stays, in the
    /// caption, because it is the vocabulary the menu bar speaks.
    @ViewBuilder
    private var header: some View {
        let state = model.state
        // When an agent is selected these are *its* window. The menu bar title
        // keeps showing the session's, which is the one thing that must never
        // be a subagent's.
        let agent = model.focusedAgent
        let occupancy = agent.map(\.occupancy) ?? state.occupancy
        let contextTokens = agent?.lastContextTokens ?? state.contextTokens
        let windowLimit = agent?.windowLimit ?? state.windowLimit
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent?.displayName ?? state.project ?? "No sessions ingested yet")
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        if let subtitle = subtitle(agent: agent, state: state) {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        // "window assumed" means this percentage may be wrong.
                        // It used to be two grey words after the model name.
                        if agent == nil, state.modelWindowIsAssumed, state.status != .empty {
                            assumedWindowBadge
                        }
                        if model.pinFellBack {
                            Text("· pinned session has no turns")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 8)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(headroom(contextTokens: contextTokens, windowLimit: windowLimit))
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(headroomStyle(state: state, occupancy: occupancy, windowLimit: windowLimit))
                    if windowLimit != nil, state.status != .empty {
                        Text("left")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            OccupancyBar(
                occupancy: state.status == .empty ? nil : occupancy,
                peak: peakOccupancy(windowLimit: windowLimit)
            )

            // The bar's own arithmetic, on its own line, ends aligned with the
            // ends of the bar.
            HStack(spacing: 6) {
                Text(exactLine(state: state, contextTokens: contextTokens, windowLimit: windowLimit))
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                if let occupancy, state.status != .empty {
                    Text(MenuBarFormatter.percentage(occupancy) + " used")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
            .lineLimit(1)
        }
    }

    private func headroomStyle(state: MenuBarState, occupancy: Double?, windowLimit: Int?) -> AnyShapeStyle {
        guard windowLimit != nil, state.status != .empty else { return AnyShapeStyle(.tertiary) }
        if (occupancy ?? 0) >= MenuBarFormatter.warningThreshold { return AnyShapeStyle(Color.orange) }
        return AnyShapeStyle(model.focusedAgent == nil && state.isIdle ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
    }

    /// The room left — the thing the app is named for, and the one number the
    /// menu bar has no space to show.
    private func headroom(contextTokens: Int?, windowLimit: Int?) -> String {
        guard let windowLimit, let contextTokens else { return "—" }
        return CompositionView.compact(max(0, windowLimit - contextTokens))
    }

    private func exactLine(state: MenuBarState, contextTokens: Int?, windowLimit: Int?) -> String {
        guard state.status != .empty else { return "nothing ingested yet" }
        guard let contextTokens else { return "no turns recorded" }
        guard let windowLimit else { return "\(contextTokens.formatted()) tokens · no window reported" }
        return "\(contextTokens.formatted()) / \(windowLimit.formatted())"
    }

    /// Drawn as a mark on the same track, not as a second gauge: it is the same
    /// ratio against the same window, and on a growing session it is simply the
    /// current value.
    private func peakOccupancy(windowLimit: Int?) -> Double? {
        guard let windowLimit, windowLimit > 0, let peak = model.history?.peakContextTokens else { return nil }
        return Double(peak) / Double(windowLimit)
    }

    private var assumedWindowBadge: some View {
        Text("window assumed")
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.orange.opacity(0.18)))
            .foregroundStyle(Color.orange)
            .help("This model is not in the window-limit table, so the percentage is against an assumed 200k window.")
    }

    private func subtitle(agent: AgentSummary?, state: MenuBarState) -> String? {
        if let agent {
            return [agent.agentType, agent.model, state.project]
                .compactMap { $0 }
                .joined(separator: " · ")
        }
        return state.model
    }

    // MARK: Session picker

    /// Most recent is the default and needs no control; switching sessions is
    /// rare enough to live behind the title it already names, rather than a
    /// full-width field competing with the answer.
    ///
    /// The chevron takes the accent colour while a session is pinned, so the
    /// one state that is not the default announces itself.
    private var sessionMenu: some View {
        Menu {
            Picker("Session", selection: $model.selection) {
                Text("Most recent").tag(SessionSelection.automatic)
                // Grouped by project: a session id is not a name, and the
                // agents inside one are named by other agents. The project is
                // the label the person reading this already knows.
                ForEach(model.projects) { group in
                    Section(group.project) {
                        ForEach(group.sessions) { session in
                            Text(label(for: session)).tag(SessionSelection.pinned(session.sessionId))
                        }
                    }
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "chevron.down.circle")
                .font(.system(size: 11, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(model.selection == .automatic ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
        .help(model.selection == .automatic ? "Following the most recent session — click to pin one" : "Pinned; click to change or follow the most recent again")
    }

    /// Inside a project section, the project name is already the header.
    private func label(for session: SessionSummary) -> String {
        let when = Timestamps.date(from: session.lastTs)
            .map { Self.relative.localizedString(for: $0, relativeTo: Date()) } ?? ""
        let occupancy = session.occupancy.map(MenuBarFormatter.percentage) ?? "?"
        let agents = session.agents == 0
            ? ""
            : " · \(session.agents) agent\(session.agents == 1 ? "" : "s")"
        return "\(session.sessionId.prefix(8)) · \(occupancy)\(agents) · \(when)"
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    // MARK: Stats

    @ViewBuilder
    private var stats: some View {
        let state = model.state
        // Every figure describes the stream the popover is looking at, so a
        // selected agent's turns are never shown next to the session's tokens.
        let agent = model.focusedAgent
        let contextTokens = agent?.lastContextTokens ?? state.contextTokens
        let windowLimit = agent?.windowLimit ?? state.windowLimit
        let delta = agent == nil ? state.contextDelta : model.history?.points.last?.contextDelta
        let lastActivity = agent.flatMap { $0.lastTs.flatMap(Timestamps.date(from:)) } ?? state.lastActivity
        if state.status != .empty {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                // Values right-aligned against the popover edge so they scan as
                // a column instead of a ragged left edge wherever the longest
                // label happened to push them.
                // Context is the headline's own arithmetic and lives up there;
                // repeating it here put the explanation 300pt from the number.
                if let contextTokens, windowLimit == nil {
                    row("Context", contextTokens.formatted() + "  (no window reported)")
                }
                if let delta {
                    row("Last turn", (delta >= 0 ? "+" : "") + delta.formatted())
                }
                if let history = model.history {
                    row("Turns", history.points.count.formatted()
                        + (history.compactionTurns.isEmpty ? "" : " · \(history.compactionTurns.count) compaction\(history.compactionTurns.count == 1 ? "" : "s")"))
                    // Peak is a tick on the ring: same ratio, same window, and
                    // on a growing session it is the current value anyway.
                }
                // Under an agent, the session id and the session's agent count
                // describe something other than every number around them, which
                // made both rows read as false.
                if let agent {
                    row("Agent", [agent.agentType, agent.statusLabel].compactMap { $0 }.joined(separator: " · "))
                } else if let session = state.sessionId {
                    row("Session", String(session.prefix(8)))
                }
                if let lastActivity {
                    row(state.isIdle && agent == nil ? "Idle since" : "Last turn at",
                        lastActivity.formatted(date: .omitted, time: .standard))
                }
            }
            .font(.callout)
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary)
            Text(value)
                .monospacedDigit()
                .textSelection(.enabled)
                .gridColumnAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    // MARK: Actions

    /// One button for the thing you might actually want next; the app's own
    /// housekeeping goes behind a menu instead of standing at the same weight
    /// as the task.
    private var actions: some View {
        HStack(spacing: 8) {
            Button("History…") {
                openWindow(id: HistoryWindow.id)
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .controlSize(.small)
    }

    private var overflowMenu: some View {
        Menu {
            Button(model.isWatching ? "Refresh now" : "Start watching") {
                if model.isWatching { model.refreshNow() } else { model.start() }
            }
            Button("Show database in Finder") { model.openDatabaseFolder() }
            Divider()
            Button("Quit Ullage") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 11, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.tertiary)
        .help("Refresh, show the database, quit")
    }
}
#endif

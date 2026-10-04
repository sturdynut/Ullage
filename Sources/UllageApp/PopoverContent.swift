#if os(macOS)
import AppKit
import SwiftUI
import UllageCore

/// M5/M8 — the popover behind the menu bar title: which project and session,
/// which of its agents, how full that one's window is, and how it got there.
struct PopoverContent: View {
    @ObservedObject var model: MenuBarModel
    @Environment(\.openWindow) private var openWindow
    /// Height of everything below the header, measured, so the scroll view is
    /// exactly as tall as its content until the screen runs out.
    @State private var sectionsHeight: CGFloat = 0
    @State private var headerHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        // A MenuBarExtra window taller than the screen is clipped at the top,
        // which is where the session name and model live. The toolbar and
        // header stay pinned; the sections below scroll once they don't fit.
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                toolbar
                header
                // Straight under the bar it charts: how the window filled up.
                // No section rule — the headline above already names it.
                if let history = model.history {
                    ContextChart(history: history, showsIdleCaption: false, readoutOverlay: true)
                        .frame(height: 72)

                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            ScrollView(.vertical) {
                sections
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sectionsHeight = $0 }
            }
            .scrollIndicators(.automatic)
            .frame(height: min(sectionsHeight, maxSectionsHeight))
        }
        .padding(14)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        .background(WindowFitter(height: contentHeight))
        .onAppear { model.popoverDidOpen() }
        .onDisappear { model.popoverDidClose() }
    }

    /// The room left under the menu bar once the pinned header and padding are
    /// placed, with a margin so the window never touches the bottom edge.
    private var maxSectionsHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return max(200, screen - headerHeight - 14 * 2 - 8 - 24)
    }

    /// Each section is one row: its name, its one line of figures, and a
    /// chevron. The row opens that section's page in the main window; the
    /// popover itself stays a glance.
    @ViewBuilder
    private var sections: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let composition = model.composition {
                SectionLink("Context", scope: scopeName,
                            shares: composition.segments.map {
                                RuleShare(color: CompositionView.color(for: $0.name), weight: Double($0.tokens))
                            },
                            open: { open(.composition) }) {
                    ReadoutLine(items: zip(composition.summary, composition.segments).map {
                        ReadoutLine.Item(readout: $0, dot: CompositionView.color(for: $1.name))
                    })
                }
            }
            if model.state.status != .empty {
                SectionLink("Session information", scope: scopeName, open: { open(.session) }) { statsSummary }
            }
            if let tree = model.agents, !tree.isEmpty {
                SectionLink("Agents", open: { open(.agents) }, trailing: { agentsTrailing }) {
                    ReadoutLine(tree.summary)
                }
            }
            if !model.savers.isEmpty {
                SectionLink("Token savers", open: { open(.savers) }) { ReadoutLine(model.savers.summary) }
            }
            // Last: the account's allowance, not this session's window — the
            // sections above all describe the session.
            planLimitsSection
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
            actions
                .padding(.top, 2)
        }
    }

    /// The main window, on one page.
    private func open(_ page: MainPage) {
        model.windowPage = page
        openWindow(id: MainWindow.id)
        NSApp.activate(ignoringOtherApps: true)
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


    /// The main-thread row's second line, in the same shape as an agent's:
    /// what is answering, then how much it has done.
    private var mainThreadDetail: String {
        [
            model.state.modelLine,
            model.history.map { "\($0.points.count) turn\($0.points.count == 1 ? "" : "s")" },
        ].compactMap { $0 }.joined(separator: " · ")
    }

    /// Every control the popover has, in one strip at the top: which session to
    /// follow, and the app's own housekeeping. Nothing between the answer and
    /// the evidence below it.
    private var toolbar: some View {
        HStack(spacing: 8) {
            // The menu bar item's own gauge, not the app icon: that icon is a
            // full illustration on its own dark plate, drawn for 128pt in the
            // Dock, and at 17pt on a dark popover it is a smudge in a hole.
            // A symbol tints with the theme, stays crisp, and is the same mark
            // the user just clicked in the menu bar.
            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                .font(.system(size: 12, weight: .regular))
            Text("Ullage")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .textCase(.uppercase)
            Spacer(minLength: 0)
            sessionMenu
            overflowMenu
        }
        .foregroundStyle(.tertiary)
        .frame(height: 16)
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
                    // The basename alone is ambiguous across worktrees and
                    // same-named checkouts; the full path is not.
                    if let path = MenuBarFormatter.displayPath(state.cwd) {
                        Text(path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .help(state.cwd ?? path)
                            .textSelection(.enabled)
                    }
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
                // Sized to sit with the session name, not to shout over it: a
                // rounded figure set twice the size of the exact one, and of the
                // name that says what you are looking at, inverts the hierarchy.
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(headroom(contextTokens: contextTokens, windowLimit: windowLimit))
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(headroomStyle(state: state, occupancy: occupancy, windowLimit: windowLimit))
                    if windowLimit != nil, state.status != .empty {
                        Text("left")
                            .font(.caption2)
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
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                if let occupancy, state.status != .empty {
                    Text(MenuBarFormatter.percentage(occupancy) + " used")
                        .foregroundStyle(.tertiary)
                }
                if let link = model.sessionLink, agent == nil, let url = URL(string: link.url) {
                    Link(link.label + " ↗", destination: url)
                        .help("Continue this session where you can type into it: /clear, /compact and skills work there")
                }
            }
            .font(.caption)
            .monospacedDigit()
            .lineLimit(1)
            if agent == nil, let notice = figures.gaugeNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func headroomStyle(state: MenuBarState, occupancy: Double?, windowLimit: Int?) -> AnyShapeStyle {
        guard windowLimit != nil, state.status != .empty else { return AnyShapeStyle(.tertiary) }
        if (occupancy ?? 0) >= MenuBarFormatter.warningThreshold { return AnyShapeStyle(Color.orange) }
        return AnyShapeStyle(model.focusedAgent == nil && state.isIdle ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
    }

    /// The room left — the thing the app is named for, and the one number the
    /// menu bar has no space to show.
    private func headroom(contextTokens: Int?, windowLimit: Int?) -> String { figures.headroom }

    private func exactLine(state: MenuBarState, contextTokens: Int?, windowLimit: Int?) -> String { figures.exactLine }

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
        return state.modelLine
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
        let path = MenuBarFormatter.displayPath(session.cwd).map { " · \($0)" } ?? ""
        return "\(session.sessionId.prefix(8)) · \(occupancy)\(agents) · \(when)\(path)"
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    // MARK: Stats


    /// What the stream the popover is looking at says about itself: the
    /// session's own figures, or a selected agent's. Every figure describes
    /// that one stream, so an agent's turns are never shown next to the
    /// session's tokens.
    private var figures: StreamFigures {
        let state = model.state
        guard let agent = model.focusedAgent else { return StreamFigures(state: state) }
        return StreamFigures(
            status: state.status,
            contextTokens: agent.lastContextTokens,
            windowLimit: agent.windowLimit,
            occupancy: agent.occupancy,
            contextDelta: model.history?.points.last?.contextDelta,
            lastActivity: agent.lastTs.flatMap(Timestamps.date(from:)) ?? state.lastActivity,
            sessionId: nil,
            agentLine: [agent.agentType, agent.statusLabel].compactMap { $0 }.joined(separator: " · "),
            agentStatus: agent.statusLabel,
            isIdle: false
        )
    }

    /// The collapsed Details: the same figures as `stats`, on one line.
    private var statsSummary: some View { ReadoutLine(statsReadouts) }

    private var statsReadouts: [Readout] { SessionInfo.summary(figures, history: model.history) }

    // MARK: Plan limits

    @ViewBuilder
    private var planLimitsSection: some View {
        let hasClaude = model.planLimits.contains { $0.vendor == Vendor.claudeCode }
        if !model.planLimits.isEmpty || !model.checksClaudeLimits || model.claudeLimitsError != nil {
            if model.planLimits.isEmpty {
                SectionRule("Plan limits")
            } else {
                SectionLink("Plan limits", open: { open(.limits) }) {
                    ReadoutLine(PlanLimitFormatter.summary(model.planLimits))
                }
            }
            if let error = model.claudeLimitsError {
                Text("Claude: " + error)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if !model.checksClaudeLimits, !hasClaude {
                Button("Show Claude's plan limits") { model.checksClaudeLimits = true }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help(Self.claudeLimitsExplanation)
            }
        }
    }

    static let claudeLimitsExplanation = """
    Asks Anthropic every 5 minutes, the way Claude Code's /usage does, using \
    Claude Code's own sign-in from the Keychain. Sends that token to \
    api.anthropic.com and nothing else. Turn off from the ⋯ menu.
    """

    // MARK: Actions

    /// One button for the thing you might actually want next; the app's own
    /// housekeeping goes behind a menu instead of standing at the same weight
    /// as the task.
    private var actions: some View {
        HStack(spacing: 8) {
            Button("Open Ullage") { open(.overview) }
                .buttonStyle(.borderedProminent)
                .help("Everything here at full size: composition, session, agents, token savers, history and limits")
            Spacer()
            // One way in to every explanation, opposite the main action.
            HelpButton()
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
            Toggle("Check Claude plan limits", isOn: $model.checksClaudeLimits)
                .help(Self.claudeLimitsExplanation)
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

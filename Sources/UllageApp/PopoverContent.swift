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
        VStack(alignment: .leading, spacing: 12) {
            header
            sessionPicker
            if let tree = model.agents, !tree.isEmpty {
                AgentTreeView(
                    tree: tree,
                    mainThreadDetail: [model.state.model, model.state.project]
                        .compactMap { $0 }.joined(separator: " · "),
                    mainThreadOccupancy: model.state.occupancy,
                    focus: model.focus,
                    onSelect: { model.focus(on: $0) }
                )
            }
            if let history = model.history {
                ContextChart(history: history)
                    .frame(height: 120)
            }
            if let composition = model.composition {
                CompositionView(composition: composition)
            }
            stats
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
            Divider()
            actions
        }
        .padding(14)
        .frame(width: 360)
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        let state = model.state
        // When an agent is selected the headline number is *its* window. The
        // menu bar title keeps showing the session's, which is the one thing
        // that must never be a subagent's.
        let agent = model.focusedAgent
        let occupancy = agent.map(\.occupancy) ?? state.occupancy
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(agent?.displayName ?? state.project ?? "No sessions ingested yet")
                    .font(.headline)
                    .lineLimit(1)
                if let subtitle = subtitle(agent: agent, state: state) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if state.status == .empty {
                Text(MenuBarFormatter.idleGlyph)
                    .font(.system(size: 26, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
            } else if let occupancy {
                Text(MenuBarFormatter.percentage(occupancy))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(occupancy >= MenuBarFormatter.warningThreshold
                        ? Color.orange
                        : (agent == nil && state.isIdle ? Color.secondary : Color.primary))
            }
        }
    }

    private func subtitle(agent: AgentSummary?, state: MenuBarState) -> String? {
        if let agent {
            return [agent.agentType, agent.model, state.project]
                .compactMap { $0 }
                .joined(separator: " · ")
        }
        guard let modelName = state.model else { return nil }
        return modelName + (state.modelWindowIsAssumed ? "  · window assumed" : "")
    }

    // MARK: Session picker

    private var sessionPicker: some View {
        HStack(spacing: 8) {
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
            .labelsHidden()
            .pickerStyle(.menu)
            if model.pinFellBack {
                Text("pinned session has no turns; showing most recent")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
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
                if let contextTokens {
                    row("Context", "\(contextTokens.formatted()) / \(windowLimit?.formatted() ?? "?")")
                }
                if let delta {
                    row("Last turn", (delta >= 0 ? "+" : "") + delta.formatted())
                }
                if let history = model.history {
                    row("Turns", history.points.count.formatted()
                        + (history.compactionTurns.isEmpty ? "" : " · \(history.compactionTurns.count) compaction\(history.compactionTurns.count == 1 ? "" : "s")"))
                    row("Peak", history.peakContextTokens.formatted())
                }
                if let session = state.sessionId {
                    row("Session", String(session.prefix(8)))
                }
                if let agents = model.agents, !agents.isEmpty {
                    row("Agents", agents.count.formatted()
                        + (agents.crowded().isEmpty ? "" : " · \(agents.crowded().count) over \(Int(MenuBarFormatter.warningThreshold * 100))%"))
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
            Text(value).monospacedDigit()
        }
    }

    // MARK: Actions

    private var actions: some View {
        HStack {
            Button(model.isWatching ? "Refresh" : "Start watching") {
                if model.isWatching { model.refreshNow() } else { model.start() }
            }
            Button("History…") {
                openWindow(id: HistoryWindow.id)
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Reveal database") { model.openDatabaseFolder() }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .controlSize(.small)
    }
}
#endif

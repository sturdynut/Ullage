#if os(macOS)
import SwiftUI
import UllageCore

/// M8 — the agents a session spawned, each with its own window.
///
/// Indentation is the spawn tree: an agent sits under whichever agent asked for
/// it. The name is the description the parent wrote, because that is the only
/// label written for a human — an agent id is not a name, and neither is a
/// session id. Selecting a row scopes the chart and the composition below to
/// that agent's context, which is a different window from the session's.
struct AgentTreeView: View {
    let tree: AgentTree
    /// The main thread, drawn as the root the agents hang off.
    let mainThreadDetail: String
    let mainThreadOccupancy: Double?
    let focus: AgentScope
    let onSelect: (AgentScope) -> Void

    @State private var expanded = true
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if tree.count > 1 {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Text(expanded ? "hide agents" : title)
                            .font(.caption)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if expanded {
                // A ScrollView's ideal height is zero, so one inside the
                // popover's VStack collapses to nothing. Short trees — nearly
                // all of them — are laid out directly; only a tall one scrolls,
                // at a height it is told explicitly.
                if rowCount <= Self.maxVisibleRows {
                    rows
                } else {
                    ScrollView(.vertical) { rows }
                        .frame(height: Self.rowHeight * CGFloat(Self.maxVisibleRows))
                }
            }
        }
    }

    /// Enough for a row of name over detail, plus its padding.
    private static let rowHeight: CGFloat = 36
    private static let maxVisibleRows = 4

    /// The main thread, then every agent under whichever agent asked for it.
    private var rowCount: Int { tree.count + 1 }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 2) {
            row(
                name: "main thread",
                detail: mainThreadDetail,
                depth: 0,
                occupancy: mainThreadOccupancy,
                scope: .mainThread
            )
            ForEach(tree.flattened) { node in
                row(
                    name: node.agent.displayName,
                    detail: detail(for: node.agent),
                    depth: node.depth + 1,
                    occupancy: node.agent.occupancy,
                    scope: .agent(node.agent.agentId),
                    agent: node.agent
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: String {
        tree.count == 1 ? "1 agent" : "\(tree.count) agents"
    }

    /// Counts only. The run's *state* used to be last in this string, so it was
    /// the part macOS truncated ("· ba…"); it is a glyph on the row now, where
    /// it cannot be cut, and the window is named because two rows' bars are
    /// drawn at the same length against different windows.
    private func detail(for agent: AgentSummary) -> String {
        [
            agent.agentType,
            agent.calls == 1 ? "1 turn" : "\(agent.calls) turns",
            agent.toolCalls > 0 ? "\(agent.toolCalls) tools" : nil,
            agent.windowLimit.map { "\(ContextChart.compact($0)) window" },
        ].compactMap { $0 }.joined(separator: " · ")
    }

    /// Silence means it finished; anything else is a state worth a mark.
    @ViewBuilder
    private func statusMark(_ agent: AgentSummary?) -> some View {
        if let agent, let label = agent.statusLabel {
            Image(systemName: agent.status == nil ? "questionmark.circle" : "circle.dotted")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .help(label)
        }
    }

    private func row(
        name: String,
        detail: String,
        depth: Int,
        occupancy: Double?,
        scope: AgentScope,
        agent: AgentSummary? = nil
    ) -> some View {
        let selected = scope == focus
        let key = Self.key(for: scope)
        return Button {
            onSelect(scope)
        } label: {
            HStack(spacing: 6) {
                if depth > 0 {
                    // A hairline down the left of a parent's children is what
                    // makes a list read as a tree; an arrow on every row of a
                    // flat sibling list only reads as a bullet.
                    Color.clear.frame(width: CGFloat(depth - 1) * 14, height: 1)
                    Rectangle()
                        .fill(.quaternary)
                        .frame(width: 1, height: 22)
                        .padding(.leading, 4)
                }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        Text(name)
                            .font(.callout)
                            .fontWeight(selected ? .medium : .regular)
                            .lineLimit(1)
                        statusMark(agent)
                    }
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                gauge(occupancy, selected: selected)
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    // The default focus is the main thread, so a filled block
                    // would be the resting state of every popover — the loudest
                    // object on screen saying nothing. The fill is the hover
                    // affordance; the accent rule carries "current".
                    .fill(hovered == key ? Color.primary.opacity(0.06) : Color.clear)
            )
            .overlay(alignment: .leading) {
                if selected {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Color.accentColor)
                        .frame(width: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in hovered = inside ? key : nil }
        .help(detail)
    }

    private static func key(for scope: AgentScope) -> String {
        switch scope {
        case .mainThread: return "main"
        case .agent(let id): return id
        case .all: return "all"
        }
    }

    /// Each row's own window, never the session's. A window we do not know is
    /// left blank rather than drawn as empty.
    @ViewBuilder
    private func gauge(_ occupancy: Double?, selected: Bool = false) -> some View {
        HStack(spacing: 5) {
            if let occupancy {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color(nsColor: .quaternaryLabelColor))
                    .frame(width: 38, height: 4)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(occupancy >= MenuBarFormatter.warningThreshold ? Color.orange : Color.accentColor)
                            .frame(width: max(2, 38 * min(1, occupancy)), height: 4)
                    }
                Text(MenuBarFormatter.percentage(occupancy))
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 32, alignment: .trailing)
            } else {
                Text("—")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 75, alignment: .trailing)
            }
        }
    }
}
#endif

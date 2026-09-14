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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(title)
                        .font(.caption)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                // Tall trees scroll rather than pushing the chart off the
                // popover; six rows is about where that starts to matter.
                ScrollView(.vertical) {
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
                                scope: .agent(node.agent.agentId)
                            )
                        }
                    }
                }
                .frame(maxHeight: 148)
            }
        }
    }

    private var title: String {
        tree.count == 1 ? "1 agent" : "\(tree.count) agents"
    }

    private func detail(for agent: AgentSummary) -> String {
        [
            agent.agentType,
            agent.calls == 1 ? "1 turn" : "\(agent.calls) turns",
            agent.toolCalls > 0 ? "\(agent.toolCalls) tools" : nil,
            agent.statusLabel,
        ].compactMap { $0 }.joined(separator: " · ")
    }

    private func row(
        name: String,
        detail: String,
        depth: Int,
        occupancy: Double?,
        scope: AgentScope
    ) -> some View {
        let selected = scope == focus
        return Button {
            onSelect(scope)
        } label: {
            HStack(spacing: 6) {
                if depth > 0 {
                    Color.clear.frame(width: CGFloat(depth - 1) * 12, height: 1)
                    Text("↳")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(name)
                        .font(.callout)
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                gauge(occupancy)
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(detail)
    }

    /// Each row's own window, never the session's. A window we do not know is
    /// left blank rather than drawn as empty.
    @ViewBuilder
    private func gauge(_ occupancy: Double?) -> some View {
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

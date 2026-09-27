#if os(macOS)
import SwiftUI
import UllageCore

/// The popover's treemap, window-sized, one level at a time: the window's four
/// segments, then a segment's parts — every tool, MCP tools grouped by server —
/// then a server's tools. Click a tile (or its row) to open it; the breadcrumb
/// or Escape goes back up.
///
/// Live: it follows whatever the popover is showing, the session's main
/// thread or a selected agent, and keeps its place in the tree across turns.
/// The tree and the layout are `CompositionNode` and `CompositionTreemap
/// .squarify`, both in Core; this only draws them.
struct CompositionExplorer: View {
    static let id = "composition-explorer"

    @ObservedObject var model: MenuBarModel
    @State private var path: [String] = []
    @State private var hovered: String?

    var body: some View {
        Group {
            if let composition = model.composition {
                explorer(composition)
            } else {
                Text("No session to break down yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .onExitCommand { if !path.isEmpty { path.removeLast() } }
    }

    private func explorer(_ composition: ContextComposition) -> some View {
        let root = CompositionNode.tree(composition)
        let (level, reached) = root.descend(path)
        return VStack(alignment: .leading, spacing: 10) {
            header(root: root, reached: reached, composition: composition)
            HStack(alignment: .top, spacing: 14) {
                treemap(level, composition: composition)
                table(level, composition: composition)
                    .frame(width: 300)
            }
        }
        .padding(16)
        // A turn can remove the level being looked at (a compaction restarts
        // the window); fall back to as far as the path still leads.
        .onChange(of: reached) { _, reached in if reached != path { path = reached } }
    }

    // MARK: Header

    private func header(root: CompositionNode, reached: [String], composition: ContextComposition) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button { path = [] } label: { Text(scopeTitle) }
                .buttonStyle(.plain)
                .font(.headline)
                .foregroundStyle(reached.isEmpty ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.accentColor))
            ForEach(Array(reached.enumerated()), id: \.offset) { index, _ in
                let node = root.descend(Array(reached.prefix(index + 1))).node
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                Button { path = Array(reached.prefix(index + 1)) } label: { Text(node.name) }
                    .buttonStyle(.plain)
                    .font(.headline)
                    .foregroundStyle(index == reached.count - 1 ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.accentColor))
            }
            Spacer(minLength: 8)
            Text(caption(composition))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    private var scopeTitle: String {
        model.focusedAgent?.displayName ?? model.state.project ?? "Context window"
    }

    private func caption(_ composition: ContextComposition) -> String {
        var parts = [
            composition.contextTokens.formatted() + " tokens",
            "turns \(composition.windowStartTurn)–\(composition.lastTurn)",
        ]
        if composition.compactions > 0 {
            parts.append("after \(composition.compactions) compaction\(composition.compactions == 1 ? "" : "s")")
        }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: Treemap

    private func treemap(_ level: CompositionNode, composition: ContextComposition) -> some View {
        GeometryReader { geometry in
            let metrics = Self.metrics
            let placed = CompositionTreemap.squarify(
                level.children.isEmpty ? [level] : level.children,
                width: Double(geometry.size.width),
                height: Double(geometry.size.height),
                gap: 2,
                metrics: metrics
            )
            ZStack(alignment: .topLeading) {
                ForEach(placed) { tile in
                    tileView(tile, composition: composition)
                        .frame(width: CGFloat(tile.rect.width), height: CGFloat(tile.rect.height))
                        .offset(x: CGFloat(tile.rect.x), y: CGFloat(tile.rect.y))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .animation(.easeInOut(duration: 0.2), value: path)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Larger type than the popover's: the tiles are several times the size.
    private static let metrics: CompositionTreemap.Metrics = {
        var metrics = CompositionTreemap.Metrics()
        metrics.nameFontSize = 13
        metrics.valueFontSize = 12
        metrics.lineHeight = 16
        metrics.horizontalPadding = 8
        return metrics
    }()

    private static let shadeBrightness: [Double] = [0.0, 0.10, 0.04, 0.14, 0.07]

    private func tileView(_ tile: CompositionTreemap.Placed, composition: ContextComposition) -> some View {
        let node = tile.node
        let isHovered = hovered == node.id
        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(CompositionView.color(for: node.segment))
            .brightness(Self.shadeBrightness[tile.shade % Self.shadeBrightness.count] + (isHovered ? 0.06 : 0))
            .overlay(alignment: .topLeading) { label(tile.label, canDrill: node.canDrill) }
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.black.opacity(isHovered ? 0.35 : 0), lineWidth: 1.5)
            }
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { hovered = node.id } else if hovered == node.id { hovered = nil }
            }
            .onTapGesture { open(node) }
            .help(help(for: node, composition: composition))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(node.fullName + ", " + (node.isEstimate ? "about " : "")
                                + node.tokens.formatted() + " tokens")
            .accessibilityAddTraits(node.canDrill ? .isButton : [])
    }

    @ViewBuilder
    private func label(_ label: CompositionTreemap.Label, canDrill: Bool) -> some View {
        let name = Font.system(size: 13, weight: .semibold)
        let value = Font.system(size: 12).monospacedDigit()
        Group {
            switch label {
            case .none:
                EmptyView()
            case .value(let text):
                Text(text).font(value).foregroundStyle(Color.black.opacity(0.66))
            case .name(let text):
                Text(text).font(name).foregroundStyle(Color.black.opacity(0.84))
            case .nameAndValue(let title, let text):
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(title).font(name).foregroundStyle(Color.black.opacity(0.84))
                        if canDrill {
                            Image(systemName: "chevron.right.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.black.opacity(0.45))
                        }
                    }
                    Text(text).font(value).foregroundStyle(Color.black.opacity(0.66))
                }
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.top, 5)
    }

    private func help(for node: CompositionNode, composition: ContextComposition) -> String {
        var lines = [
            node.fullName,
            (node.isEstimate ? "≈" : "") + node.tokens.formatted() + " tokens · "
                + MenuBarFormatter.percentage(composition.share(node.tokens)) + " of context",
        ]
        if let calls = node.calls, calls > 0 { lines.append("\(calls) call\(calls == 1 ? "" : "s")") }
        if let detail = node.detail { lines.append(detail) }
        if node.id == node.segment { lines.append(CompositionView.note(for: node.segment)) }
        if node.canDrill { lines.append("Click to open") }
        return lines.joined(separator: "\n")
    }

    private func open(_ node: CompositionNode) {
        guard node.canDrill else { return }
        path.append(node.id)
        hovered = nil
    }

    // MARK: Table

    /// The level as rows: every tile, including the ones too small to label.
    private func table(_ level: CompositionNode, composition: ContextComposition) -> some View {
        let rows = level.children.isEmpty ? [level] : level.children.sorted { $0.tokens > $1.tokens }
        let showsCalls = rows.contains { ($0.calls ?? 0) > 0 }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(level.name)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text((level.isEstimate ? "≈" : "") + level.tokens.formatted())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if level.id == level.segment {
                Text(CompositionView.note(for: level.segment))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if level.id == ContextComposition.baselineName { baselineFacts(composition) }
            Divider()
            HStack(spacing: 8) {
                Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                if showsCalls { Text("calls").frame(width: 40, alignment: .trailing) }
                Text("tokens").frame(width: 62, alignment: .trailing)
                Text("share").frame(width: 40, alignment: .trailing)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(rows) { node in
                        tableRow(node, composition: composition, showsCalls: showsCalls)
                    }
                }
            }
        }
    }

    private func tableRow(_ node: CompositionNode, composition: ContextComposition, showsCalls: Bool) -> some View {
        Button { open(node) } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(CompositionView.color(for: node.segment))
                    .brightness(node.id == node.segment ? 0 : Self.shadeBrightness[
                        CompositionTreemap.shade(for: node.id) % Self.shadeBrightness.count])
                    .frame(width: 9, height: 9)
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if node.canDrill {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                if showsCalls {
                    Text(node.calls.map { $0.formatted() } ?? "")
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                Text((node.isEstimate ? "≈" : "") + TokenFormat.compact(node.tokens))
                    .frame(width: 62, alignment: .trailing)
                Text(MenuBarFormatter.percentage(composition.share(node.tokens)))
                    .foregroundStyle(.tertiary)
                    .frame(width: 40, alignment: .trailing)
            }
            .font(.caption)
            .monospacedDigit()
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(hovered == node.id ? Color.primary.opacity(0.08) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!node.canDrill)
        .onHover { inside in
            if inside { hovered = node.id } else if hovered == node.id { hovered = nil }
        }
        .help(node.fullName)
    }

    /// What rides in the baseline but has no size on disk of its own.
    @ViewBuilder
    private func baselineFacts(_ composition: ContextComposition) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if !composition.mcpServers.isEmpty {
                Text("MCP servers: " + composition.mcpServers.joined(separator: ", "))
            }
            if !composition.skills.isEmpty {
                Text("Skills (\(composition.skills.count)): " + composition.skills.joined(separator: ", "))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
#endif

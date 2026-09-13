#if os(macOS)
import SwiftUI
import UllageCore

/// M7 — one stacked bar of what the current window holds, with a legend that
/// names and sizes every segment so identity never rides on colour alone.
struct CompositionView: View {
    let composition: ContextComposition
    var showTools = false

    /// Fixed per segment: a segment keeps its colour whatever its size.
    static func color(for segment: String) -> Color {
        switch segment {
        case ContextComposition.baselineName: return Color(nsColor: .systemGray)
        case ContextComposition.toolResultsName: return Color.accentColor
        case ContextComposition.assistantOutputName: return Color(nsColor: .systemPurple)
        default: return Color(nsColor: .quaternaryLabelColor)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(composition.segments.filter { $0.tokens > 0 }) { segment in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Self.color(for: segment.name))
                            .frame(width: max(3, (geometry.size.width - 6) * composition.share(segment.tokens)))
                            .help("\(segment.name): \(segment.tokens.formatted()) tokens")
                    }
                }
            }
            .frame(height: 10)

            legend

            if let hint = environmentHint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }

            if showTools, !composition.tools.isEmpty {
                tools
            }
        }
    }

    private var caption: String {
        var text = "What the window holds  ·  turns \(composition.windowStartTurn)–\(composition.lastTurn)"
        if composition.compactions > 0 { text += "  ·  after \(composition.compactions) compaction\(composition.compactions == 1 ? "" : "s")" }
        if composition.estimatesOvershoot { text += "  ·  estimates overshoot" }
        return text
    }

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach(composition.segments) { segment in
                HStack(spacing: 4) {
                    Circle().fill(Self.color(for: segment.name)).frame(width: 7, height: 7)
                    Text(segment.name).foregroundStyle(.secondary)
                    Text(Self.compact(segment.tokens)).monospacedDigit()
                }
            }
        }
        .font(.caption2)
        .lineLimit(1)
    }

    private var environmentHint: String? {
        var parts: [String] = []
        if let claudeMd = composition.claudeMdTokensEstimate, claudeMd > 0 { parts.append("CLAUDE.md ~\(Self.compact(claudeMd))") }
        if !composition.mcpServers.isEmpty { parts.append("\(composition.mcpServers.count) MCP server\(composition.mcpServers.count == 1 ? "" : "s")") }
        if !composition.skills.isEmpty { parts.append("\(composition.skills.count) skills") }
        guard !parts.isEmpty else { return nil }
        return "Baseline rides every turn: system prompt, tool schemas, " + parts.joined(separator: ", ")
            + (composition.windowStartTurn == 0 ? ", opening prompt." : ", compaction summary.")
    }

    private var tools: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
            GridRow {
                Text("Tool results in the window").foregroundStyle(.secondary)
                Text("calls").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                Text("≈ tokens").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            }
            ForEach(composition.tools.prefix(8)) { tool in
                GridRow {
                    Text(tool.name).lineLimit(1)
                    Text(tool.calls.formatted()).monospacedDigit()
                    Text(tool.resultTokens.formatted()).monospacedDigit()
                }
            }
            if composition.tools.count > 8 {
                GridRow {
                    Text("and \(composition.tools.count - 8) more").foregroundStyle(.tertiary)
                    Text("")
                    Text("")
                }
            }
        }
        .font(.caption)
    }

    static func compact(_ tokens: Int) -> String {
        switch tokens {
        case 1_000_000...: return String(format: "%.1fM", Double(tokens) / 1_000_000)
        case 10_000...: return "\(tokens / 1_000)k"
        case 1_000...: return String(format: "%.1fk", Double(tokens) / 1_000)
        default: return "\(tokens)"
        }
    }
}
#endif

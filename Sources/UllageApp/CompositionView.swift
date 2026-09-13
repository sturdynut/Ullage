#if os(macOS)
import SwiftUI
import UllageCore

/// M7 — one stacked bar of what the current window holds, a legend that names
/// and sizes every segment, and an expandable breakdown: the baseline's known
/// components (CLAUDE.md, MCP servers, skills) and the tools whose results are
/// sitting in the window.
struct CompositionView: View {
    let composition: ContextComposition
    /// Start with the breakdown open (the History window); the popover starts collapsed.
    var startExpanded = false

    @State private var expanded = false

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

            bar
            legend

            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 10) {
                    baseline
                    if !composition.tools.isEmpty { tools }
                }
                .padding(.top, 6)
            } label: {
                Text("What's inside")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { expanded = startExpanded }
    }

    private var bar: some View {
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

    // MARK: - Baseline breakdown

    @ViewBuilder
    private var baseline: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Baseline — rides every turn (\(Self.compact(composition.baseline)))")
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                baselineRow("System prompt + tool schemas", "not separable on disk")
                if let claudeMd = composition.claudeMdTokensEstimate, claudeMd > 0 {
                    baselineRow("CLAUDE.md", "≈\(Self.compact(claudeMd)) tokens")
                }
                if !composition.mcpServers.isEmpty {
                    baselineRow("MCP servers", composition.mcpServers.joined(separator: ", "))
                }
                if !composition.skills.isEmpty {
                    baselineRow("Skills", "\(composition.skills.count): " + composition.skills.prefix(6).joined(separator: ", ")
                                + (composition.skills.count > 6 ? "…" : ""))
                }
                baselineRow(composition.windowStartTurn == 0 ? "Opening prompt" : "Compaction summary", "")
            }
            .font(.caption2)
        }
    }

    private func baselineRow(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name).foregroundStyle(.primary)
            Text(value).foregroundStyle(.tertiary).lineLimit(1)
        }
    }

    // MARK: - Tool results

    private var tools: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Tool results in the window (\(Self.compact(composition.toolResults)), estimated)")
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                GridRow {
                    Text("Tool")
                    Text("calls").gridColumnAlignment(.trailing)
                    Text("≈ tokens").gridColumnAlignment(.trailing)
                }
                .foregroundStyle(.tertiary)
                ForEach(composition.tools.prefix(10)) { tool in
                    GridRow {
                        Text(tool.name).lineLimit(1)
                        Text(tool.calls.formatted()).monospacedDigit()
                        Text(tool.resultTokens.formatted()).monospacedDigit()
                    }
                }
                if composition.tools.count > 10 {
                    GridRow {
                        Text("and \(composition.tools.count - 10) more").foregroundStyle(.tertiary)
                        Text(""); Text("")
                    }
                }
            }
            .font(.caption2)
        }
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

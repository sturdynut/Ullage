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
    /// The popover names the block in its section rule; the history window has
    /// no such rule, so it keeps the name in the caption.
    var showsTitle = true

    @State private var expanded = false

    /// Fixed per segment: a segment keeps its colour whatever its size.
    ///
    /// None of these is the accent, which means one thing only — the stream you
    /// are looking at. `Other` is a real colour rather than the system's
    /// *absence* colour: it is routinely a third of the window, and drawing the
    /// second-largest share in the same grey family as the largest made
    /// two-thirds of the bar unreadable.
    static func color(for segment: String) -> Color {
        switch segment {
        case ContextComposition.baselineName: return Color(nsColor: .systemGray)
        case ContextComposition.toolResultsName: return Color(nsColor: .systemTeal)
        case ContextComposition.assistantOutputName: return Color(nsColor: .systemPurple)
        default: return Color(nsColor: .systemBrown)
        }
    }

    /// Which legend values are not measurements. Tool results are a length
    /// estimate and Other is the remainder that absorbs their error; the
    /// baseline is a measured prompt size, and assistant output is reported
    /// (it undercounts, which the detail says, but it is not a guess).
    static func isEstimated(_ segment: String) -> Bool {
        segment == ContextComposition.toolResultsName || segment == ContextComposition.otherName
    }

    static func note(for segment: String) -> String {
        switch segment {
        case ContextComposition.baselineName:
            return "Rides every turn: system prompt, tool schemas, skills, CLAUDE.md, and the opening prompt — or the summary, after a compaction."
        case ContextComposition.toolResultsName:
            return "Estimated from the length of what each tool returned (~4 bytes per token), never a counted figure."
        case ContextComposition.assistantOutputName:
            return "Output tokens as reported. They are a mid-stream snapshot and undercount."
        default:
            return "Prompts, thinking, tool inputs, and the error in the two estimates above."
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

            // A full-width button, not a bare DisclosureGroup label: the whole
            // row is the target and the chevron makes the affordance obvious.
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(expanded ? "Hide details" : "What's inside — baseline & tools")
                        .font(.caption)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    baseline
                    if !composition.tools.isEmpty { tools }
                }
                .padding(.top, 2)
                .transition(.opacity)
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

    /// The section rule above names the block and carries the overshoot
    /// warning, which used to be appended last to a one-line caption and was
    /// therefore the first thing macOS truncated.
    private var caption: String {
        var text = showsTitle
            ? "What the window holds  ·  turns \(composition.windowStartTurn)–\(composition.lastTurn)"
            : "turns \(composition.windowStartTurn)–\(composition.lastTurn)"
        if composition.compactions > 0 { text += "  ·  after \(composition.compactions) compaction\(composition.compactions == 1 ? "" : "s")" }
        return text
    }

    /// Two rows of two. As one row it needed about 416pt in a 332pt box, so two
    /// of the four labels were always truncated — including, routinely, the
    /// largest share in the bar.
    private var legend: some View {
        let segments = composition.segments
        return Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
            GridRow {
                ForEach(segments.prefix(2)) { legendItem($0) }
            }
            GridRow {
                ForEach(segments.dropFirst(2)) { legendItem($0) }
            }
        }
        .font(.caption2)
    }

    private func legendItem(_ segment: ContextComposition.Segment) -> some View {
        HStack(spacing: 4) {
            Circle().fill(Self.color(for: segment.name)).frame(width: 7, height: 7)
            Text(segment.name).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 2)
            // `≈` where the figure is an estimate: in the collapsed state — the
            // one most people ever see — all four numbers used to be set
            // identically, so a length estimate read as a measurement.
            Text((Self.isEstimated(segment.name) ? "≈" : "") + Self.compact(segment.tokens))
                .monospacedDigit()
            Text(MenuBarFormatter.percentage(composition.share(segment.tokens)))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .frame(width: 30, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(Self.note(for: segment.name))
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

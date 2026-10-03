#if os(macOS)
import SwiftUI
import UllageCore

/// M7 — what the current window holds. Collapsed, one bar of the four shares
/// and a legend; expanded, a treemap and the table view of it: the four
/// totals, the baseline's known components (CLAUDE.md, MCP servers, skills)
/// and every tool whose results are sitting in the window.
///
/// The layout is `CompositionTreemap`, computed and tested in Core. It is
/// ordered rather than squarified so the tiles hold still while the popover
/// redraws every turn; this view only draws the rectangles it is given.
struct CompositionView: View {
    let composition: ContextComposition
    /// The treemap and every table (the History window, or the popover's
    /// section when opened), or just the distribution bar and its legend.
    var expanded = true
    /// 88pt fits the popover; the History window has room to label more tiles.
    var treemapHeight: CGFloat = 88
    /// The popover names the block in its section rule; the history window has
    /// no such rule, so it keeps the name in the caption.
    var showsTitle = true
    /// When set, clicking the treemap or the bar opens the explorer window.
    var onOpen: (() -> Void)?

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
        ContextComposition.isEstimate(segment: segment)
    }

    static func note(for segment: String) -> String { ContextComposition.note(for: segment) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if expanded {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                // The full view: the treemap, and the table view of it — every
                // figure a tile was too small to label is here, so nothing is
                // reachable only by hovering.
                treemapAndKey
                    .onTapGesture { onOpen?() }
                VStack(alignment: .leading, spacing: 10) {
                    totals
                    baseline
                    if !composition.tools.isEmpty { tools }
                    if !mostCalled.isEmpty { mostCalledList }
                    if composition.staleToolResults > 0 || !composition.repeatedReads.isEmpty { alongForTheRide }
                }
                .padding(.top, 2)
                .transition(.opacity)
            } else {
                // One row: the four totals in their colours, `≈` on the
                // estimates. Everything else is one click away.
                summaryRow
                    .onTapGesture { onOpen?() }
                    .transition(.opacity)
            }
        }
    }

    // MARK: - Collapsed row

    private var summaryRow: some View {
        ReadoutLine(items: zip(composition.summary, composition.segments).map { readout, segment in
            ReadoutLine.Item(readout: readout, dot: Self.color(for: segment.name))
        })
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .help(caption + "\n" + composition.segments.map {
            "\($0.name): " + MenuBarFormatter.percentage(composition.share($0.tokens)) + " — " + Self.note(for: $0.name)
        }.joined(separator: "\n"))
    }

    // MARK: - Treemap

    /// Height of the one-line key under the treemap (caption2 and its swatch).
    private static let keyHeight: CGFloat = 14
    private static let keySpacing: CGFloat = 6

    /// The treemap and its key come from one layout pass: the key prints the
    /// totals the layout could not fit on any tile.
    private var treemapAndKey: some View {
        GeometryReader { geometry in
            let map = CompositionTreemap.layout(
                composition,
                width: Double(geometry.size.width),
                height: Double(treemapHeight)
            )
            VStack(alignment: .leading, spacing: Self.keySpacing) {
                ZStack(alignment: .topLeading) {
                    ForEach(map.tiles) { tile in
                        tileView(tile)
                            .frame(width: CGFloat(max(tile.rect.width, 1)), height: CGFloat(max(tile.rect.height, 1)))
                            .offset(x: CGFloat(tile.rect.x), y: CGFloat(tile.rect.y))
                    }
                }
                .frame(width: geometry.size.width, height: treemapHeight, alignment: .topLeading)
                key(hiddenTotals: map.hiddenTotals)
                    .frame(height: Self.keyHeight)
            }
        }
        .frame(height: treemapHeight + Self.keySpacing + Self.keyHeight)
    }

    /// Lightness steps for the parts of a split segment: same hue, so the
    /// segment still reads by colour, with neighbours told apart. The step is
    /// derived from the part's name, so it follows the tool, not its rank.
    private static let partBrightness: [Double] = [0.0, 0.10, 0.04, 0.14, 0.07]

    private func tileView(_ tile: CompositionTreemap.Tile) -> some View {
        let corner: CGFloat = tile.role == .segment ? 3 : 2
        let brightness = tile.role == .part
            ? Self.partBrightness[tile.shade % Self.partBrightness.count]
            : 0
        return RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(Self.color(for: tile.segment))
            .brightness(brightness)
            .overlay(alignment: .topLeading) { tileLabel(tile.label) }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .help(helpText(for: tile))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText(for: tile))
    }

    /// Dark ink on every fill: the four system colours are all mid-to-light,
    /// and white on teal fails contrast in light mode. The same ink holds in
    /// dark mode, where the system colours get brighter still.
    @ViewBuilder
    private func tileLabel(_ label: CompositionTreemap.Label) -> some View {
        let name = Font.system(size: 10.5, weight: .semibold)
        let value = Font.system(size: 10).monospacedDigit()
        Group {
            switch label {
            case .none:
                EmptyView()
            case .value(let text):
                Text(text).font(value).foregroundStyle(Color.black.opacity(0.66))
            case .name(let text):
                Text(text).font(name).foregroundStyle(Color.black.opacity(0.84))
            case .nameAndValue(let title, let text):
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(name).foregroundStyle(Color.black.opacity(0.84))
                    Text(text).font(value).foregroundStyle(Color.black.opacity(0.66))
                }
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 5)
        .padding(.top, 1)
    }

    private func helpText(for tile: CompositionTreemap.Tile) -> String {
        let tokens = (tile.isEstimate ? "≈" : "") + tile.tokens.formatted() + " tokens"
        let share = MenuBarFormatter.percentage(composition.share(tile.tokens)) + " of context"
        var lines: [String]
        switch tile.role {
        case .segment, .header:
            lines = [tile.name, tokens + " · " + share, Self.note(for: tile.segment)]
        case .part:
            lines = [tile.fullName + " · " + tile.segment, tokens + " · " + share]
            if let calls = tile.calls { lines.append("\(calls) call\(calls == 1 ? "" : "s")") }
            if let detail = tile.detail { lines.append(detail) }
            if tile.segment == ContextComposition.toolResultsName {
                lines.append("Estimated from the length of what the tool returned.")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func accessibilityText(for tile: CompositionTreemap.Tile) -> String {
        let name = tile.role == .part ? tile.fullName + ", " + tile.segment : tile.name
        return name + ", " + (tile.isEstimate ? "about " : "") + tile.tokens.formatted() + " tokens, "
            + MenuBarFormatter.percentage(composition.share(tile.tokens)) + " of context"
    }

    /// Maps colour to name. A segment's figure appears here only when no tile
    /// had room for it — typically a thin tool-results column.
    private func key(hiddenTotals: [String: String]) -> some View {
        HStack(spacing: 11) {
            ForEach(composition.segments.filter { $0.tokens > 0 }) { segment in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 1.5).fill(Self.color(for: segment.name)).frame(width: 8, height: 8)
                    Text(segment.name).foregroundStyle(.secondary).lineLimit(1)
                    if let total = hiddenTotals[segment.name] {
                        Text(total).monospacedDigit().foregroundStyle(.primary).lineLimit(1)
                    }
                }
                .fixedSize()
                .help(Self.note(for: segment.name))
            }
            Spacer(minLength: 0)
        }
        .font(.caption2)
    }

    /// The section rule above names the block and carries the overshoot
    /// warning, which used to be appended last to a one-line caption and was
    /// therefore the first thing macOS truncated.
    private var caption: String {
        var text = showsTitle
            ? "Context composition  ·  turns \(composition.windowStartTurn)–\(composition.lastTurn)"
            : "turns \(composition.windowStartTurn)–\(composition.lastTurn)"
        if composition.compactions > 0 { text += "  ·  after \(composition.compactions) compaction\(composition.compactions == 1 ? "" : "s")" }
        return text
    }

    /// The four totals, two rows of two — what the old legend showed, kept for
    /// the segments whose tiles are too small to carry a label.
    private var totals: some View {
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

    // MARK: - Most called

    private var mostCalled: [ToolTargets.Called] { ToolTargets.mostCalled(composition) }

    /// What stays in the window only because nothing takes it out: results
    /// from long ago, and earlier copies of files read again. Length estimates.
    private var alongForTheRide: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Along for the ride")
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                if composition.staleToolResults > 0 {
                    GridRow {
                        Text("Results from \(ContextComposition.staleAfterTurns)+ turns ago")
                        Text("≈" + Self.compact(composition.staleToolResults)).monospacedDigit().gridColumnAlignment(.trailing)
                    }
                    .help("Tool results from \(ContextComposition.staleAfterTurns) or more turns back, still re-sent every turn. \(ContextComposition.staleAfterTurns) is a rule of thumb, not a measured cut-off.")
                }
                ForEach(composition.repeatedReads.prefix(4)) { read in
                    GridRow {
                        Text("Read \(ToolTargets.shortPath(read.target)) ×\(read.reads)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("≈" + Self.compact(read.extraTokens)).monospacedDigit().gridColumnAlignment(.trailing)
                    }
                    .help("\(read.target) was read \(read.reads) times; every earlier copy is still in the window.")
                }
            }
            .font(.caption2)
        }
    }

    private var mostCalledList: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Called most in the window")
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                ForEach(mostCalled) { entry in
                    GridRow {
                        Text(entry.tool).foregroundStyle(.tertiary)
                        Text(entry.displayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(entry.target.name)
                        Text("×\(entry.target.calls)").monospacedDigit().gridColumnAlignment(.trailing)
                    }
                }
            }
            .font(.caption2)
        }
    }

    static func compact(_ tokens: Int) -> String {
        TokenFormat.compact(tokens)
    }
}
#endif

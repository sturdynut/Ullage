import Foundation

/// What the composition treemap draws: every tile already positioned and
/// labelled, so the view only renders rectangles.
///
/// **Ordered, not squarified.** A squarified treemap has nicer aspect ratios
/// but re-sorts by size, so tiles swap places as a live session grows — in a
/// popover that updates every turn, the chart would never hold still. Here the
/// four segments keep their fixed order left to right, exactly like the bar
/// this replaces, and a colour follows its segment, never its rank. Only the
/// parts *inside* a segment (tools, the baseline's CLAUDE.md estimate) are
/// sliced within their own column.
///
/// Areas are proportional to tokens except where a segment would be thinner
/// than `minimumSegmentWidth`: it is widened and the difference taken from the
/// largest segment, so no non-zero share vanishes — the same rule the flat bar
/// used.
public struct CompositionTreemap: Equatable {
    public struct Rect: Equatable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public var area: Double { width * height }
        public var maxX: Double { x + width }
        public var maxY: Double { y + height }
    }

    public enum Role: Equatable {
        /// A whole segment drawn as one tile.
        case segment
        /// The band that names a segment once it is split into parts.
        case header
        /// One part of a split segment: a tool, or a piece of the baseline.
        case part
    }

    /// What fits inside a tile, decided here so the rule is tested rather than
    /// left to whatever SwiftUI truncates.
    public enum Label: Equatable {
        case none
        case value(String)
        case name(String)
        case nameAndValue(String, String)
    }

    public struct Tile: Equatable, Identifiable {
        public var id: String
        /// The segment this tile belongs to — its colour key.
        public var segment: String
        public var name: String
        /// The unabbreviated name, for the tooltip (`mcp__github__…`).
        public var fullName: String
        public var tokens: Int
        public var calls: Int?
        /// Shown with `≈`: a length estimate, or derived from one.
        public var isEstimate: Bool
        public var role: Role
        /// Picks a lightness step for parts. Derived from the part's name, not
        /// its rank, so a tool keeps its shade when it overtakes another.
        public var shade: Int
        public var rect: Rect
        public var label: Label
        /// A sentence for the tooltip, where the tile needs explaining.
        public var detail: String?
    }

    /// Approximate glyph metrics, so label fitting can run without a font.
    /// Deliberately generous: a label that would *nearly* fit is dropped rather
    /// than left for the renderer to truncate into something ambiguous.
    public struct Metrics: Equatable {
        public var nameFontSize: Double = 10.5
        public var valueFontSize: Double = 10
        /// Average advance per character as a fraction of the font size.
        public var characterWidth: Double = 0.58
        public var horizontalPadding: Double = 5
        public var lineHeight: Double = 12
        public var headerHeight: Double = 14

        public init() {}

        func width(of text: String, fontSize: Double) -> Double {
            Double(text.count) * fontSize * characterWidth + horizontalPadding * 2
        }
    }

    public static let segmentGap = 2.0
    public static let partGap = 1.0
    public static let minimumSegmentWidth = 3.0
    /// Tools beyond this many fold into one "N more" tile rather than being
    /// drawn as slivers nobody can read or hover.
    public static let maximumToolTiles = 5
    public static let shadeCount = 5

    public var width: Double
    public var height: Double
    public var tiles: [Tile]

    public static func layout(
        _ composition: ContextComposition,
        width: Double,
        height: Double,
        metrics: Metrics = Metrics()
    ) -> CompositionTreemap {
        var map = CompositionTreemap(width: width, height: height, tiles: [])
        guard width > 0, height > 0, composition.contextTokens > 0 else { return map }

        let live = composition.segments.filter { $0.tokens > 0 }
        guard !live.isEmpty else { return map }
        let widths = segmentWidths(live.map(\.tokens), available: width - segmentGap * Double(live.count - 1))

        var x = 0.0
        for (segment, segmentWidth) in zip(live, widths) {
            let rect = Rect(x: x, y: 0, width: segmentWidth, height: height)
            x += segmentWidth + segmentGap
            let parts = self.parts(of: segment, in: composition)
            if parts.count > 1 {
                map.tiles += split(segment, parts: parts, rect: rect, composition: composition, metrics: metrics)
            } else {
                map.tiles.append(
                    Tile(
                        id: segment.name,
                        segment: segment.name,
                        name: segment.name,
                        fullName: segment.name,
                        tokens: segment.tokens,
                        calls: nil,
                        isEstimate: ContextComposition.isEstimate(segment: segment.name),
                        role: .segment,
                        shade: 0,
                        rect: rect,
                        label: label(
                            name: segment.name,
                            values: segmentValues(segment, composition),
                            rect: rect,
                            metrics: metrics
                        ),
                        detail: nil
                    )
                )
            }
        }
        return map
    }

    // MARK: - Segment widths

    /// Proportional, then every non-zero segment raised to the minimum width
    /// with the difference taken from the widest, so the total never changes.
    static func segmentWidths(_ tokens: [Int], available: Double) -> [Double] {
        let total = Double(tokens.reduce(0, +))
        guard total > 0, available > 0 else { return tokens.map { _ in 0 } }
        var widths = tokens.map { available * Double($0) / total }
        let floor = min(minimumSegmentWidth, available / Double(tokens.count))
        var deficit = 0.0
        for index in widths.indices where widths[index] < floor {
            deficit += floor - widths[index]
            widths[index] = floor
        }
        if deficit > 0, let widest = widths.indices.max(by: { widths[$0] < widths[$1] }) {
            widths[widest] = max(floor, widths[widest] - deficit)
        }
        return widths
    }

    // MARK: - Parts

    struct Part {
        var id: String
        var name: String
        var fullName: String
        var tokens: Int
        var calls: Int?
        var detail: String?
    }

    /// The parts a segment splits into, largest first. Only tool results and
    /// the baseline have any; a segment with one part is drawn whole.
    static func parts(of segment: ContextComposition.Segment, in composition: ContextComposition) -> [Part] {
        switch segment.name {
        case ContextComposition.toolResultsName:
            let tools = composition.tools.filter { $0.resultTokens > 0 }
            var parts = tools.prefix(maximumToolTiles).map { tool in
                Part(
                    id: tool.name,
                    name: shortToolName(tool.name),
                    fullName: tool.name,
                    tokens: tool.resultTokens,
                    calls: tool.calls,
                    detail: nil
                )
            }
            let rest = tools.dropFirst(maximumToolTiles)
            if !rest.isEmpty {
                parts.append(
                    Part(
                        id: "more",
                        name: "\(rest.count) more",
                        fullName: rest.map(\.name).joined(separator: ", "),
                        tokens: rest.reduce(0) { $0 + $1.resultTokens },
                        calls: rest.reduce(0) { $0 + $1.calls },
                        detail: nil
                    )
                )
            }
            return parts

        case ContextComposition.baselineName:
            // Split only where the estimate is smaller than what it is carved
            // out of; otherwise the remainder would be zero or negative and the
            // split would be a guess dressed as a measurement.
            guard let claudeMd = composition.claudeMdTokensEstimate,
                  claudeMd > 0, claudeMd < segment.tokens else { return [] }
            let restName = composition.windowStartTurn == 0 ? "System + prompt" : "System + summary"
            return [
                Part(
                    id: "system",
                    name: restName,
                    fullName: restName,
                    tokens: segment.tokens - claudeMd,
                    calls: nil,
                    detail: "Not separable on disk: the baseline less the CLAUDE.md estimate."
                ),
                Part(
                    id: "claude-md",
                    name: "CLAUDE.md",
                    fullName: "CLAUDE.md",
                    tokens: claudeMd,
                    calls: nil,
                    detail: "Length estimate, ~4 bytes per token."
                ),
            ]

        default:
            return []
        }
    }

    /// `mcp__github__pull_request_read` → `github · pull request read`.
    public static func shortToolName(_ name: String) -> String {
        guard name.hasPrefix("mcp__") else { return name }
        let pieces = name.dropFirst("mcp__".count)
            .components(separatedBy: "__")
            .filter { !$0.isEmpty }
            .map { $0.replacingOccurrences(of: "_", with: " ") }
        return pieces.isEmpty ? name : pieces.joined(separator: " · ")
    }

    static func split(
        _ segment: ContextComposition.Segment,
        parts: [Part],
        rect: Rect,
        composition: ContextComposition,
        metrics: Metrics
    ) -> [Tile] {
        var tiles: [Tile] = []
        var body = rect
        let isEstimate = ContextComposition.isEstimate(segment: segment.name)

        // Once a segment is in pieces, a header band keeps its name on screen —
        // if there is room for one without starving the parts.
        if rect.height >= metrics.headerHeight * 3, rect.width >= 34 {
            let header = Rect(x: rect.x, y: rect.y, width: rect.width, height: metrics.headerHeight)
            let total = (isEstimate ? "≈" : "") + TokenFormat.compact(segment.tokens)
            tiles.append(
                Tile(
                    id: segment.name,
                    segment: segment.name,
                    name: segment.name,
                    fullName: segment.name,
                    tokens: segment.tokens,
                    calls: nil,
                    isEstimate: isEstimate,
                    role: .header,
                    shade: 0,
                    rect: header,
                    label: headerLabel(name: segment.name, total: total, rect: header, metrics: metrics),
                    detail: nil
                )
            )
            body.y += metrics.headerHeight + partGap
            body.height -= metrics.headerHeight + partGap
        }

        // Stripes across a wide, short column; a stack down a tall one.
        let horizontal = body.width > body.height * 2.2
        let length = horizontal ? body.width : body.height
        let available = max(0, length - partGap * Double(parts.count - 1))
        let total = Double(parts.reduce(0) { $0 + $1.tokens })
        var offset = 0.0
        for part in parts {
            let extent = total > 0 ? available * Double(part.tokens) / total : 0
            let partRect = horizontal
                ? Rect(x: body.x + offset, y: body.y, width: extent, height: body.height)
                : Rect(x: body.x, y: body.y + offset, width: body.width, height: extent)
            offset += extent + partGap
            let value = "≈" + TokenFormat.compact(part.tokens)
            tiles.append(
                Tile(
                    id: segment.name + "/" + part.id,
                    segment: segment.name,
                    name: part.name,
                    fullName: part.fullName,
                    tokens: part.tokens,
                    calls: part.calls,
                    // Every part is an estimate: tools are length estimates and
                    // the baseline split is carved with one.
                    isEstimate: true,
                    role: .part,
                    shade: shade(for: part.id),
                    rect: partRect,
                    label: label(name: part.name, values: [value], rect: partRect, metrics: metrics),
                    detail: part.detail
                )
            )
        }
        return tiles
    }

    /// Stable per name, so a part's shade follows it rather than its rank.
    static func shade(for id: String) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in id.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return Int(hash % UInt32(shadeCount))
    }

    // MARK: - Labels

    /// Longest first: `≈39k  18%`, then `≈39k`.
    static func segmentValues(_ segment: ContextComposition.Segment, _ composition: ContextComposition) -> [String] {
        let value = (ContextComposition.isEstimate(segment: segment.name) ? "≈" : "")
            + TokenFormat.compact(segment.tokens)
        let share = MenuBarFormatter.percentage(composition.share(segment.tokens))
        return [value + "  " + share, value]
    }

    /// Name on the first line and value on the second; whatever does not fit
    /// is dropped, never truncated mid-word.
    static func label(name: String, values: [String], rect: Rect, metrics: Metrics) -> Label {
        guard rect.height >= metrics.lineHeight + 2, rect.width >= 22 else { return .none }
        let value = values.first { metrics.width(of: $0, fontSize: metrics.valueFontSize) <= rect.width }
        let nameFits = metrics.width(of: name, fontSize: metrics.nameFontSize) <= rect.width
        let twoLines = rect.height >= metrics.lineHeight * 2 + 4
        switch (nameFits, value) {
        case (true, let value?) where twoLines: return .nameAndValue(name, value)
        case (true, _): return .name(name)
        case (false, let value?): return .value(value)
        case (false, nil): return .none
        }
    }

    /// A header is one line: name and total side by side if they fit.
    static func headerLabel(name: String, total: String, rect: Rect, metrics: Metrics) -> Label {
        let both = name + "  " + total
        if metrics.width(of: both, fontSize: metrics.nameFontSize) <= rect.width { return .name(both) }
        if metrics.width(of: name, fontSize: metrics.nameFontSize) <= rect.width { return .name(name) }
        if metrics.width(of: total, fontSize: metrics.valueFontSize) <= rect.width { return .value(total) }
        return .none
    }
}

/// Token counts at a glance: `845`, `8.4k`, `84k`, `1.2M`.
public enum TokenFormat {
    public static func compact(_ tokens: Int) -> String {
        switch tokens {
        case 1_000_000...: return String(format: "%.1fM", Double(tokens) / 1_000_000)
        case 10_000...: return "\(tokens / 1_000)k"
        case 1_000...: return String(format: "%.1fk", Double(tokens) / 1_000)
        default: return "\(tokens)"
        }
    }
}

extension ContextComposition {
    /// Which segment totals are not measurements. Tool results are a length
    /// estimate and Other is the remainder that absorbs their error; the
    /// baseline is a measured prompt size, and output is reported (it
    /// undercounts, but it is not a guess).
    public static func isEstimate(segment: String) -> Bool {
        segment == toolResultsName || segment == otherName
    }
}

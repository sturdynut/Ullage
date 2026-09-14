#if os(macOS)
import Charts
import SwiftUI
import UllageCore

/// Context tokens per turn for one stream: a single thin line under the room
/// that is left, the warning threshold as a reserved-colour rule, and a dashed
/// rule wherever compaction fired. One series, so no legend; hover gives the
/// exact figures in place of the caption.
///
/// The band *above* the curve is the point of the app — it is the ullage — so
/// it is drawn rather than left as empty plot. Axis furniture is not: the
/// numbers live in the hover readout, where they are exact.
struct ContextChart: View {
    let history: ContextHistory
    /// The popover captions the block with a section rule, so the idle line
    /// would repeat it. The history window has no such rule and keeps it.
    var showsIdleCaption = true

    @State private var hovered: ContextPoint?

    /// Nil when the harness reported no window. Nothing is substituted for it:
    /// a drawn ceiling and an 85% rule against a guessed limit would be the
    /// invented measurement the whole project refuses to show.
    private var limit: Int? { history.windowLimit }
    private var yCeiling: Int { max(limit ?? 0, history.peakContextTokens, 1) }
    private var isUnmeasured: Bool { history.points.allSatisfy { $0.contextTokens == 0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            readout
            if isUnmeasured {
                Text("This harness records no token counts — activity only")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if history.points.count < 2 {
                Text("Not enough turns to chart yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                chart
            }
        }
    }

    @ViewBuilder
    private var readout: some View {
        if let hovered {
            Text("Turn \(hovered.turnIndex)  ·  \(hovered.contextTokens.formatted()) tokens"
                 + (hovered.contextDelta.map { "  ·  \($0 >= 0 ? "+" : "")\($0.formatted())" } ?? "")
                 + (history.compactionTurns.contains(hovered.turnIndex) ? "  ·  compacted before this turn" : ""))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
        } else if showsIdleCaption {
            Text("Context per turn")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        } else if let limit, let last = history.points.last {
            // Says what the band is, once, where the hover text will replace it.
            Text("\(Self.compact(max(0, limit - last.contextTokens))) left in the window")
                .font(.caption).foregroundStyle(.tertiary).monospacedDigit().lineLimit(1)
        } else {
            Text(" ").font(.caption)
        }
    }

    private var chart: some View {
        Chart {
            // The room left, drawn: the curve to the ceiling. Faint, because it
            // is the negative space that matters, not a second series.
            if let limit {
                ForEach(history.points) { point in
                    AreaMark(
                        x: .value("Turn", point.turnIndex),
                        yStart: .value("Context", min(point.contextTokens, limit)),
                        yEnd: .value("Window", limit)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.primary.opacity(0.045))
                }
            }

            ForEach(history.points) { point in
                AreaMark(x: .value("Turn", point.turnIndex), y: .value("Context", point.contextTokens))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(
                        LinearGradient(colors: [Color.accentColor.opacity(0.18), Color.accentColor.opacity(0.0)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                LineMark(x: .value("Turn", point.turnIndex), y: .value("Context", point.contextTokens))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(Color.accentColor)
            }

            ForEach(history.compactionTurns, id: \.self) { turn in
                RuleMark(x: .value("Compaction", turn))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(.secondary)
            }

            if let limit {
                RuleMark(y: .value("Warning", Int(Double(limit) * MenuBarFormatter.warningThreshold)))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
                    .foregroundStyle(Color.orange.opacity(0.35))
            }

            if let hovered {
                RuleMark(x: .value("Turn", hovered.turnIndex))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(.tertiary)
                PointMark(x: .value("Turn", hovered.turnIndex), y: .value("Context", hovered.contextTokens))
                    .symbolSize(56)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .chartYScale(domain: 0...yCeiling)
        .chartYAxis {
            // One label: the ceiling. Every other value is a hover away, and
            // exact there rather than rounded here.
            AxisMarks(position: .trailing, values: [limit ?? history.peakContextTokens]) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let tokens = value.as(Int.self) {
                        Text(limit == nil ? "peak \(Self.compact(tokens))" : Self.compact(tokens))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .chartXAxis(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let frame = proxy.plotFrame else { return }
                            let origin = geometry[frame].origin
                            if let turn: Int = proxy.value(atX: location.x - origin.x) {
                                hovered = nearest(to: turn)
                            }
                        case .ended:
                            hovered = nil
                        }
                    }
            }
        }
    }

    private func nearest(to turn: Int) -> ContextPoint? {
        history.points.min { abs($0.turnIndex - turn) < abs($1.turnIndex - turn) }
    }

    static func compact(_ tokens: Int) -> String {
        switch tokens {
        case 1_000_000...: return String(format: "%gM", Double(tokens) / 1_000_000)
        case 1_000...: return "\(tokens / 1_000)k"
        default: return "\(tokens)"
        }
    }
}
#endif

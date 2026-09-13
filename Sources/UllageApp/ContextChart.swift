#if os(macOS)
import Charts
import SwiftUI
import UllageCore

/// Context tokens per turn for one session: a single thin line, the window
/// as the ceiling, the warning threshold as a reserved-colour rule, and a
/// dashed rule wherever compaction fired. One series, so no legend; hover
/// gives the exact figures.
struct ContextChart: View {
    let history: ContextHistory

    @State private var hovered: ContextPoint?

    private var limit: Int { history.windowLimit ?? WindowLimits.fallback }
    private var yCeiling: Int { max(limit, history.peakContextTokens) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            readout
            if history.points.count < 2 {
                Text("Not enough turns to chart yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                chart
            }
        }
    }

    private var readout: some View {
        Group {
            if let hovered {
                Text("Turn \(hovered.turnIndex)  ·  \(hovered.contextTokens.formatted()) tokens"
                     + (hovered.contextDelta.map { "  ·  \($0 >= 0 ? "+" : "")\($0.formatted())" } ?? "")
                     + (history.compactionTurns.contains(hovered.turnIndex) ? "  ·  compacted before this turn" : ""))
            } else {
                Text("Context per turn")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(1)
    }

    private var chart: some View {
        Chart {
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

            RuleMark(y: .value("Warning", Int(Double(limit) * MenuBarFormatter.warningThreshold)))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
                .foregroundStyle(Color.orange.opacity(0.7))

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
            AxisMarks(position: .trailing, values: [0, limit / 2, limit]) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let tokens = value.as(Int.self) {
                        Text(Self.compact(tokens)).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisValueLabel {
                    if let turn = value.as(Int.self) {
                        Text("\(turn)").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
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

#if os(macOS)
import SwiftUI
import UllageCore

/// Subscription limits: how much of each rolling window is left, and when it
/// resets. A plan limit is a percentage, never tokens — neither vendor states
/// one in tokens — so the only token figures here are Ullage's own count of
/// what it saw in the window, and they say so.
///
/// Disclosed in two steps. Collapsed, one line per harness: the limit that
/// will stop you first — the answer to "how much do I have left". Expanded,
/// every limit with its reset and what Ullage saw in it; hover for the four
/// counters. Remembered across launches, like any other view preference.
struct PlanLimitsView: View {
    let limits: [PlanLimitDisplay]
    let usage: [String: Store.WindowUsage]
    @AppStorage("planLimitsExpanded") private var expanded = false

    var body: some View {
        let summaries = PlanLimitFormatter.summaries(limits)
        VStack(alignment: .leading, spacing: 7) {
            if expanded {
                ForEach(limits) { limit in
                    row(limit)
                }
            } else {
                ForEach(summaries) { summary in
                    summaryRow(summary)
                }
            }
            if limits.count > summaries.count {
                disclosure
            }
        }
    }

    /// Same shape as the composition's "What's inside": the whole row is the
    /// target, the chevron is the affordance.
    private var disclosure: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Text(expanded ? "Hide details" : "All \(limits.count) limits — resets & usage")
                    .font(.caption)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Which limit it is stays on the line: "71% left" means nothing until
    /// you know whether it is the 5-hour window or the week.
    private func summaryRow(_ summary: PlanLimitSummary) -> some View {
        let limit = summary.binding
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(summary.vendorName)
                    .font(.caption.weight(.semibold))
                Text(limit.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                percentLeft(limit)
            }
            LimitBar(used: limit.usedFraction, dimmed: limit.isStale)
        }
        .help(PlanLimitFormatter.caption(for: limit) + (summary.count > 1 ? "\nTightest of \(summary.count) limits" : ""))
    }

    private func percentLeft(_ limit: PlanLimitDisplay) -> some View {
        Text(limit.remainingFraction.map { MenuBarFormatter.percentage($0) + " left" } ?? "—")
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(limit.isWarning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary))
    }

    private func row(_ limit: PlanLimitDisplay) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(limit.vendorName)
                    .font(.caption.weight(.semibold))
                Text(limit.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                percentLeft(limit)
            }
            LimitBar(used: limit.usedFraction, dimmed: limit.isStale)
            Text(caption(limit))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .help(help(limit))
    }

    /// Reset and age first — they decide whether the number is still true —
    /// then what Ullage saw in the window.
    private func caption(_ limit: PlanLimitDisplay) -> String {
        var parts = [PlanLimitFormatter.caption(for: limit)]
            .filter { !$0.isEmpty }
            // "N% left" is already on the line above.
            .map { $0.replacingOccurrences(of: #"^\d+% left · "#, with: "", options: .regularExpression) }
        if let seen = usage[limit.id], seen.calls > 0 {
            parts.append("\(seen.calls.formatted()) turns · \(CompositionView.compact(seen.output)) out here")
        }
        return parts.joined(separator: " · ")
    }

    private func help(_ limit: PlanLimitDisplay) -> String {
        var lines: [String] = []
        if let resetsAt = limit.resetsAt {
            lines.append("Resets \(resetsAt.formatted(date: .abbreviated, time: .shortened))")
        }
        if let observedAt = limit.observedAt {
            lines.append("Read \(observedAt.formatted(date: .omitted, time: .shortened))"
                + (limit.vendor == Vendor.codex ? " from Codex's own transcript" : " from Anthropic"))
        }
        if let seen = usage[limit.id], seen.calls > 0 {
            lines.append("""
            Seen by Ullage in this window (a floor — the limit also counts usage Ullage cannot see):
              input \(seen.input.formatted()) · output \(seen.output.formatted())
              cache read \(seen.cacheRead.formatted()) · cache write \(seen.cacheWrite.formatted())
            """)
        } else if limit.isScoped {
            lines.append("A limit on one model; Ullage's own counts cover every model, so none are shown.")
        }
        return lines.joined(separator: "\n")
    }
}

/// Thin used-fraction bar. Not `OccupancyBar`: its 85% mark means
/// "compaction territory", which a plan limit does not have.
private struct LimitBar: View {
    let used: Double?
    var dimmed = false
    private var isWarning: Bool { (used ?? 0) >= MenuBarFormatter.warningThreshold }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                if let used {
                    Capsule()
                        .fill(isWarning ? Color.orange : Color.accentColor)
                        .opacity(dimmed ? 0.45 : 1)
                        .frame(width: max(3, geometry.size.width * min(1, used)))
                }
            }
        }
        .frame(height: 5)
    }
}
#endif

#if os(macOS)
import AppKit
import Charts
import SwiftUI
import UllageCore

/// The usage dashboard: four key figures, the rest behind a disclosure, and
/// one tab per section. Every rule is `UsageDashboard`'s; this only draws it.
@MainActor
final class DashboardModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case weekly = "Weekly"
        case sessions = "Sessions"
        case context = "Context"
        case projects = "Projects & models"
        case tools = "Tools"
        var id: String { rawValue }
    }

    @Published var vendor = Vendor.claudeCode { didSet { reload() } }
    @Published var counter = UsageCounter.output { didSet { reload() } }
    @Published var days: Int? = 30 { didSet { reload() } }
    @Published var idleGap: TimeInterval = 30 * 60 { didSet { reload() } }
    @Published var ranking = UsageDashboard.Ranking.total
    @Published private(set) var dashboard: UsageDashboard?
    @Published private(set) var errorMessage: String?

    private var store: Store?

    init(databasePath: String = ClaudePaths.defaultDatabaseURL().path) {
        do { store = try Store(path: databasePath) } catch { errorMessage = "\(error)" }
    }

    func reload() {
        guard let store else { return }
        do {
            dashboard = try store.usageDashboard(.init(vendor: vendor, counter: counter, days: days, idleGap: idleGap))
            errorMessage = nil
        } catch {
            errorMessage = "\(error)"
        }
    }
}

struct DashboardWindow: View {
    static let id = "dashboard"

    @StateObject private var model = DashboardModel()
    @AppStorage("dashboard.tab") private var tab = DashboardModel.Tab.weekly.rawValue
    @AppStorage("dashboard.showAll") private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            controls
            if let d = model.dashboard {
                tiles(d.keyTiles, key: true)
                if !d.moreTiles.isEmpty {
                    DisclosureGroup(isExpanded: $showAll) {
                        tiles(d.moreTiles, key: false).padding(.top, 6)
                    } label: {
                        Text(showAll ? "Hide other metrics" : "Show all metrics (\(d.moreTiles.count) more)")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                            .onTapGesture { withAnimation { showAll.toggle() } }
                    }
                }
                TabView(selection: $tab) {
                    ForEach(DashboardModel.Tab.allCases) { t in
                        ScrollView { section(t, d).padding(12) }
                            .tabItem { Text(t.rawValue) }
                            .tag(t.rawValue)
                    }
                }
                footnote
            } else {
                Spacer()
            }
            if let errorMessage = model.errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(16)
        .frame(minWidth: 860, minHeight: 640)
        .onAppear { model.reload() }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Harness", selection: $model.vendor) {
                ForEach(UsageDashboard.Options.vendors, id: \.self) { Text(UsageDashboard.vendorLabel($0)).tag($0) }
            }
            .pickerStyle(.segmented).fixedSize()
            Picker("Counter", selection: $model.counter) {
                ForEach(UsageCounter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).fixedSize()
            .disabled(model.vendor == Vendor.cursor)
            .help("Every figure uses this one counter. They are never added together.")
            Picker("Range", selection: $model.days) {
                ForEach(UsageDashboard.Options.ranges, id: \.self) { Text(UsageDashboard.rangeLabel($0)).tag($0) }
            }
            .pickerStyle(.segmented).fixedSize()
            Picker("Idle gap", selection: $model.idleGap) {
                ForEach(UsageDashboard.Options.idleGaps, id: \.self) { Text(UsageDashboard.idleGapLabel($0)).tag($0) }
            }
            .pickerStyle(.menu).fixedSize()
            .help("The longest pause between calls still counted as active time")
            Spacer()
            Button("Refresh") { model.reload() }
        }
        .labelsHidden()
    }

    // MARK: Tiles

    private func tiles(_ tiles: [DashboardTile], key: Bool) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: key ? 4 : 3),
                  alignment: .leading, spacing: 10) {
            ForEach(tiles) { TileView(tile: $0, key: key) }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func section(_ tab: DashboardModel.Tab, _ d: UsageDashboard) -> some View {
        switch tab {
        case .weekly: WeeklySection(dashboard: d)
        case .sessions: SessionsSection(dashboard: d, ranking: $model.ranking)
        case .context: ContextSection(summary: d.summary)
        case .projects: ProjectsSection(dashboard: d)
        case .tools: ToolsSection(tools: d.tools, vendor: d.options.vendor)
        }
    }

    private var footnote: some View {
        Text("Active time counts the gaps between calls no longer than the idle gap, so a session resumed days later is not credited with the days between. Rates and rankings leave out sessions with under 10 active minutes. Cache rebuilds are in `ullage rebuilds --days N`.")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct TileView: View {
    let tile: DashboardTile
    let key: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(tile.title.uppercased())
                .font(.caption2.weight(.semibold)).tracking(0.6)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(tile.value)
                .font(.system(size: key ? 26 : 20, weight: .semibold))
                .monospacedDigit()
            Text(tile.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if let change = tile.change {
                (Text(change.text).fontWeight(.semibold).foregroundColor(color(change.direction))
                    + Text(" " + change.caption).foregroundColor(.secondary))
                    .font(.caption)
            }
            if let why = tile.why {
                Divider().padding(.vertical, 2)
                Text(why).font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(key ? 14 : 12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }

    private func color(_ direction: DashboardTile.Direction) -> Color {
        switch direction {
        case .up: return .orange
        case .down: return .blue
        case .flat: return .secondary
        }
    }
}

private struct Empty: View {
    let text: String
    var body: some View {
        Text(text).foregroundStyle(.tertiary).frame(maxWidth: .infinity, minHeight: 120)
    }
}

// MARK: Weekly

private struct WeeklySection: View {
    let dashboard: UsageDashboard

    var body: some View {
        let measured = dashboard.summary.measured
        let weeks = dashboard.weeks
        VStack(alignment: .leading, spacing: 10) {
            if weeks.isEmpty {
                Empty(text: "No sessions in this range")
            } else {
                Text(measured ? "\(dashboard.options.counter.title) per week" : "Sessions per week").font(.headline)
                Chart(weeks) { w in
                    BarMark(x: .value("Week", w.start, unit: .weekOfYear),
                            y: .value("Total", measured ? w.total : w.sessions))
                    .cornerRadius(2)
                }
                .chartYAxis { compactAxis }
                .frame(height: 180)
                if measured {
                    Text("\(dashboard.options.counter.title) per active hour").font(.headline)
                    Chart(weeks.filter { $0.perActiveHour != nil }) { w in
                        LineMark(x: .value("Week", w.start, unit: .weekOfYear), y: .value("Per hour", w.perActiveHour ?? 0))
                            .foregroundStyle(.purple)
                        PointMark(x: .value("Week", w.start, unit: .weekOfYear), y: .value("Per hour", w.perActiveHour ?? 0))
                            .foregroundStyle(.purple)
                    }
                    .chartYAxis { compactAxis }
                    .frame(height: 140)
                    Text("Weeks with under 10 active minutes have no rate. Active time per week uses the same idle gap.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

@AxisContentBuilder
private var compactAxis: some AxisContent {
    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
        AxisGridLine().foregroundStyle(.quaternary)
        AxisValueLabel {
            if let v = value.as(Double.self) { Text(UsageDashboard.tokens(v)).font(.caption2) }
        }
    }
}

// MARK: Sessions

private struct SessionsSection: View {
    let dashboard: UsageDashboard
    @Binding var ranking: UsageDashboard.Ranking

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !dashboard.summary.measured {
                Empty(text: "\(UsageDashboard.vendorLabel(dashboard.options.vendor)) reports no tokens to rank by")
            } else {
                HStack {
                    Text("Sessions ranked").font(.headline)
                    Text("\(dashboard.ranked(by: ranking).count) sessions with 10+ active minutes")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Picker("Rank by", selection: $ranking) {
                        ForEach(UsageDashboard.Ranking.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).fixedSize().labelsHidden()
                }
                let (highest, lowest) = dashboard.extremes(by: ranking)
                HStack(alignment: .top, spacing: 16) {
                    rankTable("Highest", highest)
                    rankTable("Lowest", lowest)
                }
                Text("Session size").font(.headline).padding(.top, 6)
                Chart(dashboard.sizeBands) { band in
                    BarMark(x: .value("Size", band.label), y: .value("Sessions", band.sessions))
                        .foregroundStyle(.teal)
                        .annotation(position: .top) {
                            if band.sessions > 0 { Text("\(band.sessions)").font(.caption2).foregroundStyle(.secondary) }
                        }
                }
                .chartXAxisLabel("\(dashboard.options.counter.noun) per session")
                .frame(height: 170)
                .frame(maxWidth: 560)
            }
        }
    }

    private func rankTable(_ title: String, _ sessions: [UsageSession]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 5) {
                GridRow {
                    Text("Session").gridColumnAlignment(.leading)
                    Text(ranking == .total ? dashboard.options.counter.title : "Per hour")
                    Text("Active"); Text("Turns"); Text("Peak")
                }
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Divider()
                ForEach(sessions) { s in
                    GridRow {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(s.project ?? "—").lineLimit(1).truncationMode(.tail)
                            Text("\(s.first.formatted(.dateTime.month(.abbreviated).day())) · \(s.id.prefix(8))")
                                .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: 180, alignment: .leading)
                        .help("\(s.project ?? "") · \(s.model ?? "") · \(s.id)")
                        Text(UsageDashboard.tokens(dashboard.rankValue(s, by: ranking)))
                        Text(UsageDashboard.hours(s.activeHours(idleGap: dashboard.options.idleGap)))
                        Text("\(s.turns)")
                        Text(UsageDashboard.percent(s.peakOccupancy))
                            .foregroundStyle((s.peakOccupancy ?? 0) >= 0.85 ? .orange : .primary)
                    }
                    .font(.callout).monospacedDigit()
                }
            }
            if sessions.isEmpty { Empty(text: "No sessions in this range") }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: Context

private struct ContextSection: View {
    let summary: UsageDashboard.Summary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Context health").font(.headline); Text("main thread only").font(.caption).foregroundStyle(.secondary) }
            if summary.windowedSessions == 0 {
                Empty(text: "No measured windows in this range")
            } else {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    row("Average peak fill", UsageDashboard.percent(summary.meanPeakOccupancy))
                    row("Median peak context", "\(UsageDashboard.tokens(summary.medianPeakContext)) tokens")
                    row("Sessions that reached 85%", "\(summary.sessionsReaching85) of \(summary.windowedSessions)")
                    row("Sessions that compacted", "\(summary.sessionsCompacted) of \(summary.sessions)")
                    row("Average growth per turn", summary.averageGrowth.map { "+" + UsageDashboard.tokens($0) } ?? "—")
                }
                .frame(maxWidth: 460, alignment: .leading)
                if let hot = summary.hotTurnShare {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Turns by how full the window was").font(.caption).foregroundStyle(.secondary)
                        GeometryReader { geo in
                            HStack(spacing: 0) {
                                Rectangle().fill(Color.accentColor.opacity(0.5)).frame(width: geo.size.width * (1 - hot))
                                Rectangle().fill(Color.orange)
                            }
                        }
                        .frame(height: 8)
                        .clipShape(Capsule())
                        (Text(UsageDashboard.percent(hot, decimals: 1)).foregroundColor(.orange).fontWeight(.semibold)
                            + Text(" of \(UsageDashboard.count(summary.windowedTurns)) turns ran at 85% or more").foregroundColor(.secondary))
                            .font(.caption)
                    }
                    .frame(maxWidth: 460)
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).fontWeight(.semibold).monospacedDigit().gridColumnAlignment(.trailing)
        }
    }
}

// MARK: Projects & models

private struct ProjectsSection: View {
    let dashboard: UsageDashboard

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            groupTable("By project", dashboard.projects)
            groupTable("By model", dashboard.models, note: "main-thread model of each session")
        }
    }

    private func groupTable(_ title: String, _ groups: [UsageDashboard.Group], note: String? = nil) -> some View {
        let measured = dashboard.summary.measured
        return VStack(alignment: .leading, spacing: 6) {
            HStack { Text(title).font(.headline); if let note { Text(note).font(.caption).foregroundStyle(.secondary) } }
            if groups.isEmpty {
                Empty(text: "No sessions in this range")
            } else {
                Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 5) {
                    GridRow {
                        Text("Name").gridColumnAlignment(.leading)
                        Text("Sessions")
                        if measured {
                            Text(dashboard.options.counter.title); Text("Per session"); Text("Per active h"); Text("Avg peak")
                        } else {
                            Text("Turns")
                        }
                    }
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Divider()
                    ForEach(groups) { g in
                        GridRow {
                            Text(g.name).lineLimit(1).frame(maxWidth: 240, alignment: .leading).help(g.name)
                            Text("\(g.sessions)")
                            if measured {
                                Text(UsageDashboard.tokens(Double(g.total)))
                                Text(UsageDashboard.tokens(g.perSession))
                                Text(UsageDashboard.tokens(g.perActiveHour))
                                Text(UsageDashboard.percent(g.meanPeakOccupancy))
                            } else {
                                Text(UsageDashboard.count(g.turns))
                            }
                        }
                        .font(.callout).monospacedDigit()
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
            }
        }
    }
}

// MARK: Tools

private struct ToolsSection: View {
    let tools: [ToolUsage]
    let vendor: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Where context comes from").font(.headline)
                Text("≈ ESTIMATE").font(.caption2.weight(.semibold)).foregroundStyle(.brown)
                    .padding(.horizontal, 4).overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.brown))
            }
            if tools.isEmpty {
                Empty(text: "No tool results recorded for \(UsageDashboard.vendorLabel(vendor)) in this range")
            } else {
                Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 5) {
                    GridRow {
                        Text("Tool").gridColumnAlignment(.leading)
                        Text("Calls"); Text("≈ Result tokens"); Text("≈ Per call"); Text("Errors")
                    }
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Divider()
                    ForEach(tools) { t in
                        GridRow {
                            Text(t.name).lineLimit(1).frame(maxWidth: 260, alignment: .leading).help(t.name)
                            Text(UsageDashboard.count(t.calls))
                            Text("≈ " + UsageDashboard.tokens(Double(t.estimatedResultTokens)))
                            Text("≈ " + UsageDashboard.tokens(Double(t.estimatedResultTokens) / Double(max(t.calls, 1))))
                            Text("\(t.errors)").foregroundStyle(t.errors > 0 ? .orange : .primary)
                        }
                        .font(.callout).monospacedDigit()
                    }
                }
                .frame(maxWidth: 640, alignment: .leading)
            }
            Text("Tool result size is a length estimate (about 4 bytes per token), not a token count.")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }
}
#endif

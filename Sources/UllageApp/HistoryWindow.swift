#if os(macOS)
import AppKit
import Charts
import SwiftUI
import UllageCore

/// M6 — history across days, and M7's composition for whichever session is
/// selected. Reads through its own connection; WAL lets it sit beside the
/// tailer's writer and the popover's reader.
@MainActor
final class HistoryModel: ObservableObject {
    enum Metric: String, CaseIterable, Identifiable {
        case turns = "Turns"
        case output = "Output tokens"
        case cacheRead = "Cache reads"
        var id: String { rawValue }

        func value(_ row: DailyActivity) -> Int {
            switch self {
            case .turns: return row.calls
            case .output: return row.output
            case .cacheRead: return row.cacheRead
            }
        }
    }

    @Published var days = 30 { didSet { reload() } }
    @Published var metric: Metric = .turns
    @Published var selectedSession: String? { didSet { loadSelection() } }
    @Published private(set) var activity: [DailyActivity] = []
    @Published private(set) var sessions: [Store.SessionTotals] = []
    @Published private(set) var history: ContextHistory?
    @Published private(set) var composition: ContextComposition?
    @Published private(set) var errorMessage: String?

    private var store: Store?

    init(databasePath: String = ClaudePaths.defaultDatabaseURL().path) {
        do { store = try Store(path: databasePath) } catch { errorMessage = "\(error)" }
    }

    func reload() {
        guard let store else { return }
        do {
            let since = Timestamps.string(from: Date().addingTimeInterval(-Double(days) * 86_400))
            activity = try store.dailyActivity(since: since)
            sessions = try store.sessionTotals().filter { $0.lastTs >= since }
            if let selectedSession, sessions.contains(where: { $0.sessionId == selectedSession }) {
                loadSelection()
            } else {
                selectedSession = sessions.first?.sessionId   // triggers loadSelection
            }
            errorMessage = nil
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func loadSelection() {
        guard let store, let selectedSession else {
            history = nil
            composition = nil
            return
        }
        do {
            history = try store.contextHistory(sessionId: selectedSession)
            composition = try store.composition(sessionId: selectedSession)
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Projects in fixed order by total activity; the long tail folds into
    /// "Other" so the legend stays readable and a colour never gets reused.
    static let maxProjects = 7

    func projectOrder() -> [String] {
        var totals: [String: Int] = [:]
        for row in activity { totals[row.project, default: 0] += metric.value(row) }
        let ordered = totals.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
        if ordered.count <= Self.maxProjects { return ordered }
        return Array(ordered.prefix(Self.maxProjects)) + ["Other"]
    }

    struct Bar: Identifiable {
        var day: Date
        var project: String
        var value: Int
        var id: String { "\(day.timeIntervalSince1970)|\(project)" }
    }

    func bars() -> [Bar] {
        let order = projectOrder()
        let keep = Set(order)
        var merged: [String: Bar] = [:]
        for row in activity {
            guard let day = Self.dayFormatter.date(from: row.day) else { continue }
            let project = keep.contains(row.project) ? row.project : "Other"
            let key = row.day + "|" + project
            var bar = merged[key] ?? Bar(day: day, project: project, value: 0)
            bar.value += metric.value(row)
            merged[key] = bar
        }
        return merged.values.sorted { $0.day != $1.day ? $0.day < $1.day : $0.project < $1.project }
    }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()
}

struct HistoryWindow: View {
    static let id = "history"

    @StateObject private var model = HistoryModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            controls
            ActivityChart(bars: model.bars(), order: model.projectOrder(), metric: model.metric)
                .frame(height: 190)
            HSplitView {
                sessionTable
                    .frame(minWidth: 420)
                detail
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.leading, 12)
            }
            if let errorMessage = model.errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(16)
        .frame(minWidth: 900, minHeight: 600)
        .onAppear { model.reload() }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Range", selection: $model.days) {
                Text("7 days").tag(7)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
                Text("Year").tag(365)
            }
            .pickerStyle(.segmented)
            .frame(width: 300)
            Picker("Metric", selection: $model.metric) {
                ForEach(HistoryModel.Metric.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 320)
            Spacer()
            Button("Refresh") { model.reload() }
        }
        .labelsHidden()
    }

    private var sessionTable: some View {
        Table(model.sessions, selection: $model.selectedSession) {
            TableColumn("Project") { Text($0.project ?? "—").lineLimit(1) }
            TableColumn("Session") { Text($0.sessionId.prefix(8)).monospaced() }.width(78)
            TableColumn("Last active") { row in
                Text(Timestamps.date(from: row.lastTs).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? row.lastTs)
            }.width(140)
            TableColumn("Turns") { Text($0.calls.formatted()).monospacedDigit() }.width(50)
            TableColumn("Last %") { row in
                Text(row.occupancy.map(MenuBarFormatter.percentage) ?? "?").monospacedDigit()
            }.width(52)
            TableColumn("⟲") { Text($0.compactions == 0 ? "" : "\($0.compactions)").monospacedDigit() }.width(28)
            TableColumn("Output") { Text(CompositionView.compact($0.output)).monospacedDigit() }.width(60)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let history = model.history {
            VStack(alignment: .leading, spacing: 12) {
                ContextChart(history: history)
                    .frame(height: 170)
                if let composition = model.composition {
                    CompositionView(composition: composition, startExpanded: true)
                }
                Spacer(minLength: 0)
            }
        } else {
            Text("Select a session")
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Stacked bars per day, coloured by project in a fixed order. One metric at
/// a time: the four token counters differ by orders of magnitude and a sum
/// would just be a cache-read chart.
struct ActivityChart: View {
    let bars: [HistoryModel.Bar]
    let order: [String]
    let metric: HistoryModel.Metric

    var body: some View {
        if bars.isEmpty {
            Text("No activity in this range")
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Chart(bars) { bar in
                BarMark(
                    x: .value("Day", bar.day, unit: .day),
                    y: .value(metric.rawValue, bar.value)
                )
                .foregroundStyle(by: .value("Project", bar.project))
                .cornerRadius(2)
            }
            .chartForegroundStyleScale(domain: order)
            .chartLegend(position: .top, alignment: .leading, spacing: 8)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel {
                        if let v = value.as(Int.self) {
                            Text(CompositionView.compact(v)).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: true)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
#endif

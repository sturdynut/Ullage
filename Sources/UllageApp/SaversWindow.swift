#if os(macOS)
import Charts
import SwiftUI
import UllageCore

/// The Context tools window: each tool over this session, 7 or 30 days.
///
/// A tool's page leads with what it is worth — keeps out, costs, with vs
/// without — because that is the page's question; every figure there carries
/// its grade, so a claim never reads as a measurement and a comparison never
/// as a saving. What the transcripts prove follows, as counts. Every figure
/// is decided in `SaverValue` and `SaverDetail`.
struct SaversPage: View {
    @ObservedObject var model: MenuBarModel
    /// `overview`, or a tool's id.
    @State private var selection: String? = SaversPage.overviewTag
    @State private var details: [SaverDetail] = []
    @State private var summary: SavingsSummary?
    @State private var loading = false
    @AppStorage("saversWindowRange") private var rangeName = SaverRange.session.rawValue

    static let overviewTag = "overview"
    private var range: SaverRange { SaverRange(rawValue: rangeName) ?? .session }
    private var detail: SaverDetail? { details.first { $0.saver.rawValue == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Context tools").font(.title2.weight(.bold))
                    Text("What each tool costs the context, and what it keeps out").foregroundStyle(.secondary)
                }
                Spacer()
                if loading { ProgressView().controlSize(.small).padding(.trailing, 6) }
                Picker("Range", selection: $rangeName) {
                    ForEach(SaverRange.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("This session is the one shown; 7 and 30 days add up every session with a turn in them")
            }
            .padding(24)
            Divider()
            HStack(spacing: 0) {
                List(selection: $selection) {
                    Text("Savings").font(.body.weight(.semibold)).padding(.vertical, 2).tag(Self.overviewTag)
                    Section("Tools") {
                        ForEach(TokenSaver.allCases, id: \.self) { saver in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(saver.displayName).font(.body.weight(.semibold))
                                Text(sidebarStatus(saver))
                                    .font(.caption)
                                    .foregroundStyle(sidebarWarning(saver) ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                            }
                            .padding(.vertical, 2)
                            .tag(saver.rawValue)
                        }
                    }
                }
                .frame(width: 190)
                Divider()
                ScrollView {
                    Group {
                        if selection == Self.overviewTag {
                            OverviewPage(summary: summary, loading: loading) { selection = $0.rawValue }
                        } else if let detail {
                            DetailPage(detail: detail, row: model.savers.rows.first { $0.saver == detail.saver },
                                       switchState: model.saverSwitchState(detail.saver),
                                       installed: model.saverIsInstalled(detail.saver),
                                       onSwitch: { model.setSaver(detail.saver, on: $0) },
                                       onUndo: { model.undoSaver(detail.saver) },
                                       onPlan: { action in
                                           let plan = model.installPlan(detail.saver, action)
                                           if InstallConfirmation.confirm(plan) { model.run(plan) }
                                       })
                            .opacity(loading ? 0.5 : 1)
                        } else if loading {
                            Text("Reading sessions…").foregroundStyle(.secondary)
                        } else {
                            Text("Pick a tool.").foregroundStyle(.secondary)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .task(id: "\(rangeName)|\(model.state.sessionId ?? "")|\(model.savers.rows.map(\.switchState.rawValue))") {
            loading = true
            let loaded = await model.saverPage(range: range)
            guard !Task.isCancelled else { return }
            details = loaded.details
            summary = loaded.summary
            loading = false
        }
    }

    private func sidebarStatus(_ saver: TokenSaver) -> String {
        if let row = model.savers.rows.first(where: { $0.saver == saver }) { return row.status }
        return model.saverIsInstalled(saver) ? "installed" : "not installed"
    }

    private func sidebarWarning(_ saver: TokenSaver) -> Bool {
        model.savers.rows.first(where: { $0.saver == saver })?.statusIsWarning ?? false
    }
}

// MARK: - Cards: what a tool took in next to what it passed on

extension Color {
    /// A palette slot from Core, stepped for the current appearance.
    static func saverSlot(_ slot: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: (dark ? SaverChart.darkPalette : SaverChart.lightPalette)[slot])
        })
    }
}

private extension NSColor {
    convenience init(hex: String) {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        self.init(srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
                  blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }
}

/// One card: a short title, one line, an info button for the rest, and
/// paired bars. Hovering a day puts that day's numbers in the total line.
private struct ChartCard: View {
    let chart: SaverChart
    /// The "after" colour: the tool's slot, or grey for the overall total.
    let color: Color
    var height: CGFloat = 170
    /// Inside another panel: no card of its own.
    var bare = false
    @State private var showMore = false
    @State private var hovered: SaverChart.Bar?

    private var after: Color { color }
    /// Keys like `2026-10-07T09` are hours.
    private var hourly: Bool { chart.bars.first?.key.contains("T") ?? (chart.firstDay?.contains("T") ?? false) }
    private var unit: Calendar.Component { hourly ? .hour : .day }
    private var before: Color { after.opacity(0.35) }
    private var mark: String { chart.approximate ? "≈" : "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(chart.title).font(.headline)
                    Text(chart.what).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showMore.toggle() } label: {
                    Image(systemName: showMore ? "info.circle.fill" : "info.circle").imageScale(.large)
                }
                .buttonStyle(.borderless)
                .help(showMore ? "Hide the details" : "What am I looking at?")
                .accessibilityLabel("About \(chart.title)")
            }
            if showMore {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(chart.more, id: \.self) { Text($0) }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                summary
                Spacer()
                legendItem(chart.beforeLabel, before)
                legendItem(chart.afterLabel, after)
            }
            .font(.callout)
            plot.frame(height: chart.kind == .comparison ? min(height, 120) : height)
        }
        .padding(bare ? 0 : 14)
        .background(RoundedRectangle(cornerRadius: 10).fill(bare ? Color.clear : Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(bare ? Color.clear : Color.secondary.opacity(0.2)))
    }

    @ViewBuilder
    private var summary: some View {
        if let bar = hovered {
            Text("\(bar.label)  \(mark)\(bar.before.formatted()) → \(mark)\(bar.after.formatted())")
                .monospacedDigit()
            Text(SaverChart.changeText(bar.change)
                 + (bar.count.map { " · \($0) \(chart.countUnit ?? "")" } ?? ""))
                .foregroundStyle(.secondary)
        } else {
            Text(chart.totalText).monospacedDigit()
            Text(chart.changeText).foregroundStyle(.secondary)
        }
    }

    private func legendItem(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(label).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var plot: some View {
        if chart.kind == .comparison, let bar = chart.bars.first {
            Chart {
                BarMark(x: .value("Side", chart.beforeLabel), y: .value("Tokens", bar.before), width: .ratio(0.5))
                    .foregroundStyle(before).cornerRadius(4)
                BarMark(x: .value("Side", chart.afterLabel), y: .value("Tokens", bar.after), width: .ratio(0.5))
                    .foregroundStyle(after).cornerRadius(4)
            }
            .chartYAxis { tokenAxis }
        } else {
            Chart(chart.bars) { bar in
                if let day = Self.date(bar.key) {
                    BarMark(x: .value("Day", day, unit: unit), y: .value("Tokens", bar.before))
                        .foregroundStyle(by: .value("Side", chart.beforeLabel))
                        .position(by: .value("Side", chart.beforeLabel))
                        .cornerRadius(3)
                    BarMark(x: .value("Day", day, unit: unit), y: .value("Tokens", bar.after))
                        .foregroundStyle(by: .value("Side", chart.afterLabel))
                        .position(by: .value("Side", chart.afterLabel))
                        .cornerRadius(3)
                }
            }
            .chartForegroundStyleScale([chart.beforeLabel: before, chart.afterLabel: after])
            .chartLegend(.hidden)
            .chartXScale(domain: domain)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                    if hourly {
                        AxisValueLabel(format: .dateTime.hour())
                    } else {
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
            }
            .chartYAxis { tokenAxis }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard let frame = proxy.plotFrame,
                                      let day: Date = proxy.value(atX: location.x - geometry[frame].origin.x) else { return }
                                hovered = chart.bars.min {
                                    abs((Self.date($0.key) ?? .distantPast).timeIntervalSince(day))
                                        < abs((Self.date($1.key) ?? .distantPast).timeIntervalSince(day))
                                }
                            case .ended:
                                hovered = nil
                            }
                        }
                }
            }
        }
    }

    private var tokenAxis: some AxisContent {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
            AxisGridLine().foregroundStyle(.quaternary)
            AxisValueLabel {
                if let tokens = value.as(Int.self) { Text(TokenFormat.compact(tokens)).font(.caption2) }
            }
        }
    }

    /// The axis spans the range, with half a bucket of room at each end.
    private var domain: ClosedRange<Date> {
        let first = chart.firstDay.flatMap(Self.date) ?? chart.bars.first.flatMap { Self.date($0.key) } ?? Date()
        let last = chart.lastDay.flatMap(Self.date) ?? chart.bars.last.flatMap { Self.date($0.key) } ?? first
        let step: TimeInterval = hourly ? 3600 : 86_400
        return first.addingTimeInterval(-step / 2)...last.addingTimeInterval(step * 1.5)
    }

    private static let dayFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let hourFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func date(_ key: String) -> Date? { key.contains("T") ? hourFormat.date(from: key) : dayFormat.date(from: key) }
}

/// What a tool adds to the context, as plain warnings above its cards.
private struct CostLines: View {
    let costs: [ValueFigure]

    var body: some View {
        if !costs.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(costs) { cost in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: cost.warning ? "exclamationmark.triangle.fill" : "minus.circle")
                            .foregroundStyle(cost.warning ? Color.orange : Color.secondary)
                        Text("\(cost.label): ").fontWeight(.medium) + Text(cost.value)
                        Text(cost.detail).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
    }
}

/// A short title, one line, and the rest behind an ⓘ.
private struct InfoHeader<Title: View>: View {
    let title: Title
    let what: String
    let more: [String]
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    title
                    Text(what).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { open.toggle() } label: {
                    Image(systemName: open ? "info.circle.fill" : "info.circle").imageScale(.large)
                }
                .buttonStyle(.borderless)
                .help(open ? "Hide the details" : "What am I looking at?")
            }
            if open {
                VStack(alignment: .leading, spacing: 6) { ForEach(more, id: \.self) { Text($0) } }
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            }
        }
    }
}

/// A panel with the window's card look.
private struct Panel<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.2)))
    }
}

/// How many tokens the tools kept from being sent: in total, over time, by
/// tool and by session. Every figure is decided in `SavingsSummary`.
private struct OverviewPage: View {
    let summary: SavingsSummary?
    let loading: Bool
    let onOpen: (TokenSaver) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            InfoHeader(title: Text("Token savings").font(.title2.weight(.semibold)),
                       what: "Everything your context tools kept from being sent to the model.",
                       more: [
                           "The total adds up the tools' own figures (≈). A call two tools both shortened is counted once.",
                           "Tools judged by comparing sessions with and without them aren't added in.",
                       ])
            if let summary, !summary.isEmpty {
                Group {
                    hero(summary)
                    Panel { ChartCardBody(chart: summary.overallChart()) }
                    Panel { tools(summary) }
                    if !summary.sessions.isEmpty { Panel { sessions(summary) } }
                }
                .opacity(loading ? 0.4 : 1)
            } else if loading {
                Text("Reading sessions…").foregroundStyle(.secondary)
            } else {
                Text("No tool claimed any savings in this range.").foregroundStyle(.secondary)
            }
        }
    }

    private func hero(_ summary: SavingsSummary) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 4) {
                Text("Saved, \(summary.periodText)").foregroundStyle(.secondary)
                Text("≈" + TokenFormat.compact(summary.saved) + " tokens")
                    .font(.system(size: 34, weight: .semibold)).monospacedDigit()
                Text("≈\(TokenFormat.compact(summary.before)) would have been sent · ≈\(TokenFormat.compact(summary.after)) was"
                     + (summary.cut.map { " · −\($0)%" } ?? ""))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(spacing: 24) {
                if summary.range.days != nil, summary.activeBuckets > 0 {
                    stat("≈" + TokenFormat.compact(summary.saved / summary.activeBuckets), summary.hourly ? "per active hour" : "per active day")
                }
                if !summary.sessions.isEmpty {
                    stat("≈" + TokenFormat.compact(summary.saved / summary.sessions.count), "per session")
                    stat("\(summary.sessions.count)", summary.sessions.count == 1 ? "session" : "sessions")
                }
            }
            .font(.callout)
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(value).fontWeight(.semibold).monospacedDigit()
            Text(label).foregroundStyle(.secondary)
        }
    }

    private func tools(_ summary: SavingsSummary) -> some View {
        let widest = max(1, summary.tools.map(\.before).max() ?? 1)
        return VStack(alignment: .leading, spacing: 12) {
            InfoHeader(title: Text("By tool").font(.headline), what: "Each tool's share of the saving.",
                       more: ["Faded is what the tool took in, solid is what it passed on. The number is what it kept back and its share of the total."])
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                ForEach(summary.tools) { tool in
                    GridRow {
                        Button { onOpen(tool.saver) } label: {
                            HStack(spacing: 7) {
                                RoundedRectangle(cornerRadius: 2).fill(Color.saverSlot(SaverChart.colorSlot(tool.saver))).frame(width: 10, height: 10)
                                Text(tool.saver.displayName).fontWeight(.semibold)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Open \(tool.saver.displayName)")
                        pairBars(tool, widest: widest)
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("≈" + TokenFormat.compact(tool.counted)).monospacedDigit()
                            Text([summary.share(tool).map { "\($0)%" }, SaverChart.percentChange(tool.before, tool.after).map { SaverChart.changeText($0) }]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .gridColumnAlignment(.trailing)
                    }
                }
            }
            if summary.overlap > 0 || !summary.compared.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    if summary.overlap > 0 {
                        Text("≈\(TokenFormat.compact(summary.overlap)) claimed by two tools for the same calls is counted once.")
                    }
                    if !summary.compared.isEmpty {
                        Text("Not added in: " + summary.compared.map(\.displayName).joined(separator: ", ") + ".")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func pairBars(_ tool: SavingsSummary.Tool, widest: Int) -> some View {
        let color = Color.saverSlot(SaverChart.colorSlot(tool.saver))
        return GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 3) {
                UnevenRoundedRectangle(bottomTrailingRadius: 3, topTrailingRadius: 3).fill(color.opacity(0.35))
                    .frame(width: max(2, geometry.size.width * CGFloat(tool.before) / CGFloat(widest)), height: 8)
                UnevenRoundedRectangle(bottomTrailingRadius: 3, topTrailingRadius: 3).fill(color)
                    .frame(width: max(2, geometry.size.width * CGFloat(tool.after) / CGFloat(widest)), height: 8)
            }
        }
        .frame(minWidth: 160, maxWidth: .infinity)
        .frame(height: 19)
        .help("≈\(tool.before.formatted()) took in · ≈\(tool.after.formatted()) passed on")
    }

    private func sessions(_ summary: SavingsSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            InfoHeader(title: Text("By session").font(.headline), what: "What each session saved, split by tool.",
                       more: ["Sessions with any saving in this range, largest first."])
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Session"); Text("Turns").gridColumnAlignment(.trailing)
                    ForEach(summary.tools) { Text($0.saver.displayName).gridColumnAlignment(.trailing) }
                    Text("Saved").gridColumnAlignment(.trailing)
                    Text("")
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(summary.sessions.prefix(15)) { session in
                    GridRow {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(session.project ?? String(session.sessionId.prefix(8))).fontWeight(.medium)
                            Text(Self.when(session.firstTs)).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(session.turns.formatted()).monospacedDigit()
                        ForEach(summary.tools) { tool in
                            Text(session.saved[tool.id].map { "≈" + TokenFormat.compact($0) } ?? "—")
                                .monospacedDigit().foregroundStyle(session.saved[tool.id] == nil ? .tertiary : .primary)
                        }
                        Text("≈" + TokenFormat.compact(session.total)).fontWeight(.semibold).monospacedDigit()
                        split(session, tools: summary.tools)
                    }
                    .font(.callout)
                }
            }
        }
    }

    /// How a session's saving splits between tools, in their colours.
    private func split(_ session: SavingsSummary.Session, tools: [SavingsSummary.Tool]) -> some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(tools.filter { (session.saved[$0.id] ?? 0) > 0 }) { tool in
                    Rectangle().fill(Color.saverSlot(SaverChart.colorSlot(tool.saver)))
                        .frame(width: max(2, (geometry.size.width - 2) * CGFloat(session.saved[tool.id] ?? 0) / CGFloat(max(1, session.total))))
                }
            }
        }
        .frame(width: 110, height: 8)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private static func when(_ ts: String?) -> String {
        guard let ts, let date = Timestamps.date(from: ts) else { return "" }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}

/// The overall chart drawn without its own panel, inside the overview's.
private struct ChartCardBody: View {
    let chart: SaverChart
    var body: some View { ChartCard(chart: chart, color: .secondary, bare: true) }
}

private struct DetailPage: View {
    let detail: SaverDetail
    let row: SaverPanel.Row?
    let switchState: SaverSwitchState
    let installed: Bool
    let onSwitch: (Bool) -> Void
    let onUndo: () -> Void
    let onPlan: (SaverAction) -> Void

    private var saver: TokenSaver { detail.saver }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            CostLines(costs: detail.value.costs)
            let charts = SaverChart.charts(for: detail)
            if charts.isEmpty {
                Text(noChartLine).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(charts) { ChartCard(chart: $0, color: .saverSlot(SaverChart.colorSlot(saver))) }
            facts
            switch saver.kind {
            case .outputFilter: ledger
            case .replyStyle: replyStyle
            case .onDemand, .codeSearch, .memory: EmptyView()
            }
        }
    }

    /// Why there is nothing to chart, in this tool's terms.
    private var noChartLine: String {
        if saver.descriptor.claims == nil, saver.kind == .outputFilter || saver.kind == .onDemand {
            return "\(saver.displayName) keeps no count of what it takes in and passes on, so there is nothing to chart."
        }
        return "Nothing to chart in this range yet."
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(saver.displayName).font(.title2.weight(.semibold))
                Text("shrinks \(saver.shrinks)").foregroundStyle(.secondary)
                Spacer()
                if switchState != .notInstalled {
                    Toggle(switchState == .on ? "On" : "Off", isOn: Binding(get: { switchState == .on }, set: onSwitch))
                        .toggleStyle(.switch)
                        .help("Changes Claude Code's user config. \(SaverPanel.nextSessionNote.prefix(1).uppercased() + SaverPanel.nextSessionNote.dropFirst()).")
                } else {
                    Button(installed ? "Set up…" : "Install…") { onPlan(.install) }
                }
                if installed {
                    Button("Uninstall…") { onPlan(.uninstall) }
                }
            }
            if let pending = row?.pending {
                HStack(spacing: 6) {
                    Text(pending).foregroundStyle(Color.accentColor)
                    if row?.canUndo == true { Button("Undo", action: onUndo).buttonStyle(.link) }
                }
                .font(.callout)
            }
        }
    }

    // MARK: What the transcripts show

    private var facts: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What the transcripts show").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 5) {
                fact(detail.range == .session ? "Ran this session" : "Sessions it ran in",
                     detail.range == .session ? (detail.sessionsUsed > 0 ? "yes" : "no")
                        : "\(detail.sessionsUsed) of \(detail.sessions)")
                switch saver.kind {
                case .outputFilter:
                    fact("Hook runs", detail.hookRuns.formatted())
                    fact("Bash commands rewritten", "\(detail.rewrites.formatted()) of \(detail.bashCalls.formatted())")
                    fact("Runs that failed", detail.failedRuns.formatted(), warning: detail.failedRuns > 0)
                    if !saver.descriptor.detect.mcpServer.isEmpty { fact("MCP calls", detail.mcpCalls.formatted()) }
                    if detail.doubleHookedCalls > 0 {
                        fact("Also rewritten by another filter", detail.doubleHookedCalls.formatted(), warning: true)
                    }
                case .replyStyle:
                    fact("Switched on / invoked", detail.invocations.formatted())
                case .onDemand, .codeSearch:
                    if !saver.descriptor.detect.mcpServer.isEmpty {
                        fact("Loaded, never used", detail.range == .session
                             ? (detail.sessionsIdle > 0 ? "yes" : "no") : "\(detail.sessionsIdle) sessions",
                             warning: detail.sessionsIdle > 0)
                    }
                    fact("Calls", (detail.mcpCalls + detail.bashRuns).formatted())
                    if detail.resultTokens > 0 {
                        fact("What they returned", "≈" + TokenFormat.compact(detail.resultTokens) + " tokens")
                    }
                case .memory:
                    fact("Injected at session start", detail.sessionsInjected == 0 ? "nothing"
                         : "≈" + TokenFormat.compact(detail.injectedBytes / 4 / max(1, detail.sessionsInjected)) + " tokens"
                            + (detail.range == .session ? "" : " per session"))
                    fact("Hook runs", detail.hookRuns.formatted())
                    fact("Runs that failed", detail.failedRuns.formatted(), warning: detail.failedRuns > 0)
                    fact("Memory searches", detail.mcpCalls.formatted())
                }
            }
            .font(.callout)
            if let message = detail.failureMessage, detail.failedRuns > 0 {
                Text("Last failure said: " + message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            if detail.sessionsIdle > 0 {
                Text("A loaded MCP server puts its tool definitions in every prompt, used or not.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func fact(_ name: String, _ value: String, warning: Bool = false) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(warning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary))
        }
    }

    // MARK: rtk and Tokenade: their own count

    @ViewBuilder
    private var ledger: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("By command").font(.headline)
            if let ledger = detail.ledger {
                commandTable(ledger)
            } else {
                Text("Nothing in \(saver.displayName)'s log matches these sessions, so there is no claim to show.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func commandTable(_ ledger: LedgerMatch) -> some View {
        let widest = max(1, ledger.groups.map { $0.beforeTokens ?? $0.savedTokens }.max() ?? 1)
        return Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
            GridRow {
                Text("Command"); Text("")
                Text("runs").gridColumnAlignment(.trailing)
                Text("before").gridColumnAlignment(.trailing)
                Text("after").gridColumnAlignment(.trailing)
                Text("saved").gridColumnAlignment(.trailing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            ForEach(ledger.groups.prefix(12), id: \.command) { group in
                GridRow {
                    Text(group.command).font(.system(.callout, design: .monospaced))
                    beforeAfterBar(before: group.beforeTokens ?? group.savedTokens,
                                   after: group.afterTokens ?? 0, widest: widest)
                    Text(group.entries.formatted())
                    Text(group.beforeTokens.map { "≈" + TokenFormat.compact($0) } ?? "—").foregroundStyle(.secondary)
                    Text(group.afterTokens.map { "≈" + TokenFormat.compact($0) } ?? "—")
                    Text("≈" + TokenFormat.compact(group.savedTokens)).fontWeight(.semibold)
                }
                .monospacedDigit()
            }
        }
        .font(.callout)
    }

    /// Before as a faint track, after as the solid part that reached the model.
    private func beforeAfterBar(before: Int, after: Int, widest: Int) -> some View {
        GeometryReader { geometry in
            let full = geometry.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.cyan.opacity(0.25))
                    .frame(width: full * CGFloat(before) / CGFloat(widest))
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.cyan)
                    .frame(width: full * CGFloat(min(after, before)) / CGFloat(widest))
            }
        }
        .frame(minWidth: 160, idealWidth: 260, maxWidth: .infinity)
        .frame(height: 10)
        .help("≈\(before.formatted()) before · ≈\(after.formatted()) reached the model, by \(saver.displayName)'s count")
    }

    // MARK: Reply style: measured, compared

    @ViewBuilder
    private var replyStyle: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This session, reply by reply").font(.headline)
            if detail.comparison == nil {
                Text("Needs \(OutputComparison.minimumTurns) replies with \(saver.displayName) and \(OutputComparison.minimumTurns) without in this folder before there is anything to compare. Output includes thinking, which \(saver.displayName) doesn't shorten.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if detail.turns.isEmpty {
                Text("No replies in this session yet.").foregroundStyle(.secondary)
            } else {
                Chart(detail.turns) { turn in
                    BarMark(x: .value("Turn", turn.turn), y: .value("Output tokens", turn.output))
                        .foregroundStyle(by: .value(saver.displayName, turn.on ? "on" : "off"))
                }
                .chartForegroundStyleScale(["on": Color.green, "off": Color.gray])
                .chartYAxisLabel("output tokens")
                .frame(height: 160)
            }
        }
    }
}
#endif

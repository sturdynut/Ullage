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
    /// The range `details` belong to: the picker changes before they do.
    @State private var loadedRange: SaverRange?
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
                    Text("Overview").font(.body.weight(.semibold)).padding(.vertical, 2).tag(Self.overviewTag)
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
                            OverviewPage(details: details, range: loadedRange, loading: loading) { selection = $0.rawValue }
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
            let loaded = await model.saverDetails(range: range)
            guard !Task.isCancelled else { return }
            details = loaded
            loadedRange = range
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
    let saver: TokenSaver
    var height: CGFloat = 170
    @State private var showMore = false
    @State private var hovered: SaverChart.Bar?

    private var after: Color { .saverSlot(SaverChart.colorSlot(saver)) }
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
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.2)))
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
                    BarMark(x: .value("Day", day, unit: .day), y: .value("Tokens", bar.before))
                        .foregroundStyle(by: .value("Side", chart.beforeLabel))
                        .position(by: .value("Side", chart.beforeLabel))
                        .cornerRadius(3)
                    BarMark(x: .value("Day", day, unit: .day), y: .value("Tokens", bar.after))
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
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
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

    /// The axis spans the range, a day either side of noon so end bars fit.
    private var domain: ClosedRange<Date> {
        let first = chart.firstDay.flatMap(Self.date) ?? chart.bars.first.flatMap { Self.date($0.key) } ?? Date()
        let last = chart.lastDay.flatMap(Self.date) ?? chart.bars.last.flatMap { Self.date($0.key) } ?? first
        return first.addingTimeInterval(-12 * 3600)...last.addingTimeInterval(36 * 3600)
    }

    private static let dayFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func date(_ key: String) -> Date? { dayFormat.date(from: key) }
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

/// Every tool's main card, in the registry's order: never ranked, because a
/// claim and a comparison aren't one scale.
private struct OverviewPage: View {
    let details: [SaverDetail]
    /// The range `details` were read for, which lags the picker while loading.
    let range: SaverRange?
    let loading: Bool
    let onOpen: (TokenSaver) -> Void

    var body: some View {
        let shown = details.filter { !SaverChart.charts(for: $0).isEmpty || !$0.value.costs.isEmpty }
        let quiet = details.filter { SaverChart.charts(for: $0).isEmpty && $0.value.costs.isEmpty }.map(\.saver)
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Token savings").font(.title2.weight(.semibold))
                Text("What each tool took in, and what it passed on" + (range.map { $0 == .session ? ", this session." : ", last \($0.days ?? 30) days." } ?? "."))
                    .foregroundStyle(.secondary)
            }
            if details.isEmpty, loading {
                Text("Reading sessions…").foregroundStyle(.secondary)
            } else if shown.isEmpty, !loading {
                Text("No context tool left a trace in this range.").foregroundStyle(.secondary)
            }
            ForEach(shown, id: \.saver) { detail in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(detail.saver.displayName).font(.headline)
                        Spacer()
                        Button("Details") { onOpen(detail.saver) }.buttonStyle(.link)
                    }
                    CostLines(costs: detail.value.costs)
                    if let chart = SaverChart.charts(for: detail).first {
                        ChartCard(chart: chart, saver: detail.saver, height: 140)
                    }
                }
            }
            .opacity(loading ? 0.4 : 1)
            if !quiet.isEmpty {
                Text("No trace in this range: " + quiet.map(\.displayName).joined(separator: ", "))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
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
            ForEach(charts) { ChartCard(chart: $0, saver: saver) }
            facts
            switch saver.kind {
            case .outputFilter: ledger
            case .replyStyle: replyStyle
            case .onDemand, .codeSearch, .memory: EmptyView()
            }
            Text(saver.savingSource.prefix(1).uppercased() + saver.savingSource.dropFirst() + ".")
                .font(.caption)
                .foregroundStyle(.secondary)
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
            Text("Where \(saver.displayName)'s claim comes from").font(.headline)
            if let ledger = detail.ledger {
                Text("Its own count, by command, largest first. Each bar is the output before \(saver.displayName) shrank it; the solid part reached the model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

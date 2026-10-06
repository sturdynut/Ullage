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

// MARK: - Cost and benefit, shared by the overview and each tool's page

/// One graded figure: the label, the value, a badge saying how it is known.
private struct FigureView: View {
    let figure: ValueFigure
    var large = true

    var body: some View {
        let big = large && !figure.secondary
        VStack(alignment: .leading, spacing: 3) {
            Text(figure.label).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(figure.value)
                    .font(big ? .system(size: 22, weight: .semibold) : .body.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(figure.warning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary))
                EvidenceBadge(evidence: figure.evidence)
            }
            Text(figure.detail)
                .font(.caption)
                .foregroundStyle(figure.warning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// How a figure is known, as a small outlined capsule. Outlined, not filled:
/// the grade qualifies the number, it isn't a status to notice. A claim, or
/// anything built on one, gets a dashed outline: weaker, not louder.
struct EvidenceBadge: View {
    let evidence: Evidence

    private var dashed: Bool { evidence == .claimed || evidence == .derived }

    var body: some View {
        Text(evidence.badge)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.6),
                                            style: StrokeStyle(lineWidth: 0.75, dash: dashed ? [2, 2] : [])))
            .help(evidence.explanation)
    }
}

/// What each badge means, folded away: the tooltips say it too.
private struct EvidenceLegend: View {
    let figures: [ValueFigure]

    var body: some View {
        let legend = Evidence.legend(for: figures)
        if !legend.isEmpty {
            DisclosureGroup("How each figure is known") {
                VStack(alignment: .leading, spacing: 3) { ForEach(legend, id: \.self) { Text($0) } }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// Keeps out on the left, costs on the right, with vs without beneath: all
/// context tokens, but of different grades, so they sit side by side and are
/// never netted.
private struct CostBenefit: View {
    let value: SaverValue

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 28) {
                column("Keeps out", value.benefits, empty: emptyBenefit)
                column("Costs", value.costs, empty: "No cost seen in this range.")
            }
            if !value.comparisons.isEmpty {
                column("With vs without", value.comparisons, empty: "")
            }
            EvidenceLegend(figures: value.all)
        }
    }

    private var emptyBenefit: String {
        let saver = value.saver
        if saver.descriptor.claims == nil, saver.kind == .outputFilter || saver.kind == .onDemand {
            return "\(saver.displayName) keeps no count of what it saves, and Ullage can't see what the output would have been."
        }
        return "Nothing it kept out shows in this range."
    }

    private func column(_ title: String, _ figures: [ValueFigure], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            if figures.isEmpty {
                Text(empty).font(.callout).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(figures) { FigureView(figure: $0) }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// Every tool's figures, in the registry's order. Not ranked: a claim, a
/// comparison and an estimate aren't one scale.
private struct OverviewPage: View {
    let details: [SaverDetail]
    /// The range `details` were read for, which lags the picker while loading.
    let range: SaverRange?
    let loading: Bool
    let onOpen: (TokenSaver) -> Void

    var body: some View {
        let overview = SaverValue.overview(details)
        VStack(alignment: .leading, spacing: 18) {
            Text("Keeps out and costs, by tool").font(.title2.weight(.semibold))
            if let range {
                Text("Over \(range == .session ? "this session" : "the last \(range.days ?? 30) days"). Each figure says how it is known; figures of different kinds are never added together.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if details.isEmpty, loading {
                Text("Reading sessions…").foregroundStyle(.secondary)
            } else if overview.shown.isEmpty, !loading {
                Text("No context tool left a trace in this range.").foregroundStyle(.secondary)
            }
            Grid(alignment: .topLeading, horizontalSpacing: 20, verticalSpacing: 16) {
                if !overview.shown.isEmpty {
                    GridRow {
                        Text("")
                        heading("Keeps out")
                        heading("Costs")
                        heading("With vs without")
                    }
                }
                ForEach(overview.shown) { value in
                    GridRow {
                        Button(value.saver.displayName) { onOpen(value.saver) }
                            .buttonStyle(.link)
                            .font(.body.weight(.semibold))
                        cell(value.benefits.filter { !$0.secondary })
                        cell(value.costs)
                        cell(value.comparisons)
                    }
                    Divider().gridCellColumns(4)
                }
            }
            .opacity(loading ? 0.4 : 1)
            if !overview.quiet.isEmpty {
                Text("No trace in this range: " + overview.quiet.map(\.displayName).joined(separator: ", "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            EvidenceLegend(figures: overview.shown.flatMap(\.all))
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
    }

    /// The first two figures; the tool's page has the rest.
    private func cell(_ figures: [ValueFigure]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if figures.isEmpty { Text("—").foregroundStyle(.tertiary) }
            ForEach(figures.prefix(2)) { FigureView(figure: $0, large: false) }
            if figures.count > 2 {
                Text("+\(figures.count - 2) more").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
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
            VStack(alignment: .leading, spacing: 10) {
                Text("Cost and benefit").font(.headline)
                CostBenefit(value: detail.value)
            }
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

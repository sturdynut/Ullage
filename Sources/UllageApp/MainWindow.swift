#if os(macOS)
import AppKit
import SwiftUI
import UllageCore

/// The pages of the main window, in sidebar order. The popover's rows and
/// the phone page's rows open the same pages.
enum MainPage: String, CaseIterable, Identifiable, Hashable {
    case overview, composition, session, agents, savers, history, limits

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .composition: return "Context composition"
        case .session: return "Session"
        case .agents: return "Agents"
        case .savers: return "Token savers"
        case .history: return "History"
        case .limits: return "Plan limits"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.67percent"
        case .composition: return "square.grid.2x2"
        case .session: return "chart.xyaxis.line"
        case .agents: return "point.3.connected.trianglepath.dotted"
        case .savers: return "slider.horizontal.3"
        case .history: return "chart.bar"
        case .limits: return "clock"
        }
    }
}

/// The one main window: everything the popover summarises, at full size.
/// The popover is the glance; this is where you go to read and to act.
struct MainWindow: View {
    static let id = "main"

    @ObservedObject var model: MenuBarModel

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(MainPage.allCases, selection: $model.windowPage) { page in
                    Label {
                        HStack {
                            Text(page.title)
                            if page == .savers, model.savers.rows.contains(where: \.statusIsWarning) {
                                Spacer()
                                Circle().fill(Color.orange).frame(width: 7, height: 7)
                                    .help("A token saver needs a look")
                            }
                        }
                    } icon: {
                        Image(systemName: page.symbol)
                    }
                    .tag(page)
                }
                HStack {
                    HelpButton()
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            page(model.windowPage)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle(model.state.project ?? "Ullage")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                SessionPicker(model: model)
            }
            ToolbarItem(placement: .primaryAction) {
                if let link = model.sessionLink, let url = URL(string: link.url) {
                    Link(link.label + " ↗", destination: url)
                        .help("Continue this session where you can type into it: /clear, /compact and skills work there")
                }
            }
        }
        .frame(minWidth: 940, minHeight: 600)
        .onAppear { model.refresh() }
    }

    @ViewBuilder
    private func page(_ page: MainPage) -> some View {
        switch page {
        case .overview: OverviewPage(model: model)
        case .composition: CompositionPage(model: model)
        case .session: SessionPage(model: model)
        case .agents: AgentsPage(model: model)
        case .savers: SaversPage(model: model)
        case .history: HistoryWindow()
        case .limits: LimitsPage(model: model)
        }
    }
}

/// Follow the latest session or hold one: the popover's chevron menu, with
/// the session named so the toolbar says what it shows.
struct SessionPicker: View {
    @ObservedObject var model: MenuBarModel

    var body: some View {
        Picker("Session", selection: $model.selection) {
            Text("Latest session").tag(SessionSelection.automatic)
            ForEach(model.projects) { group in
                Section(group.project) {
                    ForEach(group.sessions) { session in
                        Text(SessionPicker.label(for: session)).tag(SessionSelection.pinned(session.sessionId))
                    }
                }
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help(model.selection == .automatic ? "Following the latest session; pick one to hold it" : "Holding this session")
    }

    static func label(for session: SessionSummary) -> String {
        let when = Timestamps.date(from: session.lastTs)
            .map { relative.localizedString(for: $0, relativeTo: Date()) } ?? ""
        let occupancy = session.occupancy.map(MenuBarFormatter.percentage) ?? "?"
        let agents = session.agents == 0 ? "" : " · \(session.agents) agent\(session.agents == 1 ? "" : "s")"
        let path = MenuBarFormatter.displayPath(session.cwd).map { " · \($0)" } ?? ""
        return "\(session.sessionId.prefix(8)) · \(occupancy)\(agents) · \(when)\(path)"
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

// MARK: - Overview

private struct OverviewPage: View {
    @ObservedObject var model: MenuBarModel

    var body: some View {
        let figures = StreamFigures(state: model.state)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Headline(model: model, figures: figures)
                if let history = model.history {
                    PageCard {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("Context per turn").font(.headline)
                                Spacer()
                                if let caption = SessionInfo.chartCaption(windowLimit: figures.windowLimit, history: history) {
                                    Text(caption).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            ContextChart(history: history, showsIdleCaption: false, readoutOverlay: true)
                                .frame(height: 200)
                            RebuildLegend(history: history)
                        }
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], alignment: .leading, spacing: 14) {
                    if let composition = model.composition {
                        SummaryCard(title: "Context composition", page: .composition, model: model) {
                            CompositionBar(composition: composition)
                            ReadoutLine(items: zip(composition.summary, composition.segments).map {
                                ReadoutLine.Item(readout: $0, dot: CompositionView.color(for: $1.name))
                            })
                        }
                    }
                    SummaryCard(title: "Session", page: .session, model: model) {
                        ReadoutLine(SessionInfo.summary(figures, history: model.history))
                    }
                    if let tree = model.agents, !tree.isEmpty {
                        SummaryCard(title: "Agents", page: .agents, model: model) { ReadoutLine(tree.summary) }
                    }
                    if !model.savers.isEmpty {
                        SummaryCard(title: "Token savers", page: .savers, model: model) { ReadoutLine(model.savers.summary) }
                    }
                    if !model.planLimits.isEmpty {
                        SummaryCard(title: "Plan limits", page: .limits, model: model) {
                            ReadoutLine(PlanLimitFormatter.summary(model.planLimits))
                        }
                    }
                    if let composition = model.composition, composition.staleToolResults > 0 || !composition.repeatedReads.isEmpty {
                        SummaryCard(title: "Along for the ride", page: .composition, model: model) {
                            ReadoutLine([
                                Readout("from \(ContextComposition.staleAfterTurns)+ turns ago", "≈" + TokenFormat.compact(composition.staleToolResults)),
                                Readout("repeated reads", "≈" + TokenFormat.compact(composition.repeatedReadTokens)),
                            ])
                        }
                    }
                    SummaryCard(title: "History", page: .history, model: model) {
                        Text("Activity per day, by project, model or effort").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(24)
        }
    }
}

/// The session's name, the room left, and the bar.
private struct Headline: View {
    @ObservedObject var model: MenuBarModel
    let figures: StreamFigures

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.state.project ?? "No sessions ingested yet").font(.title2.weight(.bold))
                    Text([MenuBarFormatter.displayPath(model.state.cwd), model.state.modelLine].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(figures.headroom).font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                        if figures.windowLimit != nil { Text("left").foregroundStyle(.secondary) }
                    }
                    Text([figures.exactLine, figures.usedLine].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            OccupancyBar(occupancy: model.state.status == .empty ? nil : figures.occupancy,
                         peak: model.history.flatMap { history in
                             figures.windowLimit.map { Double(history.peakContextTokens) / Double($0) }
                         })
        }
    }
}

private struct RebuildLegend: View {
    let history: ContextHistory

    var body: some View {
        let caused = history.rebuilds.filter(\.cause.isAvoidable).count
        let other = history.rebuilds.count - caused
        if !history.rebuilds.isEmpty {
            HStack(spacing: 16) {
                if caused > 0 {
                    Label { Text("\(caused) rebuild\(caused == 1 ? "" : "s") you caused") } icon: {
                        HelpGlyph(glyph: .rebuildCaused).frame(width: 14, height: 12)
                    }
                }
                if other > 0 {
                    Label { Text("\(other) you didn't") } icon: {
                        HelpGlyph(glyph: .rebuildOther).frame(width: 14, height: 12)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct CompositionBar: View {
    let composition: ContextComposition

    var body: some View {
        GeometryReader { geometry in
            let total = max(1, composition.segments.reduce(0) { $0 + $1.tokens })
            HStack(spacing: 1.5) {
                ForEach(composition.segments) { segment in
                    Rectangle()
                        .fill(CompositionView.color(for: segment.name))
                        .frame(width: max(0, (geometry.size.width - 4.5) * CGFloat(segment.tokens) / CGFloat(total)))
                }
            }
        }
        .frame(height: 8)
        .clipShape(Capsule())
    }
}

/// A card on the Overview that opens its page.
private struct SummaryCard<Content: View>: View {
    let title: String
    let page: MainPage
    @ObservedObject var model: MenuBarModel
    @ViewBuilder var content: () -> Content

    var body: some View {
        Button { model.windowPage = page } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help("Open " + page.title)
    }
}

/// A plain panel on a page.
struct PageCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
    }
}

private struct PageTitle: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.title2.weight(.bold))
            if let subtitle { Text(subtitle).foregroundStyle(.secondary) }
        }
    }
}

// MARK: - Pages

private struct CompositionPage: View {
    @ObservedObject var model: MenuBarModel

    var body: some View {
        if let composition = model.composition {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PageTitle(title: "Context composition", subtitle: "What's in the context window right now")
                    // The drill-down treemap the popover's ⤢ used to open.
                    CompositionExplorer(model: model)
                        .frame(height: 440)
                    PageCard {
                        CompositionView(composition: composition, expanded: true, showsTitle: false,
                                        showsTreemap: false, onOpen: nil)
                    }
                }
                .padding(24)
            }
        } else {
            EmptyPage(text: "No session to break down yet.")
        }
    }
}

private struct SessionPage: View {
    @ObservedObject var model: MenuBarModel

    var body: some View {
        let figures = StreamFigures(state: model.state)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageTitle(title: "Session", subtitle: model.state.sessionId.map { "Session \($0.prefix(8))" })
                if let history = model.history {
                    PageCard {
                        VStack(alignment: .leading, spacing: 8) {
                            ContextChart(history: history, showsIdleCaption: false, readoutOverlay: true)
                                .frame(height: 240)
                            if let caption = SessionInfo.chartCaption(windowLimit: figures.windowLimit, history: history) {
                                Text(caption).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                PageCard {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                        ForEach(SessionInfo.rows(figures, history: model.history), id: \.label) { row in
                            GridRow {
                                Text(row.label).foregroundStyle(.secondary)
                                Text(row.value).monospacedDigit().textSelection(.enabled)
                            }
                        }
                    }
                }
                if let rebuilds = model.history?.rebuilds, !rebuilds.isEmpty {
                    PageCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Cache rebuilds").font(.headline)
                            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                                GridRow {
                                    Text("").gridColumnAlignment(.center)
                                    Text("Turn").foregroundStyle(.secondary)
                                    Text("Re-cached").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                                    Text("Why").foregroundStyle(.secondary)
                                }
                                .font(.caption)
                                ForEach(rebuilds) { rebuild in
                                    GridRow {
                                        HelpGlyph(glyph: rebuild.cause.isAvoidable ? .rebuildCaused : .rebuildOther)
                                            .frame(width: 14, height: 12)
                                        Text("\(rebuild.turnIndex)").monospacedDigit()
                                        Text(rebuild.cacheWrite.formatted()).monospacedDigit()
                                        Text(rebuild.cause.rawValue + (rebuild.detail.map { " · \($0)" } ?? ""))
                                            .foregroundStyle(rebuild.cause.isAvoidable ? .primary : .secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}

private struct AgentsPage: View {
    @ObservedObject var model: MenuBarModel

    var body: some View {
        if let tree = model.agents, !tree.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PageTitle(title: "Agents", subtitle: "Each has its own context window. Pick one to see its chart and composition.")
                    PageCard {
                        AgentTreeView(
                            tree: tree,
                            mainThreadDetail: [model.state.modelLine, model.history.map { "\($0.points.count) turns" }]
                                .compactMap { $0 }.joined(separator: " · "),
                            mainThreadOccupancy: model.state.occupancy,
                            focus: model.focus,
                            onSelect: { model.focus(on: $0) }
                        )
                    }
                }
                .padding(24)
            }
        } else {
            EmptyPage(text: "This session hasn't started any agents.")
        }
    }
}

private struct LimitsPage: View {
    @ObservedObject var model: MenuBarModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageTitle(title: "Plan limits", subtitle: "How much of your plan's usage is left")
                if model.planLimits.isEmpty {
                    Text("No limits read yet.").foregroundStyle(.secondary)
                } else {
                    PageCard {
                        PlanLimitsView(limits: model.planLimits, usage: model.planLimitUsage, expanded: true)
                    }
                }
                Toggle("Check Claude plan limits", isOn: $model.checksClaudeLimits)
                    .help(PopoverContent.claudeLimitsExplanation)
                if let error = model.claudeLimitsError {
                    Text("Claude: " + error).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
    }
}

private struct EmptyPage: View {
    let text: String
    var body: some View {
        Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif

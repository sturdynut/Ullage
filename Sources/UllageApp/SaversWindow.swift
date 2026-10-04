#if os(macOS)
import Charts
import SwiftUI
import UllageCore

/// The Token savers window: each saver over this session, 7 or 30 days.
///
/// What the transcripts prove comes first, as counts. A saver's claimed
/// saving comes second, marked `≈` and named as its own. caveman's
/// comparison is shown as two measured medians, never as a difference
/// labelled "saved". Every figure is decided in `SaverDetail`.
struct SaversPage: View {
    @ObservedObject var model: MenuBarModel
    @State private var selection: TokenSaver? = .rtk
    @State private var detail: SaverDetail?
    @AppStorage("saversWindowRange") private var rangeName = SaverRange.session.rawValue

    private var range: SaverRange { SaverRange(rawValue: rangeName) ?? .session }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Token savers").font(.title2.weight(.bold))
                    Text("Switches change Claude Code's settings for new sessions").foregroundStyle(.secondary)
                }
                Spacer()
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
                List(TokenSaver.allCases, id: \.self, selection: $selection) { saver in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(saver.displayName).font(.body.weight(.semibold))
                        Text(sidebarStatus(saver))
                            .font(.caption)
                            .foregroundStyle(sidebarWarning(saver) ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    }
                    .padding(.vertical, 2)
                }
                .frame(width: 190)
                Divider()
                ScrollView {
                    if let detail {
                        DetailPage(detail: detail, row: model.savers.rows.first { $0.saver == detail.saver },
                                   switchState: model.saverSwitchState(detail.saver),
                                   installed: model.saverIsInstalled(detail.saver),
                                   onSwitch: { model.setSaver(detail.saver, on: $0) },
                                   onUndo: { model.undoSaver(detail.saver) },
                                   onPlan: { action in
                                       let plan = model.installPlan(detail.saver, action)
                                       if InstallConfirmation.confirm(plan) { model.run(plan) }
                                   })
                            .padding(20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("Pick a token saver.").foregroundStyle(.secondary).padding(40)
                    }
                }
            }
        }
        .task(id: "\(selection?.rawValue ?? "")|\(rangeName)|\(model.state.sessionId ?? "")|\(model.savers.rows.map(\.switchState.rawValue))") {
            guard let selection else { detail = nil; return }
            detail = model.saverDetail(selection, range: range)
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
            facts
            switch saver {
            case .rtk, .tokenade: ledger
            case .caveman: caveman
            case .headroom: EmptyView()
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
                switch saver {
                case .rtk, .tokenade:
                    fact("Hook runs", detail.hookRuns.formatted())
                    fact("Bash commands rewritten", "\(detail.rewrites.formatted()) of \(detail.bashCalls.formatted())")
                    fact("Runs that failed", detail.failedRuns.formatted(), warning: detail.failedRuns > 0)
                    if saver == .tokenade { fact("MCP calls", detail.mcpCalls.formatted()) }
                    if detail.doubleHookedCalls > 0 {
                        fact("Also rewritten by the other", detail.doubleHookedCalls.formatted(), warning: true)
                    }
                case .caveman:
                    fact("Switched on / invoked", detail.invocations.formatted())
                case .headroom:
                    fact("Loaded, never used", detail.range == .session
                         ? (detail.sessionsIdle > 0 ? "yes" : "no") : "\(detail.sessionsIdle) sessions",
                         warning: detail.sessionsIdle > 0)
                    fact("Calls", detail.mcpCalls.formatted())
                }
            }
            .font(.callout)
            if let message = detail.failureMessage, detail.failedRuns > 0 {
                Text("Last failure said: " + message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            if saver == .headroom, detail.sessionsIdle > 0 {
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
            Text("What \(saver.displayName) says it saved").font(.headline)
            if let ledger = detail.ledger {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("≈" + ledger.savedTokens.formatted())
                        .font(.system(size: 28, weight: .semibold))
                        .monospacedDigit()
                    Text("tokens, by its own count, over \(ledger.entries) commands")
                        .foregroundStyle(.secondary)
                    if let reduction = ledger.reduction {
                        Text("· ≈\(Int((reduction * 100).rounded()))% smaller").foregroundStyle(.secondary)
                    }
                }
                commandTable(ledger)
            } else {
                Text("Nothing in \(saver.displayName)'s log matches these sessions, so there is no saving to show.")
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

    // MARK: caveman: measured, compared

    @ViewBuilder
    private var caveman: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Output per reply, with and without").font(.headline)
            if let comparison = detail.comparison {
                HStack(alignment: .firstTextBaseline, spacing: 36) {
                    median(comparison.withMedian, "with caveman",
                           "\(comparison.withTurns.formatted()) replies · \(comparison.withSessions) sessions")
                    median(comparison.withoutMedian, "without",
                           "\(comparison.withoutTurns.formatted()) replies · \(comparison.withoutSessions) sessions")
                }
                Text("Medians of measured output tokens, main thread, \(detail.comparisonFolder.map(Self.shortPath) ?? "this folder"), last \(detail.range.days ?? 30) days. Different replies did different work, so this is a comparison, not a saving. Output includes thinking, which caveman doesn't shorten.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Needs \(OutputComparison.minimumTurns) replies with caveman and \(OutputComparison.minimumTurns) without in this folder before there is anything to compare.")
                    .foregroundStyle(.secondary)
            }
            if !detail.turns.isEmpty {
                Text("This session, reply by reply").font(.subheadline.weight(.semibold)).padding(.top, 6)
                Chart(detail.turns) { turn in
                    BarMark(x: .value("Turn", turn.turn), y: .value("Output tokens", turn.output))
                        .foregroundStyle(by: .value("caveman", turn.on ? "on" : "off"))
                }
                .chartForegroundStyleScale(["on": Color.green, "off": Color.gray])
                .chartYAxisLabel("output tokens")
                .frame(height: 160)
            }
        }
    }

    private func median(_ value: Int, _ label: String, _ sample: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value.formatted()).font(.system(size: 28, weight: .semibold)).monospacedDigit()
                Text("tokens/reply \(label)").foregroundStyle(.secondary)
            }
            Text(sample).font(.caption).foregroundStyle(.tertiary)
        }
    }

    private static func shortPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
#endif

import Foundation

/// The popover's "Token savers" section, decided here so SwiftUI only draws it.
///
/// A saver gets a row when it is installed in Claude Code's user config (so it
/// can be switched) or left a trace in the session shown. The headline figure
/// is whatever is most honest for that saver: a ledger claim marked `≈`, a
/// measured comparison, a count, or the plain fact that it is not running.
public struct SaverPanel: Equatable {
    public enum Tone: Equatable {
        case normal
        /// Worth a second look: idle, broken, or overlapping.
        case warning
    }

    public struct Row: Equatable, Identifiable {
        public var saver: TokenSaver
        public var id: String { saver.rawValue }
        public var switchState: SaverSwitchState
        /// Right-aligned headline, e.g. `≈18k`, `214`, `idle`.
        public var metric: String
        /// The word under or beside it: `kept out`, `out/turn`.
        public var metricCaption: String
        public var metricTone: Tone
        /// What happened, in this session.
        public var line: String
        /// Only for exceptions — why it is broken or idle. Where a figure comes
        /// from is said once, in `legend`, not under every row.
        public var note: String?
        /// On this machine, so it can be uninstalled.
        public var isInstalled = false
        /// What has changed since this session loaded its config, e.g. "Off
        /// from the next session". The switch shows config *now*; the figures
        /// show *this session*; this line is what reconciles the two.
        public var pending: String?
        /// The pending change came from a switch here and can be put back.
        public var canUndo = false
        /// The one-word state for the collapsed line.
        public var status: String = ""
        public var statusIsWarning = false
        public var canSwitch: Bool { switchState != .notInstalled }
    }

    public var rows: [Row]
    /// Shown above the rows when two savers are working against each other.
    public var warning: String?
    /// Not on this machine: offered for the user to install, never installed
    /// on their behalf.
    public var installable: [TokenSaver]
    /// Installs or uninstalls started from here that have not shown up yet.
    public var pendingInstalls: [String]
    /// Where the figures shown come from, one line per kind, said once.
    public var legend: [String] = []

    public init(rows: [Row] = [], warning: String? = nil, installable: [TokenSaver] = [], pendingInstalls: [String] = []) {
        self.rows = rows
        self.warning = warning
        self.installable = installable
        self.pendingInstalls = pendingInstalls
    }

    /// The collapsed line: problems first, then how many are on and off. The
    /// figures live in the expanded rows — they are in different units and
    /// must never sit side by side as if comparable.
    public var summary: [Readout] {
        guard !rows.isEmpty else { return [Readout("None installed")] }
        // Savers with the same problem share one item: "rtk, Tokenade not running".
        var items: [Readout] = []
        for status in rows.filter(\.statusIsWarning).map(\.status).uniqued() {
            let names = rows.filter { $0.statusIsWarning && $0.status == status }.map(\.saver.displayName)
            items.append(Readout(names.joined(separator: ", "), status, warning: true))
        }
        // Two savers can only overlap if both are actually rewriting; a broken
        // one already has its own, more urgent item.
        let filtersBroken = rows.contains { $0.saver.kind == .outputFilter && $0.statusIsWarning }
        if warning != nil, !filtersBroken {
            let names = rows.filter { $0.saver.kind == .outputFilter && $0.switchState == .on }.map(\.saver.displayName)
            items.append(Readout((names.count >= 2 ? names.joined(separator: " + ") : "filters") + " overlap", warning: true))
        }
        let calm = rows.filter { !$0.statusIsWarning }
        let on = calm.filter { $0.switchState == .on }.count
        let off = calm.filter { $0.switchState == .off }.count
        let unset = calm.filter { $0.switchState == .notInstalled }.count
        if on > 0 { items.append(Readout("\(on) on")) }
        if off > 0 { items.append(Readout("\(off) off")) }
        if unset > 0 { items.append(Readout("\(unset) not set up")) }
        return items
    }

    public var isEmpty: Bool { rows.isEmpty && installable.isEmpty }

    public static let nextSessionNote = "applies to sessions started from now"
    public static let offNextSession = "Off from the next session"
    public static let onNextSession = "On from the next session"

    static func status(state: SaverSwitchState, usage: SaverUsage) -> String {
        if usage.broken { return "not running" }
        if usage.idle { return "idle" }
        switch state {
        case .on: return "on"
        case .off: return "off"
        case .notInstalled: return "not set up"
        }
    }

    /// `comparisons`: with/without output for each reply-style tool that has
    /// enough turns to compare (caveman, or any described as `replyStyle`).
    public static func build(
        report: SaverSessionReport?,
        states: [TokenSaver: SaverSwitchState],
        comparisons: [TokenSaver: OutputComparison] = [:],
        installed: Set<TokenSaver> = [],
        pending: [TokenSaver: String] = [:],
        undoable: Set<TokenSaver> = []
    ) -> SaverPanel {
        var rows: [Row] = []
        var installable: [TokenSaver] = []
        for saver in TokenSaver.allCases {
            let state = states[saver] ?? .notInstalled
            let usage = report?.usage(saver) ?? SaverUsage(saver: saver)
            let onMachine = installed.contains(saver) || state != .notInstalled
            if !onMachine { installable.append(saver) }
            guard onMachine || usage.ran || usage.idle else { continue }
            var row = row(saver, state: state, usage: usage, bashCalls: report?.bashCalls ?? 0,
                          comparison: comparisons[saver])
            row.isInstalled = onMachine
            if onMachine, state == .notInstalled, !usage.broken, !usage.ran {
                row.line = "Installed, not set up in Claude Code"
            }
            // A saver this session loaded but that is switched off now: what
            // the row says is true of this session, and stops from the next.
            row.pending = pending[saver] ?? (state == .off && (usage.ran || usage.idle) ? offNextSession : nil)
            row.canUndo = undoable.contains(saver) && pending[saver] != nil
            row.status = status(state: state, usage: usage)
            row.statusIsWarning = usage.broken || usage.idle
            rows.append(row)
        }
        // Two output filters on the same Bash call each claim the whole saving.
        var warning: String?
        let filtersOn = TokenSaver.allCases.filter { $0.kind == .outputFilter && states[$0] == .on }
        if let doubled = report?.doubleHookedCalls, doubled > 0 {
            let names = report?.overlapping.map(\.displayName) ?? []
            warning = "\(names.joined(separator: " and ")) both rewrote \(doubled) Bash call\(doubled == 1 ? "" : "s"). Each claims the whole saving on those, so the two can't be added. Keep one on."
        } else if filtersOn.count >= 2 {
            warning = "\(filtersOn.map(\.displayName).joined(separator: " and ")) are all switched on and all rewrite Bash. Keep one on."
        }
        var legend: [String] = []
        let claims = rows.filter { $0.metric.hasPrefix("≈") && $0.saver.descriptor.claims != nil }
            .compactMap { $0.saver.descriptor.claims?.how }
        if !claims.isEmpty {
            legend.append("≈ saved is the tool's own count, which Ullage can't check (\(claims.joined(separator: "; "))).")
        }
        let compared = rows.filter { $0.saver.kind == .replyStyle && $0.metricCaption == "tokens/reply" }.map(\.saver.displayName)
        if !compared.isEmpty {
            legend.append("\(compared.joined(separator: " and "))'s figure compares measured replies with it on and off. Different work, so not a saving.")
        }
        if rows.contains(where: { $0.saver.kind == .memory && $0.metricCaption == "injected" }) {
            legend.append("≈ injected is the size of what a memory tool added at session start, estimated from its length.")
        }
        let pendingInstalls = TokenSaver.allCases
            .filter { saver in !rows.contains { $0.saver == saver } }
            .compactMap { pending[$0] }
        var panel = SaverPanel(rows: rows, warning: warning, installable: installable, pendingInstalls: pendingInstalls)
        panel.legend = legend
        return panel
    }

    /// What a row says, decided by what kind of tool it is — never by which.
    static func row(
        _ saver: TokenSaver, state: SaverSwitchState, usage: SaverUsage, bashCalls: Int, comparison: OutputComparison?
    ) -> Row {
        var row = Row(saver: saver, switchState: state, metric: "—", metricCaption: "",
                      metricTone: .normal, line: "", note: nil)
        let offLine = state == .off ? "Off" : "On"

        if usage.broken {
            row.metric = "not running"
            row.metricTone = .warning
            row.line = "Hook ran \(usage.hookRuns)× and failed every time"
            row.note = usage.failureMessage.map(firstSentence)
            return row
        }

        func idle() {
            row.metric = "idle"
            row.metricTone = .warning
            row.line = "Loaded but never used this session"
            row.note = "Its tool definitions still ride in every prompt"
        }

        switch saver.kind {
        case .outputFilter:
            if let ledger = usage.ledger {
                row.metric = "≈" + TokenFormat.compact(ledger.savedTokens)
                row.metricCaption = "saved"
                var facts: [String] = []
                if usage.rewrites > 0, bashCalls > 0 {
                    facts.append("\(usage.rewrites) of \(bashCalls) Bash calls rewritten")
                } else {
                    facts.append("\(ledger.entries) commands")
                }
                if let reduction = ledger.reduction { facts.append("≈\(Int((reduction * 100).rounded()))% smaller") }
                row.line = facts.joined(separator: " · ")
            } else if usage.ran {
                row.metric = "\(usage.rewrites)"
                row.metricCaption = usage.rewrites == 1 ? "rewrite" : "rewrites"
                row.line = "Hook ran \(usage.hookRuns)× · nothing in its log to count savings from"
            } else if usage.idle {
                idle()
            } else {
                row.line = "\(offLine) · no runs this session"
            }
        case .replyStyle:
            if let comparison {
                row.metric = "\(comparison.withMedian)"
                row.metricCaption = "tokens/reply"
                row.line = "\(comparison.withoutMedian) without it · this folder, last 30 days"
            } else {
                row.metric = usage.ran ? "on" : "—"
                row.line = usage.ran
                    ? "Ran this session · \(OutputComparison.minimumTurns) turns each way to compare"
                    : "\(offLine) · not used this session"
            }
        case .onDemand:
            if usage.mcpCalls > 0 {
                row.metric = "\(usage.mcpCalls)"
                row.metricCaption = usage.mcpCalls == 1 ? "call" : "calls"
                row.line = "Used this session · it keeps no record of savings"
            } else if usage.idle {
                idle()
            } else {
                row.line = "\(offLine) · not loaded in this session"
            }
        case .codeSearch:
            let lookups = usage.mcpCalls + usage.bashRuns
            if lookups > 0 {
                row.metric = "\(lookups)"
                row.metricCaption = lookups == 1 ? "lookup" : "lookups"
                row.line = usage.mcpResultTokens > 0
                    ? "Returned ≈\(TokenFormat.compact(usage.mcpResultTokens)) instead of whole files"
                    : "Used this session"
            } else if usage.idle {
                idle()
            } else {
                row.line = "\(offLine) · not used this session"
            }
        case .memory:
            if usage.injectedBytes > 0 {
                row.metric = "≈" + TokenFormat.compact(usage.injectedBytes / 4)
                row.metricCaption = "injected"
                row.line = "Added at session start" + (usage.mcpCalls > 0 ? " · \(usage.mcpCalls) memory searches" : "")
                row.note = "Past-session context, sent with every turn after"
            } else if usage.ran {
                row.metric = "on"
                row.line = "Ran this session"
            } else if usage.idle {
                idle()
            } else {
                row.line = "\(offLine) · not used this session"
            }
        }
        return row
    }

    private static func firstSentence(_ text: String) -> String {
        let cleaned = text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"^\[[^\]]+\]\s*"#, with: "", options: .regularExpression)
        if let end = cleaned.range(of: ". ") { return String(cleaned[..<end.lowerBound]) }
        return String(cleaned.prefix(90))
    }
}

private extension Array where Element: Hashable {
    /// First occurrence of each, in order.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

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
        /// Where the headline comes from — a claim, a comparison, a count.
        public var note: String?
        public var canSwitch: Bool { switchState != .notInstalled }
    }

    public var rows: [Row]
    /// Shown above the rows when two savers are working against each other.
    public var warning: String?

    public init(rows: [Row] = [], warning: String? = nil) {
        self.rows = rows
        self.warning = warning
    }

    public var isEmpty: Bool { rows.isEmpty }

    public static let nextSessionNote = "applies to sessions started from now"

    public static func build(
        report: SaverSessionReport?,
        states: [TokenSaver: SaverSwitchState],
        comparison: OutputComparison?
    ) -> SaverPanel {
        var rows: [Row] = []
        for saver in TokenSaver.allCases {
            let state = states[saver] ?? .notInstalled
            let usage = report?.usage(saver) ?? SaverUsage(saver: saver)
            guard state != .notInstalled || usage.ran || usage.idle else { continue }
            rows.append(row(saver, state: state, usage: usage, bashCalls: report?.bashCalls ?? 0,
                            comparison: saver == .caveman ? comparison : nil))
        }
        var warning: String?
        if let doubled = report?.doubleHookedCalls, doubled > 0 {
            warning = "rtk and Tokenade both rewrote \(doubled) Bash call\(doubled == 1 ? "" : "s"). Each claims the whole saving on those, so the two can't be added. Keep one on."
        } else if states[.rtk] == .on, states[.tokenade] == .on {
            warning = "rtk and Tokenade are both switched on and both rewrite Bash. Keep one on."
        }
        return SaverPanel(rows: rows, warning: warning)
    }

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

        switch saver {
        case .rtk, .tokenade:
            if let ledger = usage.ledger {
                row.metric = "≈" + TokenFormat.compact(ledger.savedTokens)
                row.metricCaption = "kept out"
                var facts: [String] = []
                if usage.rewrites > 0, bashCalls > 0 {
                    facts.append("\(usage.rewrites) of \(bashCalls) Bash calls rewritten")
                } else {
                    facts.append("\(ledger.entries) commands")
                }
                if let reduction = ledger.reduction { facts.append("≈\(Int((reduction * 100).rounded()))% smaller") }
                row.line = facts.joined(separator: " · ")
                row.note = saver.savingSource
            } else if usage.ran {
                row.metric = "\(usage.rewrites)"
                row.metricCaption = "rewritten"
                row.line = "Hook ran \(usage.hookRuns)× this session"
                row.note = "No ledger entries matched, so no saving to claim"
            } else {
                row.line = "\(offLine) · no runs this session"
            }
        case .caveman:
            if let comparison {
                row.metric = "\(comparison.withMedian)"
                row.metricCaption = "out/turn"
                row.line = "\(comparison.withoutMedian) without it, this directory, 30 days"
                row.note = "Measured · a comparison, not a saving"
            } else {
                row.metric = usage.ran ? "on" : "—"
                row.line = usage.ran
                    ? "Ran this session · \(OutputComparison.minimumTurns) turns each way to compare"
                    : "\(offLine) · not used this session"
            }
        case .headroom:
            if usage.mcpCalls > 0 {
                row.metric = "\(usage.mcpCalls)"
                row.metricCaption = usage.mcpCalls == 1 ? "call" : "calls"
                row.line = "Called this session; savings not recorded"
            } else if usage.idle {
                row.metric = "idle"
                row.metricCaption = "0 calls"
                row.metricTone = .warning
                row.line = "Loaded, never called this session"
                row.note = "Its tool definitions ride in every prompt"
            } else {
                row.line = "\(offLine) · not loaded in this session"
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

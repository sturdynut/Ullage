import Foundation

/// One card on a context tool's page: a short title, one line of what it
/// is, the longer explanation behind an info button, and paired bars —
/// what the tool took in next to what it passed on, so the gap is the
/// reduction.
///
/// Daily cards pair a tool's own before and after per day (its claim, so
/// every value is approximate). Comparison cards pair sessions without the
/// tool and sessions with it: two medians, never a before and after of the
/// same work. Built here from `SaverDetail`, by the evidence a tool has —
/// never by which tool it is — and drawn the same by the window, the phone
/// and the CLI.
public struct SaverChart: Equatable, Identifiable {
    public enum Kind: String, Equatable, Codable {
        case daily
        case comparison
    }

    public struct Bar: Equatable, Identifiable {
        /// `2026-10-04` for a day; the metric for a comparison.
        public var key: String
        /// `Oct 4`, or empty for a comparison's single pair.
        public var label: String
        public var before: Int
        public var after: Int
        /// Commands or requests behind a day, when known.
        public var count: Int?
        public var id: String { key }

        /// Rounded percent from before to after: −47 is 47% smaller.
        public var change: Int? { SaverChart.percentChange(before, after) }
    }

    public var id: String
    public var kind: Kind
    /// "Bash output": short, because it sits under the tool's own name.
    public var title: String
    /// One line: "Bash output, before and after rtk shortened it."
    public var what: String
    /// Behind the info button, a sentence or two each.
    public var more: [String]
    /// "Before" / "After", or "Without" / "With".
    public var beforeLabel: String
    public var afterLabel: String
    /// "commands", "requests": what `Bar.count` counts.
    public var countUnit: String?
    public var bars: [Bar]
    /// Every value is an estimate or a claim, so it carries `≈`.
    public var approximate: Bool
    /// The days the axis spans, so a quiet stretch shows as empty. Nil for a
    /// comparison.
    public var firstDay: String?
    public var lastDay: String?

    public var before: Int { bars.reduce(0) { $0 + $1.before } }
    public var after: Int { bars.reduce(0) { $0 + $1.after } }
    public var change: Int? { Self.percentChange(before, after) }

    /// `≈570k → ≈302k`, or `53k without → 53k with`.
    public var totalText: String {
        let mark = approximate ? "≈" : ""
        if kind == .comparison {
            return "\(mark)\(TokenFormat.compact(before)) \(beforeLabel.lowercased()) → \(mark)\(TokenFormat.compact(after)) \(afterLabel.lowercased())"
        }
        return "\(mark)\(TokenFormat.compact(before)) → \(mark)\(TokenFormat.compact(after))"
    }

    /// `−47%`, `+5%`, or `no change`.
    public var changeText: String { Self.changeText(change) }

    /// Rounded percent from before to after: −47 is 47% smaller.
    public static func percentChange(_ before: Int, _ after: Int) -> Int? {
        guard before > 0 else { return nil }
        return Int((Double(after - before) / Double(before) * 100).rounded())
    }

    public static func changeText(_ change: Int?) -> String {
        guard let change else { return "" }
        if change == 0 { return "no change" }
        return change < 0 ? "−\(-change)%" : "+\(change)%"
    }
}

extension SaverChart {
    /// Every card a tool has in a range: its output per day, the same over
    /// later prompts, then each comparison.
    public static func charts(for detail: SaverDetail, now: Date = Date(), calendar: Calendar = .current) -> [SaverChart] {
        let days = DayKeys(calendar: calendar)
        var charts: [SaverChart] = []
        if let output = outputChart(detail, now: now, days: days) { charts.append(output) }
        if let prompts = promptsChart(detail, now: now, days: days) { charts.append(prompts) }
        charts += detail.comparisons.map { comparisonChart($0, saver: detail.saver) }
        return charts
    }

    /// The first clause of what a tool shrinks, capitalised: "Bash output".
    static func subject(_ saver: TokenSaver) -> String {
        let first = saver.shrinks.split(separator: ",").first.map(String.init) ?? saver.shrinks
        return first.prefix(1).uppercased() + first.dropFirst()
    }

    static func outputChart(_ detail: SaverDetail, now: Date, days: DayKeys) -> SaverChart? {
        let saver = detail.saver, name = saver.displayName
        guard let claims = saver.descriptor.claims else { return nil }
        let known = detail.ledgerEntries.filter { $0.beforeTokens != nil && $0.afterTokens != nil }
        guard !known.isEmpty else { return nil }
        let perRequest = claims.perRequest == true
        let bars = daily(known, days: days) { ($0.beforeTokens ?? 0, $0.afterTokens ?? 0) }

        var more = ["\(name)'s own numbers, from its log. \(claims.how)."]
        if perRequest {
            more.append("After is what the proxy sent on; before adds what \(name) says it removed. Each request sends the whole conversation again, so repeats are already counted.")
        } else if let carried = detail.carried, carried.checkedCalls >= CarriedClaim.minimumChecks, let agreement = carried.agreement {
            more.append(agreement >= 0.9
                ? "Partly checked: where a call ran a single command, \(name)'s \"after\" matched what reached the model on \(carried.checkedCalls) calls."
                : "Doesn't match: where a call ran a single command, \(name) says ≈\(TokenFormat.compact(carried.claimedAfter)) reached the model, but the transcript shows ≈\(TokenFormat.compact(carried.seenAfter)), on \(carried.checkedCalls) calls.")
        } else {
            more.append("Ullage only sees the output after \(name) shortened it, so the \"before\" is \(name)'s word.")
        }
        let missing = detail.ledgerEntries.count - known.count
        if missing > 0 { more.append("\(missing) without a before and after \(missing == 1 ? "is" : "are") left out.") }
        if bars.last?.key == days.key(now) { more.append("Today is so far.") }

        return SaverChart(
            id: saver.rawValue + ".output", kind: .daily,
            title: perRequest ? "Requests" : subject(saver),
            what: perRequest ? "Requests to the model, before and after \(name) compressed them."
                : "\(subject(saver)), before and after \(name) shortened it.",
            more: more, beforeLabel: "Before", afterLabel: "After", countUnit: perRequest ? "requests" : "commands",
            bars: bars, approximate: true,
            firstDay: firstDay(detail.range, bars: bars, now: now, days: days), lastDay: lastDay(detail.range, bars: bars, now: now, days: days)
        )
    }

    static func promptsChart(_ detail: SaverDetail, now: Date, days: DayKeys) -> SaverChart? {
        let saver = detail.saver, name = saver.displayName
        guard saver.descriptor.claims?.perRequest != true else { return nil }
        let placed = detail.ledgerEntries.filter {
            $0.beforeTokens != nil && $0.afterTokens != nil && $0.toolUseId.flatMap { detail.prompts[$0] } != nil
        }
        guard !placed.isEmpty else { return nil }
        let bars = daily(placed, days: days) { entry in
            let prompts = entry.toolUseId.flatMap { detail.prompts[$0] } ?? 0
            return ((entry.beforeTokens ?? 0) * prompts, (entry.afterTokens ?? 0) * prompts)
        }
        guard bars.contains(where: { $0.before > 0 }) else { return nil }
        var more = [
            "A result stays in the conversation and is sent again with every turn until the context is compacted. Ullage counts those turns.",
            "Before and after are \(name)'s figures × that count. Most of these are cheap cache reads: tokens sent, not how full the window is.",
        ]
        let left = detail.ledgerEntries.count - placed.count
        if left > 0 { more.append("\(left) command\(left == 1 ? "" : "s") Ullage couldn't match to a call \(left == 1 ? "is" : "are") left out.") }
        if bars.last?.key == days.key(now) { more.append("Today is so far.") }
        return SaverChart(
            id: saver.rawValue + ".prompts", kind: .daily,
            title: "Later prompts",
            what: "The same output, counted in every prompt it stayed in.",
            more: more, beforeLabel: "Before", afterLabel: "After", countUnit: "commands",
            bars: bars, approximate: true,
            firstDay: firstDay(detail.range, bars: bars, now: now, days: days), lastDay: lastDay(detail.range, bars: bars, now: now, days: days)
        )
    }

    static func comparisonChart(_ comparison: SaverComparison, saver: TokenSaver) -> SaverChart {
        let name = saver.displayName
        let what: String
        switch comparison.metric {
        case .firstPrompt: what = "A session's first prompt, without and with \(name)."
        case .outputPerReply: what = "Reply length, without and with \(name)."
        case .readsPerSession: what = "File reads per session, without and with \(name)."
        case .exploreBeforeEdit: what = "Exploring before the first edit, without and with \(name)."
        }
        let sample = comparison.metric.sample
        var more = [
            "Medians of \(comparison.without.count) \(sample) without \(name) and \(comparison.with.count) with, from \(comparison.scope.rawValue), over the days both had sessions.",
            "Different sessions did different work, so the gap hints at an effect but doesn't measure it.",
        ]
        if min(comparison.with.count, comparison.without.count) < SaverComparison.fewBelow { more.append("Few sessions, so read it loosely.") }
        let bar = Bar(key: comparison.metric.rawValue, label: "", before: comparison.without.median, after: comparison.with.median, count: nil)
        if let change = bar.change, abs(change) <= 5 { more.append("Within 5%: no clear difference.") }
        return SaverChart(
            id: saver.rawValue + "." + comparison.metric.rawValue, kind: .comparison,
            title: comparison.metric.title, what: what, more: more,
            beforeLabel: "Without", afterLabel: "With", countUnit: nil, bars: [bar],
            approximate: comparison.metric.evidenceOfSides == .estimated, firstDay: nil, lastDay: nil
        )
    }

    /// Entries summed per local day, oldest first, with each day's count.
    static func daily(_ entries: [LedgerEntry], days: DayKeys, value: (LedgerEntry) -> (Int, Int)) -> [Bar] {
        var byDay: [String: (before: Int, after: Int, count: Int, date: Date)] = [:]
        for entry in entries {
            let key = days.key(entry.ts)
            let (before, after) = value(entry)
            let current = byDay[key] ?? (0, 0, 0, entry.ts)
            byDay[key] = (current.before + before, current.after + after, current.count + 1, current.date)
        }
        return byDay.keys.sorted().map { key in
            let day = byDay[key]!
            return Bar(key: key, label: days.label(day.date), before: day.before, after: day.after, count: day.count)
        }
    }

    /// A range's axis runs over the whole range; a session's over its bars.
    static func firstDay(_ range: SaverRange, bars: [Bar], now: Date, days: DayKeys) -> String? {
        guard let count = range.days else { return bars.first?.key }
        return days.key(now.addingTimeInterval(-Double(count - 1) * 86_400))
    }

    static func lastDay(_ range: SaverRange, bars: [Bar], now: Date, days: DayKeys) -> String? {
        range.days == nil ? bars.last?.key : days.key(now)
    }
}

/// Local calendar days as sortable keys and short labels.
struct DayKeys {
    let calendar: Calendar
    private let formatter: DateFormatter

    init(calendar: Calendar) {
        self.calendar = calendar
        formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
    }

    func key(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    func label(_ date: Date) -> String { formatter.string(from: date) }
}

extension SaverChart {
    /// A tool's colour follows the tool, never its rank: its place in the
    /// registry picks a slot in a fixed, colour-blind-checked order (blue,
    /// orange, aqua, yellow, magenta, green, violet, red), stepped for each
    /// theme. "After" is the slot; "before" is the same hue, faded.
    public static let lightPalette = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#4a3aa7", "#e34948"]
    public static let darkPalette = ["#3987e5", "#d95926", "#199e70", "#c98500", "#d55181", "#008300", "#9085e9", "#e66767"]

    public static func colorSlot(_ saver: TokenSaver) -> Int {
        (TokenSaver.allCases.firstIndex(of: saver) ?? 0) % lightPalette.count
    }
}

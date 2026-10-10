import Foundation

/// `dashboard.json`: the usage dashboard as the phone page draws it. Every
/// figure is decided and formatted here, from the same `UsageDashboard` the
/// Mac window and `ullage dashboard` use, so the page only lays it out.
public struct ServeDashboard: Encodable {
    public struct Choice: Encodable, Equatable {
        public var id: String
        public var label: String
    }

    public struct Options: Encodable {
        var vendor: String
        var counter: String
        var days: String
        var gap: String
        var vendors: [Choice]
        var counters: [Choice]
        var ranges: [Choice]
        var gaps: [Choice]
    }

    public struct Tile: Encodable, Equatable {
        var title: String
        var value: String
        var detail: String
        var change: String?
        /// up, down or flat.
        var direction: String?
        var caption: String?
        var why: String?
    }

    public struct Week: Encodable, Equatable {
        var label: String
        var total: Int
        var sessions: Int
        var active: String
        var perHour: Double?
    }

    public struct Session: Encodable, Equatable {
        var id: String
        var project: String
        var line: String
        var value: String
        var share: Double
        var peak: String
        var hot: Bool
    }

    public struct Ranking: Encodable {
        var title: String
        var highest: [Session]
        var lowest: [Session]
    }

    public struct Band: Encodable, Equatable {
        var label: String
        var sessions: Int
    }

    public struct Fact: Encodable, Equatable {
        var label: String
        var value: String
    }

    public struct Health: Encodable {
        var facts: [Fact]
        var hotShare: Double?
        var hotText: String?
    }

    public struct Row: Encodable, Equatable {
        var name: String
        var value: String
        var line: String
        var share: Double
    }

    var options: Options
    var measured: Bool
    var keyTiles: [Tile]
    var moreTiles: [Tile]
    var weeksTitle: String
    var rateTitle: String?
    var weeks: [Week]
    /// Keyed by `UsageDashboard.Ranking`: the page switches between them
    /// without asking again.
    var rankings: [String: Ranking]
    var eligible: Int
    var sizeTitle: String
    var sizeBands: [Band]
    var health: Health?
    var projects: [Row]
    var models: [Row]
    var tools: [Row]
    var footnote: String

    public static func options(from query: [String: String]) -> UsageDashboard.Options {
        var o = UsageDashboard.Options()
        if let v = query["vendor"], UsageDashboard.Options.vendors.contains(v) { o.vendor = v }
        if let c = query["counter"].flatMap(UsageCounter.init(rawValue:)) { o.counter = c }
        if let d = query["days"] {
            if d == "all" || d == "0" { o.days = nil } else if let n = Int(d), (1...3650).contains(n) { o.days = n }
        }
        if let g = query["gap"].flatMap(Double.init), UsageDashboard.Options.idleGaps.contains(g * 60) { o.idleGap = g * 60 }
        return o
    }

    public init(_ d: UsageDashboard, calendar: Calendar = .current) {
        let o = d.options
        options = Options(
            vendor: o.vendor, counter: o.counter.rawValue, days: o.days.map(String.init) ?? "all",
            gap: String(Int(o.idleGap / 60)),
            vendors: UsageDashboard.Options.vendors.map { Choice(id: $0, label: UsageDashboard.vendorLabel($0)) },
            counters: UsageCounter.allCases.map { Choice(id: $0.rawValue, label: $0.title) },
            ranges: UsageDashboard.Options.ranges.map { Choice(id: $0.map(String.init) ?? "all", label: $0.map { "\($0)d" } ?? "All") },
            gaps: UsageDashboard.Options.idleGaps.map { Choice(id: String(Int($0 / 60)), label: UsageDashboard.idleGapLabel($0)) }
        )
        let measured = d.summary.measured
        self.measured = measured
        keyTiles = d.keyTiles.map(Self.tile)
        moreTiles = d.moreTiles.map(Self.tile)

        let day = DateFormatter()
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        day.setLocalizedDateFormatFromTemplate("MMMd")
        weeksTitle = measured ? "\(o.counter.title) per week" : "Sessions per week"
        rateTitle = measured ? "\(o.counter.title) per active hour" : nil
        weeks = d.weeks.map {
            Week(label: day.string(from: $0.start), total: measured ? $0.total : $0.sessions, sessions: $0.sessions,
                 active: UsageDashboard.hours($0.activeHours), perHour: measured ? $0.perActiveHour : nil)
        }

        var rankings: [String: Ranking] = [:]
        for ranking in UsageDashboard.Ranking.allCases {
            let (highest, lowest) = d.extremes(by: ranking)
            let top = highest.first.map { d.rankValue($0, by: ranking) } ?? 1
            func row(_ s: UsageSession) -> Session {
                let value = d.rankValue(s, by: ranking)
                return Session(
                    id: s.id, project: s.project ?? "—",
                    line: "\(day.string(from: s.first)) · \(UsageDashboard.hours(s.activeHours(idleGap: o.idleGap))) · \(s.turns) turns",
                    value: UsageDashboard.tokens(value) + (ranking == .perActiveHour ? "/h" : ""),
                    share: top > 0 ? value / top : 0,
                    peak: UsageDashboard.percent(s.peakOccupancy), hot: (s.peakOccupancy ?? 0) >= 0.85
                )
            }
            rankings[ranking == .total ? "total" : "perHour"] = Ranking(
                title: ranking == .total ? o.counter.title : "\(o.counter.title) per active hour",
                highest: highest.map(row), lowest: lowest.map(row)
            )
        }
        self.rankings = rankings
        eligible = d.ranked(by: .total).count
        sizeTitle = "\(o.counter.noun) per session"
        sizeBands = d.sizeBands.map { Band(label: $0.label, sessions: $0.sessions) }

        let s = d.summary
        if s.windowedSessions > 0 {
            health = Health(
                facts: [
                    Fact(label: "Average peak fill", value: UsageDashboard.percent(s.meanPeakOccupancy)),
                    Fact(label: "Median peak context", value: "\(UsageDashboard.tokens(s.medianPeakContext)) tokens"),
                    Fact(label: "Sessions that reached 85%", value: "\(s.sessionsReaching85) of \(s.windowedSessions)"),
                    Fact(label: "Sessions that compacted", value: "\(s.sessionsCompacted) of \(s.sessions)"),
                    Fact(label: "Average growth per turn", value: s.averageGrowth.map { "+" + UsageDashboard.tokens($0) } ?? "—"),
                ],
                hotShare: s.hotTurnShare,
                hotText: s.hotTurnShare.map {
                    "\(UsageDashboard.percent($0, decimals: 1)) of \(UsageDashboard.count(s.windowedTurns)) turns ran at 85% or more"
                }
            )
        } else {
            health = nil
        }

        func groupRows(_ groups: [UsageDashboard.Group]) -> [Row] {
            let top = Double(groups.first.map { measured ? $0.total : $0.turns } ?? 1)
            return groups.map { g in
                if !measured {
                    return Row(name: g.name, value: "\(UsageDashboard.count(g.turns)) turns",
                               line: Self.sessions(g.sessions), share: top > 0 ? Double(g.turns) / top : 0)
                }
                return Row(
                    name: g.name, value: UsageDashboard.tokens(Double(g.total)),
                    line: "\(Self.sessions(g.sessions)) · \(UsageDashboard.tokens(g.perSession)) each · "
                        + "\(UsageDashboard.tokens(g.perActiveHour))/h · peak \(UsageDashboard.percent(g.meanPeakOccupancy))",
                    share: top > 0 ? Double(g.total) / top : 0
                )
            }
        }
        projects = groupRows(d.projects)
        models = groupRows(d.models)
        let topTool = Double(d.tools.first?.estimatedResultTokens ?? 1)
        tools = d.tools.map { t in
            Row(
                name: t.name, value: "≈ " + UsageDashboard.tokens(Double(t.estimatedResultTokens)),
                line: "\(UsageDashboard.count(t.calls)) calls · ≈ \(UsageDashboard.tokens(Double(t.estimatedResultTokens) / Double(max(t.calls, 1)))) each"
                    + (t.errors > 0 ? " · \(t.errors) failed" : ""),
                share: topTool > 0 ? Double(t.estimatedResultTokens) / topTool : 0
            )
        }
        footnote = "Active time counts gaps between calls of \(UsageDashboard.idleGapLabel(o.idleGap)) or less, "
            + "so a session resumed days later is not credited with the days between. "
            + "Rates and rankings leave out sessions with under 10 active minutes. Every figure is one counter; none are added together."
    }

    static func sessions(_ n: Int) -> String { n == 1 ? "1 session" : "\(n) sessions" }

    static func tile(_ t: DashboardTile) -> Tile {
        let direction: String? = t.change.map {
            switch $0.direction { case .up: return "up"; case .down: return "down"; case .flat: return "flat" }
        }
        return Tile(title: t.title, value: t.value, detail: t.detail, change: t.change?.text,
                    direction: direction, caption: t.change?.caption, why: t.why)
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

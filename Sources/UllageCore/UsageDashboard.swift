import Foundation

/// The usage dashboard: how much work sessions do, how fast, and how close
/// they run to the window, across a range of days.
///
/// Every figure is one counter (rule 2). A rate is per *active* hour: the gaps
/// between a session's consecutive calls, counting only gaps no longer than the
/// idle gap, so a session resumed three days later is not credited with three
/// days. Cursor reports no tokens (rule 3), so it gets sessions, turns and
/// active time and nothing else.

/// The counter a dashboard is drawn in. Never a sum of them.
public enum UsageCounter: String, CaseIterable, Identifiable {
    case output
    case cacheWrite = "cache_write"
    case cacheRead = "cache_read"
    case input

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .output: return "Output"
        case .cacheWrite: return "Cache write"
        case .cacheRead: return "Cache read"
        case .input: return "Input"
        }
    }

    /// Lower-case, for inside a sentence ("output per active hour").
    public var noun: String { title.lowercased() }
}

/// The few columns of one call the dashboard needs.
public struct UsageCall: Equatable {
    public var sessionId: String
    public var vendor: String
    public var project: String?
    public var model: String?
    public var ts: Date
    /// Nil for the main thread. A subagent's tokens are the session's spend,
    /// but its window is its own and never the session's (rule 1).
    public var agentId: String?
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    public var contextTokens: Int
    public var windowLimit: Int?
    public var contextDelta: Int?
    /// False for a harness that reports no tokens.
    public var measured: Bool

    public init(
        sessionId: String, vendor: String = Vendor.claudeCode, project: String? = nil, model: String? = nil,
        ts: Date, agentId: String? = nil, input: Int = 0, output: Int = 0, cacheRead: Int = 0,
        cacheWrite: Int = 0, contextTokens: Int = 0, windowLimit: Int? = nil, contextDelta: Int? = nil,
        measured: Bool = true
    ) {
        self.sessionId = sessionId
        self.vendor = vendor
        self.project = project
        self.model = model
        self.ts = ts
        self.agentId = agentId
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.contextTokens = contextTokens
        self.windowLimit = windowLimit
        self.contextDelta = contextDelta
        self.measured = measured
    }
}

/// One session, rolled up.
public struct UsageSession: Equatable, Identifiable {
    public var id: String
    public var vendor: String
    public var project: String?
    /// The main thread's most-used model.
    public var model: String?
    public var first: Date
    public var last: Date
    /// All streams: a subagent's calls are real API calls of this session.
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheWrite = 0
    /// The part of `output` written by subagents.
    public var agentOutput = 0
    /// Main-thread turns.
    public var turns = 0
    /// The main thread's fullest turn, as a share of that turn's own window.
    /// Per row, so a model switch mid-session cannot divide one model's
    /// context by another's window.
    public var peakOccupancy: Double?
    public var peakContext = 0
    /// Main-thread turns with a window, and how many of them were at 85%+.
    public var windowedTurns = 0
    public var hotTurns = 0
    /// Positive main-thread context deltas, summed and counted.
    public var growthTotal = 0
    public var growthTurns = 0
    /// Main-thread compactions.
    public var compactions = 0
    public var measured = false
    /// Seconds between consecutive calls, any stream, in order.
    public var gaps: [TimeInterval] = []

    public func value(_ counter: UsageCounter) -> Int {
        switch counter {
        case .output: return output
        case .cacheWrite: return cacheWrite
        case .cacheRead: return cacheRead
        case .input: return input
        }
    }

    /// Hours spent in gaps no longer than `idleGap`.
    public func activeHours(idleGap: TimeInterval) -> Double {
        gaps.reduce(0) { $1 <= idleGap ? $0 + $1 : $0 } / 3600
    }

    /// First call to last, resumes and all.
    public var elapsedHours: Double { last.timeIntervalSince(first) / 3600 }

    /// Sessions this short are left out of rates and rankings: a two-minute
    /// session's per-hour rate is mostly noise from its first turn.
    public static let minimumActiveHours = 10.0 / 60
}

public struct UsageDashboard {
    public struct Options: Equatable {
        public var vendor: String
        public var counter: UsageCounter
        /// Nil for all time.
        public var days: Int?
        public var idleGap: TimeInterval

        public init(vendor: String = Vendor.claudeCode, counter: UsageCounter = .output, days: Int? = 30, idleGap: TimeInterval = 30 * 60) {
            self.vendor = vendor
            self.counter = counter
            self.days = days
            self.idleGap = idleGap
        }

        public static let idleGaps: [TimeInterval] = [15 * 60, 30 * 60, 60 * 60]
        public static let ranges: [Int?] = [7, 30, 90, nil]
        public static let vendors = [Vendor.claudeCode, Vendor.codex, Vendor.cursor]
    }

    /// The figures every tile and table is drawn from, for one set of sessions.
    public struct Summary: Equatable {
        public var sessions = 0
        public var turns = 0
        public var activeHours = 0.0
        public var elapsedHours = 0.0
        public var total = 0
        public var mean: Double?
        public var median: Double?
        /// Over sessions with at least `minimumActiveHours`.
        public var perActiveHour: Double?
        public var ratedSessions = 0
        /// cache read ÷ (cache read + cache write + input): the share of the
        /// prompt that came from cache. A ratio of counters, so it is honest
        /// in a way a sum of them is not.
        public var cacheHitRatio: Double?
        public var compactions = 0
        public var agentOutputShare: Double?
        /// Median of each session's peak occupancy.
        public var medianPeakOccupancy: Double?
        public var meanPeakOccupancy: Double?
        public var windowedSessions = 0
        public var sessionsReaching85 = 0
        public var sessionsCompacted = 0
        public var medianPeakContext: Double?
        public var windowedTurns = 0
        public var hotTurns = 0
        public var averageGrowth: Double?
        public var measured = false

        public var hotTurnShare: Double? { windowedTurns > 0 ? Double(hotTurns) / Double(windowedTurns) : nil }
    }

    public struct Week: Equatable, Identifiable {
        public var start: Date
        public var sessions: Int
        public var total: Int
        public var activeHours: Double
        public var id: Date { start }

        public var perActiveHour: Double? {
            activeHours >= UsageSession.minimumActiveHours ? Double(total) / activeHours : nil
        }
    }

    public struct Group: Equatable, Identifiable {
        public var name: String
        public var sessions: Int
        public var turns: Int
        public var total: Int
        public var perSession: Double
        public var perActiveHour: Double?
        public var meanPeakOccupancy: Double?
        public var id: String { name }
    }

    public struct SizeBand: Equatable, Identifiable {
        public var label: String
        public var sessions: Int
        public var id: String { label }
    }

    public enum Ranking: String, CaseIterable, Identifiable {
        case total = "Total"
        case perActiveHour = "Per active hour"
        public var id: String { rawValue }
    }

    public var options: Options
    /// Sessions whose last call falls in the range, busiest first.
    public var sessions: [UsageSession]
    public var summary: Summary
    /// The same figures for the range before this one; nil for all time.
    public var previous: Summary?
    public var weeks: [Week]
    public var tools: [ToolUsage]

    public init(
        calls: [UsageCall], compactions: [String: Int] = [:], tools: [ToolUsage] = [],
        options: Options, now: Date = Date(), calendar: Calendar = .current
    ) {
        self.options = options
        let all = Self.sessions(from: calls.filter { $0.vendor == options.vendor }, compactions: compactions)
        let counter = options.counter
        if let days = options.days {
            let span = Double(days) * 86_400
            let from = now.addingTimeInterval(-span)
            sessions = all.filter { $0.last > from && $0.last <= now }
            previous = Self.summarize(
                all.filter { $0.last > from.addingTimeInterval(-span) && $0.last <= from }, options: options
            )
        } else {
            sessions = all.filter { $0.last <= now }
            previous = nil
        }
        sessions.sort { $0.value(counter) != $1.value(counter) ? $0.value(counter) > $1.value(counter) : $0.last > $1.last }
        summary = Self.summarize(sessions, options: options)
        let from = options.days.map { now.addingTimeInterval(-Double($0) * 86_400) }
        weeks = Self.weeks(
            calls: calls.filter { $0.vendor == options.vendor }, from: from, now: now, options: options, calendar: calendar
        )
        self.tools = tools
    }

    // MARK: Rollup

    static func sessions(from calls: [UsageCall], compactions: [String: Int]) -> [UsageSession] {
        var bySession: [String: [UsageCall]] = [:]
        for call in calls { bySession[call.sessionId, default: []].append(call) }
        return bySession.map { id, calls in
            let calls = calls.sorted { $0.ts < $1.ts }
            var s = UsageSession(id: id, vendor: calls[0].vendor, first: calls[0].ts, last: calls[calls.count - 1].ts)
            var models: [String: Int] = [:]
            var previous: Date?
            for call in calls {
                if let previous { s.gaps.append(call.ts.timeIntervalSince(previous)) }
                previous = call.ts
                if s.project == nil { s.project = call.project }
                s.measured = s.measured || call.measured
                s.input += call.input
                s.output += call.output
                s.cacheRead += call.cacheRead
                s.cacheWrite += call.cacheWrite
                guard call.agentId == nil else {
                    s.agentOutput += call.output
                    continue
                }
                s.turns += 1
                if let model = call.model, !model.hasPrefix("<") { models[model, default: 0] += 1 }
                if let window = call.windowLimit, window > 0 {
                    let occupancy = Double(call.contextTokens) / Double(window)
                    s.peakOccupancy = max(s.peakOccupancy ?? 0, occupancy)
                    s.peakContext = max(s.peakContext, call.contextTokens)
                    s.windowedTurns += 1
                    if occupancy >= 0.85 { s.hotTurns += 1 }
                }
                if let delta = call.contextDelta, delta > 0 {
                    s.growthTotal += delta
                    s.growthTurns += 1
                }
            }
            s.model = models.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
            s.compactions = compactions[id] ?? 0
            return s
        }
    }

    static func summarize(_ sessions: [UsageSession], options: Options) -> Summary {
        let counter = options.counter
        var s = Summary()
        s.sessions = sessions.count
        s.measured = sessions.contains { $0.measured }
        var ratedTotal = 0, ratedHours = 0.0
        var cacheRead = 0, cacheWrite = 0, input = 0, output = 0, agentOutput = 0, growth = 0, growthTurns = 0
        for session in sessions {
            let active = session.activeHours(idleGap: options.idleGap)
            s.turns += session.turns
            s.activeHours += active
            s.elapsedHours += session.elapsedHours
            s.total += session.value(counter)
            if active >= UsageSession.minimumActiveHours {
                s.ratedSessions += 1
                ratedTotal += session.value(counter)
                ratedHours += active
            }
            cacheRead += session.cacheRead
            cacheWrite += session.cacheWrite
            input += session.input
            output += session.output
            agentOutput += session.agentOutput
            s.compactions += session.compactions
            if session.compactions > 0 { s.sessionsCompacted += 1 }
            s.windowedTurns += session.windowedTurns
            s.hotTurns += session.hotTurns
            growth += session.growthTotal
            growthTurns += session.growthTurns
        }
        let measured = sessions.filter(\.measured)
        if !measured.isEmpty {
            s.mean = Double(measured.reduce(0) { $0 + $1.value(counter) }) / Double(measured.count)
            s.median = median(measured.map { Double($0.value(counter)) })
        }
        s.perActiveHour = ratedHours > 0 && s.measured ? Double(ratedTotal) / ratedHours : nil
        let prompt = cacheRead + cacheWrite + input
        s.cacheHitRatio = prompt > 0 ? Double(cacheRead) / Double(prompt) : nil
        s.agentOutputShare = output > 0 ? Double(agentOutput) / Double(output) : nil
        let windowed = sessions.filter { $0.peakOccupancy != nil }
        s.windowedSessions = windowed.count
        if !windowed.isEmpty {
            let peaks = windowed.compactMap(\.peakOccupancy)
            s.medianPeakOccupancy = median(peaks)
            s.meanPeakOccupancy = peaks.reduce(0, +) / Double(peaks.count)
            s.sessionsReaching85 = peaks.filter { $0 >= 0.85 }.count
            s.medianPeakContext = median(windowed.map { Double($0.peakContext) })
        }
        s.averageGrowth = growthTurns > 0 ? Double(growth) / Double(growthTurns) : nil
        return s
    }

    static func weeks(calls: [UsageCall], from: Date?, now: Date, options: Options, calendar: Calendar) -> [Week] {
        var calendar = calendar
        calendar.firstWeekday = 2   // Monday
        func weekStart(_ date: Date) -> Date {
            calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        }
        let earliest = from.map(weekStart)
        var totals: [Date: Int] = [:], hours: [Date: Double] = [:], sessions: [Date: Set<String>] = [:]
        var bySession: [String: [UsageCall]] = [:]
        for call in calls where call.ts <= now { bySession[call.sessionId, default: []].append(call) }
        for (_, calls) in bySession {
            let calls = calls.sorted { $0.ts < $1.ts }
            var previous: Date?
            for call in calls {
                let week = weekStart(call.ts)
                defer { previous = call.ts }
                if let earliest, week < earliest { continue }
                let value: Int
                switch options.counter {
                case .output: value = call.output
                case .cacheWrite: value = call.cacheWrite
                case .cacheRead: value = call.cacheRead
                case .input: value = call.input
                }
                totals[week, default: 0] += value
                sessions[week, default: []].insert(call.sessionId)
                if let previous {
                    let gap = call.ts.timeIntervalSince(previous)
                    if gap <= options.idleGap { hours[week, default: 0] += gap / 3600 }
                }
            }
        }
        guard let first = sessions.keys.min() else { return [] }
        // Every week in the range, empty ones included, so the chart's x axis
        // is time and a quiet week shows as a gap rather than vanishing.
        var out: [Week] = []
        var week = earliest.map { max($0, first) } ?? first
        let last = weekStart(now)
        while week <= last {
            out.append(Week(start: week, sessions: sessions[week]?.count ?? 0, total: totals[week] ?? 0, activeHours: hours[week] ?? 0))
            guard let next = calendar.date(byAdding: .weekOfYear, value: 1, to: week) else { break }
            week = next
        }
        return out
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    // MARK: Sections

    /// Sessions with enough active time to rank, highest first.
    public func ranked(by ranking: Ranking) -> [UsageSession] {
        let counter = options.counter, gap = options.idleGap
        func metric(_ s: UsageSession) -> Double {
            switch ranking {
            case .total: return Double(s.value(counter))
            case .perActiveHour: return Double(s.value(counter)) / s.activeHours(idleGap: gap)
            }
        }
        return sessions
            .filter { $0.measured && $0.activeHours(idleGap: gap) >= UsageSession.minimumActiveHours }
            .sorted { metric($0) != metric($1) ? metric($0) > metric($1) : $0.last > $1.last }
    }

    /// The highest and lowest `limit`, never the same session twice.
    public func extremes(by ranking: Ranking, limit: Int = 8) -> (highest: [UsageSession], lowest: [UsageSession]) {
        let ranked = ranked(by: ranking)
        let highest = Array(ranked.prefix(limit))
        let lowest = Array(ranked.dropFirst(highest.count).suffix(limit).reversed())
        return (highest, lowest)
    }

    public func rankValue(_ session: UsageSession, by ranking: Ranking) -> Double {
        let value = Double(session.value(options.counter))
        switch ranking {
        case .total: return value
        case .perActiveHour:
            let hours = session.activeHours(idleGap: options.idleGap)
            return hours > 0 ? value / hours : 0
        }
    }

    static let bandEdges: [Int] = [0, 1_000, 10_000, 100_000, 1_000_000, 10_000_000, 100_000_000, 1_000_000_000]
    static let bandLabels = ["<1k", "1–10k", "10–100k", "100k–1M", "1–10M", "10–100M", "100M–1B", "1B+"]

    /// Sessions per order of magnitude, trimmed to the bands that have any.
    public var sizeBands: [SizeBand] {
        var counts = Array(repeating: 0, count: Self.bandLabels.count)
        for session in sessions where session.measured {
            let value = session.value(options.counter)
            let index = (Self.bandEdges.lastIndex { value >= $0 }) ?? 0
            counts[index] += 1
        }
        guard let lo = counts.firstIndex(where: { $0 > 0 }), let hi = counts.lastIndex(where: { $0 > 0 }) else { return [] }
        return (lo...hi).map { SizeBand(label: Self.bandLabels[$0], sessions: counts[$0]) }
    }

    public func groups(by key: (UsageSession) -> String?, limit: Int) -> [Group] {
        var buckets: [String: [UsageSession]] = [:]
        for session in sessions { buckets[key(session) ?? "—", default: []].append(session) }
        let rows = buckets.map { name, sessions -> Group in
            let s = Self.summarize(sessions, options: options)
            return Group(
                name: name, sessions: sessions.count, turns: s.turns, total: s.total,
                perSession: Double(s.total) / Double(sessions.count), perActiveHour: s.perActiveHour,
                meanPeakOccupancy: s.meanPeakOccupancy
            )
        }
        let measured = summary.measured
        return Array(rows.sorted {
            let a = measured ? $0.total : $0.turns, b = measured ? $1.total : $1.turns
            return a != b ? a > b : $0.name < $1.name
        }.prefix(limit))
    }

    public var projects: [Group] { groups(by: \.project, limit: 12) }
    public var models: [Group] { groups(by: \.model, limit: 8) }
}

/// One tool's results over a range. The size is a length estimate (rule 6).
public struct ToolUsage: Equatable, Identifiable {
    public var name: String
    public var calls: Int
    public var estimatedResultTokens: Int
    public var errors: Int
    public var id: String { name }

    public init(name: String, calls: Int, estimatedResultTokens: Int, errors: Int) {
        self.name = name
        self.calls = calls
        self.estimatedResultTokens = estimatedResultTokens
        self.errors = errors
    }
}

// MARK: - Tiles

/// A figure as the dashboard shows it, formatted once for the app and the CLI.
public struct DashboardTile: Equatable, Identifiable {
    public enum Direction: Equatable { case up, down, flat }

    public struct Change: Equatable {
        public var text: String
        public var direction: Direction
        public var caption: String
    }

    public var title: String
    public var value: String
    public var detail: String
    public var change: Change?
    /// Why this figure is worth looking at. Only the key tiles carry one.
    public var why: String?
    public var id: String { title }
}

extension UsageDashboard {
    /// The four that answer "how am I using it": how fast, how big a typical
    /// session is, how close to the wall, and for how long.
    public var keyTiles: [DashboardTile] {
        let s = summary, p = previous, noun = options.counter.noun
        // A harness that reports no tokens gets activity, not dashes.
        if options.vendor == Vendor.cursor || (!s.measured && !sessions.isEmpty) {
            return [
                DashboardTile(title: "Sessions", value: Self.count(s.sessions), detail: "\(Self.count(s.turns)) turns",
                              change: change(Double(s.sessions), p.map { Double($0.sessions) })),
                DashboardTile(title: "Active time", value: Self.hours(s.activeHours),
                              detail: "vs \(Self.hours(s.elapsedHours)) first-to-last"),
                DashboardTile(title: "Tokens", value: "not reported", detail: "no token counts on disk"),
                DashboardTile(title: "Window fill", value: "not reported", detail: "no window size either"),
            ]
        }
        return [
            DashboardTile(
                title: "\(options.counter.title) per active hour", value: Self.tokens(s.perActiveHour),
                detail: "\(s.ratedSessions) sessions with 10+ min",
                change: change(s.perActiveHour, p?.perActiveHour),
                why: "How fast work happens, comparable across sessions of any length."
            ),
            DashboardTile(
                title: "Typical session", value: Self.tokens(s.median),
                detail: "median \(noun) · average \(Self.tokens(s.mean))",
                change: change(s.median, p?.median),
                why: "The median, because a few huge sessions drag the average up."
            ),
            DashboardTile(
                title: "Peak window fill", value: Self.percent(s.medianPeakOccupancy),
                detail: "\(s.sessionsReaching85) of \(s.windowedSessions) sessions reached 85%",
                change: change(s.medianPeakOccupancy, p?.medianPeakOccupancy, points: true),
                why: "Median of each session's fullest turn. How close you run to the wall."
            ),
            DashboardTile(
                title: "Active time", value: Self.hours(s.activeHours),
                detail: "\(Self.count(s.sessions)) sessions · \(Self.hours(s.elapsedHours)) first-to-last",
                change: change(s.activeHours, p?.activeHours),
                why: "The denominator for every rate. Gaps over the idle gap don't count."
            ),
        ]
    }

    /// Behind "Show all metrics".
    public var moreTiles: [DashboardTile] {
        let s = summary, p = previous, noun = options.counter.noun
        guard s.measured, options.vendor != Vendor.cursor else { return [] }
        return [
            DashboardTile(title: "Sessions", value: Self.count(s.sessions), detail: "\(Self.count(s.turns)) main-thread turns",
                          change: change(Double(s.sessions), p.map { Double($0.sessions) })),
            DashboardTile(title: "Average \(noun) per session", value: Self.tokens(s.mean),
                          detail: "pulled up by the largest sessions", change: change(s.mean, p?.mean)),
            DashboardTile(title: "Total \(noun)", value: Self.tokens(Double(s.total)),
                          detail: "across every session in range", change: change(Double(s.total), p.map { Double($0.total) })),
            DashboardTile(title: "Cache hit ratio", value: Self.percent(s.cacheHitRatio, decimals: 1),
                          detail: "cache read ÷ whole prompt"),
            DashboardTile(title: "Compactions", value: Self.count(s.compactions),
                          detail: s.sessions > 0 ? String(format: "%.2f per session", Double(s.compactions) / Double(s.sessions)) : "—"),
            DashboardTile(title: "Subagent output", value: Self.percent(s.agentOutputShare),
                          detail: "share of output tokens"),
        ]
    }

    func change(_ current: Double?, _ previous: Double?, points: Bool = false) -> DashboardTile.Change? {
        guard let days = options.days, let current, let previous else { return nil }
        let caption = "vs prior \(days) days"
        if points {
            let delta = (current - previous) * 100
            if abs(delta) < 0.5 { return .init(text: "flat", direction: .flat, caption: caption) }
            return .init(text: "\(delta > 0 ? "▲" : "▼") \(Int(abs(delta).rounded())) pts", direction: delta > 0 ? .up : .down, caption: caption)
        }
        guard previous > 0 else { return nil }
        let ratio = current / previous - 1
        if abs(ratio) < 0.005 { return .init(text: "flat", direction: .flat, caption: caption) }
        return .init(text: "\(ratio > 0 ? "▲" : "▼") \(Int((abs(ratio) * 100).rounded()))%", direction: ratio > 0 ? .up : .down, caption: caption)
    }

    // MARK: Formatting

    public static func tokens(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        let a = abs(value)
        switch a {
        case 1e9...: return String(format: a >= 1e10 ? "%.1fB" : "%.2fB", value / 1e9)
        case 1e6...: return String(format: a >= 1e7 ? "%.1fM" : "%.2fM", value / 1e6)
        case 1e4...: return "\(Int((value / 1e3).rounded()))k"
        case 1e3...: return String(format: "%.1fk", value / 1e3)
        default: return "\(Int(value.rounded()))"
        }
    }

    public static func count(_ value: Int) -> String {
        value >= 10_000 ? tokens(Double(value)) : "\(value)"
    }

    public static func percent(_ value: Double?, decimals: Int = 0) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.\(decimals)f%%", value * 100)
    }

    public static func hours(_ value: Double) -> String {
        switch value {
        case 10...: return "\(Int(value.rounded())) h"
        case 1...: return String(format: "%.1f h", value)
        default: return "\(Int((value * 60).rounded())) min"
        }
    }

    public static func idleGapLabel(_ gap: TimeInterval) -> String { "\(Int(gap / 60)) min" }

    public static func rangeLabel(_ days: Int?) -> String { days.map { "\($0) days" } ?? "All time" }

    public static func vendorLabel(_ vendor: String) -> String {
        switch vendor {
        case Vendor.claudeCode: return "Claude Code"
        case Vendor.codex: return "Codex"
        case Vendor.cursor: return "Cursor"
        default: return vendor
        }
    }
}

// MARK: - Store

extension Store {
    /// Every call of every session whose last call is on or after `since` (all
    /// sessions when nil), so a session is always whole.
    public func usageCalls(lastActiveSince since: String?) throws -> [UsageCall] {
        let filter = since == nil ? "" : """
        WHERE session_id IN (SELECT session_id FROM call GROUP BY session_id HAVING MAX(ts) >= ?1)
        """
        let sql = """
        SELECT session_id, vendor, project, model, (julianday(ts) - 2440587.5) * 86400.0, agent_id, input, output, cache_read, cache_write,
               context_tokens, window_limit, context_delta, confidence
        FROM call \(filter)
        ORDER BY session_id, ts;
        """
        // Epoch seconds from SQLite: parsing 36k ISO strings with a formatter
        // took two seconds, which a phone waiting on the page should not.
        return try database.query(sql, since.map { [.text($0)] } ?? []) { row in
            UsageCall(
                sessionId: row.text(0), vendor: row.text(1), project: row.optionalText(2), model: row.optionalText(3),
                ts: row.isNull(4) ? .distantPast : Date(timeIntervalSince1970: row.double(4)), agentId: row.optionalText(5),
                input: row.int(6), output: row.int(7), cacheRead: row.int(8), cacheWrite: row.int(9),
                contextTokens: row.int(10), windowLimit: row.optionalInt(11), contextDelta: row.optionalInt(12),
                measured: row.text(13) != Confidence.unmeasured.rawValue
            )
        }.filter { $0.ts != .distantPast }
    }

    /// Main-thread compactions per session.
    public func compactionCounts() throws -> [String: Int] {
        let rows = try database.query(
            "SELECT session_id, COUNT(*) FROM event WHERE kind = ?1 AND agent_id IS NULL GROUP BY session_id;",
            [.text(EventKind.compaction.rawValue)]
        ) { ($0.text(0), $0.int(1)) }
        return Dictionary(rows, uniquingKeysWith: +)
    }

    /// Tools by the estimated size of what they returned, for one harness.
    public func toolUsage(vendor: String, since: String?, limit: Int = 10) throws -> [ToolUsage] {
        let sql = """
        SELECT t.name, COUNT(*), COALESCE(SUM(t.result_tokens), 0), COALESCE(SUM(t.is_error), 0)
        FROM tool_call t JOIN call c ON c.dedupe_key = t.call_id
        WHERE c.vendor = ?1 AND (?2 IS NULL OR t.ts >= ?2)
        GROUP BY t.name
        ORDER BY 3 DESC, 2 DESC
        LIMIT ?3;
        """
        return try database.query(sql, [.text(vendor), since.map { .text($0) } ?? .null, .integer(Int64(limit))]) { row in
            ToolUsage(name: row.text(0), calls: row.int(1), estimatedResultTokens: row.int(2), errors: row.int(3))
        }
    }

    public func usageDashboard(_ options: UsageDashboard.Options, now: Date = Date()) throws -> UsageDashboard {
        // Twice the range, so the previous period can be compared.
        let since = options.days.map { Timestamps.string(from: now.addingTimeInterval(-2 * Double($0) * 86_400)) }
        let toolsSince = options.days.map { Timestamps.string(from: now.addingTimeInterval(-Double($0) * 86_400)) }
        return UsageDashboard(
            calls: try usageCalls(lastActiveSince: since),
            compactions: try compactionCounts(),
            tools: try toolUsage(vendor: options.vendor, since: toolsSince),
            options: options,
            now: now
        )
    }
}

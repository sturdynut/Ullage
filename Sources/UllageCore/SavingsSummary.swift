import Foundation

/// How many tokens the context tools kept from being sent, in total, per
/// tool, over time and per session — the answer to "how much am I saving?".
///
/// Every figure is the tools' own claims (rule 10), on one basis: tokens not
/// sent to the model, counted in every prompt a shortened result stayed in.
/// A result-level claim (rtk) is multiplied by the prompts its Bash call's
/// result stayed in, or counted once when Ullage couldn't place it on a call;
/// a request-level claim (Headroom's proxy) is already per prompt. A call two
/// tools both claim is counted once, under the larger claim. With/without
/// comparisons are never added in: they compare different work.
public struct SavingsSummary: Equatable {
    public struct Tool: Equatable, Identifiable {
        public var saver: TokenSaver
        /// What it took in and passed on, on the summary's basis.
        public var before: Int
        public var after: Int
        /// What it says it kept back, and the part counted in the total once
        /// calls another tool also claimed are taken out.
        public var saved: Int
        public var counted: Int
        public var id: String { saver.rawValue }
    }

    /// One day, or one hour of a 1-day range.
    public struct Bucket: Equatable, Identifiable {
        public var key: String
        public var label: String
        public var before: Int
        public var after: Int
        /// Counted saving per tool id.
        public var saved: [String: Int]
        public var id: String { key }
    }

    public struct Session: Equatable, Identifiable {
        public var sessionId: String
        public var project: String?
        public var firstTs: String?
        /// Main-thread turns.
        public var turns: Int
        /// Counted saving per tool id.
        public var saved: [String: Int]
        public var total: Int { saved.values.reduce(0, +) }
        public var id: String { sessionId }
    }

    public var range: SaverRange
    /// Hourly for a 1-day range, daily otherwise.
    public var hourly: Bool
    public var tools: [Tool]
    public var buckets: [Bucket]
    /// Largest saving first.
    public var sessions: [Session]
    /// Claimed by two tools for the same call, counted once.
    public var overlap: Int
    /// Tools judged by with/without comparisons, which the total leaves out.
    public var compared: [TokenSaver]

    public var before: Int { tools.reduce(0) { $0 + $1.before } - overlapBefore }
    public var after: Int { before - saved }
    public var saved: Int { tools.reduce(0) { $0 + $1.counted } }
    /// Rounded percent of what would have been sent.
    public var cut: Int? { before > 0 ? Int((Double(saved) / Double(before) * 100).rounded()) : nil }
    public var activeBuckets: Int { buckets.filter { $0.before > $0.after }.count }
    public var isEmpty: Bool { tools.isEmpty }

    /// The before of the claims dropped as overlap, so the total's "would
    /// have sent" counts each call once too.
    var overlapBefore: Int = 0

    public func share(_ tool: Tool) -> Int? {
        saved > 0 ? Int((Double(tool.counted) / Double(saved) * 100).rounded()) : nil
    }

    public struct SessionMeta: Equatable {
        public var project: String?
        public var firstTs: String?
        public var turns: Int
        public init(project: String?, firstTs: String?, turns: Int) {
            self.project = project
            self.firstTs = firstTs
            self.turns = turns
        }
    }

    public static func build(
        details: [SaverDetail], range: SaverRange, sessions meta: [String: SessionMeta] = [:],
        now: Date = Date(), calendar: Calendar = .current
    ) -> SavingsSummary {
        struct Claim {
            var saver: TokenSaver
            var entry: LedgerEntry
            var before: Int
            var after: Int
            var saved: Int { before - after }
            var session: String?
        }
        // Every claim on the one basis.
        var claims: [Claim] = []
        // A session still running can hold claims from before the period.
        let start = range.days.map { now.addingTimeInterval(-Double($0) * 86_400) }
        for detail in details {
            guard let ledgerClaims = detail.saver.descriptor.claims else { continue }
            for entry in detail.ledgerEntries where start.map({ entry.ts >= $0 }) ?? true {
                let after = entry.afterTokens ?? 0
                let before = entry.beforeTokens ?? (after + entry.savedTokens)
                let prompts = ledgerClaims.perRequest == true ? 1
                    : max(1, entry.toolUseId.flatMap { detail.prompts[$0] } ?? 1)
                claims.append(Claim(saver: detail.saver, entry: entry, before: before * prompts, after: after * prompts,
                                    session: detail.entrySessions[entry.id] ?? entry.sessionId))
            }
        }
        // A call two tools claim: the larger claim counts, the rest are overlap.
        var dropped = Set<Int>()
        let byCall = Dictionary(grouping: claims.indices.filter { claims[$0].entry.toolUseId != nil }) { claims[$0].entry.toolUseId! }
        for (_, indices) in byCall where Set(indices.map { claims[$0].saver }).count > 1 {
            let keep = indices.max { (claims[$0].saved, claims[$1].saver.rawValue) < (claims[$1].saved, claims[$0].saver.rawValue) }
            let keeper = keep.map { claims[$0].saver }
            for index in indices where claims[index].saver != keeper { dropped.insert(index) }
        }

        let hourly = range == .day
        let keys = BucketKeys(calendar: calendar, hourly: hourly)
        var tools: [TokenSaver: Tool] = [:]
        var buckets: [String: Bucket] = [:]
        var sessions: [String: [String: Int]] = [:]
        var overlap = 0, overlapBefore = 0
        for (index, claim) in claims.enumerated() {
            var tool = tools[claim.saver] ?? Tool(saver: claim.saver, before: 0, after: 0, saved: 0, counted: 0)
            tool.before += claim.before
            tool.after += claim.after
            tool.saved += claim.saved
            if dropped.contains(index) {
                overlap += claim.saved
                overlapBefore += claim.before
                tools[claim.saver] = tool
                continue
            }
            tool.counted += claim.saved
            tools[claim.saver] = tool
            let key = keys.key(claim.entry.ts)
            var bucket = buckets[key] ?? Bucket(key: key, label: keys.label(claim.entry.ts), before: 0, after: 0, saved: [:])
            bucket.before += claim.before
            bucket.after += claim.after
            bucket.saved[claim.saver.rawValue, default: 0] += claim.saved
            buckets[key] = bucket
            if let session = claim.session {
                sessions[session, default: [:]][claim.saver.rawValue, default: 0] += claim.saved
            }
        }

        var summary = SavingsSummary(
            range: range, hourly: hourly,
            tools: TokenSaver.allCases.compactMap { tools[$0] },
            buckets: buckets.values.sorted { $0.key < $1.key },
            sessions: sessions.map { id, saved in
                Session(sessionId: id, project: meta[id]?.project, firstTs: meta[id]?.firstTs, turns: meta[id]?.turns ?? 0, saved: saved)
            }
            .filter { $0.total > 0 }
            .sorted { ($0.total, $1.sessionId) > ($1.total, $0.sessionId) },
            overlap: overlap,
            compared: details.filter { $0.saver.descriptor.claims == nil && !$0.comparisons.isEmpty }.map(\.saver)
        )
        summary.overlapBefore = overlapBefore
        return summary
    }
}

/// Local days, or local hours, as sortable keys and short labels.
struct BucketKeys {
    let calendar: Calendar
    let hourly: Bool
    private let formatter: DateFormatter

    init(calendar: Calendar, hourly: Bool) {
        self.calendar = calendar
        self.hourly = hourly
        formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = hourly ? "H:00" : "MMM d"
    }

    func key(_ date: Date) -> String {
        let p = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        let day = String(format: "%04d-%02d-%02d", p.year ?? 0, p.month ?? 0, p.day ?? 0)
        return hourly ? day + String(format: "T%02d", p.hour ?? 0) : day
    }

    func label(_ date: Date) -> String { formatter.string(from: date) }
}

extension Store {
    /// Project, first turn and main-thread turns for each session.
    public func sessionMeta(_ ids: [String]) throws -> [String: SavingsSummary.SessionMeta] {
        var result: [String: SavingsSummary.SessionMeta] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            for (id, first, turns, cwd) in try database.query(
                """
                SELECT session_id, MIN(ts), SUM(agent_id IS NULL), MAX(CASE WHEN agent_id IS NULL THEN cwd END)
                FROM call WHERE session_id IN (\(marks)) GROUP BY session_id;
                """, chunk.map { .text($0) }
            ) { ($0.text(0), $0.optionalText(1), $0.int(2), $0.optionalText(3)) } {
                result[id] = .init(project: cwd.map { ($0 as NSString).lastPathComponent }, firstTs: first, turns: turns)
            }
        }
        return result
    }

    /// The summary for details already read, with each session's name.
    public func savingsSummary(_ details: [SaverDetail], range: SaverRange, now: Date = Date()) throws -> SavingsSummary {
        let ids = Set(details.flatMap { $0.entrySessions.values })
        return SavingsSummary.build(details: details, range: range, sessions: try sessionMeta(Array(ids)), now: now)
    }
}

extension SavingsSummary {
    /// Every tool's before and after added together, per day (per hour for
    /// a 1-day range): the overview's chart, in the same card shape as a
    /// tool's own.
    public func overallChart(now: Date = Date(), calendar: Calendar = .current) -> SaverChart {
        let keys = BucketKeys(calendar: calendar, hourly: hourly)
        let span: (String?, String?)
        if let days = range.days {
            span = hourly ? (keys.key(now.addingTimeInterval(-23 * 3600)), keys.key(now))
                : (keys.key(now.addingTimeInterval(-Double(days - 1) * 86_400)), keys.key(now))
        } else {
            span = (buckets.first?.key, buckets.last?.key)
        }
        var more = ["Every tool's before and after added together. The gap is the total saving."]
        if overlap > 0 { more.append("≈\(TokenFormat.compact(overlap)) that two tools both claimed for the same calls is counted once.") }
        if !compared.isEmpty {
            more.append("Not added in: \(compared.map(\.displayName).joined(separator: ", ")). They're compared across sessions, which isn't a saving.")
        }
        more.append("\"Would have sent\" counts every prompt a shortened result stayed in, so most of it is cheap cache reads.")
        return SaverChart(
            id: "overall", kind: .daily, title: "Overall",
            what: hourly ? "What would have been sent, next to what was sent, per hour." : "What would have been sent, next to what was sent, per day.",
            more: more, beforeLabel: "Would have sent", afterLabel: "Sent", countUnit: nil,
            bars: buckets.map { .init(key: $0.key, label: $0.label, before: $0.before, after: $0.after, count: nil) },
            approximate: true, firstDay: span.0, lastDay: span.1
        )
    }

    /// "last 7 days", "last 24 hours", "this session".
    public var periodText: String {
        guard let days = range.days else { return "this session" }
        return days == 1 ? "last 24 hours" : "last \(days) days"
    }
}

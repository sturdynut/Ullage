import Foundation

/// One subscription limit as the harness last reported it: how much of a
/// rolling window is used and when it resets.
///
/// Plan limits are reported as percentages, never as tokens — neither vendor
/// publishes a limit in tokens, so Ullage does not invent one. The tokens shown
/// beside a limit are Ullage's own count of what it saw in that window, and are
/// labelled that way.
public struct PlanLimitRow: Equatable {
    public var vendor: String
    /// Stable per vendor, e.g. `session`, `weekly_scoped:Fable`, `codex:primary`.
    public var limitKey: String
    public var label: String
    /// 0–100, as reported.
    public var usedPercent: Double
    /// Normalised UTC timestamp.
    public var resetsAt: String?
    public var windowMinutes: Int?
    public var observedAt: String
    /// `api` (fetched) or `transcript` (read off disk).
    public var source: String
    public var sortOrder: Int

    /// A limit on one model or surface rather than the whole plan. Ullage's
    /// own token count for the window covers every model, so it is only shown
    /// beside a plan-wide limit. Both parsers write scoped keys as
    /// `<kind>:<scope>` / `<limit_id>:<slot>` — see below.
    public var isScoped: Bool {
        switch vendor {
        case Vendor.claudeCode: return limitKey.contains(":")
        case Vendor.codex: return !limitKey.hasPrefix(CodexRateLimits.planWideId + ":")
        default: return false
        }
    }

    public init(
        vendor: String, limitKey: String, label: String, usedPercent: Double,
        resetsAt: String?, windowMinutes: Int?, observedAt: String, source: String, sortOrder: Int = 0
    ) {
        self.vendor = vendor
        self.limitKey = limitKey
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.windowMinutes = windowMinutes
        self.observedAt = observedAt
        self.source = source
        self.sortOrder = sortOrder
    }
}

public enum PlanLimitSource {
    public static let api = "api"
    public static let transcript = "transcript"
}

// MARK: - Claude (the usage endpoint)

/// Parses the body of `GET /api/oauth/usage` — the endpoint behind Claude
/// Code's `/usage`. Undocumented, so it gets the transcript treatment: every
/// field guarded, unknown shapes skipped, never a throw.
public enum ClaudeUsageParser {
    public static let fiveHourMinutes = 300
    public static let weekMinutes = 7 * 24 * 60

    public static func parse(_ data: Data, observedAt: String) -> [PlanLimitRow] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        let fromList = parseLimitsList(root, observedAt: observedAt)
        return fromList.isEmpty ? parseLegacyWindows(root, observedAt: observedAt) : fromList
    }

    /// The newer `limits` array: one entry per limit, scoped ones named.
    static func parseLimitsList(_ root: [String: Any], observedAt: String) -> [PlanLimitRow] {
        guard let list = JSONAccess.list(root, "limits") else { return [] }
        var rows: [PlanLimitRow] = []
        for (index, item) in list.enumerated() {
            guard let entry = JSONAccess.object(item),
                  let kind = JSONAccess.string(entry, "kind"),
                  let percent = JSONAccess.double(entry, "percent") else { continue }
            let group = JSONAccess.string(entry, "group")
            let scope = JSONAccess.dict(entry, "scope")
            let scopeName = JSONAccess.string(JSONAccess.dict(scope, "model"), "display_name")
                ?? JSONAccess.string(JSONAccess.dict(scope, "surface"), "display_name")
            let isWeekly = group == "weekly" || kind.hasPrefix("weekly")
            let isSession = group == "session" || kind == "session"
            var label = isSession ? "5-hour" : (isWeekly ? "Weekly" : kind.replacingOccurrences(of: "_", with: " ").capitalized)
            if let scopeName { label += " · " + scopeName }
            rows.append(PlanLimitRow(
                vendor: Vendor.claudeCode,
                limitKey: scopeName.map { "\(kind):\($0)" } ?? kind,
                label: label,
                usedPercent: percent,
                resetsAt: Timestamps.normalize(JSONAccess.string(entry, "resets_at")),
                windowMinutes: isSession ? fiveHourMinutes : (isWeekly ? weekMinutes : nil),
                observedAt: observedAt,
                source: PlanLimitSource.api,
                sortOrder: index
            ))
        }
        return rows
    }

    /// The older top-level windows, kept as a fallback in case `limits` goes.
    static func parseLegacyWindows(_ root: [String: Any], observedAt: String) -> [PlanLimitRow] {
        let windows: [(key: String, label: String, minutes: Int)] = [
            ("five_hour", "5-hour", fiveHourMinutes),
            ("seven_day", "Weekly", weekMinutes),
            ("seven_day_opus", "Weekly · Opus", weekMinutes),
            ("seven_day_sonnet", "Weekly · Sonnet", weekMinutes),
        ]
        return windows.enumerated().compactMap { index, window in
            guard let entry = JSONAccess.dict(root, window.key),
                  let used = JSONAccess.double(entry, "utilization") else { return nil }
            return PlanLimitRow(
                vendor: Vendor.claudeCode,
                limitKey: window.key,
                label: window.label,
                usedPercent: used,
                resetsAt: Timestamps.normalize(JSONAccess.string(entry, "resets_at")),
                windowMinutes: window.minutes,
                observedAt: observedAt,
                source: PlanLimitSource.api,
                sortOrder: index
            )
        }
    }
}

// MARK: - Codex (on disk)

/// Codex writes its limits into the rollout itself, on every `token_count`
/// event: no network, no credentials.
public enum CodexRateLimits {
    /// The plan-wide limit; any other `limit_id` is a per-model allowance.
    public static let planWideId = "codex"

    public static func parse(_ rateLimits: [String: Any]?, observedAt: String) -> [PlanLimitRow] {
        guard let rateLimits else { return [] }
        let limitId = JSONAccess.string(rateLimits, "limit_id") ?? planWideId
        let limitName = JSONAccess.string(rateLimits, "limit_name")
        return ["primary", "secondary"].enumerated().compactMap { index, slot in
            guard let window = JSONAccess.dict(rateLimits, slot),
                  let used = JSONAccess.double(window, "used_percent") else { return nil }
            let minutes = JSONAccess.int(window, "window_minutes")
            var label = windowLabel(minutes: minutes) ?? slot.capitalized
            if limitId != planWideId { label += " · " + (limitName ?? limitId) }
            let resets = JSONAccess.double(window, "resets_at")
                .map { Timestamps.string(from: Date(timeIntervalSince1970: $0)) }
            return PlanLimitRow(
                vendor: Vendor.codex,
                limitKey: "\(limitId):\(slot)",
                label: label,
                usedPercent: used,
                resetsAt: resets,
                windowMinutes: minutes,
                observedAt: observedAt,
                source: PlanLimitSource.transcript,
                // Plan-wide first; per-model allowances after, whatever order
                // their lines arrive in.
                sortOrder: (limitId == planWideId ? 0 : 10) + index
            )
        }
    }

    static func windowLabel(minutes: Int?) -> String? {
        guard let minutes, minutes > 0 else { return nil }
        if minutes == ClaudeUsageParser.weekMinutes { return "Weekly" }
        if minutes % 1440 == 0 { return "\(minutes / 1440)-day" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour" }
        return "\(minutes)-minute"
    }
}

// MARK: - Display

/// What the popover draws for one limit. Pure, so the rules — a reading from
/// before the reset says nothing about now; an old reading says so — are
/// tested without a UI.
public struct PlanLimitDisplay: Equatable, Identifiable {
    public var id: String { vendor + "|" + limitKey }
    public var vendor: String
    public var vendorName: String
    public var limitKey: String
    public var label: String
    /// Nil once the window has reset since the reading: the old number is no
    /// longer true, and the new one has not been seen.
    public var usedFraction: Double?
    /// From the reported percentage, not `1 - usedFraction`: 1 − 0.9 is
    /// 0.0999… in floating point, and floored that reads "9% left" at 90% used.
    public var remainingFraction: Double?
    public var resetsAt: Date?
    /// Nil for a scoped limit: Ullage's count for the window would cover every
    /// model, not the one the limit is on.
    public var windowStart: Date?
    public var observedAt: Date?
    public var hasResetSinceReading: Bool
    public var isStale: Bool
    public var isScoped: Bool
    public var isWarning: Bool { (usedFraction ?? 0) >= MenuBarFormatter.warningThreshold }
}

public enum PlanLimitFormatter {
    /// Older than this, a reading is shown with its age.
    public static let staleAfter: TimeInterval = 15 * 60

    public static func vendorName(_ vendor: String) -> String {
        switch vendor {
        case Vendor.claudeCode: return "Claude"
        case Vendor.codex: return "Codex"
        case Vendor.cursor: return "Cursor"
        default: return vendor
        }
    }

    static func vendorOrder(_ vendor: String) -> Int {
        [Vendor.claudeCode, Vendor.codex, Vendor.cursor].firstIndex(of: vendor) ?? 99
    }

    public static func displays(for rows: [PlanLimitRow], now: Date = Date()) -> [PlanLimitDisplay] {
        rows
            .sorted {
                (vendorOrder($0.vendor), $0.vendor, $0.sortOrder, $0.limitKey)
                    < (vendorOrder($1.vendor), $1.vendor, $1.sortOrder, $1.limitKey)
            }
            .map { row in
                let resetsAt = row.resetsAt.flatMap(Timestamps.date(from:))
                let observedAt = Timestamps.date(from: row.observedAt)
                let hasReset = resetsAt.map { $0 <= now } ?? false
                let windowStart: Date? = {
                    guard let resetsAt, let minutes = row.windowMinutes, !hasReset, !row.isScoped else { return nil }
                    return resetsAt.addingTimeInterval(-Double(minutes) * 60)
                }()
                return PlanLimitDisplay(
                    vendor: row.vendor,
                    vendorName: vendorName(row.vendor),
                    limitKey: row.limitKey,
                    label: row.label,
                    usedFraction: hasReset ? nil : min(max(row.usedPercent, 0), 100) / 100,
                    remainingFraction: hasReset ? nil : (100 - min(max(row.usedPercent, 0), 100)) / 100,
                    resetsAt: resetsAt,
                    windowStart: windowStart,
                    observedAt: observedAt,
                    hasResetSinceReading: hasReset,
                    isStale: observedAt.map { now.timeIntervalSince($0) > staleAfter } ?? true,
                    isScoped: row.isScoped
                )
            }
    }

    /// "4d 3h", "2h 10m", "45m", "<1m". Two units at most: it is a countdown to
    /// glance at, not a timer.
    public static func duration(_ interval: TimeInterval) -> String {
        let minutes = Int(max(0, interval) / 60)
        if minutes < 1 { return "<1m" }
        let days = minutes / 1440, hours = (minutes % 1440) / 60, mins = minutes % 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h" }
        return "\(mins)m"
    }

    /// The line under a limit's bar.
    public static func caption(for display: PlanLimitDisplay, now: Date = Date()) -> String {
        if display.hasResetSinceReading { return "reset since last reading" }
        var parts: [String] = []
        if let remaining = display.remainingFraction {
            parts.append(MenuBarFormatter.percentage(remaining) + " left")
        }
        if let resetsAt = display.resetsAt {
            parts.append("resets in " + duration(resetsAt.timeIntervalSince(now)))
        }
        if display.isStale, let observedAt = display.observedAt {
            parts.append("as of " + duration(now.timeIntervalSince(observedAt)) + " ago")
        }
        return parts.joined(separator: " · ")
    }
}

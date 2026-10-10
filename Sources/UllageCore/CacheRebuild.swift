import Foundation

/// A turn that paid to cache most of its context again instead of reading it.
///
/// Every figure here is measured: the rebuild is read off the turn's own
/// `cache_write` against its `context_tokens`, and its cause off what changed
/// since the turn before. Nothing is priced and nothing is called "wasted" —
/// an expired cache after a long break is not a mistake, and the cause is
/// what makes the difference worth showing.
public struct CacheRebuild: Equatable, Identifiable {
    public enum Cause: String, Equatable, CaseIterable {
        /// A long enough break that the cache had expired anyway.
        case expired
        case modelChanged = "model changed"
        /// Claude Code's version changed between the two turns, as when a
        /// session is resumed after an update.
        case upgraded
        case effortChanged = "effort changed"
        /// A slash command between the two turns that changes how the next
        /// request is built (`/model`, `/effort`, `/fast`, `/config`, …).
        case command
        /// Nothing on disk explains it.
        case unknown

        /// Something the session did, rather than time passing or nothing
        /// Ullage can see. Only these are put to the user as a warning.
        public var isAvoidable: Bool {
            switch self {
            case .modelChanged, .effortChanged, .command: return true
            case .expired, .upgraded, .unknown: return false
            }
        }
    }

    public var turnIndex: Int
    public var ts: String
    public var cause: Cause
    /// `cache_write` of the turn: what was cached again, measured.
    public var cacheWrite: Int
    public var contextTokens: Int
    /// `opus → fable`, `high → max`, `2.1.250 → 2.1.280`, `/model opus`, `idle 1h 12m`.
    public var detail: String?

    public var id: Int { turnIndex }
}

public enum CacheRebuilds {
    /// Below this, a full re-cache is too small to be worth a marker.
    public static let minimumContext = 50_000
    /// Share of the context written to cache that makes a turn a rebuild.
    /// Ordinary turns write only what is new (a few percent).
    public static let rebuildShare = 0.5
    /// A break longer than this expires a cache written with the one-hour
    /// lifetime, and any cache whose lifetime the line doesn't record.
    /// Observed on subscription data: 267 of 275 main-thread turns after 60+
    /// idle minutes rebuilt, against 104 of 23,000 after shorter gaps.
    public static let expiryGap: TimeInterval = 60 * 60
    /// The lifetime of a cache written with the five-minute TTL: Claude Code's
    /// on an API key, usage credits or a cloud provider, and every subagent's.
    public static let shortExpiryGap: TimeInterval = 5 * 60
    /// Commands that change how the next request is built.
    public static let cacheCommands: Set<String> = ["model", "effort", "fast", "config", "output-style", "mcp", "reload-plugins", "plugin"]
    /// Claude Code delivers a new output style as a message from this version
    /// on, so `/output-style` no longer touches the cached prefix.
    static let outputStyleKeepsCache = "2.1.251"

    /// `calls`: one stream (main thread or one agent), in turn order.
    /// `commands`: that session's slash-command events.
    /// `boundaryTurns`: the first turn after each compaction. Re-caching the
    /// summary there is the point of compacting, so those turns are skipped —
    /// as is the first turn after a `/clear`, found here from the commands.
    public static func detect(calls: [CallRow], commands: [EventRow] = [], boundaryTurns: Set<Int> = []) -> [CacheRebuild] {
        var rebuilds: [CacheRebuild] = []
        let slashCommands = commands
            .filter { $0.kind == EventKind.command.rawValue }
            .compactMap { event in SlashCommand(detail: event.detail).map { (event.ts, $0) } }
        let commandsByTs = slashCommands.filter { cacheCommands.contains($0.1.name) }
        let clears = slashCommands.filter { $0.1.name == "clear" }.map(\.0)
        // The lifetime of the cache as the previous turn left it: the latest
        // write that recorded one, since a turn may write nothing new.
        var lifetime: String?
        for (previous, call) in zip(calls, calls.dropFirst()) {
            lifetime = previous.cacheTTL ?? lifetime
            guard let turn = call.turnIndex,
                  !boundaryTurns.contains(turn),
                  !clears.contains(where: { $0 > previous.ts && $0 <= call.ts }),
                  call.contextTokens >= minimumContext,
                  Double(call.cacheWrite) > rebuildShare * Double(call.contextTokens) else { continue }

            let gap = Timestamps.date(from: call.ts).flatMap { now in
                Timestamps.date(from: previous.ts).map { now.timeIntervalSince($0) }
            }
            let command = commandsByTs.last { $0.0 > previous.ts && $0.0 <= call.ts }
                .flatMap { changesRequest($0.1, version: call.harnessVersion) ? $0.1 : nil }
            let expiry = lifetime == "5m" ? shortExpiryGap : expiryGap

            let cause: CacheRebuild.Cause
            let detail: String?
            if let gap, gap > expiry {
                cause = .expired
                detail = "idle " + duration(gap)
            } else if let a = previous.model, let b = call.model, a != b {
                cause = .modelChanged
                detail = "\(a) → \(b)"
            } else if let a = previous.harnessVersion, let b = call.harnessVersion, a != b {
                cause = .upgraded
                detail = "\(a) → \(b)"
            } else if let a = previous.effort, let b = call.effort, a != b {
                cause = .effortChanged
                detail = "\(a) → \(b)"
            } else if let command {
                cause = .command
                detail = "/" + command.name + (command.args.map { " " + $0 } ?? "")
            } else {
                cause = .unknown
                detail = nil
            }
            rebuilds.append(CacheRebuild(turnIndex: turn, ts: call.ts, cause: cause,
                                         cacheWrite: call.cacheWrite, contextTokens: call.contextTokens, detail: detail))
        }
        return rebuilds
    }

    /// Whether `command` still changes the request on the Claude Code version
    /// that ran the turn after it. An unknown version keeps the command.
    static func changesRequest(_ command: SlashCommand, version: String?) -> Bool {
        guard command.name == "output-style", let version else { return true }
        return compareVersions(version, outputStyleKeepsCache) == .orderedAscending
    }

    /// Compares dotted numeric versions (`2.1.99` < `2.1.251`); a part that
    /// isn't a number compares as 0.
    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p < q ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// `rebuilt 2× · model changed ×1, expired ×1`, most common cause first.
    public static func causeSummary(_ rebuilds: [CacheRebuild]) -> String {
        let counts = Dictionary(grouping: rebuilds, by: \.cause).mapValues(\.count)
        return CacheRebuild.Cause.allCases
            .compactMap { cause in counts[cause].map { (cause, $0) } }
            .sorted { $0.1 > $1.1 }
            .map { "\($0.0.rawValue) ×\($0.1)" }
            .joined(separator: ", ")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60, rest = minutes % 60
        if hours >= 24 { return "\(hours / 24)d \(hours % 24)h" }
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }
}

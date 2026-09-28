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
        case effortChanged = "effort changed"
        /// A slash command between the two turns that changes how the next
        /// request is built (`/model`, `/effort`, `/fast`, `/config`, …).
        case command
        /// Nothing on disk explains it.
        case unknown

        /// Something the session did, rather than time passing.
        public var isAvoidable: Bool { self != .expired }
    }

    public var turnIndex: Int
    public var ts: String
    public var cause: Cause
    /// `cache_write` of the turn: what was cached again, measured.
    public var cacheWrite: Int
    public var contextTokens: Int
    /// `opus → fable`, `high → max`, `/model opus`, `idle 1h 12m`.
    public var detail: String?

    public var id: Int { turnIndex }
}

public enum CacheRebuilds {
    /// Below this, a full re-cache is too small to be worth a marker.
    public static let minimumContext = 50_000
    /// Share of the context written to cache that makes a turn a rebuild.
    /// Ordinary turns write only what is new (a few percent).
    public static let rebuildShare = 0.5
    /// A break longer than this expires the cache on its own. Observed on
    /// this data: 267 of 275 main-thread turns after 60+ idle minutes rebuilt,
    /// against 104 of 23,000 after shorter gaps.
    public static let expiryGap: TimeInterval = 60 * 60
    /// Commands that change how the next request is built.
    public static let cacheCommands: Set<String> = ["model", "effort", "fast", "config", "output-style", "mcp", "reload-plugins", "plugin"]

    /// `calls`: one stream (main thread or one agent), in turn order.
    /// `commands`: that session's slash-command events.
    public static func detect(calls: [CallRow], commands: [EventRow] = []) -> [CacheRebuild] {
        var rebuilds: [CacheRebuild] = []
        let commandsByTs = commands
            .filter { $0.kind == EventKind.command.rawValue }
            .compactMap { event in SlashCommand(detail: event.detail).map { (event.ts, $0) } }
            .filter { cacheCommands.contains($0.1.name) }
        for (previous, call) in zip(calls, calls.dropFirst()) {
            guard let turn = call.turnIndex,
                  call.contextTokens >= minimumContext,
                  Double(call.cacheWrite) > rebuildShare * Double(call.contextTokens),
                  // A compaction or /clear shrinks the window; re-caching the
                  // summary after it is the point of it, not a rebuild.
                  Double(call.contextTokens) >= 0.6 * Double(previous.contextTokens) else { continue }

            let gap = Timestamps.date(from: call.ts).flatMap { now in
                Timestamps.date(from: previous.ts).map { now.timeIntervalSince($0) }
            }
            let command = commandsByTs.last { $0.0 > previous.ts && $0.0 <= call.ts }?.1

            let cause: CacheRebuild.Cause
            let detail: String?
            if let gap, gap > expiryGap {
                cause = .expired
                detail = "idle " + duration(gap)
            } else if let a = previous.model, let b = call.model, a != b {
                cause = .modelChanged
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

import Foundation

/// One thing worth waking a phone for.
public struct ContextAlert: Equatable {
    public var streamKey: String
    public var sessionId: String
    public var project: String?
    public var model: String?
    public var threshold: Double
    public var occupancy: Double
    public var contextTokens: Int
    public var windowLimit: Int
    public var title: String
    public var body: String
}

/// When to say something, and — much more importantly — when to shut up.
///
/// Level-triggered alerting is the obvious implementation and the wrong one: a
/// session that crosses 85% sends a notification on *every* turn from there to
/// the end, which trains you to swipe them away by the third. So this is edge
/// triggered per stream, and the edge it remembers is persisted, because a
/// restart is not new information.
public enum AlertRule {
    /// The first is the menu bar's own amber threshold, so the phone and the
    /// Mac agree about when a window has become a problem.
    public static let defaultThresholds: [Double] = [MenuBarFormatter.warningThreshold, 0.95]

    public enum Decision: Equatable {
        case fire(ContextAlert)
        /// Back below every threshold — a compaction, usually. Forget what was
        /// said so the next climb is announced again.
        case rearm(streamKey: String)
        case nothing
    }

    /// `(session_id, agent_id)` is the key for everything else about a stream,
    /// so it is the key here too.
    public static func streamKey(sessionId: String, agentId: String?) -> String {
        sessionId + "|" + (agentId ?? "main")
    }

    public static func decide(
        call: CallRow,
        firedThreshold: Double?,
        thresholds: [Double] = defaultThresholds,
        now: Date = Date(),
        idleThreshold: TimeInterval = MenuBarFormatter.idleThreshold
    ) -> Decision {
        // Rule 1: a subagent's window is its own, and it is not the window you
        // are about to run out of. The phone speaks for the main thread only.
        guard call.agentId == nil else { return .nothing }
        // Rule 3: no window, no occupancy, no alert. An unmeasured harness does
        // not get a guessed percentage, least of all one that buzzes.
        guard let windowLimit = call.windowLimit, let occupancy = call.occupancy else { return .nothing }
        // Rule 6, and harder here than in the menu bar: a Claude model the
        // lookup table does not know falls back to 200k, and the resulting
        // percentage is flagged "assumed" on screen. A phone buzz cannot carry
        // that flag in a way anyone reads, so it does not buzz at all. Codex
        // reports its window on every turn and is never assumed.
        if call.vendor == Vendor.claudeCode, !WindowLimits.isKnown(call.model) { return .nothing }
        // A backfill re-reads months of transcripts. Every one of those sessions
        // crossed 85% at some point and none of them is news.
        guard let timestamp = Timestamps.date(from: call.ts),
              now.timeIntervalSince(timestamp) <= idleThreshold else { return .nothing }

        let key = streamKey(sessionId: call.sessionId, agentId: call.agentId)
        let sorted = thresholds.sorted()
        guard let crossed = sorted.last(where: { occupancy >= $0 }) else {
            // Below everything: if something was said before, this is the
            // compaction that makes it stale.
            return firedThreshold == nil ? .nothing : .rearm(streamKey: key)
        }
        // Already said this, or something louder. 95% does still follow 85%;
        // only the same rung twice is silent.
        if let firedThreshold, crossed <= firedThreshold { return .nothing }

        let percentage = MenuBarFormatter.percentage(occupancy)
        return .fire(ContextAlert(
            streamKey: key,
            sessionId: call.sessionId,
            project: call.project,
            model: call.model,
            threshold: crossed,
            occupancy: occupancy,
            contextTokens: call.contextTokens,
            windowLimit: windowLimit,
            title: percentage + " · " + (call.project ?? "context window"),
            body: AlertRule.grouped(call.contextTokens) + " of " + AlertRule.grouped(windowLimit)
                + " tokens" + (call.model.map { " · " + $0 } ?? "")
        ))
    }

    static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

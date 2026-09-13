import Foundation

/// M5 — what the popover shows beyond the single headline number: which
/// sessions are around to choose from, and how one session's context moved
/// turn by turn. Computed here so the rules are testable without a UI.

/// One row of the session picker.
public struct SessionSummary: Equatable, Identifiable {
    public var sessionId: String
    public var project: String?
    public var model: String?
    public var lastTs: String
    public var lastContextTokens: Int
    public var windowLimit: Int?
    public var calls: Int

    public var id: String { sessionId }

    public var occupancy: Double? {
        guard let windowLimit, windowLimit > 0 else { return nil }
        return Double(lastContextTokens) / Double(windowLimit)
    }

    public init(
        sessionId: String,
        project: String? = nil,
        model: String? = nil,
        lastTs: String,
        lastContextTokens: Int,
        windowLimit: Int? = nil,
        calls: Int
    ) {
        self.sessionId = sessionId
        self.project = project
        self.model = model
        self.lastTs = lastTs
        self.lastContextTokens = lastContextTokens
        self.windowLimit = windowLimit
        self.calls = calls
    }
}

/// One turn on the chart.
public struct ContextPoint: Equatable, Identifiable {
    public var turnIndex: Int
    public var ts: String
    public var contextTokens: Int
    public var contextDelta: Int?

    public var id: Int { turnIndex }

    public init(turnIndex: Int, ts: String, contextTokens: Int, contextDelta: Int? = nil) {
        self.turnIndex = turnIndex
        self.ts = ts
        self.contextTokens = contextTokens
        self.contextDelta = contextDelta
    }
}

/// A session's context per turn, plus where compaction fired.
///
/// Compaction is the one moment the line falls off a cliff between adjacent
/// turns. Without a marker that reads as a bug; with one it is the most
/// interesting thing on the chart.
public struct ContextHistory: Equatable {
    public var sessionId: String
    public var windowLimit: Int?
    public var points: [ContextPoint]
    /// Turn indexes whose prompt was the first one *after* a compaction.
    public var compactionTurns: [Int]

    public var peakContextTokens: Int { points.map(\.contextTokens).max() ?? 0 }

    public init(sessionId: String, windowLimit: Int?, points: [ContextPoint], compactionTurns: [Int]) {
        self.sessionId = sessionId
        self.windowLimit = windowLimit
        self.points = points
        self.compactionTurns = compactionTurns
    }

    /// `calls` in turn order (the store's `calls(sessionId:)` ordering);
    /// `events` of any kind, only compactions are used. Timestamps are the
    /// store's normalised UTC strings, so string comparison is chronological.
    public static func build(sessionId: String, calls: [CallRow], events: [EventRow]) -> ContextHistory {
        let points = calls.compactMap { call -> ContextPoint? in
            guard let turn = call.turnIndex else { return nil }
            return ContextPoint(
                turnIndex: turn,
                ts: call.ts,
                contextTokens: call.contextTokens,
                contextDelta: call.contextDelta
            )
        }
        // The last known limit describes the whole chart; a session does not
        // change window mid-flight, and if the model changed the newest wins.
        let windowLimit = calls.last(where: { $0.windowLimit != nil })?.windowLimit

        var compactionTurns = Set<Int>()
        for event in events where event.kind == EventKind.compaction.rawValue {
            if let next = points.first(where: { $0.ts >= event.ts }) {
                compactionTurns.insert(next.turnIndex)
            }
        }
        return ContextHistory(
            sessionId: sessionId,
            windowLimit: windowLimit,
            points: points,
            compactionTurns: compactionTurns.sorted()
        )
    }
}

/// Which session the menu bar follows.
///
/// `automatic` is v1's rule — whichever session spoke last — and stays the
/// default because it needs no decision from the user. `pinned` holds one
/// session still while others are talking.
public enum SessionSelection: Hashable {
    case automatic
    case pinned(String)

    public var pinnedSessionId: String? {
        if case .pinned(let id) = self { return id }
        return nil
    }

    /// The call to display. A pinned session that has no rows (deleted, or
    /// not yet ingested) falls back to the newest overall rather than showing
    /// nothing: an empty menu bar is worse than the automatic answer.
    public static func resolve(
        _ selection: SessionSelection,
        latestOverall: CallRow?,
        latestInSession: (String) throws -> CallRow?
    ) rethrows -> CallRow? {
        guard let pinned = selection.pinnedSessionId else { return latestOverall }
        return try latestInSession(pinned) ?? latestOverall
    }
}

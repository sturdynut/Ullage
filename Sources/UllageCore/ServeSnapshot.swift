import Foundation

/// What a browser gets from `ullage serve`.
///
/// The rules live here and not in the page, so the phone and the menu bar
/// cannot drift apart: both read `MenuBarFormatter`, and a number too old to
/// trust goes quiet in a browser for the same reason it does in the menu bar.
public struct ServeSnapshot: Codable, Equatable {

    /// The one stream the gauge is about: the newest main-thread turn that has
    /// a window. `MenuBarState` with one addition — an absolute age in seconds,
    /// because the phone's clock is not this machine's and a rendered "2 min
    /// ago" computed from two different clocks is a lie waiting to happen.
    public struct Live: Codable, Equatable {
        public var status: String       // empty | idle | live | warning
        public var title: String
        public var occupancy: Double?
        public var contextTokens: Int?
        public var windowLimit: Int?
        public var contextDelta: Int?
        public var sessionId: String?
        public var project: String?
        public var model: String?
        public var modelWindowIsAssumed: Bool
        public var lastActivity: String?
        public var ageSeconds: Double?
    }

    public struct Session: Codable, Equatable {
        public var sessionId: String
        public var project: String?
        public var model: String?
        public var lastTs: String
        public var contextTokens: Int
        public var windowLimit: Int?
        /// Nil whenever the harness reported no window. A Cursor session gets
        /// no percentage here for the same reason it gets none anywhere else:
        /// an unmeasured row is not a zero, and it is not a guess.
        public var occupancy: Double?
        public var calls: Int
        public var agents: Int
        public var ageSeconds: Double?
    }

    public var generatedAt: String
    /// Sent rather than hardcoded in the page, so the browser turns amber at
    /// the same instant the menu bar does.
    public var warningThreshold: Double
    public var idleThresholdSeconds: Double
    public var live: Live
    public var sessions: [Session]
}

extension ServeSnapshot {
    public static func build(
        store: Store,
        sessionLimit: Int = 20,
        now: Date = Date()
    ) throws -> ServeSnapshot {
        // `latestCall()` already refuses window-less and subagent rows; the
        // gauge in a browser is the same gauge, so it reuses that filter rather
        // than writing a second one that can disagree with it.
        let state = MenuBarFormatter.state(for: try store.latestCall(), now: now)
        let sessions = try store.recentSessions(limit: sessionLimit).map { summary in
            Session(
                sessionId: summary.sessionId,
                project: summary.project,
                model: summary.model,
                lastTs: summary.lastTs,
                contextTokens: summary.lastContextTokens,
                windowLimit: summary.windowLimit,
                occupancy: summary.occupancy,
                calls: summary.calls,
                agents: summary.agents,
                ageSeconds: age(of: summary.lastTs, now: now)
            )
        }
        return ServeSnapshot(
            generatedAt: Timestamps.string(from: now),
            warningThreshold: MenuBarFormatter.warningThreshold,
            idleThresholdSeconds: MenuBarFormatter.idleThreshold,
            live: Live(state: state, now: now),
            sessions: sessions
        )
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    static func age(of timestamp: String?, now: Date) -> Double? {
        guard let timestamp, let date = Timestamps.date(from: timestamp) else { return nil }
        return now.timeIntervalSince(date)
    }
}

extension ServeSnapshot.Live {
    init(state: MenuBarState, now: Date) {
        self.init(
            status: ServeSnapshot.name(of: state.status),
            title: state.title,
            occupancy: state.occupancy,
            contextTokens: state.contextTokens,
            windowLimit: state.windowLimit,
            contextDelta: state.contextDelta,
            sessionId: state.sessionId,
            project: state.project,
            model: state.model,
            modelWindowIsAssumed: state.modelWindowIsAssumed,
            lastActivity: state.lastActivity.map(Timestamps.string(from:)),
            ageSeconds: state.lastActivity.map { now.timeIntervalSince($0) }
        )
    }
}

extension ServeSnapshot {
    /// Spelled out rather than reflected: this string is a wire format the page
    /// switches on, so renaming a case must break a test, not a browser.
    static func name(of status: MenuBarState.Status) -> String {
        switch status {
        case .empty: return "empty"
        case .idle: return "idle"
        case .live: return "live"
        case .warning: return "warning"
        }
    }
}

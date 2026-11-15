#if os(macOS)
import Foundation
import UllageCore

struct MenuBarSnapshot {
    var menuBarState = MenuBarFormatter.state(for: nil)
    var state = MenuBarFormatter.state(for: nil)
    var pinFellBack = false
    var sessions: [SessionSummary] = []
    var agents: AgentTree?
    var focus: AgentScope = .mainThread
    var history: ContextHistory?
    var composition: ContextComposition?
    var sessionLink: SessionLink?
    var planLimits: [PlanLimitDisplay] = []
    var planLimitUsage: [String: Store.WindowUsage] = [:]

    static func read(path: String, selection: SessionSelection, focus: AgentScope,
                     held: String?, limit: Int) throws -> Self {
        let store = try Store(path: path)
        var data = Self()
        let latest = try store.latestCall()
        let resolved = try SessionSelection.resolve(selection, latestOverall: latest) {
            try store.latestCall(sessionId: $0)
        }
        data.menuBarState = MenuBarFormatter.state(for: resolved)
        var shown = resolved
        if selection == .automatic, let held,
           let stillThere = try store.latestCall(sessionId: held) { shown = stillThere }
        data.state = MenuBarFormatter.state(for: shown)
        data.pinFellBack = selection.pinnedSessionId != nil && shown?.sessionId != selection.pinnedSessionId
        data.sessions = try store.recentSessions(limit: limit)
        data.agents = try shown.map { try store.agentTree(sessionId: $0.sessionId) }
        data.focus = focus
        if case .agent(let id) = focus,
           data.agents?.flattened.contains(where: { $0.agent.agentId == id }) != true { data.focus = .mainThread }
        data.history = try shown.map { try store.contextHistory(sessionId: $0.sessionId, scope: data.focus) }
        data.composition = try shown.flatMap { try store.composition(sessionId: $0.sessionId, scope: data.focus) }
        data.sessionLink = try shown.flatMap { try store.sessionLink(sessionId: $0.sessionId) }
        data.planLimits = PlanLimitFormatter.displays(for: try store.planLimits())
        for limit in data.planLimits {
            guard let start = limit.windowStart else { continue }
            data.planLimitUsage[limit.id] = try store.windowUsage(
                vendor: limit.vendor, since: Timestamps.string(from: start)
            )
        }
        return data
    }
}
#endif

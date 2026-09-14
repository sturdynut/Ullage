import Foundation

/// M8 — who spawned whom, and how full each one's own window got.
///
/// A subagent is neither a session nor a turn of the parent's session: it is an
/// independent context window owned by one turn of the parent. Claude Code
/// writes it to its own transcript (`<session>/subagents/agent-<id>.jsonl`)
/// whose lines carry the *parent's* `sessionId`, so without an explicit stream
/// key every subagent turn lands in the parent's series and the parent's chart
/// reads as a sawtooth of windows that were never the same window.
///
/// Every figure here is measured. The label is the description the parent wrote
/// when it spawned the agent, the type is `attributionAgent`, and the occupancy
/// is the agent's own last prompt over its own window.

/// Which stream of a session a query is about.
///
/// `.mainThread` is the default everywhere a gauge, a chart or a composition is
/// involved: mixing streams produces a curve that never existed on any screen.
/// `.all` is for rollups that count turns rather than plot them.
public enum AgentScope: Equatable {
    case mainThread
    case agent(String)
    case all
}

/// One spawned agent, joined to the turns it actually recorded.
public struct AgentSummary: Equatable, Identifiable {
    public var agentId: String
    public var sessionId: String
    /// The agent that spawned this one; nil when the main thread did.
    public var parentAgentId: String?
    /// `attributionAgent` / `agentType`: "Explore", "general-purpose", …
    public var agentType: String?
    /// The `description` the parent passed to the `Agent` tool — the name one
    /// agent gave another, and the only human-written text in this struct.
    public var label: String?
    public var model: String?
    /// As the parent saw the run end: completed, error, …
    public var status: String?
    public var calls: Int
    public var lastContextTokens: Int?
    public var windowLimit: Int?
    public var peakContextTokens: Int?
    public var toolCalls: Int
    /// The parent's own tool-use count for the run. Kept as a cross-check on
    /// `toolCalls`; the parent also reports a `totalTokens`, which is one
    /// turn's four counters summed, so it is deliberately not stored.
    public var reportedToolUses: Int?
    public var durationMs: Int?
    public var firstTs: String?
    public var lastTs: String?

    public var id: String { agentId }

    public init(
        agentId: String,
        sessionId: String,
        parentAgentId: String? = nil,
        agentType: String? = nil,
        label: String? = nil,
        model: String? = nil,
        status: String? = nil,
        calls: Int = 0,
        lastContextTokens: Int? = nil,
        windowLimit: Int? = nil,
        peakContextTokens: Int? = nil,
        toolCalls: Int = 0,
        reportedToolUses: Int? = nil,
        durationMs: Int? = nil,
        firstTs: String? = nil,
        lastTs: String? = nil
    ) {
        self.agentId = agentId
        self.sessionId = sessionId
        self.parentAgentId = parentAgentId
        self.agentType = agentType
        self.label = label
        self.model = model
        self.status = status
        self.calls = calls
        self.lastContextTokens = lastContextTokens
        self.windowLimit = windowLimit
        self.peakContextTokens = peakContextTokens
        self.toolCalls = toolCalls
        self.reportedToolUses = reportedToolUses
        self.durationMs = durationMs
        self.firstTs = firstTs
        self.lastTs = lastTs
    }

    /// The agent's own window, never the parent's.
    public var occupancy: Double? {
        guard let windowLimit, windowLimit > 0, let lastContextTokens else { return nil }
        return Double(lastContextTokens) / Double(windowLimit)
    }

    public var peakOccupancy: Double? {
        guard let windowLimit, windowLimit > 0, let peakContextTokens else { return nil }
        return Double(peakContextTokens) / Double(windowLimit)
    }

    /// What to call it in a list. The parent's description first because that is
    /// the one string written for a human; the type is the fallback, and the id
    /// is the last resort so a row is never nameless.
    public var displayName: String {
        if let label, !label.isEmpty { return label }
        if let agentType, !agentType.isEmpty { return agentType }
        return "agent " + String(agentId.prefix(8))
    }

    /// Type plus model, for the second line. Nil when neither is known.
    public var detail: String? {
        let parts = [agentType, model].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// True until the parent records the run as completed: still working,
    /// launched in the background and never collected, or a transcript that
    /// aged out before the result was written.
    public var isUnfinished: Bool { status != "completed" }

    /// Status as observed on 2026-09-13: `completed`, or `async_launched` for
    /// an agent the parent started in the background rather than waiting for.
    /// Anything else passes through unchanged instead of being reinterpreted,
    /// and a completed run says nothing at all.
    public var statusLabel: String? {
        switch status {
        case nil: return "no result recorded"
        case "completed": return nil
        case "async_launched": return "background"
        case let other: return other
        }
    }
}

/// The spawn tree for one session: the main thread's agents, their agents, and
/// so on. Depth is not capped by the format, only by what the data shows.
public struct AgentTree: Equatable {
    public struct Node: Equatable, Identifiable {
        public var agent: AgentSummary
        public var depth: Int
        public var children: [Node]

        public var id: String { agent.agentId }

        public init(agent: AgentSummary, depth: Int, children: [Node] = []) {
            self.agent = agent
            self.depth = depth
            self.children = children
        }
    }

    public var sessionId: String
    public var roots: [Node]

    public init(sessionId: String, roots: [Node]) {
        self.sessionId = sessionId
        self.roots = roots
    }

    public var isEmpty: Bool { roots.isEmpty }

    /// Depth-first, parents before their children: what a flat list renders.
    public var flattened: [Node] {
        func walk(_ nodes: [Node]) -> [Node] {
            nodes.flatMap { [$0] + walk($0.children) }
        }
        return walk(roots)
    }

    public var count: Int { flattened.count }

    /// Agents whose window is at or above the menu bar's warning threshold.
    public func crowded(threshold: Double = MenuBarFormatter.warningThreshold) -> [AgentSummary] {
        flattened.map(\.agent).filter { ($0.occupancy ?? 0) >= threshold }
    }

    /// Ordered by first turn, oldest first, so the tree reads as the order the
    /// work was handed out.
    ///
    /// An agent whose parent is not in the list is attached at the root rather
    /// than dropped: the parent's transcript may have aged out of `~/.claude`
    /// while the child's has not, and a spawn we cannot place is still a spawn
    /// that happened. A parent cycle (never observed; defended against because
    /// the ids come from a file format, not from us) is broken the same way.
    public static func build(sessionId: String, agents: [AgentSummary]) -> AgentTree {
        let ordered = agents.sorted {
            let left = $0.firstTs ?? $0.lastTs ?? ""
            let right = $1.firstTs ?? $1.lastTs ?? ""
            return left != right ? left < right : $0.agentId < $1.agentId
        }
        let known = Set(ordered.map(\.agentId))
        var childrenByParent: [String: [AgentSummary]] = [:]
        var roots: [AgentSummary] = []
        for agent in ordered {
            if let parent = agent.parentAgentId, parent != agent.agentId, known.contains(parent) {
                childrenByParent[parent, default: []].append(agent)
            } else {
                roots.append(agent)
            }
        }

        var visited = Set<String>()
        func node(for agent: AgentSummary, depth: Int) -> Node {
            visited.insert(agent.agentId)
            let children = (childrenByParent[agent.agentId] ?? [])
                .filter { !visited.contains($0.agentId) }
                .map { node(for: $0, depth: depth + 1) }
            return Node(agent: agent, depth: depth, children: children)
        }
        var nodes = roots.map { node(for: $0, depth: 0) }
        // Anything a cycle kept out of the walk is still an agent that ran, so
        // it is shown at the root rather than silently dropped.
        for agent in ordered where !visited.contains(agent.agentId) {
            nodes.append(node(for: agent, depth: 0))
        }
        return AgentTree(sessionId: sessionId, roots: nodes)
    }
}

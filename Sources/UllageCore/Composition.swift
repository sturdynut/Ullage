import Foundation

/// M7 — what the window is made of.
///
/// The transcript never says what the prompt contained; it only says how big
/// it was. But the size at each turn is cumulative, so the *differences*
/// between turns can be attributed to what was appended in between: the tool
/// results that came back, the assistant's own output, and whatever else the
/// user typed. The first turn of a window is the fixed overhead nothing in the
/// conversation caused — system prompt, tool schemas, skills, CLAUDE.md and
/// the opening prompt — and after a compaction the summary takes that role.
///
/// Every figure but `contextTokens` and `baseline` is an estimate and is
/// labelled as one. `other` absorbs the estimate error and is clamped at zero.
public struct ContextComposition: Equatable {
    public struct Segment: Equatable, Identifiable {
        public var name: String
        public var tokens: Int
        public var id: String { name }
    }

    public struct ToolShare: Equatable, Identifiable {
        public var name: String
        public var kind: String
        public var server: String?
        public var calls: Int
        public var resultTokens: Int
        public var id: String { name }
    }

    public static let baselineName = "Baseline"
    public static let toolResultsName = "Tool results"
    // "Assistant output" did not fit the popover's legend column and was
    // truncated to "Assistant out…" on the segment that is routinely the
    // largest share of the window.
    public static let assistantOutputName = "Output"
    public static let otherName = "Other"

    public var sessionId: String
    public var windowLimit: Int?
    /// The last turn's prompt size: what is in the window right now.
    public var contextTokens: Int
    public var lastTurn: Int
    /// First turn of the current window: 0, or the first turn after the most
    /// recent compaction.
    public var windowStartTurn: Int
    public var compactions: Int

    public var baseline: Int
    public var toolResults: Int
    public var assistantOutput: Int
    public var other: Int
    /// True when the estimates add up to more than the window holds; `other`
    /// is then zero and the shares are approximate.
    public var estimatesOvershoot: Bool

    /// Tools whose results landed in the current window, largest first.
    public var tools: [ToolShare]
    public var environment: SessionEnvRow?

    public var occupancy: Double? {
        guard let windowLimit, windowLimit > 0 else { return nil }
        return Double(contextTokens) / Double(windowLimit)
    }

    /// Fixed order, so a segment keeps its colour whatever its size.
    public var segments: [Segment] {
        [
            Segment(name: Self.baselineName, tokens: baseline),
            Segment(name: Self.toolResultsName, tokens: toolResults),
            Segment(name: Self.assistantOutputName, tokens: assistantOutput),
            Segment(name: Self.otherName, tokens: other),
        ]
    }

    public func share(_ tokens: Int) -> Double {
        contextTokens > 0 ? Double(tokens) / Double(contextTokens) : 0
    }

    // What the environment snapshot says rode along in the baseline.
    public var mcpServers: [String] { Self.names(environment?.mcpServers) }
    public var skills: [String] { Self.names(environment?.skills) }
    /// CLAUDE.md is in the prompt on every turn; ~4 bytes per token is the
    /// same rough estimate the tool-result figures use.
    public var claudeMdTokensEstimate: Int? { environment?.claudeMdBytes.map { $0 / 4 } }

    static func names(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return array
    }

    /// `calls` in turn order (the store's ordering); `toolCalls` for the same
    /// session; `events` of any kind. Nil when the session has no turns.
    public static func build(
        sessionId: String,
        calls: [CallRow],
        toolCalls: [ToolCallRow],
        events: [EventRow],
        environment: SessionEnvRow? = nil
    ) -> ContextComposition? {
        let turns = calls.filter { $0.turnIndex != nil }
        guard let last = turns.last, let lastTurn = last.turnIndex else { return nil }

        let compactions = events
            .filter { $0.kind == EventKind.compaction.rawValue }
            .sorted { $0.ts < $1.ts }
        var windowStart = turns.first
        if let latest = compactions.last,
           let after = turns.first(where: { $0.ts >= latest.ts }) {
            windowStart = after
        }
        // One boundary writes more than one line — a `compact_boundary` system
        // entry and a summary entry, ~0.3s apart — so counting events counts
        // every compaction twice. A boundary is the turn the window restarted
        // at, which is also how the chart marks them, so the two agree.
        let boundaryTurns = Set(compactions.compactMap { event in
            turns.first(where: { $0.ts >= event.ts })?.turnIndex
        })
        let windowStartTurn = windowStart?.turnIndex ?? 0
        let baseline = windowStart?.contextTokens ?? last.contextTokens

        // Everything appended between the window's first prompt and the last
        // one: results and output of turns [start, last), which the prompt at
        // `last` then carries.
        let prior = turns.filter { ($0.turnIndex ?? -1) >= windowStartTurn && ($0.turnIndex ?? -1) < lastTurn }
        let priorKeys = Set(prior.map(\.dedupeKey))
        let assistantOutput = prior.reduce(0) { $0 + $1.output }

        var shares: [String: ToolShare] = [:]
        for tool in toolCalls where priorKeys.contains(tool.callId) {
            var share = shares[tool.name] ?? ToolShare(
                name: tool.name, kind: tool.kind, server: tool.mcpServer, calls: 0, resultTokens: 0
            )
            share.calls += 1
            share.resultTokens += tool.resultTokens ?? 0
            shares[tool.name] = share
        }
        let tools = shares.values.sorted {
            $0.resultTokens != $1.resultTokens ? $0.resultTokens > $1.resultTokens : $0.name < $1.name
        }
        let toolResults = tools.reduce(0) { $0 + $1.resultTokens }

        let remainder = last.contextTokens - baseline - toolResults - assistantOutput
        return ContextComposition(
            sessionId: sessionId,
            windowLimit: last.windowLimit,
            contextTokens: last.contextTokens,
            lastTurn: lastTurn,
            windowStartTurn: windowStartTurn,
            compactions: boundaryTurns.count,
            baseline: baseline,
            toolResults: toolResults,
            assistantOutput: assistantOutput,
            other: max(0, remainder),
            estimatesOvershoot: remainder < 0,
            tools: tools,
            environment: environment
        )
    }
}

/// M6 — one project's activity on one day. Four counters, never summed.
public struct DailyActivity: Equatable, Identifiable {
    public var day: String          // YYYY-MM-DD, local time
    public var project: String
    public var sessions: Int
    public var calls: Int
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    public var peakContextTokens: Int

    public var id: String { day + "|" + project }

    public init(
        day: String, project: String, sessions: Int, calls: Int,
        input: Int, output: Int, cacheRead: Int, cacheWrite: Int, peakContextTokens: Int
    ) {
        self.day = day
        self.project = project
        self.sessions = sessions
        self.calls = calls
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.peakContextTokens = peakContextTokens
    }
}

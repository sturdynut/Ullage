import Foundation

/// M9 — everything Ullage measured, in OTLP, so several machines and several
/// harnesses aggregate in one place.
///
/// OTLP's JSON encoding is written by hand here rather than by taking a
/// dependency: the payloads are a handful of nested dictionaries, the package
/// has no dependencies beyond system SQLite, and an exporter is exactly the
/// kind of thing that should not pull gRPC and protobuf into a menu bar app.
///
/// **The trap this file exists to avoid.** `gen_ai.usage.input_tokens` means
/// the whole prompt. Claude's `input_tokens` does not — it is the uncached
/// remainder, and exporting it under that name would understate every cached
/// session by an order of magnitude, in someone else's dashboard, where nobody
/// can see the mistake. The prompt is `input + cache_read + cache_write`, which
/// is `context_tokens`, and that is what goes out under the standard name. The
/// four counters still travel separately, under `ullage.tokens`, because a
/// single "total tokens" number is a cache-read number in disguise.
public enum OTLP {
    public static let scopeName = "ullage"

    /// OTLP JSON encodes 64-bit integers as strings, and timestamps as
    /// nanoseconds since the epoch — also as strings.
    static func nanoseconds(_ date: Date) -> String {
        String(Int64((date.timeIntervalSince1970 * 1_000_000_000).rounded()))
    }

    static func nanoseconds(_ timestamp: String) -> String? {
        Timestamps.date(from: timestamp).map(nanoseconds)
    }

    // MARK: - Attributes

    static func attribute(_ key: String, _ value: String?) -> [String: Any]? {
        guard let value, !value.isEmpty else { return nil }
        return ["key": key, "value": ["stringValue": value]]
    }

    static func attribute(_ key: String, int value: Int?) -> [String: Any]? {
        guard let value else { return nil }
        return ["key": key, "value": ["intValue": String(value)]]
    }

    static func attribute(_ key: String, double value: Double?) -> [String: Any]? {
        guard let value else { return nil }
        return ["key": key, "value": ["doubleValue": value]]
    }

    /// `claude-code` is a harness; `anthropic` is the system that answered.
    /// `gen_ai.system` wants the latter, and the harness travels alongside it so
    /// nothing is lost.
    public static func genAISystem(forVendor vendor: String) -> String {
        switch vendor {
        case Vendor.claudeCode: return "anthropic"
        case Vendor.codex: return "openai"
        default: return vendor
        }
    }
}

/// What every exported signal is tagged with: which machine, which install.
public struct OTLPResource {
    public var serviceName: String
    /// Distinguishes one machine's Ullage from another's when both report into
    /// the same backend — the whole point of exporting.
    public var serviceInstanceId: String?
    public var serviceVersion: String?
    public var extra: [String: String]

    public init(
        serviceName: String = OTLP.scopeName,
        serviceInstanceId: String? = ProcessInfo.processInfo.hostName,
        serviceVersion: String? = nil,
        extra: [String: String] = [:]
    ) {
        self.serviceName = serviceName
        self.serviceInstanceId = serviceInstanceId
        self.serviceVersion = serviceVersion
        self.extra = extra
    }

    var json: [String: Any] {
        var attributes: [[String: Any]] = [
            OTLP.attribute("service.name", serviceName),
            OTLP.attribute("service.instance.id", serviceInstanceId),
            OTLP.attribute("service.version", serviceVersion),
        ].compactMap { $0 }
        for key in extra.keys.sorted() {
            if let attribute = OTLP.attribute(key, extra[key]) { attributes.append(attribute) }
        }
        return ["attributes": attributes]
    }
}

/// One context stream's totals: the row shape the metrics export is built from.
///
/// A stream is one window — a session's main thread, or one of its subagents —
/// because that is the only grouping where these numbers mean anything.
public struct StreamTotals: Equatable {
    public var sessionId: String
    public var agentId: String?
    public var agentType: String?
    public var project: String?
    public var vendor: String
    public var model: String?
    public var confidence: String
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    public var turns: Int
    public var lastContextTokens: Int?
    public var windowLimit: Int?
    public var peakContextTokens: Int?
    public var toolCalls: Int
    /// A length estimate, always. Exported with `ullage.estimated` set.
    public var toolResultTokens: Int
    public var compactions: Int
    public var firstTs: String
    public var lastTs: String

    public init(
        sessionId: String,
        agentId: String? = nil,
        agentType: String? = nil,
        project: String? = nil,
        vendor: String = Vendor.claudeCode,
        model: String? = nil,
        confidence: String = Confidence.exact.rawValue,
        input: Int = 0,
        output: Int = 0,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        turns: Int = 0,
        lastContextTokens: Int? = nil,
        windowLimit: Int? = nil,
        peakContextTokens: Int? = nil,
        toolCalls: Int = 0,
        toolResultTokens: Int = 0,
        compactions: Int = 0,
        firstTs: String,
        lastTs: String
    ) {
        self.sessionId = sessionId
        self.agentId = agentId
        self.agentType = agentType
        self.project = project
        self.vendor = vendor
        self.model = model
        self.confidence = confidence
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.turns = turns
        self.lastContextTokens = lastContextTokens
        self.windowLimit = windowLimit
        self.peakContextTokens = peakContextTokens
        self.toolCalls = toolCalls
        self.toolResultTokens = toolResultTokens
        self.compactions = compactions
        self.firstTs = firstTs
        self.lastTs = lastTs
    }

    /// The whole prompt, which is what `gen_ai.usage.input_tokens` means.
    public var promptTokens: Int? { lastContextTokens }

    public var occupancy: Double? {
        guard let windowLimit, windowLimit > 0, let lastContextTokens,
              confidence != Confidence.unmeasured.rawValue else { return nil }
        return Double(lastContextTokens) / Double(windowLimit)
    }

    /// A harness that reports no tokens exports activity and nothing else: a
    /// zero next to three real numbers reads as "this session used none".
    public var isMeasured: Bool { confidence != Confidence.unmeasured.rawValue }
}

// MARK: - Metrics

extension OTLP {
    /// Cumulative sums and point-in-time gauges, one data point per stream.
    ///
    /// Cumulative rather than delta on purpose: the export is a snapshot of
    /// everything on disk, so re-running it is idempotent — the collector sees
    /// the same monotonic series, not double-counted turns.
    public static func metrics(
        streams: [StreamTotals],
        resource: OTLPResource = OTLPResource(),
        at now: Date = Date()
    ) -> [String: Any] {
        let time = nanoseconds(now)

        var tokenPoints: [[String: Any]] = []
        var turnPoints: [[String: Any]] = []
        var toolPoints: [[String: Any]] = []
        var toolTokenPoints: [[String: Any]] = []
        var compactionPoints: [[String: Any]] = []
        var contextPoints: [[String: Any]] = []
        var windowPoints: [[String: Any]] = []
        var occupancyPoints: [[String: Any]] = []

        for stream in streams {
            let attributes = self.attributes(for: stream)
            let start = nanoseconds(stream.firstTs) ?? time

            if stream.isMeasured {
                // Four series, never one. A session is ~99% cache reads, so a
                // single "tokens" number would just be a cache-read number.
                for (type, value) in [
                    ("input", stream.input),
                    ("output", stream.output),
                    ("cache_read", stream.cacheRead),
                    ("cache_write", stream.cacheWrite),
                ] {
                    tokenPoints.append(sumPoint(
                        value: value,
                        attributes: attributes + [attribute("ullage.token.type", type)].compactMap { $0 },
                        start: start,
                        time: time
                    ))
                }
                if let context = stream.lastContextTokens {
                    contextPoints.append(gaugePoint(int: context, attributes: attributes, time: time))
                }
                if let window = stream.windowLimit {
                    windowPoints.append(gaugePoint(int: window, attributes: attributes, time: time))
                }
                if let occupancy = stream.occupancy {
                    occupancyPoints.append(gaugePoint(double: occupancy, attributes: attributes, time: time))
                }
                if stream.toolResultTokens > 0 {
                    toolTokenPoints.append(sumPoint(
                        value: stream.toolResultTokens,
                        attributes: attributes + [attribute("ullage.estimated", "true")].compactMap { $0 },
                        start: start,
                        time: time
                    ))
                }
            }

            turnPoints.append(sumPoint(value: stream.turns, attributes: attributes, start: start, time: time))
            if stream.toolCalls > 0 {
                toolPoints.append(sumPoint(value: stream.toolCalls, attributes: attributes, start: start, time: time))
            }
            if stream.compactions > 0 {
                compactionPoints.append(sumPoint(value: stream.compactions, attributes: attributes, start: start, time: time))
            }
        }

        var metrics: [[String: Any]] = []
        metrics.append(contentsOf: [
            sumMetric("ullage.tokens", unit: "{token}", description: "Tokens by counter. Never summed: prompt = input + cache_read + cache_write.", points: tokenPoints),
            sumMetric("ullage.turns", unit: "{turn}", description: "API calls recorded for this stream.", points: turnPoints),
            sumMetric("ullage.tool.calls", unit: "{call}", description: "Tool invocations made by this stream.", points: toolPoints),
            sumMetric("ullage.tool.result_tokens", unit: "{token}", description: "Estimated size of tool results, from their length (~4 bytes/token).", points: toolTokenPoints),
            sumMetric("ullage.compactions", unit: "{event}", description: "Times the window was compacted.", points: compactionPoints),
            gaugeMetric("ullage.context.tokens", unit: "{token}", description: "The last prompt's size: what is in the window now.", points: contextPoints),
            gaugeMetric("ullage.context.window", unit: "{token}", description: "The window this stream runs in.", points: windowPoints),
            gaugeMetric("ullage.context.occupancy", unit: "1", description: "Prompt over window, 0-1. Absent when the harness reports no window.", points: occupancyPoints),
        ].compactMap { $0 })

        return [
            "resourceMetrics": [[
                "resource": resource.json,
                "scopeMetrics": [[
                    "scope": ["name": scopeName],
                    "metrics": metrics,
                ]],
            ]],
        ]
    }

    static func attributes(for stream: StreamTotals) -> [[String: Any]] {
        [
            attribute("gen_ai.system", genAISystem(forVendor: stream.vendor)),
            attribute("gen_ai.request.model", stream.model),
            attribute("ullage.harness", stream.vendor),
            attribute("ullage.project", stream.project),
            attribute("ullage.session_id", stream.sessionId),
            attribute("ullage.agent_id", stream.agentId),
            attribute("ullage.agent_type", stream.agentType),
            attribute("ullage.stream", stream.agentId == nil ? "main" : "agent"),
            attribute("ullage.confidence", stream.confidence),
        ].compactMap { $0 }
    }

    static func sumPoint(value: Int, attributes: [[String: Any]], start: String, time: String) -> [String: Any] {
        [
            "asInt": String(value),
            "startTimeUnixNano": start,
            "timeUnixNano": time,
            "attributes": attributes,
        ]
    }

    static func gaugePoint(int value: Int, attributes: [[String: Any]], time: String) -> [String: Any] {
        ["asInt": String(value), "timeUnixNano": time, "attributes": attributes]
    }

    static func gaugePoint(double value: Double, attributes: [[String: Any]], time: String) -> [String: Any] {
        ["asDouble": value, "timeUnixNano": time, "attributes": attributes]
    }

    /// Empty metrics are omitted rather than sent as an empty series: a backend
    /// should not learn that a counter exists from a payload that never carries
    /// a value for it.
    static func sumMetric(_ name: String, unit: String, description: String, points: [[String: Any]]) -> [String: Any]? {
        guard !points.isEmpty else { return nil }
        return [
            "name": name,
            "unit": unit,
            "description": description,
            "sum": [
                "dataPoints": points,
                // 2 = CUMULATIVE
                "aggregationTemporality": 2,
                "isMonotonic": true,
            ],
        ]
    }

    static func gaugeMetric(_ name: String, unit: String, description: String, points: [[String: Any]]) -> [String: Any]? {
        guard !points.isEmpty else { return nil }
        return [
            "name": name,
            "unit": unit,
            "description": description,
            "gauge": ["dataPoints": points],
        ]
    }
}

// MARK: - Traces

/// One session as a trace: the main thread's turns, and under each turn that
/// spawned one, the agent it spawned and that agent's own turns.
///
/// The tree is the reason traces are worth exporting at all. A multi-agent run
/// is already a tree on disk — the spawning tool call names the child exactly —
/// and a trace is the one format every backend can already draw it in.
public struct SessionTrace {
    public var sessionId: String
    public var project: String?
    public var vendor: String
    /// Every stream's calls, in time order.
    public var calls: [CallRow]
    public var agents: [AgentSummary]
    public var compactions: [EventRow]
    /// Agent id to the `dedupe_key` of the call that spawned it.
    public var spawnCalls: [String: String]

    public init(
        sessionId: String,
        project: String? = nil,
        vendor: String = Vendor.claudeCode,
        calls: [CallRow],
        agents: [AgentSummary] = [],
        compactions: [EventRow] = [],
        spawnCalls: [String: String] = [:]
    ) {
        self.sessionId = sessionId
        self.project = project
        self.vendor = vendor
        self.calls = calls
        self.agents = agents
        self.compactions = compactions
        self.spawnCalls = spawnCalls
    }
}

extension OTLP {
    /// Ids are derived from the ids already on disk, so exporting the same
    /// session twice produces the same spans rather than a second copy of the
    /// run.
    static func traceID(session: String) -> String {
        String(SHA256.hexDigest("ullage:trace:" + session).prefix(32))
    }

    static func spanID(_ kind: String, _ id: String) -> String {
        String(SHA256.hexDigest("ullage:span:\(kind):\(id)").prefix(16))
    }

    public static func traces(
        sessions: [SessionTrace],
        resource: OTLPResource = OTLPResource()
    ) -> [String: Any] {
        var spans: [[String: Any]] = []
        for session in sessions { spans.append(contentsOf: self.spans(for: session)) }
        return traceEnvelope(spans: spans, resource: resource)
    }

    /// Spans of one trace may arrive in several requests — normal in OTLP, and
    /// necessary here: a busy day is thousands of spans and every collector caps
    /// how large a request body may be.
    public static func traceEnvelope(spans: [[String: Any]], resource: OTLPResource) -> [String: Any] {
        [
            "resourceSpans": [[
                "resource": resource.json,
                "scopeSpans": [[
                    "scope": ["name": scopeName],
                    "spans": spans,
                ]],
            ]],
        ]
    }

    public static func spans(for session: SessionTrace) -> [[String: Any]] {
        guard !session.calls.isEmpty else { return [] }
        let traceID = self.traceID(session: session.sessionId)
        let rootID = spanID("session", session.sessionId)
        let sorted = session.calls.sorted { $0.ts < $1.ts }
        let first = sorted.first!.ts
        let last = sorted.last!.ts

        // Compactions belong to the stream that compacted, and hang off that
        // stream's own span.
        func events(forAgent agentId: String?) -> [[String: Any]] {
            session.compactions
                .filter { $0.agentId == agentId && $0.kind == EventKind.compaction.rawValue }
                .compactMap { event in
                    guard let time = nanoseconds(event.ts) else { return nil }
                    return ["timeUnixNano": time, "name": "compaction"]
                }
        }

        var spans: [[String: Any]] = []

        let sessionAttributes = [
            attribute("ullage.session_id", session.sessionId),
            attribute("ullage.project", session.project),
            attribute("ullage.harness", session.vendor),
            attribute("gen_ai.system", genAISystem(forVendor: session.vendor)),
            attribute("ullage.agents", int: session.agents.count),
        ].compactMap { $0 }

        spans.append(span(
            traceID: traceID,
            spanID: rootID,
            parent: nil,
            name: "session " + (session.project ?? String(session.sessionId.prefix(8))),
            kind: 1,
            start: first,
            end: last,
            attributes: sessionAttributes,
            events: events(forAgent: nil)
        ))

        // An agent hangs off the turn that asked for it; if that turn is not in
        // the export window, off the session, rather than being dropped.
        for agent in session.agents {
            guard let start = agent.firstTs, let end = agent.lastTs else { continue }
            let parent = session.spawnCalls[agent.agentId].map { spanID("call", $0) } ?? rootID
            spans.append(span(
                traceID: traceID,
                spanID: spanID("agent", agent.agentId),
                parent: parent,
                name: "agent " + agent.displayName,
                kind: 1,
                start: start,
                end: end,
                attributes: [
                    attribute("ullage.session_id", session.sessionId),
                    attribute("ullage.agent_id", agent.agentId),
                    attribute("ullage.agent_type", agent.agentType),
                    attribute("ullage.agent_label", agent.label),
                    attribute("ullage.agent_status", agent.status),
                    attribute("gen_ai.request.model", agent.model),
                    attribute("ullage.turns", int: agent.calls),
                    attribute("ullage.context.tokens", int: agent.lastContextTokens),
                    attribute("ullage.context.window", int: agent.windowLimit),
                    attribute("ullage.context.occupancy", double: agent.occupancy),
                ].compactMap { $0 },
                events: events(forAgent: agent.agentId)
            ))
        }

        for call in sorted {
            let parent = call.agentId.map { spanID("agent", $0) } ?? rootID
            spans.append(span(
                traceID: traceID,
                spanID: spanID("call", call.dedupeKey),
                parent: parent,
                name: "chat " + (call.model ?? "unknown"),
                kind: 3,          // CLIENT
                start: start(of: call),
                end: call.ts,
                attributes: attributes(for: call, session: session),
                events: []
            ))
        }
        return spans
    }

    /// The transcript records when a turn *finished*, and how long it took when
    /// the harness bothered to say. Without a duration the span is given a
    /// millisecond rather than a guessed length.
    static func start(of call: CallRow) -> String {
        guard let end = Timestamps.date(from: call.ts) else { return call.ts }
        let seconds = Double(call.durationMs ?? 1) / 1000
        return Timestamps.string(from: end.addingTimeInterval(-seconds))
    }

    static func attributes(for call: CallRow, session: SessionTrace) -> [[String: Any]] {
        let measured = call.confidence != Confidence.unmeasured.rawValue
        return [
            attribute("gen_ai.operation.name", "chat"),
            attribute("gen_ai.system", genAISystem(forVendor: call.vendor)),
            attribute("gen_ai.request.model", call.model),
            // The prompt, not the uncached remainder — see the note at the top
            // of this file. The remainder travels as ullage.tokens.input.
            measured ? attribute("gen_ai.usage.input_tokens", int: call.contextTokens) : nil,
            measured ? attribute("gen_ai.usage.output_tokens", int: call.output) : nil,
            measured ? attribute("ullage.tokens.input", int: call.input) : nil,
            measured ? attribute("ullage.tokens.cache_read", int: call.cacheRead) : nil,
            measured ? attribute("ullage.tokens.cache_write", int: call.cacheWrite) : nil,
            measured ? attribute("ullage.context.tokens", int: call.contextTokens) : nil,
            attribute("ullage.context.window", int: call.windowLimit),
            attribute("ullage.context.occupancy", double: call.occupancy),
            attribute("ullage.context.delta", int: call.contextDelta),
            attribute("ullage.turn", int: call.turnIndex),
            attribute("ullage.session_id", call.sessionId),
            attribute("ullage.agent_id", call.agentId),
            attribute("ullage.agent_type", call.agent),
            attribute("ullage.project", call.project ?? session.project),
            attribute("ullage.harness", call.vendor),
            attribute("ullage.confidence", call.confidence),
            attribute("gen_ai.response.finish_reasons", call.stopReason),
        ].compactMap { $0 }
    }

    static func span(
        traceID: String,
        spanID: String,
        parent: String?,
        name: String,
        kind: Int,
        start: String,
        end: String,
        attributes: [[String: Any]],
        events: [[String: Any]]
    ) -> [String: Any] {
        var span: [String: Any] = [
            "traceId": traceID,
            "spanId": spanID,
            "name": name,
            "kind": kind,
            "startTimeUnixNano": nanoseconds(start) ?? "0",
            "endTimeUnixNano": nanoseconds(end) ?? "0",
            "attributes": attributes,
            "status": ["code": 0],
        ]
        if let parent { span["parentSpanId"] = parent }
        if !events.isEmpty { span["events"] = events }
        return span
    }
}

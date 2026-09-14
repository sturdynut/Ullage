import Foundation
import XCTest
@testable import UllageCore

/// M9 — the export, and the ways it could quietly lie in someone else's
/// dashboard, where nobody can see the mistake.
final class OpenTelemetryTests: XCTestCase {

    // MARK: - Reading the payloads

    private func points(_ payload: [String: Any], metric name: String) -> [[String: Any]] {
        let resourceMetrics = payload["resourceMetrics"] as? [[String: Any]] ?? []
        for resource in resourceMetrics {
            for scope in resource["scopeMetrics"] as? [[String: Any]] ?? [] {
                for metric in scope["metrics"] as? [[String: Any]] ?? [] where metric["name"] as? String == name {
                    let container = (metric["sum"] as? [String: Any]) ?? (metric["gauge"] as? [String: Any]) ?? [:]
                    return container["dataPoints"] as? [[String: Any]] ?? []
                }
            }
        }
        return []
    }

    private func metricNames(_ payload: [String: Any]) -> [String] {
        let resourceMetrics = payload["resourceMetrics"] as? [[String: Any]] ?? []
        return resourceMetrics.flatMap { resource in
            (resource["scopeMetrics"] as? [[String: Any]] ?? []).flatMap { scope in
                (scope["metrics"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            }
        }
    }

    private func attributes(_ container: [String: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for attribute in container["attributes"] as? [[String: Any]] ?? [] {
            guard let key = attribute["key"] as? String,
                  let value = attribute["value"] as? [String: Any],
                  let first = value.values.first else { continue }
            result[key] = "\(first)"
        }
        return result
    }

    private func spans(_ payload: [String: Any]) -> [[String: Any]] {
        let resourceSpans = payload["resourceSpans"] as? [[String: Any]] ?? []
        return resourceSpans.flatMap { resource in
            (resource["scopeSpans"] as? [[String: Any]] ?? []).flatMap { scope in
                scope["spans"] as? [[String: Any]] ?? []
            }
        }
    }

    private func span(_ payload: [String: Any], named name: String) -> [String: Any]? {
        spans(payload).first { ($0["name"] as? String) == name }
    }

    // MARK: - Token semantics

    /// The single most important assertion in this file.
    ///
    /// `gen_ai.usage.input_tokens` means the whole prompt. Claude's
    /// `input_tokens` is only the uncached remainder — 5 against a 21,205-token
    /// prompt here — and exporting that under the standard name would
    /// understate every cached session by three orders of magnitude in a
    /// dashboard where nobody can check it.
    func testPromptIsExportedAsInputTokensAndTheRemainderKeepsItsOwnName() throws {
        let call = CallRow(
            dedupeKey: "msg_1", ts: "2026-03-02T12:00:00.000Z", sessionId: "s",
            model: "claude-opus-5", input: 5, output: 100, cacheRead: 20_000, cacheWrite: 1_200,
            contextTokens: 21_205, windowLimit: 1_000_000, sourceFile: "f"
        )
        let payload = OTLP.traces(sessions: [SessionTrace(sessionId: "s", calls: [call])])
        let turn = try XCTUnwrap(span(payload, named: "chat claude-opus-5"))
        let attributes = self.attributes(turn)

        XCTAssertEqual(attributes["gen_ai.usage.input_tokens"], "21205")
        XCTAssertEqual(attributes["gen_ai.usage.output_tokens"], "100")
        XCTAssertEqual(attributes["ullage.tokens.input"], "5", "the uncached remainder, under its own name")
        XCTAssertEqual(attributes["ullage.tokens.cache_read"], "20000")
        XCTAssertEqual(attributes["ullage.tokens.cache_write"], "1200")
        XCTAssertEqual(attributes["ullage.context.occupancy"], "0.021205")
    }

    func testTheFourCountersAreFourSeriesAndThereIsNoTotal() throws {
        let stream = StreamTotals(
            sessionId: "s", project: "proj", model: "claude-opus-5",
            input: 5, output: 100, cacheRead: 20_000, cacheWrite: 1_200, turns: 1,
            lastContextTokens: 21_205, windowLimit: 1_000_000,
            firstTs: "2026-03-02T12:00:00.000Z", lastTs: "2026-03-02T12:00:00.000Z"
        )
        let payload = OTLP.metrics(streams: [stream])

        let tokens = points(payload, metric: "ullage.tokens")
        XCTAssertEqual(tokens.count, 4)
        let byType = Dictionary(uniqueKeysWithValues: tokens.map {
            (attributes($0)["ullage.token.type"] ?? "", $0["asInt"] as? String ?? "")
        })
        XCTAssertEqual(byType, ["input": "5", "output": "100", "cache_read": "20000", "cache_write": "1200"])

        // Nothing anywhere in the payload adds them up.
        XCTAssertFalse(metricNames(payload).contains { $0.contains("total") })
        XCTAssertEqual(points(payload, metric: "ullage.context.tokens").first?["asInt"] as? String, "21205")
        XCTAssertEqual(points(payload, metric: "ullage.context.occupancy").first?["asDouble"] as? Double, 0.021205)
    }

    /// Cursor reports no tokens and no window. It must export activity and
    /// nothing else: a zero beside three real numbers reads as a measurement.
    func testAnUnmeasuredHarnessExportsActivityOnly() throws {
        let stream = StreamTotals(
            sessionId: "cursor-1", project: "proj", vendor: Vendor.cursor,
            confidence: Confidence.unmeasured.rawValue,
            turns: 12, toolCalls: 3,
            firstTs: "2026-03-02T12:00:00.000Z", lastTs: "2026-03-02T12:30:00.000Z"
        )
        let payload = OTLP.metrics(streams: [stream])

        XCTAssertEqual(points(payload, metric: "ullage.turns").first?["asInt"] as? String, "12")
        XCTAssertEqual(points(payload, metric: "ullage.tool.calls").first?["asInt"] as? String, "3")
        XCTAssertTrue(points(payload, metric: "ullage.tokens").isEmpty)
        XCTAssertTrue(points(payload, metric: "ullage.context.occupancy").isEmpty)
        XCTAssertTrue(points(payload, metric: "ullage.context.window").isEmpty)
        XCTAssertEqual(attributes(points(payload, metric: "ullage.turns")[0])["ullage.confidence"], "unmeasured")
    }

    func testAWindowlessStreamGetsNoOccupancy() {
        let stream = StreamTotals(
            sessionId: "s", input: 1, turns: 1, lastContextTokens: 500, windowLimit: nil,
            firstTs: "2026-03-02T12:00:00.000Z", lastTs: "2026-03-02T12:00:00.000Z"
        )
        let payload = OTLP.metrics(streams: [stream])
        XCTAssertTrue(points(payload, metric: "ullage.context.occupancy").isEmpty)
        XCTAssertEqual(points(payload, metric: "ullage.context.tokens").first?["asInt"] as? String, "500")
    }

    func testEstimatedToolResultsSayTheyAreEstimated() throws {
        let stream = StreamTotals(
            sessionId: "s", input: 1, turns: 1, toolCalls: 2, toolResultTokens: 4_000,
            firstTs: "2026-03-02T12:00:00.000Z", lastTs: "2026-03-02T12:00:00.000Z"
        )
        let payload = OTLP.metrics(streams: [stream])
        let point = try XCTUnwrap(points(payload, metric: "ullage.tool.result_tokens").first)
        XCTAssertEqual(attributes(point)["ullage.estimated"], "true")
    }

    func testHarnessTravelsAlongsideTheGenAISystem() {
        XCTAssertEqual(OTLP.genAISystem(forVendor: Vendor.claudeCode), "anthropic")
        XCTAssertEqual(OTLP.genAISystem(forVendor: Vendor.codex), "openai")
        XCTAssertEqual(OTLP.genAISystem(forVendor: Vendor.cursor), "cursor")
    }

    // MARK: - Traces

    func testIdsAreDerivedFromTheIdsOnDiskSoAReExportIsTheSameTrace() {
        let call = CallRow(dedupeKey: "msg_1", ts: "2026-03-02T12:00:00.000Z", sessionId: "s",
                           contextTokens: 10, sourceFile: "f")
        let first = OTLP.traces(sessions: [SessionTrace(sessionId: "s", calls: [call])])
        let second = OTLP.traces(sessions: [SessionTrace(sessionId: "s", calls: [call])])
        XCTAssertEqual(spans(first).map { $0["spanId"] as? String }, spans(second).map { $0["spanId"] as? String })
        XCTAssertEqual(spans(first).map { $0["traceId"] as? String }, spans(second).map { $0["traceId"] as? String })

        XCTAssertEqual(OTLP.traceID(session: "s").count, 32)
        XCTAssertEqual(OTLP.spanID("call", "msg_1").count, 16)
        XCTAssertNotEqual(OTLP.traceID(session: "s"), OTLP.traceID(session: "other"))
    }

    /// The tree, which is the reason to export spans at all: an agent hangs off
    /// the turn that asked for it, and its own turns hang off the agent.
    func testAgentSpansHangOffTheTurnThatSpawnedThem() throws {
        let workspace = try TempWorkspace()
        for fixture in ["agents-main.jsonl", "agents-child-explore.jsonl",
                        "agents-child-general.jsonl", "agents-child-nested.jsonl"] {
            try workspace.ingestor.ingestFile(at: try workspace.copyFixture(fixture))
        }
        let trace = try workspace.store.sessionTrace(sessionId: "sess-agents")
        let payload = OTLP.traces(sessions: [trace])

        let explore = try XCTUnwrap(span(payload, named: "agent Map the intake flow"))
        // toolu_spawn1 was called on msg_m01, so that turn's span is the parent.
        XCTAssertEqual(explore["parentSpanId"] as? String, OTLP.spanID("call", "msg_m01"))

        let nested = try XCTUnwrap(span(payload, named: "agent Check the migrations"))
        XCTAssertEqual(nested["parentSpanId"] as? String, OTLP.spanID("call", "msg_g01"),
                       "an agent spawned by an agent hangs off that agent's turn")

        // The grandchild's own turns hang off the grandchild.
        let grandchildTurns = spans(payload).filter {
            ($0["parentSpanId"] as? String) == OTLP.spanID("agent", "a-nested-3")
        }
        XCTAssertEqual(grandchildTurns.count, 2)

        // And the session root has no parent.
        let root = try XCTUnwrap(span(payload, named: "session portal"))
        XCTAssertNil(root["parentSpanId"])
        XCTAssertEqual(spans(payload).compactMap { $0["traceId"] as? String }.uniqued().count, 1)
    }

    func testACompactionIsAnEventOnTheStreamThatCompacted() throws {
        let workspace = try TempWorkspace()
        for fixture in ["agents-main.jsonl", "agents-child-explore.jsonl"] {
            try workspace.ingestor.ingestFile(at: try workspace.copyFixture(fixture))
        }
        let payload = OTLP.traces(sessions: [try workspace.store.sessionTrace(sessionId: "sess-agents")])
        let explore = try XCTUnwrap(span(payload, named: "agent Map the intake flow"))
        let events = explore["events"] as? [[String: Any]] ?? []
        XCTAssertEqual(events.map { $0["name"] as? String }, ["compaction"])

        let root = try XCTUnwrap(span(payload, named: "session portal"))
        XCTAssertNil(root["events"], "the main thread did not compact")
    }

    func testATurnsSpanCoversTheTimeItTook() throws {
        let call = CallRow(dedupeKey: "msg_1", ts: "2026-03-02T12:00:10.000Z", sessionId: "s",
                           contextTokens: 10, durationMs: 4_000, sourceFile: "f")
        let payload = OTLP.traces(sessions: [SessionTrace(sessionId: "s", calls: [call])])
        let turn = try XCTUnwrap(span(payload, named: "chat unknown"))
        let start = Int64(turn["startTimeUnixNano"] as? String ?? "0") ?? 0
        let end = Int64(turn["endTimeUnixNano"] as? String ?? "0") ?? 0
        XCTAssertEqual(end - start, 4_000_000_000)
    }

    // MARK: - Endpoint and transport

    func testEndpointBuildsTheStandardSignalPaths() {
        let endpoint = OTLPEndpoint(base: URL(string: "http://localhost:4318")!)
        XCTAssertEqual(endpoint.metricsURL?.absoluteString, "http://localhost:4318/v1/metrics")
        XCTAssertEqual(endpoint.tracesURL?.absoluteString, "http://localhost:4318/v1/traces")

        let overridden = OTLPEndpoint(
            base: URL(string: "http://localhost:4318")!,
            tracesOverride: URL(string: "https://otlp.example.com/ingest/traces")!
        )
        XCTAssertEqual(overridden.tracesURL?.absoluteString, "https://otlp.example.com/ingest/traces")
    }

    func testHeadersComeFromTheStandardEnvironmentVariable() {
        let endpoint = OTLPEndpoint.fromEnvironment([
            "OTEL_EXPORTER_OTLP_ENDPOINT": "http://collector:4318",
            "OTEL_EXPORTER_OTLP_HEADERS": "api-key=secret, x-scope-orgid=ullage, broken",
        ])
        XCTAssertEqual(endpoint.base?.absoluteString, "http://collector:4318")
        XCTAssertEqual(endpoint.headers, ["api-key": "secret", "x-scope-orgid": "ullage"])
    }

    final class RecordingTransport: OTLPTransport {
        var posts: [(url: URL, bytes: Int, headers: [String: String])] = []
        func post(_ body: Data, to url: URL, headers: [String: String]) throws {
            posts.append((url, body.count, headers))
        }
    }

    func testExportSendsOneRequestPerSignalAndNothingOnADryRun() throws {
        let workspace = try TempWorkspace()
        try workspace.ingestor.ingestFile(at: try workspace.copyFixture("agents-main.jsonl"))

        let transport = RecordingTransport()
        let exporter = OTLPExporter(
            store: workspace.store,
            endpoint: OTLPEndpoint(base: URL(string: "http://localhost:4318")!, headers: ["api-key": "k"]),
            transport: transport
        )

        var dryRunPayloads: [String] = []
        let dry = try exporter.export(dryRun: true) { kind, _ in dryRunPayloads.append(kind) }
        XCTAssertTrue(transport.posts.isEmpty, "a dry run must not reach the network")
        XCTAssertEqual(dryRunPayloads, ["metrics", "traces"])
        XCTAssertGreaterThan(dry.spans, 0)
        XCTAssertGreaterThan(dry.metricPoints, 0)

        let sent = try exporter.export()
        XCTAssertEqual(transport.posts.map { $0.url.lastPathComponent }, ["metrics", "traces"])
        XCTAssertEqual(transport.posts.first?.headers["api-key"], "k")
        XCTAssertEqual(sent.spans, dry.spans)
        XCTAssertEqual(sent.lastTs, "2026-03-02T12:02:10.000Z")
    }

    func testTheCursorSurvivesARestart() throws {
        let workspace = try TempWorkspace()
        try workspace.store.setExportCursor(endpoint: "http://c/v1/traces", lastTs: "2026-03-02T12:00:00.000Z")
        XCTAssertEqual(try workspace.store.exportCursor(endpoint: "http://c/v1/traces"), "2026-03-02T12:00:00.000Z")
        try workspace.store.setExportCursor(endpoint: "http://c/v1/traces", lastTs: "2026-03-02T13:00:00.000Z")
        XCTAssertEqual(try workspace.store.exportCursor(endpoint: "http://c/v1/traces"), "2026-03-02T13:00:00.000Z")
        XCTAssertNil(try workspace.store.exportCursor(endpoint: "http://other/v1/traces"))
    }

    func testEverySignalIsTaggedWithTheMachineItCameFrom() throws {
        let resource = OTLPResource(serviceInstanceId: "laptop-1")
        let payload = OTLP.metrics(
            streams: [StreamTotals(sessionId: "s", input: 1, turns: 1,
                                   firstTs: "2026-03-02T12:00:00.000Z", lastTs: "2026-03-02T12:00:00.000Z")],
            resource: resource
        )
        let resourceMetrics = try XCTUnwrap((payload["resourceMetrics"] as? [[String: Any]])?.first)
        let attributes = self.attributes(try XCTUnwrap(resourceMetrics["resource"] as? [String: Any]))
        XCTAssertEqual(attributes["service.name"], "ullage")
        XCTAssertEqual(attributes["service.instance.id"], "laptop-1")
    }

    func testPayloadsSerialiseAsJSON() throws {
        let stream = StreamTotals(sessionId: "s", input: 1, turns: 1,
                                  firstTs: "2026-03-02T12:00:00.000Z", lastTs: "2026-03-02T12:00:00.000Z")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(OTLP.metrics(streams: [stream])))
        let call = CallRow(dedupeKey: "m", ts: "2026-03-02T12:00:00.000Z", sessionId: "s",
                           contextTokens: 1, sourceFile: "f")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(OTLP.traces(sessions: [SessionTrace(sessionId: "s", calls: [call])])))
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] { Array(Set(self)) }
}

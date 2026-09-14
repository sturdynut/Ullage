import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where to send, and what the standard environment variables say about it.
///
/// The names are OpenTelemetry's own (`OTEL_EXPORTER_OTLP_ENDPOINT`,
/// `OTEL_EXPORTER_OTLP_HEADERS`, and the per-signal overrides) so an existing
/// collector configuration works here without being restated.
public struct OTLPEndpoint: Equatable {
    /// Base URL — `/v1/metrics` and `/v1/traces` are appended to it.
    public var base: URL?
    public var metricsOverride: URL?
    public var tracesOverride: URL?
    public var headers: [String: String]

    public init(
        base: URL? = nil,
        metricsOverride: URL? = nil,
        tracesOverride: URL? = nil,
        headers: [String: String] = [:]
    ) {
        self.base = base
        self.metricsOverride = metricsOverride
        self.tracesOverride = tracesOverride
        self.headers = headers
    }

    public var metricsURL: URL? { metricsOverride ?? base.map { $0.appendingPathComponent("v1/metrics") } }
    public var tracesURL: URL? { tracesOverride ?? base.map { $0.appendingPathComponent("v1/traces") } }

    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> OTLPEndpoint {
        OTLPEndpoint(
            base: environment["OTEL_EXPORTER_OTLP_ENDPOINT"].flatMap(URL.init(string:)),
            metricsOverride: environment["OTEL_EXPORTER_OTLP_METRICS_ENDPOINT"].flatMap(URL.init(string:)),
            tracesOverride: environment["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"].flatMap(URL.init(string:)),
            headers: parseHeaders(environment["OTEL_EXPORTER_OTLP_HEADERS"])
        )
    }

    /// `key=value,key2=value2`, the spec's own format. A malformed pair is
    /// skipped rather than failing the export: a dropped header is visible in
    /// the response, an aborted export is not.
    public static func parseHeaders(_ raw: String?) -> [String: String] {
        guard let raw, !raw.isEmpty else { return [:] }
        var headers: [String: String] = [:]
        for pair in raw.split(separator: ",") {
            guard let separator = pair.firstIndex(of: "=") else { continue }
            let key = pair[pair.startIndex..<separator].trimmingCharacters(in: .whitespaces)
            let value = pair[pair.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { continue }
            headers[key] = value.removingPercentEncoding ?? value
        }
        return headers
    }
}

public enum OTLPError: Error, CustomStringConvertible {
    case noEndpoint
    case transport(String)
    case rejected(status: Int, body: String)

    public var description: String {
        switch self {
        case .noEndpoint:
            return "no OTLP endpoint: pass --endpoint or set OTEL_EXPORTER_OTLP_ENDPOINT"
        case .transport(let message):
            return "could not reach the collector: \(message)"
        case .rejected(let status, let body):
            return "collector rejected the payload (HTTP \(status)): \(body)"
        }
    }
}

/// Kept behind a protocol so the payloads can be tested without a collector,
/// and so a dry run is the same code path minus the send.
public protocol OTLPTransport {
    func post(_ body: Data, to url: URL, headers: [String: String]) throws
}

public struct URLSessionOTLPTransport: OTLPTransport {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 15) { self.timeout = timeout }

    public func post(_ body: Data, to url: URL, headers: [String: String]) throws {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = body

        var result: Result<(Int, Data), Error>?
        let waiter = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                result = .success((status, data ?? Data()))
            }
            waiter.signal()
        }
        task.resume()
        waiter.wait()

        switch result {
        case .failure(let error):
            throw OTLPError.transport("\(error)")
        case .success(let (status, data)):
            guard (200..<300).contains(status) else {
                throw OTLPError.rejected(status: status, body: String(decoding: data.prefix(500), as: UTF8.self))
            }
        case nil:
            throw OTLPError.transport("no response")
        }
    }
}

/// Reads the database, builds the payloads, and (unless this is a dry run)
/// sends them. The building and the sending are separate so `--dry-run` prints
/// exactly what would have gone out.
public struct OTLPExporter {
    public struct Summary: Equatable {
        public var streams = 0
        public var metricPoints = 0
        public var sessions = 0
        public var spans = 0
        /// How many requests it took. Payloads are split because collectors cap
        /// request bodies, and a day of a busy session is megabytes.
        public var requests = 0
        /// The newest turn included, which is where the next run starts.
        public var lastTs: String?
        public var metricsBytes = 0
        public var traceBytes = 0
    }

    public let store: Store
    public var resource: OTLPResource
    public var transport: OTLPTransport
    public var endpoint: OTLPEndpoint
    /// Batch sizes, chosen so a request stays around a megabyte on real data.
    public var spansPerRequest: Int
    public var streamsPerRequest: Int

    public init(
        store: Store,
        endpoint: OTLPEndpoint,
        resource: OTLPResource = OTLPResource(),
        transport: OTLPTransport = URLSessionOTLPTransport(),
        spansPerRequest: Int = 400,
        streamsPerRequest: Int = 150
    ) {
        self.store = store
        self.endpoint = endpoint
        self.resource = resource
        self.transport = transport
        self.spansPerRequest = max(1, spansPerRequest)
        self.streamsPerRequest = max(1, streamsPerRequest)
    }

    /// Metrics are a cumulative snapshot of everything on disk, so running this
    /// twice changes nothing a backend sees. Traces are not, so they are read
    /// from `since` — normally the cursor of the last successful run.
    public func export(
        metrics includeMetrics: Bool = true,
        traces includeTraces: Bool = true,
        since: String? = nil,
        activeSince: String? = nil,
        dryRun: Bool = false,
        onPayload: ((String, Data) -> Void)? = nil
    ) throws -> Summary {
        var summary = Summary()

        if includeMetrics {
            let streams = try store.telemetryStreams(since: activeSince)
            summary.streams = streams.count
            for batch in stride(from: 0, to: max(streams.count, 1), by: streamsPerRequest) {
                let slice = Array(streams[batch..<min(batch + streamsPerRequest, streams.count)])
                guard !slice.isEmpty else { continue }
                let payload = OTLP.metrics(streams: slice, resource: resource)
                let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                summary.metricPoints += OTLPExporter.countPoints(payload)
                summary.metricsBytes += body.count
                onPayload?("metrics", body)
                if !dryRun {
                    guard let url = endpoint.metricsURL else { throw OTLPError.noEndpoint }
                    try transport.post(body, to: url, headers: endpoint.headers)
                    summary.requests += 1
                }
            }
        }

        if includeTraces {
            let sessionIds = try store.sessionsActive(since: since)
            var traces: [SessionTrace] = []
            var lastTs: String?
            for sessionId in sessionIds {
                let trace = try store.sessionTrace(sessionId: sessionId, since: since)
                guard !trace.calls.isEmpty else { continue }
                traces.append(trace)
                if let newest = trace.calls.map(\.ts).max(), newest > (lastTs ?? "") { lastTs = newest }
            }
            var spans: [[String: Any]] = []
            for trace in traces { spans.append(contentsOf: OTLP.spans(for: trace)) }
            summary.sessions = traces.count
            summary.spans = spans.count
            summary.lastTs = lastTs

            for batch in stride(from: 0, to: spans.count, by: spansPerRequest) {
                let slice = Array(spans[batch..<min(batch + spansPerRequest, spans.count)])
                let payload = OTLP.traceEnvelope(spans: slice, resource: resource)
                let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                summary.traceBytes += body.count
                onPayload?("traces", body)
                if !dryRun {
                    guard let url = endpoint.tracesURL else { throw OTLPError.noEndpoint }
                    try transport.post(body, to: url, headers: endpoint.headers)
                    summary.requests += 1
                }
            }
        }

        return summary
    }

    static func countSpans(_ payload: [String: Any]) -> Int {
        let resourceSpans = payload["resourceSpans"] as? [[String: Any]] ?? []
        return resourceSpans.reduce(0) { total, resource in
            let scopes = resource["scopeSpans"] as? [[String: Any]] ?? []
            return total + scopes.reduce(0) { $0 + (($1["spans"] as? [Any])?.count ?? 0) }
        }
    }

    static func countPoints(_ payload: [String: Any]) -> Int {
        let resourceMetrics = payload["resourceMetrics"] as? [[String: Any]] ?? []
        return resourceMetrics.reduce(0) { total, resource in
            let scopes = resource["scopeMetrics"] as? [[String: Any]] ?? []
            return total + scopes.reduce(0) { subtotal, scope in
                let metrics = scope["metrics"] as? [[String: Any]] ?? []
                return subtotal + metrics.reduce(0) { count, metric in
                    let container = (metric["sum"] as? [String: Any]) ?? (metric["gauge"] as? [String: Any]) ?? [:]
                    return count + ((container["dataPoints"] as? [Any])?.count ?? 0)
                }
            }
        }
    }
}

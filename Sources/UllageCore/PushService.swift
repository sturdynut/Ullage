import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What the phone is actually sent.
struct PushPayload: Codable {
    var title: String
    var body: String
    /// One tag per stream: a session that passes 85% and later 95% replaces its
    /// own notification rather than stacking two.
    var tag: String
    var url: String
}

/// Decides what is worth saying, then says it.
///
/// The deciding half is `AlertRule` and runs anywhere; the saying half needs
/// CryptoKit and so runs on macOS only.
public final class PushService {
    public struct Report: Equatable {
        public var sent: Int = 0
        public var failed: Int = 0
        /// Subscriptions the push service said no longer exist. Deleted rather
        /// than retried forever — a phone that was reset is not coming back.
        public var removed: Int = 0

        public init(sent: Int = 0, failed: Int = 0, removed: Int = 0) {
            self.sent = sent
            self.failed = failed
            self.removed = removed
        }
    }

    /// Performs one POST and reports the HTTP status (0 when there was none).
    /// Replaceable so the delivery bookkeeping can be tested without a push
    /// service on the other end.
    public typealias Transport = (URLRequest, @escaping (Int) -> Void) -> Void

    private let store: Store
    private let subject: String
    private let transport: Transport
    /// A `Store` is one SQLite connection and is not thread safe, and this
    /// class touches it from two directions: the caller's queue when it
    /// evaluates, and the transport's queues when deliveries come back. One
    /// lock around every access, and its own connection, is the whole answer.
    private let storeLock = NSLock()

    /// VAPID requires a contact for the push service operator to complain to.
    /// It is not an address anything is sent to.
    public init(
        store: Store,
        subject: String = "mailto:ullage@localhost",
        transport: @escaping Transport = PushService.urlSessionTransport
    ) {
        self.store = store
        self.subject = subject
        self.transport = transport
    }

    public static let urlSessionTransport: Transport = { request, completion in
        URLSession.shared.dataTask(with: request) { _, response, _ in
            completion((response as? HTTPURLResponse)?.statusCode ?? 0)
        }.resume()
    }

    public func subscriptionCount() throws -> Int {
        storeLock.lock()
        defer { storeLock.unlock() }
        return try store.pushSubscriptionCount()
    }

    /// Runs the rule over every recent session and returns what is newly worth
    /// saying. Nothing is recorded as said here — that happens in `announce`,
    /// and only once a device has actually been told. Re-arms *are* applied
    /// here, since forgetting is safe to do early.
    public func pendingAlerts(now: Date = Date(), sessionLimit: Int = 20) throws -> [ContextAlert] {
        storeLock.lock()
        defer { storeLock.unlock() }
        var alerts: [ContextAlert] = []
        for summary in try store.recentSessions(limit: sessionLimit) {
            guard let call = try store.latestCall(sessionId: summary.sessionId, scope: .mainThread) else { continue }
            let key = AlertRule.streamKey(sessionId: call.sessionId, agentId: call.agentId)
            var fired = try store.firedAlert(streamKey: key)

            // A compaction re-arms whether or not anyone happened to look while
            // the post-compaction row was the newest one. The event table is
            // the durable record of it; the dip in the latest row is not.
            if let firedAt = fired?.firedAt,
               try store.events(sessionId: call.sessionId, kind: EventKind.compaction.rawValue, scope: .mainThread)
                   .contains(where: { $0.ts > firedAt }) {
                try store.clearFiredThreshold(streamKey: key)
                fired = nil
            }

            switch AlertRule.decide(call: call, firedThreshold: fired?.threshold, now: now) {
            case let .fire(alert):
                alerts.append(alert)
            case let .rearm(streamKey):
                try store.clearFiredThreshold(streamKey: streamKey)
            case .nothing:
                break
            }
        }
        return alerts
    }

    #if canImport(CryptoKit)

    /// The keypair this database pushes under, made on first use.
    @discardableResult
    public func applicationKey(now: Date = Date()) throws -> VAPIDKeyPair {
        storeLock.lock()
        defer { storeLock.unlock() }
        if let existing = try store.vapidKey() { return existing }
        let fresh = WebPush.generateKeyPair(now: now)
        try store.setVAPIDKey(fresh)
        return fresh
    }

    /// Evaluate, deliver, and — only for what actually reached a device — mark
    /// the rung as said. A delivery that failed is retried on the next pass
    /// because nothing was recorded; a stream is never silenced by a network
    /// blip. One alert failing to build does not stop the others.
    public func announce(now: Date = Date(), timeout: TimeInterval = 15) throws -> [(ContextAlert, Report)] {
        var results: [(ContextAlert, Report)] = []
        for alert in try pendingAlerts(now: now) {
            let report = (try? deliver(alert, timeout: timeout, now: now)) ?? Report(failed: 1)
            if report.sent > 0 {
                storeLock.lock()
                try store.setFiredThreshold(
                    streamKey: alert.streamKey,
                    threshold: alert.threshold,
                    at: Timestamps.string(from: now),
                    contextTokens: alert.contextTokens
                )
                storeLock.unlock()
            }
            results.append((alert, report))
        }
        return results
    }

    public func deliver(_ alert: ContextAlert, timeout: TimeInterval = 15, now: Date = Date()) throws -> Report {
        try deliver(
            payload: PushPayload(title: alert.title, body: alert.body, tag: alert.streamKey, url: "."),
            timeout: timeout,
            now: now
        )
    }

    public func deliverTest(timeout: TimeInterval = 15, now: Date = Date()) throws -> Report {
        try deliver(
            payload: PushPayload(
                title: "Ullage test",
                body: "If you can read this, alerts work.",
                tag: "ullage-test",
                url: "."
            ),
            timeout: timeout,
            now: now
        )
    }

    func deliver(payload: PushPayload, timeout: TimeInterval, now: Date) throws -> Report {
        storeLock.lock()
        let subscriptions = try store.pushSubscriptions()
        storeLock.unlock()
        guard !subscriptions.isEmpty else { return Report() }
        let key = try applicationKey(now: now)
        let body = try JSONEncoder().encode(payload)

        // Every touch of `report` happens under `tally`, including the ones on
        // this thread: completions can land while the loop below is still
        // building the next request.
        var report = Report()
        let tally = NSLock()
        let group = DispatchGroup()

        for subscription in subscriptions {
            let request: URLRequest
            do {
                request = try WebPush.request(
                    subscription: subscription, payload: body, key: key, subject: subject, now: now
                )
            } catch {
                tally.lock(); report.failed += 1; tally.unlock()
                continue
            }
            group.enter()
            transport(request) { status in
                defer { group.leave() }
                // Recorded as each answer arrives, not after the wait: a 410
                // that shows up late is still a 410, and a subscription the
                // push service has declared dead must not be kept on the
                // strength of a timeout.
                self.storeLock.lock()
                try? self.store.recordPush(
                    endpoint: subscription.endpoint, status: status, at: Timestamps.string(from: now)
                )
                if status == 404 || status == 410 {
                    try? self.store.deletePushSubscription(endpoint: subscription.endpoint)
                }
                self.storeLock.unlock()

                tally.lock()
                if status == 404 || status == 410 { report.removed += 1 }
                else if (200..<300).contains(status) { report.sent += 1 }
                else { report.failed += 1 }
                tally.unlock()
            }
        }

        _ = group.wait(timeout: .now() + timeout)
        tally.lock()
        defer { tally.unlock() }
        return report
    }

    #endif
}

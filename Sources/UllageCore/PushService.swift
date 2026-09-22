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
    }

    private let store: Store
    private let subject: String
    /// A `Store` is one SQLite connection and is not thread safe, and this
    /// class touches it from two directions: the tailer's queue when it
    /// evaluates, and URLSession's queues when deliveries come back. One lock
    /// around every access, and its own connection, is the whole answer.
    private let storeLock = NSLock()

    /// VAPID requires a contact for the push service operator to complain to.
    /// It is not an address anything is sent to.
    public init(store: Store, subject: String = "mailto:ullage@localhost") {
        self.store = store
        self.subject = subject
    }

    /// Runs the rule over every recent session and returns what is newly worth
    /// saying, recording it so the same rung is never announced twice.
    public func pendingAlerts(now: Date = Date(), sessionLimit: Int = 20) throws -> [ContextAlert] {
        storeLock.lock()
        defer { storeLock.unlock() }
        var alerts: [ContextAlert] = []
        for summary in try store.recentSessions(limit: sessionLimit) {
            guard let call = try store.latestCall(sessionId: summary.sessionId, scope: .mainThread) else { continue }
            switch AlertRule.decide(
                call: call,
                firedThreshold: try store.firedThreshold(
                    streamKey: AlertRule.streamKey(sessionId: call.sessionId, agentId: call.agentId)
                ),
                now: now
            ) {
            case let .fire(alert):
                try store.setFiredThreshold(
                    streamKey: alert.streamKey,
                    threshold: alert.threshold,
                    at: Timestamps.string(from: now),
                    contextTokens: alert.contextTokens
                )
                alerts.append(alert)
            case let .rearm(streamKey):
                try store.clearFiredThreshold(streamKey: streamKey)
            case .nothing:
                break
            }
        }
        return alerts
    }

    public func subscriptionCount() throws -> Int {
        storeLock.lock()
        defer { storeLock.unlock() }
        return try store.pushSubscriptions().count
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

        var report = Report()
        var gone: [String] = []
        let tally = NSLock()
        let group = DispatchGroup()

        for subscription in subscriptions {
            let request: URLRequest
            do {
                request = try WebPush.request(
                    subscription: subscription, payload: body, key: key, subject: subject, now: now
                )
            } catch {
                report.failed += 1
                continue
            }
            group.enter()
            URLSession.shared.dataTask(with: request) { _, response, _ in
                defer { group.leave() }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                tally.lock()
                defer { tally.unlock() }
                // 404 and 410 are the push service saying this device is gone;
                // anything else that fails may just be a flaky network.
                if status == 404 || status == 410 {
                    gone.append(subscription.endpoint)
                    report.removed += 1
                } else if (200..<300).contains(status) {
                    report.sent += 1
                } else {
                    report.failed += 1
                }
                self.storeLock.lock()
                try? self.store.recordPush(
                    endpoint: subscription.endpoint, status: status, at: Timestamps.string(from: now)
                )
                self.storeLock.unlock()
            }.resume()
        }

        _ = group.wait(timeout: .now() + timeout)
        storeLock.lock()
        for endpoint in gone { try? store.deletePushSubscription(endpoint: endpoint) }
        storeLock.unlock()
        return report
    }

    #endif
}

import Foundation
import XCTest
@testable import UllageCore

/// When a phone gets buzzed, and — mostly — when it does not.
final class PushTests: XCTestCase {

    private func call(
        context: Int,
        limit: Int? = 200_000,
        minutesAgo: Double = 1,
        agentId: String? = nil,
        session: String = "sess-1",
        now: Date
    ) -> CallRow {
        var row = CallRow(
            dedupeKey: "msg-\(context)-\(agentId ?? "main")",
            ts: Timestamps.string(from: now.addingTimeInterval(-minutesAgo * 60)),
            sessionId: session,
            project: "ullage",
            model: "claude-opus-5",
            contextTokens: context,
            windowLimit: limit,
            sourceFile: "x.jsonl"
        )
        row.agentId = agentId
        return row
    }

    // MARK: - The rule

    func testFiresOnceWhenCrossingAndStaysQuietAfter() {
        let now = Date()
        let crossing = AlertRule.decide(call: call(context: 172_000, now: now), firedThreshold: nil, now: now)
        guard case let .fire(alert) = crossing else { return XCTFail("expected a first alert, got \(crossing)") }
        XCTAssertEqual(alert.threshold, 0.85)
        XCTAssertEqual(alert.title, "86% · ullage")
        XCTAssertEqual(alert.body, "172,000 of 200,000 tokens · claude-opus-5")

        // The next turn is still over the line. Saying it again is how you
        // teach someone to ignore the alert.
        XCTAssertEqual(
            AlertRule.decide(call: call(context: 173_000, now: now), firedThreshold: 0.85, now: now),
            .nothing
        )
    }

    func testTheLouderRungStillSpeaks() {
        let now = Date()
        let decision = AlertRule.decide(call: call(context: 191_000, now: now), firedThreshold: 0.85, now: now)
        guard case let .fire(alert) = decision else { return XCTFail("95% should still be worth saying") }
        XCTAssertEqual(alert.threshold, 0.95)
    }

    func testCompactionRearms() {
        let now = Date()
        let decision = AlertRule.decide(call: call(context: 20_000, now: now), firedThreshold: 0.95, now: now)
        XCTAssertEqual(decision, .rearm(streamKey: "sess-1|main"))
        // And having re-armed, the next climb is news again.
        guard case .fire = AlertRule.decide(call: call(context: 172_000, now: now), firedThreshold: nil, now: now) else {
            return XCTFail("after a compaction the threshold should alert again")
        }
    }

    /// Rule 1: a subagent's window is its own, and it is not the one about to
    /// run out on you.
    func testSubagentsNeverAlert() {
        let now = Date()
        XCTAssertEqual(
            AlertRule.decide(call: call(context: 199_000, agentId: "agent-7", now: now), firedThreshold: nil, now: now),
            .nothing
        )
    }

    /// Rule 3: no window, no occupancy, no notification.
    func testUnmeasuredHarnessNeverAlerts() {
        let now = Date()
        XCTAssertEqual(
            AlertRule.decide(call: call(context: 999_999, limit: nil, now: now), firedThreshold: nil, now: now),
            .nothing
        )
    }

    /// A backfill re-reads months of transcripts, and every one of those
    /// sessions crossed 85% at some point. None of it is news.
    func testBackfillOfOldSessionsIsSilent() {
        let now = Date()
        XCTAssertEqual(
            AlertRule.decide(call: call(context: 190_000, minutesAgo: 240, now: now), firedThreshold: nil, now: now),
            .nothing
        )
    }

    // MARK: - Persistence

    func testFiredThresholdSurvivesARestart() throws {
        let workspace = try TempWorkspace()
        XCTAssertNil(try workspace.store.firedThreshold(streamKey: "s|main"))
        try workspace.store.setFiredThreshold(streamKey: "s|main", threshold: 0.85, at: "2026-01-01T00:00:00Z", contextTokens: 10)
        XCTAssertEqual(try workspace.store.firedThreshold(streamKey: "s|main"), 0.85)
        try workspace.store.clearFiredThreshold(streamKey: "s|main")
        XCTAssertNil(try workspace.store.firedThreshold(streamKey: "s|main"))
    }

    func testSubscriptionsRoundTripAndReplaceByEndpoint() throws {
        let workspace = try TempWorkspace()
        let first = PushSubscription(endpoint: "https://push.example/aaa", p256dh: "k1", auth: "a1", createdAt: "2026-01-01T00:00:00Z")
        try workspace.store.upsert(subscription: first)
        // A browser hands out new keys for the same endpoint after a permission
        // reset; that is an update, not a second device.
        try workspace.store.upsert(subscription: PushSubscription(
            endpoint: "https://push.example/aaa", p256dh: "k2", auth: "a2", createdAt: "2026-02-01T00:00:00Z"
        ))
        let stored = try workspace.store.pushSubscriptions()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.p256dh, "k2")

        try workspace.store.recordPush(endpoint: first.endpoint, status: 201, at: "2026-02-02T00:00:00Z")
        XCTAssertEqual(try workspace.store.pushSubscriptions().first?.lastStatus, 201)

        try workspace.store.deletePushSubscription(endpoint: first.endpoint)
        XCTAssertTrue(try workspace.store.pushSubscriptions().isEmpty)
    }

    func testBase64URLHandlesUnpaddedBrowserValues() {
        let data = Data([0xfb, 0xff, 0x00, 0x11, 0x7e])
        let encoded = Base64URL.encode(data)
        XCTAssertFalse(encoded.contains("="))
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertEqual(Base64URL.decode(encoded), data)
    }

    // MARK: - Serving the web app

    func testServesTheWebAppPieces() throws {
        let workspace = try TempWorkspace()
        let router = ServeRouter(store: workspace.store)
        func get(_ path: String) -> HTTPServer.Response {
            router.respond(to: .init(method: "GET", path: path, host: "localhost"))
        }

        let manifest = get("/manifest.webmanifest")
        XCTAssertEqual(manifest.status, 200)
        // An installed web app is the only way iOS allows notifications at all.
        XCTAssertTrue(String(decoding: manifest.body, as: UTF8.self).contains("\"display\": \"standalone\""))

        XCTAssertEqual(get("/sw.js").status, 200)
        XCTAssertTrue(String(decoding: get("/sw.js").body, as: UTF8.self).contains("addEventListener('push'"))

        let icon = get("/icon.png")
        XCTAssertEqual(icon.contentType, "image/png")
        XCTAssertGreaterThan(icon.body.count, 1000)
        XCTAssertEqual(Array(icon.body.prefix(4)), [0x89, 0x50, 0x4e, 0x47])   // it really is a PNG
    }

    func testPushEndpointsRefuseWhenPushIsUnavailable() throws {
        let workspace = try TempWorkspace()
        let router = ServeRouter(store: workspace.store)   // no PushService
        XCTAssertEqual(router.respond(to: .init(method: "GET", path: "/push-key.json", host: "localhost")).status, 501)
        XCTAssertEqual(router.respond(to: .init(method: "POST", path: "/subscribe", host: "localhost")).status, 501)
    }

    func testBodyIsReadUpToTheCap() {
        let head = "POST /subscribe HTTP/1.1\r\nHost: localhost\r\nContent-Length: 12\r\n\r\n"
        XCTAssertEqual(HTTPServer.contentLength(head), 12)
        XCTAssertNil(HTTPServer.contentLength("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"))
    }


    // MARK: - Things a review found

    func testAssumedWindowNeverBuzzes() {
        let now = Date()
        var mystery = call(context: 190_000, now: now)
        mystery.model = "claude-mystery-9"          // not in WindowLimits.table → fallback 200k
        XCTAssertEqual(AlertRule.decide(call: mystery, firedThreshold: nil, now: now), .nothing)

        // Codex reports its window on every turn; an unknown Codex model is
        // measured, not assumed, and still alerts.
        var codex = call(context: 250_000, limit: 272_000, now: now)
        codex.vendor = Vendor.codex
        codex.model = "gpt-5-codex"
        guard case .fire = AlertRule.decide(call: codex, firedThreshold: nil, now: now) else {
            return XCTFail("a measured Codex window should alert")
        }
    }

    func testCompactionEventReArmsEvenWhenNobodySampledTheDip() throws {
        let workspace = try TempWorkspace()
        let now = Date()
        let key = AlertRule.streamKey(sessionId: "sess-1", agentId: nil)
        // Said 95% two minutes ago…
        try workspace.store.setFiredThreshold(
            streamKey: key, threshold: 0.95,
            at: Timestamps.string(from: now.addingTimeInterval(-120)), contextTokens: 190_000
        )
        // …then a compaction a minute ago that was never the newest row when
        // anyone looked, and now the window is back at 90%.
        _ = try workspace.store.insert(event: EventRow(
            id: "evt-compact", sessionId: "sess-1",
            ts: Timestamps.string(from: now.addingTimeInterval(-60)),
            kind: EventKind.compaction.rawValue
        ))
        try workspace.store.upsert(call: call(context: 180_000, minutesAgo: 0.5, now: now))

        let alerts = try PushService(store: workspace.store).pendingAlerts(now: now)
        XCTAssertEqual(alerts.map(\.threshold), [0.85], "the climb after a compaction is news again")
    }

    func testPushEndpointMustBeAnHTTPSService() {
        XCTAssertTrue(ServeRouter.isPushEndpoint("https://web.push.apple.com/QOx1…"))
        XCTAssertTrue(ServeRouter.isPushEndpoint("https://fcm.googleapis.com/fcm/send/abc"))
        XCTAssertFalse(ServeRouter.isPushEndpoint("http://web.push.apple.com/x"))
        XCTAssertFalse(ServeRouter.isPushEndpoint("https://localhost:7878/subscribe"))
        XCTAssertFalse(ServeRouter.isPushEndpoint("https://127.0.0.1/x"))
        XCTAssertFalse(ServeRouter.isPushEndpoint("https://[::1]/x"))
        XCTAssertFalse(ServeRouter.isPushEndpoint("https://mac.local/x"))
        XCTAssertFalse(ServeRouter.isPushEndpoint("not a url"))
    }

    func testNegativeContentLengthIsRefusedNotFatal() throws {
        let workspace = try TempWorkspace()
        let router = ServeRouter(store: workspace.store)
        let server = HTTPServer(port: 0) { router.respond(to: $0) }
        try server.start()
        defer { server.stop() }

        let reply = RawClient.exchange(
            port: server.port,
            "POST /subscribe HTTP/1.1\r\nHost: localhost\r\nContent-Length: -1\r\n\r\n"
        )
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 400"), "got: \(reply.prefix(40))")
        // And the process is still here to answer the next one.
        XCTAssertTrue(RawClient.exchange(port: server.port, "GET /healthz HTTP/1.1\r\nHost: localhost\r\n\r\n")
            .hasPrefix("HTTP/1.1 200"))
    }

    func testAStalledClientDoesNotBlockTheOthers() throws {
        let workspace = try TempWorkspace()
        let router = ServeRouter(store: workspace.store)
        let server = HTTPServer(port: 0) { router.respond(to: $0) }
        try server.start()
        defer { server.stop() }

        // Half a request, then silence — a phone that walked out of range.
        let stalled = RawClient.open(port: server.port)
        RawClient.send(stalled, "GET / HTTP/1.1\r\nHost: localhost\r\n")
        defer { RawClient.close(stalled) }

        let started = Date()
        let reply = RawClient.exchange(port: server.port, "GET /healthz HTTP/1.1\r\nHost: localhost\r\n\r\n")
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 200"), "got: \(reply.prefix(40))")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "the healthy client waited on the stalled one")
    }

    #if canImport(CryptoKit)

    func testRungIsRecordedOnlyOnceADeviceWasTold() throws {
        let workspace = try TempWorkspace()
        let now = Date()
        try workspace.store.upsert(call: call(context: 172_000, now: now))
        try workspace.store.upsert(subscription: PushSubscription(
            endpoint: "https://web.push.apple.com/dev", p256dh: devicePublicKey(), auth: deviceAuth(),
            createdAt: "2026-01-01T00:00:00Z"
        ))
        var status = 503
        let service = PushService(store: workspace.store) { _, completion in completion(status) }

        // The push service is down: nothing reached the phone, so nothing is
        // recorded as said, and the same rung is offered again next pass.
        var results = try service.announce(now: now)
        XCTAssertEqual(results.map(\.1), [PushService.Report(failed: 1)])
        XCTAssertNil(try workspace.store.firedThreshold(streamKey: "sess-1|main"))

        status = 201
        results = try service.announce(now: now)
        XCTAssertEqual(results.map(\.1), [PushService.Report(sent: 1)])
        XCTAssertEqual(try workspace.store.firedThreshold(streamKey: "sess-1|main"), 0.85)

        // And now it has been said.
        XCTAssertTrue(try service.announce(now: now).isEmpty)
    }

    func testDeadSubscriptionIsDroppedEvenWhenTheAnswerIsLate() throws {
        let workspace = try TempWorkspace()
        try workspace.store.upsert(subscription: PushSubscription(
            endpoint: "https://web.push.apple.com/gone", p256dh: devicePublicKey(), auth: deviceAuth(),
            createdAt: "2026-01-01T00:00:00Z"
        ))
        let answered = expectation(description: "late 410")
        let service = PushService(store: workspace.store) { _, completion in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { completion(410); answered.fulfill() }
        }
        // The wait gives up before the push service answers…
        let report = try service.deliverTest(timeout: 0.1)
        XCTAssertEqual(report, PushService.Report())
        // …but the answer still counts when it arrives.
        wait(for: [answered], timeout: 5)
        XCTAssertTrue(try workspace.store.pushSubscriptions().isEmpty, "a 410 is a 410 however late")
    }

    private func devicePublicKey() -> String {
        Base64URL.encode(P256.KeyAgreement.PrivateKey().publicKey.x963Representation)
    }

    private func deviceAuth() -> String { Base64URL.encode(Data(repeating: 9, count: 16)) }

    func testSubscribingStoresTheDeviceAndMintsAKeyOnce() throws {
        let workspace = try TempWorkspace()
        let service = PushService(store: workspace.store)
        let router = ServeRouter(store: workspace.store, push: service)

        let body = Data(#"{"endpoint":"https://web.push.apple.com/x","keys":{"p256dh":"BPk","auth":"aGk"}}"#.utf8)
        let response = router.respond(to: .init(method: "POST", path: "/subscribe", host: "localhost", body: body))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(try workspace.store.pushSubscriptions().first?.endpoint, "https://web.push.apple.com/x")

        XCTAssertEqual(router.respond(to: .init(method: "POST", path: "/subscribe", host: "localhost", body: Data("{}".utf8))).status, 400)

        // The application key is made on first use and then never changes:
        // rotating it silently would invalidate every subscription.
        let first = try service.applicationKey()
        XCTAssertEqual(first.publicKey, try service.applicationKey().publicKey)
        XCTAssertEqual(Base64URL.decode(first.publicKey)?.count, 65)
        XCTAssertEqual(Base64URL.decode(first.publicKey)?.first, 0x04)
    }

    func testEncryptedPayloadHasTheAes128gcmFraming() throws {
        // Verified against node's http_ece, the library `web-push` itself uses:
        // it decrypts what this produces. Here we only pin the framing so a
        // future edit cannot quietly reshape the record header.
        let device = P256.KeyAgreement.PrivateKey()
        let body = try WebPush.encrypt(
            payload: Data("hello".utf8),
            p256dh: device.publicKey.x963Representation,
            auth: Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        )
        XCTAssertEqual(body.count, 16 + 4 + 1 + 65 + 5 + 1 + 16)   // salt|rs|idlen|key|"hello"|0x02|tag
        XCTAssertEqual(Array(body[16..<20]), [0x00, 0x00, 0x10, 0x00])   // record size 4096, big endian
        XCTAssertEqual(body[20], 65)
        XCTAssertEqual(body[21], 0x04)                                    // uncompressed point
    }

    func testRequestCarriesTheHeadersAPushServiceRequires() throws {
        let workspace = try TempWorkspace()
        let service = PushService(store: workspace.store)
        let device = P256.KeyAgreement.PrivateKey()
        let request = try WebPush.request(
            subscription: PushSubscription(
                endpoint: "https://web.push.apple.com/abc",
                p256dh: Base64URL.encode(device.publicKey.x963Representation),
                auth: Base64URL.encode(Data(repeating: 7, count: 16)),
                createdAt: "2026-01-01T00:00:00Z"
            ),
            payload: Data(#"{"title":"x"}"#.utf8),
            key: try service.applicationKey(),
            subject: "mailto:ullage@localhost"
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Encoding"), "aes128gcm")
        XCTAssertEqual(request.value(forHTTPHeaderField: "TTL"), "86400")
        let authorization = try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(authorization.hasPrefix("vapid t="))
        XCTAssertTrue(authorization.contains(", k="))
        // Three dot-separated JWT parts.
        let token = authorization.dropFirst("vapid t=".count).prefix(while: { $0 != "," })
        XCTAssertEqual(token.split(separator: ".").count, 3)
    }

    func testAudienceIsTheOriginNotTheEndpointPath() throws {
        let workspace = try TempWorkspace()
        let key = try PushService(store: workspace.store).applicationKey()
        let header = try WebPush.authorization(
            endpoint: URL(string: "https://web.push.apple.com/some/long/path")!,
            key: key,
            subject: "mailto:x@y.z"
        )
        let token = header.dropFirst("vapid t=".count).prefix(while: { $0 != "," })
        let claims = try XCTUnwrap(Base64URL.decode(String(token.split(separator: ".")[1])))
        let decoded = try JSONSerialization.jsonObject(with: claims) as? [String: Any]
        // A JWT scoped to the path is rejected by every push service.
        XCTAssertEqual(decoded?["aud"] as? String, "https://web.push.apple.com")
    }

    #endif
}

#if canImport(CryptoKit)
import CryptoKit
#endif

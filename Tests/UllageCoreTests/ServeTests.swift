import Foundation
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import UllageCore

/// What a browser is allowed to be told, and by whom.
final class ServeTests: XCTestCase {

    private func call(
        _ id: String,
        session: String = "sess-1",
        project: String? = "proj",
        model: String? = "claude-sonnet-4-5-20250929",
        context: Int,
        limit: Int? = 200_000,
        minutesAgo: Double,
        now: Date
    ) -> CallRow {
        CallRow(
            dedupeKey: id,
            ts: Timestamps.string(from: now.addingTimeInterval(-minutesAgo * 60)),
            sessionId: session,
            project: project,
            model: model,
            contextTokens: context,
            windowLimit: limit,
            sourceFile: "x.jsonl"
        )
    }

    // MARK: - The snapshot

    func testLiveGaugeFollowsTheMenuBarRule() throws {
        let workspace = try TempWorkspace()
        let now = Date()
        try workspace.store.upsert(call: call("a", context: 144_000, minutesAgo: 1, now: now))

        let snapshot = try ServeSnapshot.build(store: workspace.store, now: now)
        XCTAssertEqual(snapshot.live.status, "live")
        XCTAssertEqual(snapshot.live.title, "72%")
        XCTAssertEqual(snapshot.live.contextTokens, 144_000)
        XCTAssertEqual(snapshot.live.project, "proj")
        // The page renders age itself, from a number this machine computed.
        XCTAssertEqual(try XCTUnwrap(snapshot.live.ageSeconds), 60, accuracy: 2)
        // Sent so the browser and the menu bar cannot turn amber at different
        // moments.
        XCTAssertEqual(snapshot.warningThreshold, MenuBarFormatter.warningThreshold)
    }

    func testStaleGaugeGoesQuietInTheBrowserToo() throws {
        let workspace = try TempWorkspace()
        let now = Date()
        try workspace.store.upsert(call: call("a", context: 144_000, minutesAgo: 31, now: now))

        let snapshot = try ServeSnapshot.build(store: workspace.store, now: now)
        XCTAssertEqual(snapshot.live.status, "idle")
        XCTAssertEqual(snapshot.live.title, MenuBarFormatter.idleGlyph)
        // The detail survives; only the headline goes quiet.
        XCTAssertEqual(snapshot.live.contextTokens, 144_000)
    }

    /// Rule 1: an agent's window is not the session's, and rule 3: a harness
    /// that reported no window gets no percentage. `latestCall()` enforces both,
    /// and the browser gauge must not route around it.
    func testWindowlessRowNeverDrivesTheBrowserGauge() throws {
        let workspace = try TempWorkspace()
        let now = Date()
        try workspace.store.upsert(call: call("measured", context: 50_000, minutesAgo: 5, now: now))
        var unmeasured = call("cursor", session: "sess-cursor", project: "web",
                              model: nil, context: 0, limit: nil, minutesAgo: 1, now: now)
        unmeasured.vendor = Vendor.cursor
        unmeasured.confidence = Confidence.unmeasured.rawValue
        try workspace.store.upsert(call: unmeasured)

        let snapshot = try ServeSnapshot.build(store: workspace.store, now: now)
        // The newer row is the window-less one; the gauge still shows the older
        // measured session rather than jumping to it.
        XCTAssertEqual(snapshot.live.sessionId, "sess-1")
        XCTAssertEqual(snapshot.live.occupancy, 0.25)

        // It is still listed — activity is real even when occupancy is not —
        // but with a null occupancy, never a zero.
        let cursor = try XCTUnwrap(snapshot.sessions.first { $0.sessionId == "sess-cursor" })
        XCTAssertNil(cursor.occupancy)
        XCTAssertNil(cursor.windowLimit)
    }

    func testJSONOmitsUnmeasuredOccupancyRatherThanSendingZero() throws {
        let workspace = try TempWorkspace()
        let now = Date()
        var unmeasured = call("cursor", session: "s", project: "web", model: nil,
                              context: 0, limit: nil, minutesAgo: 1, now: now)
        unmeasured.confidence = Confidence.unmeasured.rawValue
        try workspace.store.upsert(call: unmeasured)

        let data = try ServeSnapshot.build(store: workspace.store, now: now).json()
        let text = String(decoding: data, as: UTF8.self)
        // A zero here would be read as "empty window" by anything downstream.
        XCTAssertFalse(text.contains("\"occupancy\":0,"))
        let decoded = try JSONDecoder().decode(ServeSnapshot.self, from: data)
        XCTAssertNil(decoded.sessions.first?.occupancy)
        XCTAssertEqual(decoded.live.status, "empty")
    }

    // MARK: - The guard

    /// A loopback server with no host check is readable by any page you visit.
    func testHostGuardAcceptsLoopbackAndTailnetOnly() {
        XCTAssertTrue(HTTPServer.isAllowedHost("127.0.0.1:7878"))
        XCTAssertTrue(HTTPServer.isAllowedHost("localhost"))
        XCTAssertTrue(HTTPServer.isAllowedHost("[::1]:7878"))
        XCTAssertTrue(HTTPServer.isAllowedHost("mac.tail1234.ts.net"))
        XCTAssertTrue(HTTPServer.isAllowedHost("MAC.TAIL1234.TS.NET"))

        XCTAssertFalse(HTTPServer.isAllowedHost("evil.example.com"))
        // The suffix is a real label boundary, not a substring.
        XCTAssertFalse(HTTPServer.isAllowedHost("attacker-ts.net"))
        XCTAssertFalse(HTTPServer.isAllowedHost("localhost.evil.com"))
        XCTAssertFalse(HTTPServer.isAllowedHost(nil))
        XCTAssertFalse(HTTPServer.isAllowedHost(""))
    }

    func testRequestParsingDropsTheQueryAndFindsTheHost() throws {
        let request = try XCTUnwrap(HTTPServer.parse(
            "GET /state.json?since=4 HTTP/1.1\r\nHost: 127.0.0.1:7878\r\nAccept: */*\r\n\r\n"
        ))
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/state.json")
        XCTAssertEqual(request.host, "127.0.0.1:7878")
        XCTAssertNil(HTTPServer.parse(""))
    }

    // MARK: - Routing

    func testRouterServesThePageAndTheState() throws {
        let workspace = try TempWorkspace()
        let router = ServeRouter(store: workspace.store)

        let page = router.respond(to: .init(method: "GET", path: "/", host: "localhost"))
        XCTAssertEqual(page.status, 200)
        XCTAssertTrue(page.contentType.hasPrefix("text/html"))
        // The page must fetch the endpoint this router actually serves.
        XCTAssertTrue(String(decoding: page.body, as: UTF8.self).contains("state.json"))

        XCTAssertEqual(router.respond(to: .init(method: "GET", path: "/state.json", host: "localhost")).status, 200)
        XCTAssertEqual(router.respond(to: .init(method: "GET", path: "/secrets", host: "localhost")).status, 404)
    }

    // MARK: - End to end

    func testServerAnswersOverLoopback() throws {
        let workspace = try TempWorkspace()
        let now = Date()
        try workspace.store.upsert(call: call("a", context: 100_000, minutesAgo: 1, now: now))

        let router = ServeRouter(store: workspace.store, now: { now })
        // Port 0: the kernel picks a free one, so the suite never collides with
        // a server someone is actually running.
        let server = HTTPServer(port: 0) { router.respond(to: $0) }
        try server.start()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(server.port)/state.json")!
        let expectation = expectation(description: "response")
        var payload: Data?
        var status: Int?
        URLSession.shared.dataTask(with: url) { data, response, _ in
            payload = data
            status = (response as? HTTPURLResponse)?.statusCode
            expectation.fulfill()
        }.resume()
        wait(for: [expectation], timeout: 10)

        XCTAssertEqual(status, 200)
        let snapshot = try JSONDecoder().decode(ServeSnapshot.self, from: try XCTUnwrap(payload))
        XCTAssertEqual(snapshot.live.occupancy, 0.5)
        XCTAssertEqual(snapshot.live.title, "50%")
    }
}

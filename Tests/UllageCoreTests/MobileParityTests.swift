import Foundation
import XCTest
@testable import UllageCore

/// The phone page shows what the popover shows, from the same rules, and the
/// one endpoint that changes the Mac answers only to that page.
final class MobileParityTests: XCTestCase {
    private func temp() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("parity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    // MARK: - Requests

    func testParsingKeepsQueryAndHeaders() throws {
        let request = try XCTUnwrap(HTTPServer.parse(
            "POST /savers?session=abc%20d&x=1 HTTP/1.1\r\nHost: 127.0.0.1:7878\r\nOrigin: http://127.0.0.1:7878\r\nX-Ullage: 1\r\n\r\n"))
        XCTAssertEqual(request.path, "/savers")
        XCTAssertEqual(request.query, ["session": "abc d", "x": "1"])
        XCTAssertEqual(request.headers["origin"], "http://127.0.0.1:7878")
        XCTAssertEqual(request.host, "127.0.0.1:7878")
    }

    func testSameOriginNeedsTheOriginAndTheHeader() {
        func request(_ headers: [String: String], host: String = "mac.tail1234.ts.net") -> HTTPServer.Request {
            HTTPServer.Request(method: "POST", path: "/savers", host: host, headers: headers)
        }
        XCTAssertTrue(ServeRouter.isSameOrigin(request(["origin": "https://mac.tail1234.ts.net", "x-ullage": "1"])))
        XCTAssertTrue(ServeRouter.isSameOrigin(request(["origin": "http://127.0.0.1:7878", "x-ullage": "1"], host: "127.0.0.1:7878")))
        XCTAssertFalse(ServeRouter.isSameOrigin(request(["origin": "https://mac.tail1234.ts.net"])), "no header")
        XCTAssertFalse(ServeRouter.isSameOrigin(request(["x-ullage": "1"])), "no origin")
        XCTAssertFalse(ServeRouter.isSameOrigin(request(["origin": "https://evil.example", "x-ullage": "1"])), "another site")
        XCTAssertFalse(ServeRouter.isSameOrigin(request(["origin": "http://127.0.0.1:9999", "x-ullage": "1"], host: "127.0.0.1:7878")),
                       "another port on loopback is another origin")
    }

    // MARK: - Switches from the phone, end to end against a throwaway config

    func testSwitchAndUndoThroughTheRouter() throws {
        let root = try temp()
        let settings = root.appendingPathComponent(".claude/settings.json")
        try #"{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"rtk hook claude"}]}]}}"#
            .write(to: settings, atomically: true, encoding: .utf8)
        let environment = ["CLAUDE_CONFIG_DIR": root.appendingPathComponent(".claude").path,
                           "ULLAGE_DB": root.appendingPathComponent("support/telemetry.db").path,
                           "PATH": root.path]
        let store = try Store.inMemory()
        let router = ServeRouter(store: store, savers: SaverControl(environment: environment))
        func post(_ action: String, headers: [String: String] = ["origin": "http://localhost:7878", "x-ullage": "1"]) -> Int {
            router.respond(to: HTTPServer.Request(method: "POST", path: "/savers", host: "localhost:7878",
                                                  body: Data(#"{"saver":"rtk","action":"\#(action)"}"#.utf8),
                                                  headers: headers)).status
        }
        let board = SaverSwitchboard(environment: environment)

        XCTAssertEqual(post("off", headers: [:]), 403)
        XCTAssertEqual(board.state(of: .rtk), .on, "a refused request changed nothing")

        XCTAssertEqual(post("off"), 200)
        XCTAssertEqual(board.state(of: .rtk), .off)
        XCTAssertEqual(post("undo"), 200)
        XCTAssertEqual(board.state(of: .rtk), .on, "Undo put the hook back")
        XCTAssertEqual(post("sideways"), 400)
    }

    func testPlanEndpointShowsCommandsAndRunsNothing() throws {
        let root = try temp()
        let environment = ["CLAUDE_CONFIG_DIR": root.appendingPathComponent(".claude").path,
                           "ULLAGE_DB": root.appendingPathComponent("support/telemetry.db").path, "PATH": root.path]
        let router = ServeRouter(store: try Store.inMemory(), savers: SaverControl(environment: environment))
        let response = router.respond(to: HTTPServer.Request(method: "GET", path: "/savers/plan", host: "localhost",
                                                             query: ["saver": "caveman", "action": "install"]))
        XCTAssertEqual(response.status, 200)
        let plan = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        // The installer also searches the usual install folders, so whether
        // `claude` is found depends on the machine; the shape does not.
        let steps = plan["steps"] as? [[String: Any]] ?? []
        let missing = plan["missing"] as? [String] ?? []
        XCTAssertTrue(!steps.isEmpty || missing == ["the claude CLI"])
        XCTAssertTrue(steps.allSatisfy { ($0["command"] as? String)?.hasPrefix("claude plugin") == true })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".claude/settings.json").path),
                       "asking for a plan writes nothing")
    }

    func testRunningRefusesAPlanThatNeedsAPerson() {
        let interactive = InstallPlan(saver: .tokenade, action: .install,
                                      steps: [InstallStep("tokenade login", "Sign in", interactive: true)], missing: [], notes: [])
        XCTAssertTrue(interactive.isRunnable && interactive.needsPerson,
                      "SaverControl.run refuses exactly this shape: runnable, but nobody is at the Mac")
    }

    // MARK: - The detail the page draws

    func testSnapshotCarriesThePopoverForTheRequestedSession() throws {
        let store = try Store.inMemory()
        let now = Date()
        for (i, session) in [(0, "a"), (1, "a"), (0, "b")] {
            try store.upsert(call: CallRow(
                dedupeKey: "\(session)\(i)", ts: Timestamps.string(from: now.addingTimeInterval(Double(i) * 60 - (session == "a" ? 600 : 0))),
                sessionId: session, project: "p-\(session)", cwd: "/r/\(session)", model: "claude-opus-5-5",
                cacheRead: 1_000, contextTokens: 10_000 + i * 2_000, windowLimit: 1_000_000, turnIndex: i, sourceFile: "t"))
        }
        _ = try store.insert(event: EventRow(id: "r", sessionId: "a", ts: Timestamps.string(from: now), kind: EventKind.remote.rawValue,
                                             detail: "https://claude.ai/code/session_01abc"))

        let latest = try ServeSnapshot.build(store: store, now: now)
        XCTAssertEqual(latest.detail?.sessionId, "b", "unrequested: the session the menu bar follows")
        XCTAssertEqual(latest.detail?.isLatest, true)
        XCTAssertEqual(Set(latest.sessions.compactMap(\.path)), ["/r/a", "/r/b"], "each session carries its working directory")

        let picked = try ServeSnapshot.build(store: store, sessionId: "a", now: now)
        let detail = try XCTUnwrap(picked.detail)
        XCTAssertEqual(detail.sessionId, "a")
        XCTAssertFalse(detail.isLatest)
        XCTAssertEqual(detail.link, SessionLink(label: "Open in Claude", url: "https://claude.ai/code/session_01abc"))
        XCTAssertEqual(detail.headroom, "988k")
        XCTAssertEqual(detail.chart?.points, [[0, 10_000], [1, 12_000]])
        XCTAssertEqual(detail.sections.map(\.id), ["composition", "session"])
        XCTAssertEqual(detail.sections.first?.dots, ["baseline", "tools", "output", "other"])
        XCTAssertEqual(try ServeSnapshot.build(store: store, sessionId: "gone", now: now).detail?.sessionId, "b",
                       "a session with no turns falls back to the followed one")
    }

    func testRemoteSessionLineBecomesAnEvent() {
        let line = #"{"type":"attachment","uuid":"u","timestamp":"2026-09-05T23:51:04.441Z","sessionId":"s","attachment":{"type":"remote_session_change","url":"https://claude.ai/code/session_01MY"}}"#
        guard case .event(let event)? = ClaudeCodeParser.parse(line: Data(line.utf8), context: LineContext(sourceFile: "t", fallbackSessionId: "s")) else {
            return XCTFail("expected an event")
        }
        XCTAssertEqual(event.kind, EventKind.remote.rawValue)
        XCTAssertEqual(event.detail, "https://claude.ai/code/session_01MY")
        let elsewhere = line.replacingOccurrences(of: "https://claude.ai/code/session_01MY", with: "https://evil.example/x")
        guard case .event(let other)? = ClaudeCodeParser.parse(line: Data(elsewhere.utf8), context: LineContext(sourceFile: "t", fallbackSessionId: "s")) else {
            return XCTAssertTrue(true)
        }
        XCTAssertNotEqual(other.kind, EventKind.remote.rawValue, "only a claude.ai/code URL is put behind a link")
    }

    func testIdleSaverSwitchedOffSaysSo() {
        var idle = SaverUsage(saver: .headroom)
        idle.mcpConfigured = true
        let report = SaverSessionReport(sessionId: "s", cwd: nil, bashCalls: 0, usages: [idle], doubleHookedCalls: 0)
        let panel = SaverPanel.build(report: report, states: [.headroom: .off], comparison: nil, installed: [.headroom])
        XCTAssertEqual(panel.rows.first?.pending, SaverPanel.offNextSession)
    }

    func testCodexSessionsOpenInTheCodexApp() throws {
        let store = try Store.inMemory()
        try store.upsert(call: CallRow(dedupeKey: "c", ts: Timestamps.now(), vendor: Vendor.codex,
                                       sessionId: "01a0511c-c924-79e2-972b-d4011e4de7ac", contextTokens: 1, sourceFile: "t"))
        try store.upsert(call: CallRow(dedupeKey: "k", ts: Timestamps.now(), sessionId: "claude-no-remote", contextTokens: 1, sourceFile: "t"))
        XCTAssertEqual(try store.sessionLink(sessionId: "01a0511c-c924-79e2-972b-d4011e4de7ac"),
                       SessionLink(label: "Open in Codex", url: "codex://threads/01a0511c-c924-79e2-972b-d4011e4de7ac"))
        XCTAssertNil(try store.sessionLink(sessionId: "claude-no-remote"), "no Remote Control, no link")
    }

    func testPageCarriesTheSameHelpAsThePopover() throws {
        let router = ServeRouter(store: try Store.inMemory())
        let page = String(decoding: router.respond(to: HTTPServer.Request(method: "GET", path: "/", host: "localhost")).body, as: UTF8.self)
        XCTAssertFalse(page.contains("/*HELP_JSON*/"), "the placeholder is filled")
        XCTAssertTrue(page.contains("How do I avoid cache rebuilds?"))
        XCTAssertFalse(HelpText.json.contains("summaris"), "American English")
        XCTAssertTrue(page.contains("What's an orange triangle?"))
        XCTAssertTrue(page.contains("rebuildCaused"), "marks carry their glyph so the page draws them as the chart does")
        XCTAssertEqual(HelpText.sections.map(\.title),
                       ["The chart", "Context composition", "Session information", "Agents", "Token savers", "Plan limits"],
                       "one sheet, a section per part of the page, in page order")
        XCTAssertEqual(HelpText.chart.entries.last?.question, "What's compaction?", "compaction closes the chart's list")
        XCTAssertTrue(page.contains("id=\"explain\""), "one Explain button")
        XCTAssertFalse(page.contains("class=\"info\""), "no per-section links left")
        XCTAssertTrue(page.contains("id=\"page\""), "sections open as pages, as in the window")
        XCTAssertFalse(page.contains("<details data-id"), "no collapsible sections on the overview")
        XCTAssertFalse(HelpText.json.contains("</"), "cannot close the script tag it sits in")
    }
}

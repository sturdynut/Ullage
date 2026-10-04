import Foundation
import XCTest
@testable import UllageCore

/// The usage dashboard's rules, without a UI.
final class UsageDashboardTests: XCTestCase {
    private let now = Timestamps.date(from: "2026-10-01T12:00:00.000Z")!

    private func at(_ minutes: Double, daysAgo: Double = 1) -> Date {
        now.addingTimeInterval(-daysAgo * 86_400 + minutes * 60)
    }

    /// A session of `turns` calls `every` minutes apart, each with `output`.
    private func session(
        _ id: String, turns: Int, every: Double = 1, output: Int = 100, daysAgo: Double = 1,
        project: String = "proj", vendor: String = Vendor.claudeCode, measured: Bool = true
    ) -> [UsageCall] {
        (0..<turns).map { i in
            UsageCall(
                sessionId: id, vendor: vendor, project: project, model: "claude-opus-5", ts: at(Double(i) * every, daysAgo: daysAgo),
                output: measured ? output : 0, cacheRead: measured ? 1_000 : 0, contextTokens: measured ? 10_000 : 0,
                windowLimit: measured ? 100_000 : nil, measured: measured
            )
        }
    }

    func testActiveTimeSkipsGapsLongerThanTheIdleGap() {
        // Three calls a minute apart, then a resume two days later, then one more.
        var calls = session("a", turns: 3, daysAgo: 3)
        calls += session("a", turns: 2, daysAgo: 1).enumerated().map { var c = $1; c.ts = at(Double($0), daysAgo: 1); return c }
        let s = UsageDashboard.sessions(from: calls, compactions: [:])[0]
        XCTAssertEqual(s.activeHours(idleGap: 30 * 60), 3.0 / 60, accuracy: 1e-9)   // 2 + 1 minutes
        XCTAssertGreaterThan(s.elapsedHours, 47)
        XCTAssertEqual(s.activeHours(idleGap: 3 * 86_400), s.elapsedHours, accuracy: 1e-9)
    }

    func testSubagentTokensCountButItsWindowDoesNot() {
        var calls = session("a", turns: 2)
        // A subagent turn: more output, and a context that would read as 90% of the window.
        calls.append(UsageCall(sessionId: "a", ts: at(5), agentId: "agent-1", output: 500,
                               contextTokens: 90_000, windowLimit: 100_000))
        let s = UsageDashboard.sessions(from: calls, compactions: [:])[0]
        XCTAssertEqual(s.output, 700)
        XCTAssertEqual(s.agentOutput, 500)
        XCTAssertEqual(s.turns, 2)
        XCTAssertEqual(s.peakOccupancy, 0.1)
        XCTAssertEqual(s.hotTurns, 0)
    }

    func testPeakOccupancyIsPerRowSoAModelSwitchCannotExceedTheWindow() {
        // 800k on a 1M window, then a 200k-window model at 50k. Dividing the
        // peak context by the last window would say 400%.
        let calls = [
            UsageCall(sessionId: "a", ts: at(0), contextTokens: 800_000, windowLimit: 1_000_000),
            UsageCall(sessionId: "a", ts: at(1), contextTokens: 50_000, windowLimit: 200_000),
        ]
        let s = UsageDashboard.sessions(from: calls, compactions: [:])[0]
        XCTAssertEqual(s.peakOccupancy, 0.8)
        XCTAssertEqual(s.peakContext, 800_000)
    }

    func testTheTypicalSessionIsTheMedianAndTheAverageIsShownBesideIt() {
        let calls = session("a", turns: 20, output: 100) + session("b", turns: 20, output: 200)
            + session("c", turns: 20, output: 100_000)
        let d = UsageDashboard(calls: calls, options: .init(), now: now)
        XCTAssertEqual(d.summary.median, 4_000)
        XCTAssertEqual(d.summary.mean!, (2_000.0 + 4_000 + 2_000_000) / 3, accuracy: 1e-6)
        XCTAssertEqual(d.keyTiles[1].title, "Typical session")
        XCTAssertEqual(d.keyTiles[1].value, "4.0k")
    }

    func testRatesLeaveOutSessionsUnderTenActiveMinutes() {
        // "short" has 2 active minutes and an absurd rate; it must not count.
        let calls = session("long", turns: 61, every: 1, output: 100) + session("short", turns: 3, every: 1, output: 1_000_000)
        let d = UsageDashboard(calls: calls, options: .init(), now: now)
        XCTAssertEqual(d.summary.ratedSessions, 1)
        XCTAssertEqual(d.summary.perActiveHour!, 6_100, accuracy: 1e-6)   // 61 × 100 over one hour
        XCTAssertEqual(d.ranked(by: .perActiveHour).map(\.id), ["long"])
        XCTAssertEqual(d.sessions.count, 2)   // still a session, just not rated
    }

    func testExtremesNeverListTheSameSessionTwice() {
        let calls = (0..<5).flatMap { session("s\($0)", turns: 20, output: ($0 + 1) * 100) }
        let d = UsageDashboard(calls: calls, options: .init(), now: now)
        let (highest, lowest) = d.extremes(by: .total, limit: 3)
        XCTAssertEqual(highest.map(\.id), ["s4", "s3", "s2"])
        XCTAssertEqual(lowest.map(\.id), ["s0", "s1"])
    }

    func testTheCounterIsChosenNeverSummed() {
        let calls = session("a", turns: 20, output: 100)
        let output = UsageDashboard(calls: calls, options: .init(counter: .output), now: now)
        let cacheRead = UsageDashboard(calls: calls, options: .init(counter: .cacheRead), now: now)
        XCTAssertEqual(output.summary.total, 2_000)
        XCTAssertEqual(cacheRead.summary.total, 20_000)
        XCTAssertEqual(output.summary.cacheHitRatio, 1)   // all prompt came from cache
    }

    func testRangeComparesWithThePeriodBeforeIt() {
        let calls = session("now", turns: 20, output: 300, daysAgo: 2) + session("before", turns: 20, output: 100, daysAgo: 10)
            + session("ancient", turns: 20, output: 999, daysAgo: 40)
        let d = UsageDashboard(calls: calls, options: .init(days: 7), now: now)
        XCTAssertEqual(d.sessions.map(\.id), ["now"])
        XCTAssertEqual(d.previous?.sessions, 1)
        XCTAssertEqual(d.keyTiles[1].change?.text, "▲ 200%")
        XCTAssertEqual(d.keyTiles[1].change?.caption, "vs prior 7 days")
        XCTAssertNil(UsageDashboard(calls: calls, options: .init(days: nil), now: now).previous)
    }

    func testPeakFillChangeIsInPointsNotPercentOfAPercent() {
        var a = session("now", turns: 20, daysAgo: 2), b = session("before", turns: 20, daysAgo: 10)
        a[0].contextTokens = 60_000   // 60% vs 10%
        b[0].contextTokens = 30_000   // 30%
        let d = UsageDashboard(calls: a + b, options: .init(days: 7), now: now)
        XCTAssertEqual(d.keyTiles[2].value, "60%")
        XCTAssertEqual(d.keyTiles[2].change?.text, "▲ 30 pts")
    }

    func testAHarnessWithoutTokensGetsActivityNotZeros() {
        let calls = session("c", turns: 20, vendor: Vendor.cursor, measured: false)
        let d = UsageDashboard(calls: calls, options: .init(vendor: Vendor.cursor), now: now)
        XCTAssertFalse(d.summary.measured)
        XCTAssertNil(d.summary.perActiveHour)
        XCTAssertNil(d.summary.median)
        XCTAssertEqual(d.keyTiles.map(\.value).suffix(2), ["not reported", "not reported"])
        XCTAssertTrue(d.moreTiles.isEmpty)
        XCTAssertTrue(d.ranked(by: .total).isEmpty)
        XCTAssertTrue(d.sizeBands.isEmpty)
    }

    func testOnlyTheChosenHarnessIsCounted() {
        let calls = session("claude", turns: 20, output: 100) + session("codex", turns: 20, output: 5_000, vendor: Vendor.codex)
        XCTAssertEqual(UsageDashboard(calls: calls, options: .init(), now: now).summary.total, 2_000)
        XCTAssertEqual(UsageDashboard(calls: calls, options: .init(vendor: Vendor.codex), now: now).summary.total, 100_000)
    }

    func testWeeksRunThroughEmptyWeeksAndCountActiveTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let calls = session("a", turns: 31, every: 2, output: 10, daysAgo: 20) + session("b", turns: 2, output: 10, daysAgo: 1)
        let d = UsageDashboard(calls: calls, options: .init(days: 30), now: now, calendar: calendar)
        XCTAssertEqual(d.weeks.count, 4)   // Sep 7 … Sep 28, Mondays
        XCTAssertEqual(d.weeks.map(\.total), [310, 0, 0, 20])
        XCTAssertEqual(d.weeks[0].activeHours, 1, accuracy: 1e-9)
        XCTAssertEqual(d.weeks[0].perActiveHour!, 310, accuracy: 1e-6)
        XCTAssertNil(d.weeks[3].perActiveHour)   // one minute is not a rate
    }

    func testSizeBandsAreTrimmedToTheOnesWithSessions() {
        let calls = session("a", turns: 20, output: 100) + session("b", turns: 20, output: 10_000)
        let d = UsageDashboard(calls: calls, options: .init(), now: now)
        XCTAssertEqual(d.sizeBands.map(\.label), ["1–10k", "10–100k", "100k–1M"])
        XCTAssertEqual(d.sizeBands.map(\.sessions), [1, 0, 1])
    }

    func testFormatting() {
        XCTAssertEqual(UsageDashboard.tokens(950), "950")
        XCTAssertEqual(UsageDashboard.tokens(12_400), "12k")
        XCTAssertEqual(UsageDashboard.tokens(2_090_000), "2.09M")
        XCTAssertEqual(UsageDashboard.tokens(8_600_000_000), "8.60B")
        XCTAssertEqual(UsageDashboard.tokens(nil), "—")
        XCTAssertEqual(UsageDashboard.hours(0.4), "24 min")
        XCTAssertEqual(UsageDashboard.hours(6.66), "6.7 h")
        XCTAssertEqual(UsageDashboard.hours(694.6), "695 h")
    }

    func testStoreBuildsTheDashboardWithMainThreadCompactionsOnly() throws {
        let store = try Store.inMemory()
        func row(_ session: String, _ turn: Int, _ minute: Int, agent: String? = nil) -> CallRow {
            CallRow(
                dedupeKey: "msg_\(session)_\(turn)_\(agent ?? "")", ts: Timestamps.string(from: at(Double(minute))),
                agentId: agent, sessionId: session, project: "proj", model: "claude-opus-5", output: 100,
                contextTokens: 40_000, windowLimit: 200_000, turnIndex: turn, sourceFile: "\(session).jsonl"
            )
        }
        for i in 0..<15 { try store.upsert(call: row("a", i, i)) }
        try store.upsert(call: row("a", 0, 3, agent: "sub"))
        _ = try store.insert(event: EventRow(id: "e1", sessionId: "a", ts: Timestamps.string(from: at(4)), kind: EventKind.compaction.rawValue))
        _ = try store.insert(event: EventRow(id: "e2", sessionId: "a", agentId: "sub", ts: Timestamps.string(from: at(4)), kind: EventKind.compaction.rawValue))
        try store.upsert(toolCall: ToolCallRow(id: "t1", callId: "msg_a_0_", sessionId: "a", ts: Timestamps.string(from: at(0)),
                                               name: "Read", kind: "builtin", resultTokens: 1_200, isError: false))

        let d = try store.usageDashboard(.init(days: 30), now: now)
        XCTAssertEqual(d.sessions.count, 1)
        let s = d.sessions[0]
        XCTAssertEqual(s.turns, 15)
        XCTAssertEqual(s.output, 1_600)
        XCTAssertEqual(s.agentOutput, 100)
        XCTAssertEqual(s.compactions, 1)
        XCTAssertEqual(s.peakOccupancy, 0.2)
        XCTAssertEqual(d.tools, [ToolUsage(name: "Read", calls: 1, estimatedResultTokens: 1_200, errors: 0)])
    }
}

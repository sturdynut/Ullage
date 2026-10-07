import Foundation
import XCTest
@testable import UllageCore

/// The total: every tool's claim on one basis, a call two tools claim
/// counted once, comparisons left out, split by tool, time and session.
final class SavingsSummaryTests: XCTestCase {
    private let at = { (s: String) in Timestamps.date(from: s)! }
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    private let now = Timestamps.date(from: "2026-10-07T12:00:00Z")!

    private func entry(_ id: String, _ ts: String, before: Int, after: Int, call: String? = nil, saver: TokenSaver = .rtk) -> LedgerEntry {
        LedgerEntry(saver: saver, ts: at(ts), cwd: "/repo", command: "ls", beforeTokens: before, afterTokens: after,
                    savedTokens: before - after, id: id, toolUseId: call)
    }

    private func detail(_ saver: TokenSaver, _ entries: [LedgerEntry], prompts: [String: Int] = [:], sessions: [String: String] = [:]) -> SaverDetail {
        var detail = SaverDetail.build(saver: saver, range: .week, reports: [])
        detail.ledgerEntries = entries
        detail.prompts = prompts
        detail.entrySessions = sessions
        return detail
    }

    func testClaimsAreTotalledOnePromptBasis() {
        let rtk = detail(.rtk, [
            entry("r1", "2026-10-06T10:00:00Z", before: 100, after: 40, call: "a"),   // stayed in 10 prompts
            entry("r2", "2026-10-07T09:00:00Z", before: 50, after: 30),               // not placed: counted once
        ], prompts: ["a": 10], sessions: ["r1": "s1", "r2": "s2"])
        let headroom = detail(.headroom, [entry("h1", "2026-10-07T08:00:00Z", before: 1000, after: 900, saver: .headroom)],
                              prompts: [:], sessions: ["h1": "s2"])
        let summary = SavingsSummary.build(details: [rtk, headroom], range: .week,
                                           sessions: ["s1": .init(project: "Ullage", firstTs: "2026-10-06T09:00:00.000Z", turns: 40)],
                                           now: now, calendar: utc)
        XCTAssertEqual(summary.tools.map(\.saver), [.rtk, .headroom], "registry order")
        XCTAssertEqual(summary.tools[0].counted, 60 * 10 + 20)
        XCTAssertEqual(summary.tools[1].counted, 100, "a request's claim is already per prompt")
        XCTAssertEqual(summary.saved, 720)
        XCTAssertEqual(summary.before, 1000 + 50 + 1000)
        XCTAssertEqual(summary.after, summary.before - 720)
        XCTAssertEqual(summary.cut, 35)
        XCTAssertEqual(summary.share(summary.tools[0]), 86)
        XCTAssertEqual(summary.buckets.map(\.key), ["2026-10-06", "2026-10-07"])
        XCTAssertEqual(summary.buckets.map { $0.saved["rtk"] ?? 0 }, [600, 20])
        XCTAssertEqual(summary.sessions.map(\.sessionId), ["s1", "s2"], "largest first")
        XCTAssertEqual(summary.sessions[1].saved, ["rtk": 20, "headroom": 100])
        XCTAssertEqual(summary.sessions[0].project, "Ullage")
        XCTAssertEqual(summary.sessions[0].turns, 40)
        XCTAssertEqual(summary.activeBuckets, 2)
    }

    func testACallTwoToolsClaimIsCountedOnceUnderTheLargerClaim() {
        let rtk = detail(.rtk, [entry("r1", "2026-10-07T10:00:00Z", before: 100, after: 40, call: "a")])
        let tokenade = detail(.tokenade, [
            entry("t1", "2026-10-07T10:00:00Z", before: 100, after: 70, call: "a", saver: .tokenade),
            entry("t2", "2026-10-07T11:00:00Z", before: 80, after: 50, call: "b", saver: .tokenade),
        ])
        let summary = SavingsSummary.build(details: [rtk, tokenade], range: .week, now: now, calendar: utc)
        let byTool = Dictionary(uniqueKeysWithValues: summary.tools.map { ($0.saver, $0) })
        XCTAssertEqual(byTool[.rtk]?.counted, 60)
        XCTAssertEqual(byTool[.tokenade]?.saved, 60, "its own claim, shown as its own")
        XCTAssertEqual(byTool[.tokenade]?.counted, 30, "call a is rtk's, the larger claim")
        XCTAssertEqual(summary.overlap, 30)
        XCTAssertEqual(summary.saved, 90)
        XCTAssertEqual(summary.before, 180, "call a's before is counted once too")
    }

    func testComparisonsAreNamedButNeverAddedIn() {
        var caveman = SaverDetail.build(saver: .caveman, range: .week, reports: [])
        caveman.comparisons = [SaverComparison(metric: .outputPerReply, with: .init(median: 300, count: 40, sessions: 3),
                                               without: .init(median: 700, count: 90, sessions: 6))]
        let summary = SavingsSummary.build(details: [caveman], range: .week, now: now, calendar: utc)
        XCTAssertTrue(summary.isEmpty)
        XCTAssertEqual(summary.saved, 0)
        XCTAssertEqual(summary.compared, [.caveman])
    }

    func testOnlyClaimsInsideThePeriodCount() {
        let rtk = detail(.rtk, [
            entry("old", "2026-09-20T10:00:00Z", before: 999, after: 1),
            entry("new", "2026-10-07T11:00:00Z", before: 10, after: 5),
        ])
        XCTAssertEqual(SavingsSummary.build(details: [rtk], range: .week, now: now, calendar: utc).saved, 5,
                       "a session still running can hold claims from before the week")
        XCTAssertEqual(SavingsSummary.build(details: [rtk], range: .session, now: now, calendar: utc).saved, 1003,
                       "a session has no period")
    }

    func testADayIsSplitIntoHours() {
        let rtk = detail(.rtk, [
            entry("a", "2026-10-07T09:10:00Z", before: 10, after: 5),
            entry("b", "2026-10-07T09:50:00Z", before: 10, after: 5),
            entry("c", "2026-10-07T11:00:00Z", before: 10, after: 5),
        ])
        let summary = SavingsSummary.build(details: [rtk], range: .day, now: now, calendar: utc)
        XCTAssertTrue(summary.hourly)
        XCTAssertEqual(summary.buckets.map(\.key), ["2026-10-07T09", "2026-10-07T11"])
        XCTAssertEqual(summary.buckets.map(\.label), ["9:00", "11:00"])
        let chart = summary.overallChart(now: now, calendar: utc)
        XCTAssertEqual(chart.firstDay, "2026-10-06T13", "the last 24 hours")
        XCTAssertEqual(chart.lastDay, "2026-10-07T12")
        XCTAssertEqual([chart.beforeLabel, chart.afterLabel], ["Would have sent", "Sent"])
        XCTAssertEqual(summary.periodText, "last 24 hours")
    }

    func testRangeCoveringDays() {
        XCTAssertEqual(SaverRange.covering(days: 1), .day)
        XCTAssertEqual(SaverRange.covering(days: 5), .week)
        XCTAssertEqual(SaverRange.covering(days: 21), .threeWeeks)
        XCTAssertEqual(SaverRange.covering(days: 90), .month)
    }

    func testStoreNamesEachSession() throws {
        let store = try Store.inMemory()
        try store.upsert(call: CallRow(dedupeKey: "a", ts: "2026-10-07T10:00:00.000Z", sessionId: "s1", cwd: "/Users/me/Code/Ullage",
                                       contextTokens: 1, sourceFile: "f"))
        try store.upsert(call: CallRow(dedupeKey: "b", ts: "2026-10-07T10:05:00.000Z", sessionId: "s1", cwd: "/Users/me/Code/Ullage",
                                       contextTokens: 1, sourceFile: "f"))
        try store.upsert(call: CallRow(dedupeKey: "c", ts: "2026-10-07T10:06:00.000Z", agentId: "x", sessionId: "s1",
                                       contextTokens: 1, sourceFile: "f"))
        let meta = try store.sessionMeta(["s1", "missing"])
        XCTAssertEqual(meta["s1"], .init(project: "Ullage", firstTs: "2026-10-07T10:00:00.000Z", turns: 2), "the agent's turn isn't the session's")
        XCTAssertNil(meta["missing"])
    }

    func testPhoneCarriesTheTotalAndEachTool() throws {
        let rtk = detail(.rtk, [entry("r1", "2026-10-07T10:00:00Z", before: 100, after: 40)])
        let summary = SavingsSummary.build(details: [rtk], range: .week, now: now, calendar: utc)
        let data = try XCTUnwrap(ServeDetail.savingsData(summary, now: now))
        XCTAssertEqual(data.total, "≈60 tokens")
        XCTAssertEqual(data.period, "last 7 days")
        XCTAssertEqual(data.tools.map(\.name), ["rtk"])
        XCTAssertEqual(data.tools.first?.share, "100%")
        XCTAssertEqual(data.overall.slot, -1, "the total is drawn in grey")
        XCTAssertNil(ServeDetail.savingsData(SavingsSummary.build(details: [], range: .week, now: now), now: now))
    }
}

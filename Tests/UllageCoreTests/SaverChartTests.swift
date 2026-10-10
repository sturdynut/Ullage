import Foundation
import XCTest
@testable import UllageCore

/// The cards: what a tool took in next to what it passed on, per local day,
/// and without vs with for comparisons.
final class SaverChartTests: XCTestCase {
    private let at = { (s: String) in Timestamps.date(from: s)! }
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func entry(_ ts: String, before: Int?, after: Int?, saved: Int, call: String? = nil, saver: TokenSaver = .rtk) -> LedgerEntry {
        LedgerEntry(saver: saver, ts: at(ts), cwd: "/repo", command: "ls", beforeTokens: before, afterTokens: after,
                    savedTokens: saved, id: UUID().uuidString, toolUseId: call)
    }

    private func detail(_ saver: TokenSaver = .rtk, range: SaverRange = .week, _ configure: (inout SaverDetail) -> Void) -> SaverDetail {
        var detail = SaverDetail.build(saver: saver, range: range, reports: [])
        configure(&detail)
        return detail
    }

    func testOutputIsSummedPerDayWithBeforeNextToAfter() throws {
        let d = detail {
            $0.ledgerEntries = [
                entry("2026-10-04T09:00:00Z", before: 300, after: 100, saved: 200),
                entry("2026-10-04T20:00:00Z", before: 100, after: 100, saved: 0),
                entry("2026-10-06T08:00:00Z", before: 50, after: 10, saved: 40),
                entry("2026-10-06T09:00:00Z", before: nil, after: nil, saved: 7),
            ]
        }
        let charts = SaverChart.charts(for: d, now: at("2026-10-06T12:00:00Z"), calendar: utc)
        let output = try XCTUnwrap(charts.first)
        XCTAssertEqual(output.title, "Bash output")
        XCTAssertEqual(output.kind, .daily)
        XCTAssertEqual(output.bars.map(\.key), ["2026-10-04", "2026-10-06"], "a quiet day has no bar")
        XCTAssertEqual(output.bars.map(\.label), ["Oct 4", "Oct 6"])
        XCTAssertEqual(output.bars.map(\.before), [400, 50])
        XCTAssertEqual(output.bars.map(\.after), [200, 10])
        XCTAssertEqual(output.bars.map(\.count), [2, 1])
        XCTAssertEqual(output.totalText, "≈450 → ≈210")
        XCTAssertEqual(output.changeText, "−53%")
        XCTAssertEqual(output.firstDay, "2026-09-30", "a week's axis runs the whole week")
        XCTAssertEqual(output.lastDay, "2026-10-06")
        XCTAssertTrue(output.more.contains("1 without a before and after is left out."))
        XCTAssertTrue(output.more.contains("Today is so far."))
        XCTAssertEqual(charts.count, 1, "nothing placed, so no later-prompts card")
    }

    func testDaysAreLocal() {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let d = detail { $0.ledgerEntries = [entry("2026-10-04T20:00:00Z", before: 10, after: 5, saved: 5)] }
        XCTAssertEqual(SaverChart.charts(for: d, now: at("2026-10-06T00:00:00Z"), calendar: tokyo).first?.bars.first?.key,
                       "2026-10-05", "8 pm UTC is the next morning in Tokyo")
    }

    func testLaterPromptsMultiplyBothSidesByThePromptsTheResultStayedIn() throws {
        let d = detail(range: .session) {
            $0.ledgerEntries = [
                entry("2026-10-04T09:00:00Z", before: 300, after: 100, saved: 200, call: "a"),
                entry("2026-10-04T10:00:00Z", before: 50, after: 50, saved: 0, call: "b"),
                entry("2026-10-04T11:00:00Z", before: 999, after: 1, saved: 998),
            ]
            $0.prompts = ["a": 10, "b": 2]
        }
        let charts = SaverChart.charts(for: d, now: at("2026-10-05T12:00:00Z"), calendar: utc)
        let prompts = try XCTUnwrap(charts.first { $0.id == "rtk.prompts" })
        XCTAssertEqual(prompts.bars.map(\.before), [300 * 10 + 50 * 2])
        XCTAssertEqual(prompts.bars.map(\.after), [100 * 10 + 50 * 2])
        XCTAssertTrue(prompts.more.contains("1 command Ullage couldn't match to a call is left out."))
        XCTAssertEqual(prompts.firstDay, "2026-10-04", "a session's axis is its own days")
        XCTAssertFalse(prompts.more.contains("Today is so far."), "the last bar is yesterday")
    }

    func testAProxyIsChartedAsRequestsAndNeverCarried() throws {
        let d = detail(.headroom) {
            $0.ledgerEntries = [entry("2026-06-08T10:00:00Z", before: 1000, after: 900, saved: 100, call: "x", saver: .headroom)]
            $0.prompts = ["x": 50]
        }
        let charts = SaverChart.charts(for: d, now: at("2026-06-08T12:00:00Z"), calendar: utc)
        XCTAssertEqual(charts.map(\.title), ["Requests"])
        XCTAssertEqual(charts.first?.countUnit, "requests")
    }

    func testAComparisonIsOnePairWithoutThenWith() throws {
        let d = detail {
            $0.comparisons = [SaverComparison(metric: .firstPrompt, with: .init(median: 55_000, count: 6, sessions: 6),
                                              without: .init(median: 50_000, count: 12, sessions: 12))]
        }
        let chart = try XCTUnwrap(SaverChart.charts(for: d, calendar: utc).first)
        XCTAssertEqual(chart.kind, .comparison)
        XCTAssertEqual(chart.title, "First prompt")
        XCTAssertEqual([chart.beforeLabel, chart.afterLabel], ["Without", "With"])
        XCTAssertEqual(chart.bars.map(\.before), [50_000])
        XCTAssertEqual(chart.bars.map(\.after), [55_000])
        XCTAssertEqual(chart.totalText, "50k without → 55k with", "measured, so no ≈")
        XCTAssertEqual(chart.changeText, "+10%")
        XCTAssertTrue(chart.more.contains("Few sessions, so read it loosely."))
        XCTAssertFalse(chart.more.contains { $0.hasPrefix("Within 5%") })
    }

    func testAToolWithNothingToChartHasNoCards() {
        XCTAssertTrue(SaverChart.charts(for: detail(.caveman) { _ in }).isEmpty)
    }

    func testColourFollowsTheToolsPlaceInTheRegistry() {
        XCTAssertEqual(SaverChart.colorSlot(.rtk), 0)
        XCTAssertEqual(SaverChart.colorSlot(.headroom), TokenSaver.allCases.firstIndex(of: .headroom))
        XCTAssertEqual(SaverChart.lightPalette.count, SaverChart.darkPalette.count)
    }

    func testThePhonePageCarriesTheSamePalette() {
        for hex in SaverChart.lightPalette + SaverChart.darkPalette {
            XCTAssertTrue(WebPage.html.contains("'\(hex)'"), "WebPage draws \(hex) for its slot")
        }
    }

    func testPhoneRowsCarryChartsAndCosts() {
        var usage = SaverUsage(saver: .rtk)
        usage.hookRuns = 3
        let report = SaverSessionReport(sessionId: "s1", cwd: "/repo", bashCalls: 5, usages: [usage, SaverUsage(saver: .headroom)],
                                        doubleHookedCalls: 0)
        let panel = SaverPanel.build(report: report, states: [.rtk: .on, .headroom: .on])
        let rtk = detail { $0.ledgerEntries = [entry("2026-10-04T09:00:00Z", before: 300, after: 100, saved: 200)] }
        let headroom = detail(.headroom) { $0.sessionsIdle = 4 }
        let section = ServeDetail.saversSection(panel, details: [.rtk: rtk, .headroom: headroom], now: at("2026-10-06T12:00:00Z"))
        let rows = Dictionary(uniqueKeysWithValues: (section.savers ?? []).map { ($0.id, $0) })
        XCTAssertEqual(rows["rtk"]?.charts?.map(\.title), ["Bash output"])
        XCTAssertEqual(rows["rtk"]?.charts?.first?.bars.map(\.before), [300])
        XCTAssertEqual(rows["rtk"]?.charts?.first?.slot, 0)
        XCTAssertNil(rows["headroom"]?.charts)
        XCTAssertEqual(rows["headroom"]?.costs?.map(\.label), ["Loaded, never used"])
        XCTAssertEqual(rows["headroom"]?.costs?.first?.warning, true)
    }

    func testRewritesAreOutOfBashCallsItsHookCouldSee() {
        var hooked = SaverUsage(saver: .rtk)
        hooked.hookRuns = 4
        hooked.rewrites = 3
        hooked.bashCallsSeen = 5
        let after = SaverSessionReport(sessionId: "a", cwd: "/r", bashCalls: 5, usages: [hooked], doubleHookedCalls: 0)
        let before = SaverSessionReport(sessionId: "b", cwd: "/r", bashCalls: 900, usages: [], doubleHookedCalls: 0)
        let d = SaverDetail.build(saver: .rtk, range: .month, reports: [before, after])
        XCTAssertEqual(d.rewrites, 3)
        XCTAssertEqual(d.bashCalls, 5, "the 900 calls from before it was installed aren't counted against it")
    }

    /// rtk installed partway into a session: the Bash calls before its first
    /// hook run were never its to rewrite.
    func testBashCallsCountFromTheFirstHookRun() {
        let bash = (0..<6).map { i in
            ToolCallRow(id: "t\(i)", callId: "c", sessionId: "s1", ts: "2026-10-04T10:0\(i):00.000Z", name: "Bash", kind: "bash", target: "ls")
        }
        let run = HookRun(hookEvent: "PreToolUse", command: "rtk hook claude", toolUseId: "t3", exitCode: 0, rewrittenCommand: "rtk ls")
        let event = EventRow(id: "e", sessionId: "s1", ts: "2026-10-04T10:03:00.000Z", kind: EventKind.hook.rawValue, detail: run.detailJSON)
        let report = SaverReport.build(sessionId: "s1", calls: [], toolCalls: bash, events: [event], sessionEnv: nil, ledger: [])
        XCTAssertEqual(report.bashCalls, 6)
        XCTAssertEqual(report.usage(.rtk).bashCallsSeen, 3, "10:03, 10:04, 10:05")
    }

    func testHelpExplainsThePairedBars() {
        let questions = HelpText.savers.entries.map(\.question)
        XCTAssertTrue(questions.contains("What do the paired bars show?"))
        XCTAssertFalse(HelpText.savers.entries.contains { $0.question.contains("badges") }, "no badges are drawn any more")
    }
}

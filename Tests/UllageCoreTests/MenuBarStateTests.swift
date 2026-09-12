import Foundation
import XCTest
@testable import UllageCore

/// M4 — the display rules, without a UI.
final class MenuBarStateTests: XCTestCase {
    private func call(
        context: Int,
        limit: Int? = 200_000,
        minutesAgo: Double,
        model: String? = "claude-sonnet-4-5-20250929",
        now: Date
    ) -> CallRow {
        CallRow(
            dedupeKey: "msg_x",
            ts: Timestamps.string(from: now.addingTimeInterval(-minutesAgo * 60)),
            sessionId: "sess-1",
            project: "proj",
            model: model,
            contextTokens: context,
            windowLimit: limit,
            sourceFile: "x.jsonl"
        )
    }

    func testLivePercentage() {
        let now = Date()
        let state = MenuBarFormatter.state(for: call(context: 144_000, minutesAgo: 1, now: now), now: now)
        XCTAssertEqual(state.status, .live)
        XCTAssertEqual(state.title, "72%")
        XCTAssertFalse(state.isIdle)
        XCTAssertEqual(state.project, "proj")
    }

    func testWarningAboveThreshold() {
        let now = Date()
        let state = MenuBarFormatter.state(for: call(context: 172_000, minutesAgo: 1, now: now), now: now)
        XCTAssertEqual(state.status, .warning)
        XCTAssertEqual(state.title, "86% ⚠︎")
    }

    func testPercentageRoundsDownSoFullNeverArrivesEarly() {
        XCTAssertEqual(MenuBarFormatter.percentage(0.999), "99%")
        XCTAssertEqual(MenuBarFormatter.percentage(0.85), "85%")
        XCTAssertEqual(MenuBarFormatter.percentage(1.04), "104%")
    }

    func testStalePercentageBecomesAnIdleGlyph() {
        let now = Date()
        let fresh = MenuBarFormatter.state(for: call(context: 144_000, minutesAgo: 29, now: now), now: now)
        XCTAssertEqual(fresh.title, "72%")

        let stale = MenuBarFormatter.state(for: call(context: 144_000, minutesAgo: 31, now: now), now: now)
        XCTAssertEqual(stale.status, .idle)
        XCTAssertEqual(stale.title, MenuBarFormatter.idleGlyph)
        XCTAssertTrue(stale.isIdle)
        // The detail is still there for the menu; only the headline goes quiet.
        XCTAssertEqual(stale.contextTokens, 144_000)
    }

    func testEmptyDatabase() {
        let state = MenuBarFormatter.state(for: nil)
        XCTAssertEqual(state.status, .empty)
        XCTAssertEqual(state.title, MenuBarFormatter.idleGlyph)
        XCTAssertNil(state.contextTokens)
    }

    func testUnknownModelIsFlaggedAsAssumed() {
        let now = Date()
        let state = MenuBarFormatter.state(
            for: call(context: 100_000, minutesAgo: 1, model: "claude-something-new", now: now),
            now: now
        )
        XCTAssertTrue(state.modelWindowIsAssumed)
        XCTAssertEqual(state.title, "50%")
    }

    func testMissingWindowLimitShowsNoNumber() {
        let now = Date()
        let state = MenuBarFormatter.state(
            for: call(context: 100_000, limit: nil, minutesAgo: 1, now: now),
            now: now
        )
        XCTAssertEqual(state.title, MenuBarFormatter.idleGlyph)
        XCTAssertNil(state.occupancy)
    }

    func testStateTracksTheMostRecentlyActiveSession() throws {
        // Plan §12: with several sessions running, default to most-recently-active.
        let workspace = try TempWorkspace()
        try workspace.ingestor.ingestFile(at: try workspace.copyFixture("basic-session.jsonl"))
        try workspace.ingestor.ingestFile(at: try workspace.copyFixture("orphan-tool-result.jsonl"))

        let latest = try XCTUnwrap(try workspace.store.latestCall())
        XCTAssertEqual(latest.dedupeKey, "msg_201")   // the later timestamp wins
        let state = MenuBarFormatter.state(for: latest, now: Date())
        XCTAssertEqual(state.sessionId, "sess-abc123")
    }
}

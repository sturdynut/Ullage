import Foundation
import XCTest
@testable import UllageCore

/// M5 — the session picker and the chart's data, without a UI.
final class SessionHistoryTests: XCTestCase {
    private func call(
        _ session: String, turn: Int, at ts: String, context: Int, delta: Int? = nil,
        limit: Int? = 1_000_000, project: String = "proj"
    ) -> CallRow {
        CallRow(
            dedupeKey: "msg_\(session)_\(turn)",
            ts: ts,
            sessionId: session,
            project: project,
            cwd: "/work/\(project)",
            model: "claude-opus-5",
            contextTokens: context,
            windowLimit: limit,
            turnIndex: turn,
            contextDelta: delta,
            sourceFile: "\(session).jsonl"
        )
    }

    private func seeded() throws -> Store {
        let store = try Store.inMemory()
        try store.upsert(call: call("a", turn: 0, at: "2026-09-12T10:00:00.000Z", context: 50_000))
        try store.upsert(call: call("a", turn: 1, at: "2026-09-12T10:01:00.000Z", context: 800_000, delta: 750_000))
        // Compaction fires between turn 1 and turn 2 of session a.
        _ = try store.insert(event: EventRow(
            id: "evt-1", sessionId: "a", ts: "2026-09-12T10:01:30.000Z", kind: EventKind.compaction.rawValue
        ))
        try store.upsert(call: call("a", turn: 2, at: "2026-09-12T10:02:00.000Z", context: 120_000, delta: nil))
        try store.upsert(call: call("b", turn: 0, at: "2026-09-12T10:03:00.000Z", context: 30_000, project: "other"))
        return store
    }

    func testRecentSessionsAreNewestFirstAndCarryTheLastTurn() throws {
        let store = try seeded()
        let sessions = try store.recentSessions(limit: 10)
        XCTAssertEqual(sessions.map(\.sessionId), ["b", "a"])
        let a = sessions[1]
        XCTAssertEqual(a.lastContextTokens, 120_000)   // the last turn, not the peak
        XCTAssertEqual(a.calls, 3)
        XCTAssertEqual(a.project, "proj")
        XCTAssertEqual(a.cwd, "/work/proj")
        XCTAssertEqual(a.occupancy.map { Int($0 * 100) }, 12)
        XCTAssertEqual(try store.recentSessions(limit: 1).map(\.sessionId), ["b"])
    }

    func testLatestCallInSessionIgnoresOtherSessions() throws {
        let store = try seeded()
        XCTAssertEqual(try store.latestCall()?.sessionId, "b")
        XCTAssertEqual(try store.latestCall(sessionId: "a")?.turnIndex, 2)
        XCTAssertNil(try store.latestCall(sessionId: "nope"))
    }

    func testContextHistoryMapsCompactionOntoTheNextTurn() throws {
        let store = try seeded()
        let history = try store.contextHistory(sessionId: "a")
        XCTAssertEqual(history.points.map(\.turnIndex), [0, 1, 2])
        XCTAssertEqual(history.points.map(\.contextTokens), [50_000, 800_000, 120_000])
        XCTAssertEqual(history.compactionTurns, [2])
        XCTAssertEqual(history.windowLimit, 1_000_000)
        XCTAssertEqual(history.peakContextTokens, 800_000)
        XCTAssertNil(history.points[2].contextDelta, "delta across a compaction is noise and stays nil")
    }

    func testCompactionAfterTheLastTurnHasNoMarkerYet() {
        let calls = [call("a", turn: 0, at: "2026-09-12T10:00:00.000Z", context: 1)]
        let events = [EventRow(id: "e", sessionId: "a", ts: "2026-09-12T10:05:00.000Z", kind: "compaction")]
        let history = ContextHistory.build(sessionId: "a", calls: calls, events: events)
        XCTAssertEqual(history.compactionTurns, [])
    }

    func testPinnedSelectionFallsBackWhenTheSessionHasNoRows() throws {
        let store = try seeded()
        let latest = try store.latestCall()
        let pinned = try SessionSelection.resolve(.pinned("a"), latestOverall: latest) { try store.latestCall(sessionId: $0) }
        XCTAssertEqual(pinned?.sessionId, "a")
        let gone = try SessionSelection.resolve(.pinned("nope"), latestOverall: latest) { try store.latestCall(sessionId: $0) }
        XCTAssertEqual(gone?.sessionId, "b")
        let auto = try SessionSelection.resolve(.automatic, latestOverall: latest) { _ in XCTFail("not consulted"); return nil }
        XCTAssertEqual(auto?.sessionId, "b")
    }
}

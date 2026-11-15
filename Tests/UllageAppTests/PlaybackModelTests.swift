import XCTest
import UllageCore
@testable import UllageApp

@MainActor
final class PlaybackModelTests: XCTestCase {
    func testLiveFollowsAppendWhileInspectionHoldsStableID() {
        var selection = PlaybackSelection()
        selection.update(sessionId: "one", eventIds: ["a", "b"])
        XCTAssertEqual(selection.eventId, "b")
        selection.inspect("a")
        selection.update(sessionId: "one", eventIds: ["a", "b", "c"])
        XCTAssertEqual(selection.eventId, "a")
        XCTAssertFalse(selection.followsLive)
        selection.follow(eventIds: ["a", "b", "c"])
        XCTAssertEqual(selection.eventId, "c")
        XCTAssertTrue(selection.followsLive)
    }

    func testSessionSwitchClearsHistoricalSelection() {
        var selection = PlaybackSelection()
        selection.update(sessionId: "one", eventIds: ["a", "b"])
        selection.inspect("a")
        selection.update(sessionId: "two", eventIds: ["x", "y"])
        XCTAssertEqual(selection.sessionId, "two")
        XCTAssertEqual(selection.eventId, "y")
        XCTAssertTrue(selection.followsLive)
    }

    func testRemovedHistoricalEventDoesNotSelectAnotherEvent() {
        var selection = PlaybackSelection()
        selection.update(sessionId: "one", eventIds: ["a", "b"])
        selection.inspect("a")
        selection.update(sessionId: "one", eventIds: ["b", "c"])
        XCTAssertEqual(selection.eventId, "a")
        XCTAssertFalse(selection.followsLive)
    }

    func testSessionChangesClearContentsBeforeReadCompletes() async {
        let model = PlaybackModel()
        model.activate(sessionId: "old")
        await model.refresh { SessionPlayback(notices: ["old content"]) }
        XCTAssertEqual(model.playback.notices, ["old content"])
        model.activate(sessionId: "new")
        XCTAssertTrue(model.playback.notices.isEmpty)
        XCTAssertNil(model.snapshot)
        XCTAssertTrue(model.isLoading)
    }

    func testLateReadCannotReplaceNewSession() async {
        let model = PlaybackModel()
        model.activate(sessionId: "old")
        let oldRead = Task {
            await model.refresh {
                try? await Task.sleep(for: .milliseconds(80))
                return SessionPlayback(notices: ["old content"])
            }
        }
        await Task.yield()
        model.activate(sessionId: "new")
        await model.refresh { SessionPlayback(notices: ["new content"]) }
        await oldRead.value
        XCTAssertEqual(model.playback.notices, ["new content"])
    }

    func testLiveAdvanceClearsOldRequestBeforeNewEventAppears() async {
        let model = PlaybackModel()
        model.activate(sessionId: "one")
        let first = PlaybackEvent(id: "a", kind: .request, title: "First")
        let second = PlaybackEvent(id: "b", kind: .request, title: "Second")
        await model.refresh { SessionPlayback(events: [first]) }
        await model.loadSnapshot { PlaybackRequestSnapshot(sourcePath: "a.json", body: "old secret") }
        XCTAssertNotNil(model.snapshot)
        await model.refresh { SessionPlayback(events: [first, second]) }
        XCTAssertEqual(model.selectedEvent?.id, "b")
        XCTAssertNil(model.snapshot, "A new request must never render a previous request's body")
    }

    func testPinnedRequestRefreshReplacesDeletedSourceAndInvalidatesLateBody() async {
        let model = PlaybackModel()
        model.activate(sessionId: "one")
        let event = PlaybackEvent(id: "a", kind: .request, title: "Request")
        await model.refresh { SessionPlayback(events: [event]) }
        model.inspect("a")
        await model.loadSnapshot { PlaybackRequestSnapshot(sourcePath: "a.json", body: "before deletion") }
        let revision = model.revision
        await model.refresh { SessionPlayback(events: [event]) }
        XCTAssertGreaterThan(model.revision, revision, "Unchanged selected IDs still need source revalidation")
        await model.loadSnapshot { PlaybackRequestSnapshot(sourcePath: "a.json", notice: "Deleted") }
        XCTAssertNil(model.snapshot?.body)
        XCTAssertEqual(model.snapshot?.notice, "Deleted")
        let lateBody = Task {
            await model.loadSnapshot {
                try? await Task.sleep(for: .milliseconds(50))
                return PlaybackRequestSnapshot(sourcePath: "a.json", body: "stale")
            }
        }
        await Task.yield()
        model.activate(sessionId: "two")
        await lateBody.value
        XCTAssertNil(model.snapshot)
    }

    func testAgentFilterFollowsOnlyItsOwnStream() async {
        let model = PlaybackModel()
        model.activate(sessionId: "one")
        let main = PlaybackEvent(id: "main", kind: .message, title: "Main")
        let agent = PlaybackEvent(id: "agent", agentId: "child", kind: .message, title: "Agent")
        await model.refresh { SessionPlayback(events: [main, agent]) }
        model.selectStream("main")
        XCTAssertEqual(model.visibleEvents.map(\.id), ["main"])
        XCTAssertEqual(model.selectedEvent?.id, "main")
        let next = PlaybackEvent(id: "next", agentId: "child", kind: .toolCall, title: "Read")
        await model.refresh { SessionPlayback(events: [main, agent, next]) }
        XCTAssertEqual(model.selectedEvent?.id, "main")
        model.selectStream("child")
        XCTAssertEqual(model.visibleEvents.map(\.id), ["agent", "next"])
        XCTAssertEqual(model.selectedEvent?.id, "next")
    }

    func testRefreshingSameRequestKeepsVisibleBodyUntilRevalidated() async {
        let model = PlaybackModel()
        model.activate(sessionId: "one")
        let event = PlaybackEvent(id: "a", kind: .request, title: "Request")
        await model.refresh { SessionPlayback(events: [event]) }
        await model.loadSnapshot { PlaybackRequestSnapshot(sourcePath: "a.json", body: "original") }
        await model.refresh { SessionPlayback(events: [event]) }
        XCTAssertEqual(model.snapshot?.body, "original")
        await model.loadSnapshot {
            XCTAssertEqual(model.snapshot?.body, "original", "Periodic validation must not disrupt reading")
            XCTAssertFalse(model.isLoadingSnapshot)
            return PlaybackRequestSnapshot(sourcePath: "a.json", body: "updated")
        }
        XCTAssertEqual(model.snapshot?.body, "updated")
    }

    func testChangedRequestReferenceClearsBodyEvenWithStableStepID() async {
        let model = PlaybackModel()
        model.activate(sessionId: "one")
        var event = PlaybackEvent(id: "a", kind: .request, title: "Request",
                                  snapshot: PlaybackRequestSnapshot(sourcePath: "old/a.json"))
        await model.refresh { SessionPlayback(events: [event]) }
        await model.loadSnapshot { PlaybackRequestSnapshot(sourcePath: "old/a.json", body: "old") }
        event.snapshot = PlaybackRequestSnapshot(sourcePath: "new/a.json")
        await model.refresh { SessionPlayback(events: [event]) }
        XCTAssertNil(model.snapshot)
        XCTAssertEqual(model.selectedEvent?.snapshot?.sourcePath, "new/a.json")
    }
}

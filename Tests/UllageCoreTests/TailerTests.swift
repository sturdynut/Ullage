import Foundation
import XCTest
@testable import UllageCore

/// M3 — appending to a watched file produces new rows without re-reading it.
final class TailerTests: XCTestCase {
    func testAppendedLinesBecomeRowsWithoutRereadingTheFile() throws {
        let workspace = try TempWorkspace()
        let lines = try Fixtures.lines("basic-session.jsonl")
        let projectDirectory = workspace.root.appendingPathComponent("-Users-dev-proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let transcript = projectDirectory.appendingPathComponent("sess-abc123.jsonl")
        try (lines.prefix(3).joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)

        let tailer = SessionTailer(
            ingestor: workspace.ingestor,
            watcher: PollingWatcher(interval: 0.05),
            debounce: 0.05
        )
        let batch = expectation(description: "appended lines ingested")
        var observed: [IngestStats] = []
        tailer.onIngest = { stats in
            observed.append(stats)
            if stats.callsUpserted > 0 && observed.count > 1 { batch.fulfill() }
        }

        try tailer.start(roots: [workspace.root])
        defer { tailer.stop() }
        XCTAssertEqual(try workspace.store.callCount(), 1)   // the initial sweep

        // Claude Code finishes a turn.
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines[5] + "\n").utf8))
        try handle.close()

        wait(for: [batch], timeout: 5.0)
        XCTAssertEqual(try workspace.store.callCount(), 2)
        let appended = try XCTUnwrap(observed.last)
        // Only the appended line was read back, not the whole file.
        XCTAssertEqual(appended.linesParsed, 1)
        XCTAssertEqual(appended.restartedFromZero, 0)
    }

    func testBurstOfWritesCoalescesIntoOneIngest() throws {
        let workspace = try TempWorkspace()
        let lines = try Fixtures.lines("basic-session.jsonl")
        let transcript = workspace.root.appendingPathComponent("sess-abc123.jsonl")
        try "".write(to: transcript, atomically: true, encoding: .utf8)

        let watcher = PollingWatcher(interval: 0.05)
        let tailer = SessionTailer(ingestor: workspace.ingestor, watcher: watcher, debounce: 0.3)
        let done = expectation(description: "ingested")
        var batches = 0
        tailer.onIngest = { stats in
            if stats.callsUpserted > 0 {
                batches += 1
                done.fulfill()
            }
        }
        try tailer.start(roots: [workspace.root])
        defer { tailer.stop() }

        let handle = try FileHandle(forWritingTo: transcript)
        for line in lines {
            try handle.write(contentsOf: Data((line + "\n").utf8))
            Thread.sleep(forTimeInterval: 0.02)
        }
        try handle.close()

        wait(for: [done], timeout: 5.0)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(batches, 1, "a burst of writes should debounce into a single ingest")
        XCTAssertEqual(try workspace.store.callCount(), 4)
    }

    func testWatcherStartRequiresAPath() {
        let watcher = PollingWatcher(interval: 0.05)
        XCTAssertThrowsError(try watcher.start(paths: []) { _ in })
    }

    func testSweepNowIngestsWithoutWaitingForATick() throws {
        let workspace = try TempWorkspace()
        let tailer = SessionTailer(
            ingestor: workspace.ingestor,
            watcher: PollingWatcher(interval: 60),
            debounce: 0.05
        )
        try tailer.start(roots: [workspace.root])
        defer { tailer.stop() }

        _ = try workspace.copyFixture("basic-session.jsonl")
        let stats = tailer.sweepNow()
        XCTAssertEqual(stats.callsUpserted, 5)
        XCTAssertEqual(try workspace.store.callCount(), 4)
    }
}

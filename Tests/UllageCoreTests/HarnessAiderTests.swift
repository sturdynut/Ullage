import Foundation
import XCTest
@testable import UllageCore

/// Aider's `.aider.chat.history.md`, synthesized in the shape `aider/io.py`
/// and `aider/coders/base_coder.py` write. No real prompt text.
final class HarnessAiderTests: XCTestCase {
    static let history = """

    # aider chat started at 2026-10-04 09:15:02

    > Aider v0.86.1
    > Main model: anthropic/claude-sonnet-4-5 with diff edit format, prompt cache, infinite output
    > Weak model: anthropic/claude-haiku-4-5
    > Git repo: .git with 12 files

    #### first question

    an answer

    > Tokens: 12k sent, 1.5k cache write, 8.2k cache hit, 1.2k received.
    Cost: $0.02 message, $0.02 session.

    #### /clear

    > Tokens: 834 sent, 95 received. Cost: $0.0040 message, $0.02 session.
    > Tokens: garbage sent, received.

    # aider chat started at not-a-date

    > Tokens: 5k sent, 1k received.

    # aider chat started at 2026-10-04 11:00:00

    > Model: gpt-5 with whole edit format
    > Tokens: 2.3k sent, 445 received.
    """

    private func lines() -> [ParsedLine] {
        AiderReader.parse(Self.history, path: "/Users/me/Code/app/.aider.chat.history.md")
    }

    private func calls() -> [CallRow] {
        lines().compactMap { if case .call(let c) = $0 { return c.call } else { return nil } }
    }

    func testTokensLineMapsToFourCountersAsEstimates() throws {
        let rows = calls()
        XCTAssertEqual(rows.count, 3)   // garbage line and the undated session are skipped
        let first = rows[0]
        XCTAssertEqual(first.cacheWrite, 1500)
        XCTAssertEqual(first.cacheRead, 8200)
        XCTAssertEqual(first.input, 12000 - 8200 - 1500)
        XCTAssertEqual(first.contextTokens, 12000)
        XCTAssertEqual(first.output, 1200)
        XCTAssertEqual(first.model, "anthropic/claude-sonnet-4-5")
        XCTAssertEqual(first.confidence, Confidence.estimated.rawValue)
        XCTAssertNil(first.windowLimit)
        XCTAssertNil(first.occupancy)
        XCTAssertEqual(first.cwd, "/Users/me/Code/app")
        XCTAssertEqual(first.project, "app")

        XCTAssertEqual(rows[1].input, 834)
        XCTAssertEqual(rows[1].output, 95)
        XCTAssertEqual(rows[1].sessionId, first.sessionId)

        XCTAssertNotEqual(rows[2].sessionId, first.sessionId)
        XCTAssertEqual(rows[2].model, "gpt-5")
    }

    func testClearIsAnEvent() {
        let events = lines().compactMap { if case .event(let e) = $0 { return e } else { return nil } }
        XCTAssertEqual(events.map(\.kind), [EventKind.clear.rawValue])
    }

    func testStableKeysAcrossReads() {
        XCTAssertEqual(calls().map(\.dedupeKey), calls().map(\.dedupeKey))
        XCTAssertEqual(Set(calls().map(\.dedupeKey)).count, 3)
    }

    func testFormatTokens() {
        XCTAssertEqual(AiderReader.tokens("834"), 834)
        XCTAssertEqual(AiderReader.tokens("1.2k"), 1200)
        XCTAssertEqual(AiderReader.tokens("12k"), 12000)
        XCTAssertNil(AiderReader.tokens("k"))
        XCTAssertNil(AiderReader.tokens("-3"))
    }

    func testIngestAppendIsIdempotent() throws {
        let workspace = try TempWorkspace()
        let dir = workspace.root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(".aider.chat.history.md")
        try Self.history.write(to: url, atomically: true, encoding: .utf8)
        try workspace.ingestor.ingestFile(at: url)
        XCTAssertEqual(try workspace.store.callCount(), 3)
        try workspace.append("repo/.aider.chat.history.md", text: "\n> Tokens: 3k sent, 200 received.  \n")
        try workspace.ingestor.ingestFile(at: url)
        XCTAssertEqual(try workspace.store.callCount(), 4)
    }

    func testOwnsAndRoots() {
        XCTAssertEqual(Harness.owning("/Users/me/Code/app/.aider.chat.history.md")?.id, "aider")
        XCTAssertNil(Harness.owning("/Users/me/Code/app/.aider.input.history"))
        XCTAssertNil(Harness.owning("/Users/me/Code/app/README.md"))
        XCTAssertEqual(
            AiderPaths.historyFiles(environment: ["ULLAGE_AIDER_REPOS": "/a:/b/custom.md:"]).map(\.path),
            ["/a/.aider.chat.history.md", "/b/custom.md"]
        )
        XCTAssertTrue(AiderPaths.historyFiles(environment: [:]).isEmpty)
        XCTAssertFalse(Harness.aider.capabilities.hasGauge)
    }
}

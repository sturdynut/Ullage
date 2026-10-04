import Foundation
import XCTest
@testable import UllageCore

/// Every harness says what it can't record, built from its capabilities.
final class HarnessSupportTests: XCTestCase {
    func testClaudeCodeHasNoGaps() {
        let support = HarnessSupport(harness: .claudeCode)
        XCTAssertNil(support.gaugeNotice)
        XCTAssertTrue(support.gaps.isEmpty)
        XCTAssertNil(support.unverifiedNote)
    }

    func testCursorIsActivityOnlyAndSaysWhy() {
        let support = HarnessSupport(harness: .cursor)
        XCTAssertEqual(support.gaugeNotice, "Cursor doesn't record token counts on your Mac. Showing activity only.")
        XCTAssertEqual(support.gap(.model), "Cursor doesn't record which model ran")
        XCTAssertNotNil(support.gap(.contextTools))
    }

    func testPartialOccupancyIsAvailableWithACaveat() {
        let harness = Harness(
            id: "x", name: "X", capabilities: .init(occupancy: .perRequest, window: .lookup, cacheSplit: true),
            roots: { _ in [] }, owns: { _ in false }, reading: .lines(tail: true, parser: { CursorParser() }))
        let support = HarnessSupport(harness: harness)
        XCTAssertNil(support.gaugeNotice)
        let row = support.rows.first { $0.feature == .everyCall }
        XCTAssertEqual(row?.available, false)
        XCTAssertTrue(row?.detail?.contains("One reading per request") ?? false)
        XCTAssertNotNil(support.unverifiedNote)
    }

    func testFiguresSayActivityOnlyInsteadOfZeroTokens() {
        let call = CallRow(dedupeKey: "c", ts: Timestamps.string(from: Date()), vendor: Vendor.cursor, sessionId: "s",
                           contextTokens: 0, sourceFile: "f", confidence: Confidence.unmeasured.rawValue)
        let figures = StreamFigures(state: MenuBarFormatter.state(for: call))
        XCTAssertEqual(figures.exactLine, "activity only")
        XCTAssertNotNil(figures.gaugeNotice)
        XCTAssertEqual(figures.headroom, "—")
    }

    func testOwningRoutesAndFallsBackToClaude() {
        XCTAssertEqual(Harness.owning("/Users/me/.codex/sessions/2026/10/04/rollout-x.jsonl"), .codex)
        XCTAssertEqual(Harness.owning("/tmp/anything.jsonl"), .claudeCode)
        XCTAssertNil(Harness.owning("/tmp/notes.md"))
        if let root = Harness.otherRoots.first {
            XCTAssertNotEqual(Harness.owning(root + "repos/x/notes.jsonl"), .claudeCode,
                              "a .jsonl in another harness's folder is not a Claude session")
        }
        XCTAssertEqual(Harness.databasePath("/a/opencode.db-wal"), "/a/opencode.db")
    }

    func testEveryHarnessHasAUniqueIdAndName() {
        XCTAssertEqual(Set(Harness.all.map(\.id)).count, Harness.all.count)
        XCTAssertEqual(Harness.all.last, .claudeCode, "Claude is the fallback, tried last")
    }
}

final class ModelWindowTests: XCTestCase {
    func testNonClaudeModelsAreExactOrDatedNeverPrefix() {
        XCTAssertEqual(WindowLimits.knownLimit(for: "gpt-5"), 272_000, "prompt capacity, not the 400k context")
        XCTAssertEqual(WindowLimits.knownLimit(for: "openai/gpt-5.4"), 922_000)
        XCTAssertEqual(WindowLimits.knownLimit(for: "gemini-2.5-pro"), 1_048_576)
        XCTAssertEqual(WindowLimits.knownLimit(for: "gpt-4o-2024-08-06"), WindowLimits.knownLimit(for: "gpt-4o"))
        XCTAssertNil(WindowLimits.knownLimit(for: "gpt-5.99-future"), "an unknown model never borrows gpt-5's window")
        XCTAssertNil(WindowLimits.knownLimit(for: "some-local-model"))
    }

    func testDottedClaudeIdsResolve() {
        XCTAssertEqual(WindowLimits.knownLimit(for: "anthropic/claude-sonnet-4.5"), 200_000)
        XCTAssertEqual(WindowLimits.limit(for: "claude-opus-5-5"), 1_000_000)
    }
}

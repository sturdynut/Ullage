import Foundation
import XCTest
@testable import UllageCore

/// The treemap that replaced the flat composition bar: ordered, so it holds
/// still in a popover that redraws every turn.
final class CompositionTreemapTests: XCTestCase {
    private func composition(
        baseline: Int = 48_000,
        tools: [(String, Int, Int)] = [("Read", 38, 21_000), ("Bash", 61, 12_000), ("Grep", 44, 6_000)],
        output: Int = 81_000,
        other: Int = 39_000,
        claudeMdBytes: Int? = nil,
        windowStartTurn: Int = 0
    ) -> ContextComposition {
        let shares = tools.map {
            ContextComposition.ToolShare(name: $0.0, kind: "builtin", server: nil, calls: $0.1, resultTokens: $0.2)
        }
        let toolResults = shares.reduce(0) { $0 + $1.resultTokens }
        let environment = claudeMdBytes.map {
            SessionEnvRow(sessionId: "s", capturedAt: "2026-09-27T00:00:00.000Z", claudeMdBytes: $0)
        }
        return ContextComposition(
            sessionId: "s",
            windowLimit: 1_000_000,
            contextTokens: baseline + toolResults + output + other,
            lastTurn: 125,
            windowStartTurn: windowStartTurn,
            compactions: 0,
            baseline: baseline,
            toolResults: toolResults,
            assistantOutput: output,
            other: other,
            estimatesOvershoot: false,
            tools: shares,
            environment: environment
        )
    }

    private func segmentRects(_ map: CompositionTreemap) -> [(String, CompositionTreemap.Rect)] {
        // A split segment's extent is the union of its header and parts.
        var order: [String] = []
        var extents: [String: CompositionTreemap.Rect] = [:]
        for tile in map.tiles {
            if let r = extents[tile.segment] {
                let minX = min(r.x, tile.rect.x), minY = min(r.y, tile.rect.y)
                extents[tile.segment] = .init(
                    x: minX, y: minY,
                    width: max(r.maxX, tile.rect.maxX) - minX,
                    height: max(r.maxY, tile.rect.maxY) - minY
                )
            } else {
                order.append(tile.segment)
                extents[tile.segment] = tile.rect
            }
        }
        return order.map { ($0, extents[$0]!) }
    }

    func testSegmentsKeepTheirFixedOrderWhateverTheirSize() {
        // Output is the largest and Baseline the smallest; order must not care.
        let map = CompositionTreemap.layout(
            composition(baseline: 5_000, output: 300_000, other: 20_000), width: 332, height: 88
        )
        let segments = segmentRects(map)
        XCTAssertEqual(segments.map(\.0), ["Baseline", "Tool results", "Output", "Other"])
        let xs = segments.map(\.1.x)
        XCTAssertEqual(xs, xs.sorted(), "segments run left to right in the fixed order")
    }

    func testSegmentWidthsAreProportionalToTokens() {
        let c = composition(tools: [])
        let map = CompositionTreemap.layout(c, width: 332, height: 88)
        let available = 332 - CompositionTreemap.segmentGap * 2   // three live segments
        for (name, rect) in segmentRects(map) {
            let tokens = c.segments.first { $0.name == name }!.tokens
            XCTAssertEqual(rect.width, available * Double(tokens) / Double(c.contextTokens), accuracy: 0.01, name)
            XCTAssertEqual(rect.height, 88, accuracy: 0.001)
        }
    }

    func testEveryTileStaysInsideTheBoundsAndNoTwoOverlap() {
        let map = CompositionTreemap.layout(
            composition(
                tools: [("Read", 1, 9_000), ("Bash", 1, 7_000), ("Grep", 1, 3_000), ("Glob", 1, 900),
                        ("Edit", 1, 400), ("WebFetch", 1, 200), ("mcp__github__pull_request_read", 1, 150)],
                claudeMdBytes: 14_560
            ),
            width: 332, height: 88
        )
        for tile in map.tiles {
            XCTAssertGreaterThanOrEqual(tile.rect.x, -0.001, tile.id)
            XCTAssertGreaterThanOrEqual(tile.rect.y, -0.001, tile.id)
            XCTAssertLessThanOrEqual(tile.rect.maxX, 332.001, tile.id)
            XCTAssertLessThanOrEqual(tile.rect.maxY, 88.001, tile.id)
        }
        for (i, a) in map.tiles.enumerated() {
            for b in map.tiles[(i + 1)...] {
                let overlapX = min(a.rect.maxX, b.rect.maxX) - max(a.rect.x, b.rect.x)
                let overlapY = min(a.rect.maxY, b.rect.maxY) - max(a.rect.y, b.rect.y)
                XCTAssertFalse(overlapX > 0.001 && overlapY > 0.001, "\(a.id) overlaps \(b.id)")
            }
        }
    }

    func testToolsBeyondFiveFoldIntoOneTile() {
        let tools: [(String, Int, Int)] = [
            ("Read", 38, 21_400), ("Bash", 61, 11_900), ("Grep", 44, 6_100), ("Task", 3, 4_200),
            ("Glob", 19, 1_800), ("Edit", 27, 900), ("WebFetch", 2, 700), ("Skill", 1, 30),
        ]
        let c = composition(tools: tools)
        // Tall enough that no part is thin: this isolates the five-tile cap.
        let map = CompositionTreemap.layout(c, width: 332, height: 600)
        let parts = map.tiles.filter { $0.segment == "Tool results" && $0.role == .part }
        XCTAssertEqual(parts.map(\.name), ["Read", "Bash", "Grep", "Task", "Glob", "3 more"])
        let more = parts.last!
        XCTAssertEqual(more.tokens, 900 + 700 + 30)
        XCTAssertEqual(more.calls, 27 + 2 + 1)
        XCTAssertEqual(more.fullName, "Edit, WebFetch, Skill")
        XCTAssertEqual(parts.reduce(0) { $0 + $1.tokens }, c.toolResults, "the parts account for the whole segment")
        XCTAssertTrue(parts.allSatisfy(\.isEstimate))
    }

    func testASplitSegmentKeepsItsNameInAHeaderWhenThereIsRoom() {
        let tall = CompositionTreemap.layout(composition(), width: 332, height: 88)
        let header = tall.tiles.first { $0.role == .header }
        XCTAssertEqual(header?.segment, "Tool results")
        XCTAssertEqual(header?.tokens, 39_000)

        // Too short for a band: the parts take the whole column.
        let short = CompositionTreemap.layout(composition(), width: 332, height: 30)
        XCTAssertNil(short.tiles.first { $0.role == .header })
        XCTAssertEqual(short.tiles.filter { $0.segment == "Tool results" }.count, 3)
    }

    func testTheBaselineSplitsOnlyAroundAClaudeMdEstimateSmallerThanItself() {
        // 14,560 bytes ≈ 3,640 tokens, carved out of a 48,000 baseline — at
        // the History window's height, where the CLAUDE.md part is ~11pt.
        let split = CompositionTreemap.layout(composition(claudeMdBytes: 14_560), width: 620, height: 160)
        let parts = split.tiles.filter { $0.segment == "Baseline" && $0.role == .part }
        XCTAssertEqual(parts.map(\.name), ["System + prompt", "CLAUDE.md"])
        XCTAssertEqual(parts.map(\.tokens), [48_000 - 3_640, 3_640])
        XCTAssertTrue(parts.allSatisfy(\.isEstimate), "a part carved with an estimate is an estimate")

        let afterCompaction = CompositionTreemap.layout(
            composition(claudeMdBytes: 14_560, windowStartTurn: 58), width: 620, height: 160
        )
        XCTAssertTrue(afterCompaction.tiles.contains { $0.name == "System + summary" })

        // No snapshot, or an estimate as big as the baseline: drawn whole.
        for c in [composition(), composition(claudeMdBytes: 48_000 * 4)] {
            let whole = CompositionTreemap.layout(c, width: 332, height: 88)
            let baseline = whole.tiles.filter { $0.segment == "Baseline" }
            XCTAssertEqual(baseline.map(\.role), [.segment])
            XCTAssertFalse(baseline[0].isEstimate, "the baseline is a measured prompt size")
        }
    }

    func testASliverStillGetsTheMinimumWidthAndTheTotalIsUnchanged() {
        let c = composition(baseline: 400_000, tools: [("Read", 1, 300)], output: 500_000, other: 100_000)
        let map = CompositionTreemap.layout(c, width: 332, height: 88)
        let segments = segmentRects(map)
        let tools = segments.first { $0.0 == "Tool results" }!.1
        XCTAssertEqual(tools.width, CompositionTreemap.minimumSegmentWidth, accuracy: 0.001)
        let used = segments.reduce(0) { $0 + $1.1.width } + CompositionTreemap.segmentGap * Double(segments.count - 1)
        XCTAssertEqual(used, 332, accuracy: 0.01)
    }

    func testAToolKeepsItsShadeWhenItChangesRank() {
        let before = CompositionTreemap.layout(
            composition(tools: [("Read", 1, 9_000), ("Bash", 1, 4_000)]), width: 620, height: 160
        )
        let after = CompositionTreemap.layout(
            composition(tools: [("Bash", 1, 20_000), ("Read", 1, 9_000)]), width: 620, height: 160
        )
        func shade(_ map: CompositionTreemap, _ tool: String) -> Int? {
            map.tiles.first { $0.id == "Tool results/" + tool }?.shade
        }
        XCTAssertNotNil(shade(before, "Read"), "the column must actually be split for this to test anything")
        XCTAssertEqual(shade(before, "Read"), shade(after, "Read"))
        XCTAssertEqual(shade(before, "Bash"), shade(after, "Bash"))
    }

    func testMcpToolNamesAreShortenedButKeptWholeForTheTooltip() {
        XCTAssertEqual(CompositionTreemap.shortToolName("mcp__github__pull_request_read"), "github · pull request read")
        XCTAssertEqual(CompositionTreemap.shortToolName("Read"), "Read")
        let map = CompositionTreemap.layout(
            composition(tools: [("mcp__github__pull_request_read", 2, 9_000), ("Bash", 1, 4_000)]),
            width: 620, height: 160
        )
        let tile = map.tiles.first { $0.id == "Tool results/mcp__github__pull_request_read" }
        XCTAssertEqual(tile?.name, "github · pull request read")
        XCTAssertEqual(tile?.fullName, "mcp__github__pull_request_read")
    }

    func testLabelsAreDroppedRatherThanTruncated() {
        let metrics = CompositionTreemap.Metrics()
        let roomy = CompositionTreemap.Rect(x: 0, y: 0, width: 120, height: 60)
        XCTAssertEqual(
            CompositionTreemap.label(name: "Output", values: ["81k  37%", "81k"], rect: roomy, metrics: metrics),
            .nameAndValue("Output", "81k  37%")
        )
        // Too narrow for the share: the shorter value alternative is used.
        let narrow = CompositionTreemap.Rect(x: 0, y: 0, width: 48, height: 60)
        XCTAssertEqual(
            CompositionTreemap.label(name: "Output", values: ["81k  37%", "81k"], rect: narrow, metrics: metrics),
            .nameAndValue("Output", "81k")
        )
        // Name does not fit: the value alone, never "Too…".
        let slim = CompositionTreemap.Rect(x: 0, y: 0, width: 38, height: 60)
        XCTAssertEqual(
            CompositionTreemap.label(name: "Tool results", values: ["≈39k"], rect: slim, metrics: metrics),
            .value("≈39k")
        )
        // One line of room: the name only.
        let flat = CompositionTreemap.Rect(x: 0, y: 0, width: 120, height: 16)
        XCTAssertEqual(
            CompositionTreemap.label(name: "Output", values: ["81k"], rect: flat, metrics: metrics),
            .name("Output")
        )
        let sliver = CompositionTreemap.Rect(x: 0, y: 0, width: 3, height: 88)
        XCTAssertEqual(CompositionTreemap.label(name: "Other", values: ["1k"], rect: sliver, metrics: metrics), .none)
    }

    func testSegmentLabelsCarryTheEstimateMarkAndFallBackToTheShorterValue() {
        // 39k of 207k is 18.8%, floored like every other share in the app.
        let wide = CompositionTreemap.layout(composition(), width: 620, height: 160)
        XCTAssertEqual(wide.tiles.first { $0.id == "Other" }?.label, .nameAndValue("Other", "≈39k  18%"))
        XCTAssertEqual(wide.tiles.first { $0.id == "Baseline" }?.label, .nameAndValue("Baseline", "48k  23%"), "measured: no ≈")

        // At popover width Other is ~61pt: the share no longer fits, the value does.
        let popover = CompositionTreemap.layout(composition(), width: 332, height: 88)
        XCTAssertEqual(popover.tiles.first { $0.id == "Other" }?.label, .nameAndValue("Other", "≈39k"))
    }

    func testAnEmptyWindowDrawsNothing() {
        let empty = composition(baseline: 0, tools: [], output: 0, other: 0)
        XCTAssertTrue(CompositionTreemap.layout(empty, width: 332, height: 88).tiles.isEmpty)
        XCTAssertTrue(CompositionTreemap.layout(composition(), width: 0, height: 88).tiles.isEmpty)
    }

    func testTheWiderHistoryLayoutLabelsMoreTiles() {
        let c = composition(tools: [("Read", 38, 21_400), ("Bash", 61, 11_900), ("Grep", 44, 6_100),
                                    ("Glob", 19, 1_800), ("Edit", 27, 900)])
        func labelled(_ map: CompositionTreemap) -> Int { map.tiles.filter { $0.label != .none }.count }
        let popover = CompositionTreemap.layout(c, width: 332, height: 88)
        let history = CompositionTreemap.layout(c, width: 620, height: 160)
        XCTAssertGreaterThanOrEqual(labelled(history), labelled(popover))
    }

    // MARK: - Splitting only where the parts can be seen

    /// This repo's first build session: tool results are 3% of the window, a
    /// ~10pt column. Cut into six parts it was a stack of unlabelled slivers
    /// and its total appeared nowhere.
    private var smallToolShare: ContextComposition {
        composition(
            baseline: 70_434,
            tools: [("Bash", 84, 9_618), ("mcp__github__pull_request_read", 1, 1_401), ("Artifact", 2, 540),
                    ("AskUserQuestion", 1, 58), ("mcp__github__create_pull_request", 1, 18), ("Skill", 2, 14)],
            output: 199_816,
            other: 56_264
        )
    }

    func testASegmentTooNarrowToLabelIsDrawnWhole() {
        let map = CompositionTreemap.layout(smallToolShare, width: 332, height: 88)
        let tools = map.tiles.filter { $0.segment == "Tool results" }
        XCTAssertEqual(tools.map(\.role), [.segment], "one tile, not six slivers")
        XCTAssertLessThan(tools[0].rect.width, CompositionTreemap.minimumSplitWidth)
        XCTAssertEqual(tools[0].tokens, 11_649)
    }

    func testATotalNoTileShowsIsHandedToTheKey() {
        let map = CompositionTreemap.layout(smallToolShare, width: 332, height: 88)
        XCTAssertEqual(map.hiddenTotals["Tool results"], "≈11k")
        // Segments whose tiles carry their figure are not repeated in the key.
        XCTAssertNil(map.hiddenTotals["Output"])
        XCTAssertNil(map.hiddenTotals["Baseline"])
    }

    func testAHeaderWithRoomForTheTotalKeepsItOutOfTheKey() {
        // Wide enough for "Tool results  ≈39k" in the header band.
        let wide = CompositionTreemap.layout(composition(), width: 900, height: 160)
        XCTAssertEqual(wide.tiles.first { $0.role == .header }?.label, .name("Tool results  ≈39k"))
        XCTAssertNil(wide.hiddenTotals["Tool results"])

        // At 620pt the band fits the name alone, so the key carries the figure.
        let narrower = CompositionTreemap.layout(composition(), width: 620, height: 160)
        XCTAssertEqual(narrower.tiles.first { $0.role == .header }?.label, .name("Tool results"))
        XCTAssertEqual(narrower.hiddenTotals["Tool results"], "≈39k")
    }

    func testPartsTooThinToSeeFoldIntoMore() {
        let tools: [(String, Int, Int)] = [
            ("Read", 38, 21_400), ("Bash", 61, 11_900), ("Grep", 44, 6_100), ("mcp__github__pull_request_read", 5, 4_200),
            ("Glob", 19, 1_800), ("Edit", 27, 900), ("WebFetch", 2, 700),
        ]
        let c = composition(baseline: 48_212, tools: tools, output: 81_340, other: 39_309)
        let map = CompositionTreemap.layout(c, width: 332, height: 88)
        let parts = map.tiles.filter { $0.segment == "Tool results" && $0.role == .part }
        XCTAssertEqual(parts.map(\.name), ["Read", "Bash", "Grep", "4 more"])
        XCTAssertEqual(parts.last?.fullName, "mcp__github__pull_request_read, Glob, Edit, WebFetch", "largest first")
        XCTAssertEqual(parts.last?.calls, 5 + 19 + 27 + 2)
        XCTAssertEqual(parts.reduce(0) { $0 + $1.tokens }, c.toolResults, "folding moves tokens, never drops them")
        for part in parts where part.name != "4 more" {
            XCTAssertGreaterThanOrEqual(part.rect.height, CompositionTreemap.minimumPartExtent, part.name)
        }
    }

    func testTheBaselineIsNotSplitAroundASliver() {
        // In the popover the CLAUDE.md part would be ~5pt: the baseline stays whole.
        let map = CompositionTreemap.layout(composition(claudeMdBytes: 14_560), width: 332, height: 88)
        let baseline = map.tiles.filter { $0.segment == "Baseline" }
        XCTAssertEqual(baseline.map(\.role), [.segment])
        XCTAssertEqual(baseline.first?.label, .nameAndValue("Baseline", "48k  23%"))
    }

    func testFoldingEverythingMeansNotSplitting() {
        // One sizeable tool and a crowd of crumbs in a short column: after
        // folding, if no named part is left the segment is simply drawn whole.
        let parts = [
            CompositionTreemap.Part(id: "A", name: "A", fullName: "A", tokens: 5, calls: 1),
            CompositionTreemap.Part(id: "B", name: "B", fullName: "B", tokens: 5, calls: 1),
        ]
        let body = CompositionTreemap.Rect(x: 0, y: 0, width: 10, height: 12)   // ~5.5pt each
        XCTAssertTrue(CompositionTreemap.fold(parts, segment: "Tool results", body: body).isEmpty)
    }

    func testCompactTokenFormat() {
        XCTAssertEqual(TokenFormat.compact(845), "845")
        XCTAssertEqual(TokenFormat.compact(8_400), "8.4k")
        XCTAssertEqual(TokenFormat.compact(84_999), "84k")
        XCTAssertEqual(TokenFormat.compact(1_234_567), "1.2M")
    }
}

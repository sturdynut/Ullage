import Foundation
import XCTest
@testable import UllageCore

/// The explorer's tree and its squarified layout.
final class CompositionDrillTests: XCTestCase {
    private func composition(tools: [ContextComposition.ToolShare]) -> ContextComposition {
        let toolResults = tools.reduce(0) { $0 + $1.resultTokens }
        return ContextComposition(
            sessionId: "s", windowLimit: 1_000_000,
            contextTokens: 48_000 + toolResults + 9_000 + 5_000,
            lastTurn: 10, windowStartTurn: 0, compactions: 0,
            baseline: 48_000, toolResults: toolResults, assistantOutput: 9_000, other: 5_000,
            estimatesOvershoot: false, tools: tools, environment: nil
        )
    }

    private func tool(_ name: String, _ tokens: Int, calls: Int = 1, server: String? = nil) -> ContextComposition.ToolShare {
        .init(name: name, kind: server == nil ? "builtin" : "mcp", server: server, calls: calls, resultTokens: tokens)
    }

    func testMcpToolsGroupUnderTheirServerAndNothingFolds() {
        let tools = [
            tool("Read", 20_000), tool("Bash", 3_000),
            tool("mcp__github__get_file", 8_000, calls: 2),
            tool("mcp__github__search_code", 4_000, calls: 3),
            tool("mcp__neon__run_sql", 1_000),
        ] + (1...12).map { tool("Tiny\($0)", 10) }
        let root = CompositionNode.tree(composition(tools: tools))
        XCTAssertEqual(root.children.map(\.name), ["Baseline", "Tool results", "Output", "Other"])

        let results = root.children[1]
        XCTAssertTrue(results.canDrill)
        // Twelve tiny tools are all still there: the explorer never folds.
        XCTAssertEqual(results.children.count, 2 + 1 + 1 + 12)
        XCTAssertEqual(results.children.first?.name, "Read")

        let github = try! XCTUnwrap(results.children.first { $0.name == "github" })
        XCTAssertEqual(github.tokens, 12_000)
        XCTAssertEqual(github.calls, 5)
        XCTAssertEqual(github.children.map(\.name), ["get file", "search code"])
        // A server with one tool is a tool, not a group of one.
        XCTAssertTrue(results.children.contains { $0.name == "neon · run sql" && !$0.canDrill })
        XCTAssertFalse(root.children[2].canDrill)
    }

    func testDescendStopsWhereThePathNoLongerLeads() {
        let root = CompositionNode.tree(composition(tools: [tool("Read", 2_000)]))
        let (node, path) = root.descend(["Tool results", "Tool results/Gone"])
        XCTAssertEqual(node.name, "Tool results")
        XCTAssertEqual(path, ["Tool results"])
    }

    func testSquarifyFillsTheAreaWithTilesInProportion() {
        let nodes = [60, 25, 10, 4, 1].map {
            CompositionNode(id: "\($0)", name: "\($0)", fullName: "\($0)", segment: "Tool results",
                            tokens: $0, calls: nil, isEstimate: true, detail: nil, children: [])
        }
        let placed = CompositionTreemap.squarify(nodes, width: 600, height: 400, gap: 0)
        XCTAssertEqual(placed.map(\.node.tokens), [60, 25, 10, 4, 1])
        let area = placed.reduce(0) { $0 + $1.rect.area }
        XCTAssertEqual(area, 600 * 400, accuracy: 1)
        for tile in placed {
            XCTAssertEqual(tile.rect.area / (600 * 400), Double(tile.node.tokens) / 100, accuracy: 0.001)
            XCTAssertLessThanOrEqual(tile.rect.maxX, 600.5)
            XCTAssertLessThanOrEqual(tile.rect.maxY, 400.5)
        }
        // Squarified: the biggest tile is not a sliver.
        let big = placed[0].rect
        XCTAssertLessThan(max(big.width / big.height, big.height / big.width), 3)
    }
}

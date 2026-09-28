#if canImport(AppKit)
import AppKit
import XCTest
@testable import UllageCore

/// The house rule for collapsed sections, checked: every collapsed line fits
/// the popover at worst-case values, so nothing that matters is cut off at
/// the edge. 332pt is the popover's 360pt less its padding; `.caption` on
/// macOS is the 10pt system font, drawn with monospaced digits.
final class ReadoutWidthTests: XCTestCase {
    static let available: CGFloat = 332

    private func width(_ items: [Readout], dots: Bool = false) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let text = Readout.line(items) + (dots ? String(repeating: "● ", count: items.count) : "")
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    func testCompositionAtAMillionTokens() {
        let items = [Readout("Baseline", "148k"), Readout("Tools", "≈412k"), Readout("Output", "185k"), Readout("Other", "≈1.2M")]
        XCTAssertLessThanOrEqual(width(items, dots: true), Self.available)
    }

    func testSaversWithEveryProblemAtOnce() {
        // Broken savers cannot also overlap (a broken hook rewrites nothing),
        // so these are the two worst lines the panel can build.
        var broken = SaverUsage(saver: .rtk); broken.hookRuns = 1; broken.failedRuns = 1
        var brokenToo = SaverUsage(saver: .tokenade); brokenToo.hookRuns = 1; brokenToo.failedRuns = 1
        var idle = SaverUsage(saver: .headroom); idle.mcpConfigured = true
        let report = SaverSessionReport(sessionId: "s", cwd: nil, bashCalls: 0,
                                        usages: [broken, brokenToo, SaverUsage(saver: .caveman), idle], doubleHookedCalls: 0)
        let states: [TokenSaver: SaverSwitchState] = [.rtk: .on, .tokenade: .on, .caveman: .off, .headroom: .on]
        let panel = SaverPanel.build(report: report, states: states, comparison: nil)
        XCTAssertEqual(Readout.line(panel.summary).hasPrefix("rtk, Tokenade not running · Headroom idle"), true)
        XCTAssertLessThanOrEqual(width(panel.summary), Self.available)
        let overlap = [Readout("rtk + Tokenade overlap", warning: true), Readout("Headroom", "idle", warning: true),
                       Readout("2 on"), Readout("1 off")]
        XCTAssertLessThanOrEqual(width(overlap), Self.available)
    }

    func testPlanLimitsTwoHarnesses() {
        let items = [Readout("Claude Fable", "100% left"), Readout("Codex gpt-reserve", "100% left")]
        XCTAssertLessThanOrEqual(width(items), Self.available)
    }

    func testAgentsWithALongLabel() {
        let label = String(repeating: "Review the whole diff ", count: 4)
        let agent = AgentSummary(agentId: "a", sessionId: "s", label: label, status: nil,
                                 lastContextTokens: 190_000, windowLimit: 200_000)
        let tree = AgentTree(sessionId: "s", roots: Array(repeating: .init(agent: agent, depth: 0), count: 12))
        XCTAssertLessThanOrEqual(width(tree.summary), Self.available)
        XCTAssertTrue(tree.summary.last?.isWarning == true)
    }

    func testSessionInformation() {
        let items = [Readout("last turn", "+12,951"), Readout("turns", "1,112"), Readout("compacted", "3×"),
                     Readout("idle", "11:27 PM")]
        XCTAssertLessThanOrEqual(width(items), Self.available)
    }
}
#endif

import Foundation
import XCTest
@testable import UllageCore

/// Which things each tool was called on, most-called first.
final class ToolTargetsTests: XCTestCase {
    private func call(_ tool: String, _ target: String?, tokens: Int = 100, error: Bool = false) -> ToolCallRow {
        ToolCallRow(id: UUID().uuidString, callId: "c", sessionId: "s", ts: "2026-09-27T00:00:00.000Z",
                    name: tool, kind: "builtin", mcpServer: nil, target: target,
                    resultTokens: tokens, isError: error, parserVersion: 3)
    }

    func testBashCommandsGroupByProgramAndSubcommand() {
        XCTAssertEqual(ToolTargets.program(of: "git status -s"), "git status")
        XCTAssertEqual(ToolTargets.program(of: "cd /x && git log --oneline -5"), "git log")
        XCTAssertEqual(ToolTargets.program(of: "FOO=1 swift test 2>&1 | grep error"), "swift test")
        XCTAssertEqual(ToolTargets.program(of: "scripts/install-app.sh 2>&1 | tail -30"), "scripts/install-app.sh")
        XCTAssertEqual(ToolTargets.program(of: "/usr/bin/open -a Foo"), "open")
        XCTAssertEqual(ToolTargets.program(of: "sed -n 1,20p file"), "sed")
        XCTAssertEqual(ToolTargets.program(of: "uv run python -c \"\nprint(1)\n\""), "uv run")
        // A quoted value with a space is one word, and a bare assignment runs nothing.
        XCTAssertEqual(ToolTargets.program(of: "DB=\"$HOME/Library/Application Support/t.db\"; sqlite3 \"$DB\" .tables"), "sqlite3")
        XCTAssertEqual(ToolTargets.program(of: "S=/tmp/x; rm -f $S/a.png; ls"), "rm")
        XCTAssertEqual(ToolTargets.program(of: "cd /x && python3 - <<'EOF'"), "python3")
        XCTAssertEqual(ToolTargets.program(of: "false || echo 'a | b'"), "false")
        XCTAssertEqual(ToolTargets.program(of: "(OUT=$S ./build/app & P=$!; sleep 30)"), "app")
    }

    func testMostCalledFirstWithDistinctCommandsUnderAProgram() {
        let groups = ToolTargets.group(tool: "Bash", calls: [
            call("Bash", "git status", tokens: 10),
            call("Bash", "git status", tokens: 10),
            call("Bash", "git status -s", tokens: 5),
            call("Bash", "swift build", tokens: 900, error: true),
        ])
        XCTAssertEqual(groups.map(\.name), ["git status", "swift build"])
        XCTAssertEqual(groups[0].calls, 3)
        XCTAssertEqual(groups[0].resultTokens, 25)
        XCTAssertEqual(groups[0].members.map(\.name), ["git status", "git status -s"])
        XCTAssertEqual(groups[1].errors, 1)
        XCTAssertTrue(groups[1].members.isEmpty)
    }

    func testFileToolsGroupByPathAndOpenInTheExplorer() {
        let read = ContextComposition.ToolShare(
            name: "Read", kind: "builtin", server: nil, calls: 3, resultTokens: 300,
            targets: ToolTargets.group(tool: "Read", calls: [
                call("Read", "/Users/me/Code/App/Sources/Core/Store.swift"),
                call("Read", "/Users/me/Code/App/Sources/Core/Store.swift"),
                call("Read", "/Users/me/Code/App/README.md"),
            ])
        )
        let children = CompositionNode.targets(read, parent: "Tool results/Read")
        XCTAssertEqual(children.map(\.name), ["Core/Store.swift", "App/README.md"])
        XCTAssertEqual(children[0].calls, 2)
        XCTAssertEqual(children[0].fullName, "/Users/me/Code/App/Sources/Core/Store.swift")
    }

    func testNothingToOpenWhenEveryCallHadNoTarget() {
        let ask = ContextComposition.ToolShare(
            name: "AskUserQuestion", kind: "builtin", server: nil, calls: 2, resultTokens: 50,
            targets: ToolTargets.group(tool: "AskUserQuestion", calls: [call("AskUserQuestion", nil), call("AskUserQuestion", nil)])
        )
        XCTAssertTrue(CompositionNode.targets(ask, parent: "p").isEmpty)
    }

    func testMostCalledAcrossToolsSkipsSinglesAndMissingTargets() {
        let bash = ContextComposition.ToolShare(
            name: "Bash", kind: "builtin", server: nil, calls: 5, resultTokens: 0,
            targets: ToolTargets.group(tool: "Bash", calls: [
                call("Bash", "git status"), call("Bash", "git diff"), call("Bash", "git status"),
                call("Bash", "git status -s"), call("Bash", "ls"),
            ])
        )
        let read = ContextComposition.ToolShare(
            name: "Read", kind: "builtin", server: nil, calls: 2, resultTokens: 0,
            targets: ToolTargets.group(tool: "Read", calls: [call("Read", "/a/b/c.swift"), call("Read", "/a/b/c.swift")])
        )
        let composition = ContextComposition(
            sessionId: "s", windowLimit: nil, contextTokens: 1, lastTurn: 1, windowStartTurn: 0, compactions: 0,
            baseline: 1, toolResults: 0, assistantOutput: 0, other: 0, estimatesOvershoot: false,
            tools: [bash, read], environment: nil
        )
        let top = ToolTargets.mostCalled(composition)
        XCTAssertEqual(top.map(\.displayName), ["git status", "b/c.swift"])
        XCTAssertEqual(top.map(\.target.calls), [3, 2])
    }
}

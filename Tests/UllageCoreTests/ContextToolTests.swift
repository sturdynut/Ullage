import Foundation
import XCTest
@testable import UllageCore

/// Context tools are data: a descriptor drives detection, rows and installs,
/// and a JSON file in the tools folder adds one without code.
final class ContextToolTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ullage-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Registry

    func testBuiltinsComeFirstInAFixedOrder() {
        let ids = ToolRegistry.load(environment: ["ULLAGE_TOOLS_DIR": "/nonexistent"]).tools.map(\.id)
        XCTAssertEqual(ids, ["rtk", "tokenade", "caveman", "headroom", "serena", "codegraph", "claude-context", "claude-mem"])
    }

    func testUserDescriptorAddsAToolAndCanReplaceABuiltin() throws {
        let dir = try temporaryDirectory()
        // Only what's needed: every list in `detect` and `install` is optional.
        try Data(#"{"id":"mytool","name":"My Tool","kind":"codeSearch","shrinks":"file reads","about":"Finds code.","detect":{"mcpServer":["^mytool$"]}}"#.utf8)
            .write(to: dir.appendingPathComponent("mytool.json"))
        try Data(#"{"id":"serena","name":"Serena (mine)","kind":"codeSearch","shrinks":"x","about":"y","detect":{"mcpServer":["^serena-dev$"]}}"#.utf8)
            .write(to: dir.appendingPathComponent("serena.json"))
        try Data("not json".utf8).write(to: dir.appendingPathComponent("broken.json"))
        try Data(#"{"id":"Bad Id","name":"x","kind":"memory","shrinks":"x","about":"x","detect":{}}"#.utf8)
            .write(to: dir.appendingPathComponent("bad.json"))

        let registry = ToolRegistry.load(environment: ["ULLAGE_TOOLS_DIR": dir.path])
        let mine = try XCTUnwrap(registry.tool(id: "mytool"))
        XCTAssertEqual(registry.tools.last?.id, "mytool", "user tools follow the built-ins")
        XCTAssertTrue(mine.matches(mcpServer: "mytool"))
        XCTAssertFalse(mine.matches(mcpServer: "mytool2"))
        XCTAssertEqual(registry.tool(id: "serena")?.displayName, "Serena (mine)")
        XCTAssertEqual(registry.tools.filter { $0.id == "serena" }.count, 1)
        XCTAssertEqual(registry.problems.count, 2, "a broken file is reported, never fatal")
    }

    func testAnInvalidPatternMatchesNothing() {
        XCTAssertFalse(TokenSaver.any(["(unclosed"], "(unclosed"))
    }

    // MARK: - Detection

    func testCodegraphIsSeenInBashAndMCP() {
        XCTAssertTrue(TokenSaver(BuiltinTools.codegraph).matches(bashCommand: "cd ~/x && codegraph explore Store"))
        XCTAssertFalse(TokenSaver(BuiltinTools.codegraph).matches(bashCommand: "grep codegraph README.md"))
        XCTAssertTrue(TokenSaver(BuiltinTools.codegraph).matches(mcpServer: "codegraph"))
        XCTAssertFalse(TokenSaver.rtk.matches(bashCommand: "rtk git status"), "rtk has no bash pattern")
    }

    func testClaudeMemMatchesItsPluginServerHooksAndKey() {
        let mem = TokenSaver(BuiltinTools.claudeMem)
        XCTAssertTrue(mem.matches(mcpServer: "plugin_claude-mem_mcp-search"))
        XCTAssertTrue(mem.matches(pluginKey: "claude-mem@thedotmack"))
        XCTAssertTrue(mem.matches(hookCommand: #"bun "$HOME/.claude/plugins/cache/thedotmack/claude-mem/13.29.0/scripts/worker-service.cjs" hook claude-code context"#))
    }

    // MARK: - Memory injection

    func testInjectedBytesFromAdditionalContextOrPlainStdout() {
        let json = #"{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"0123456789"}}"#
        XCTAssertEqual(ClaudeCodeParser.injectedBytes(event: "SessionStart", stdout: json), 10)
        XCTAssertEqual(ClaudeCodeParser.injectedBytes(event: "SessionStart", stdout: "plain memory"), 12)
        XCTAssertNil(ClaudeCodeParser.injectedBytes(event: "PreToolUse", stdout: "ignored"), "PreToolUse stdout isn't context")
        XCTAssertNil(ClaudeCodeParser.injectedBytes(event: "SessionStart", stdout: #"{"systemMessage":"hi"}"#))
        XCTAssertNil(ClaudeCodeParser.injectedBytes(event: "SessionStart", stdout: ""))
    }

    func testMemoryRowShowsWhatWasInjected() {
        let mem = TokenSaver(BuiltinTools.claudeMem)
        let run = HookRun(hookEvent: "SessionStart", command: "node claude-mem/x.cjs hook claude-code context",
                          exitCode: 0, injectedBytes: 8_000)
        let events = [EventRow(id: "e1", sessionId: "s1", ts: "2026-09-01T10:00:00.000Z", kind: EventKind.hook.rawValue, detail: run.detailJSON)]
        let report = SaverReport.build(sessionId: "s1", calls: [], toolCalls: [], events: events, sessionEnv: nil, ledger: [])
        XCTAssertEqual(report.usage(mem).injectedBytes, 8_000)
        let panel = SaverPanel.build(report: report, states: [mem: .on])
        let row = try? XCTUnwrap(panel.rows.first { $0.saver == mem })
        XCTAssertEqual(row?.metric, "≈2.0k")
        XCTAssertEqual(row?.metricCaption, "injected")
        XCTAssertEqual(panel.legend, [SaverPanel.claimsLegendLead + "."], "one line says what ≈ means")
    }

    // MARK: - Code search

    func testCodeSearchRowCountsLookupsAndWhatTheyReturned() {
        let serena = TokenSaver(BuiltinTools.serena)
        let codegraph = TokenSaver(BuiltinTools.codegraph)
        let tools = [
            ToolCallRow(id: "t1", callId: "m", sessionId: "s1", ts: "2026-09-01T10:00:01.000Z", name: "mcp__serena__find_symbol",
                        kind: "mcp", mcpServer: "serena", resultTokens: 300),
            ToolCallRow(id: "t2", callId: "m", sessionId: "s1", ts: "2026-09-01T10:00:02.000Z", name: "mcp__serena__get_symbols_overview",
                        kind: "mcp", mcpServer: "serena", resultTokens: 1_200),
            ToolCallRow(id: "t3", callId: "m", sessionId: "s1", ts: "2026-09-01T10:00:03.000Z", name: "Bash",
                        kind: "builtin", target: "codegraph explore SaverPanel", resultTokens: 900),
        ]
        let report = SaverReport.build(sessionId: "s1", calls: [], toolCalls: tools, events: [], sessionEnv: nil, ledger: [])
        XCTAssertEqual(report.usage(serena).mcpCalls, 2)
        XCTAssertEqual(report.usage(serena).mcpResultTokens, 1_500)
        XCTAssertEqual(report.usage(codegraph).bashRuns, 1)
        XCTAssertTrue(report.usage(codegraph).ran)

        let panel = SaverPanel.build(report: report, states: [serena: .on])
        let row = panel.rows.first { $0.saver == serena }
        XCTAssertEqual(row?.metric, "2")
        XCTAssertEqual(row?.metricCaption, "lookups")
        XCTAssertEqual(row?.line, "Returned ≈1.5k instead of whole files")
    }

    // MARK: - Installs from the recipe

    func testRecipeDrivesInstallAndUninstall() {
        let serena = TokenSaver(BuiltinTools.serena)
        let none = SaverInstallation(binary: nil, manager: nil, wired: false)
        let install = SaverInstaller.installPlan(serena, current: none, available: ["uv", "claude"])
        XCTAssertEqual(install.steps.map(\.command), [
            "uv tool install -p 3.13 serena-agent",
            "claude mcp add --scope user serena -- serena start-mcp-server --context claude-code --project-from-cwd",
        ])
        XCTAssertTrue(install.notes.contains { $0.contains("dashboard") })

        let missing = SaverInstaller.installPlan(serena, current: none, available: [])
        XCTAssertEqual(missing.missing, ["uv", "the claude CLI"])

        let installed = SaverInstallation(binary: "/Users/me/.local/bin/serena", manager: .uv, wired: true)
        XCTAssertEqual(SaverInstaller.uninstallPlan(serena, current: installed, available: ["uv", "claude"]).steps.map(\.command), [
            "claude mcp remove --scope user serena",
            "uv tool uninstall serena-agent",
        ])
    }

    func testAToolWithoutARecipeSaysSo() {
        let bare = TokenSaver(ToolDescriptor(id: "bare", name: "Bare", kind: .memory, shrinks: "x", about: "x",
                                             detect: .init(), claims: nil, install: nil))
        let plan = SaverInstaller.installPlan(bare, current: SaverInstallation(binary: nil, manager: nil, wired: false), available: [])
        XCTAssertTrue(plan.steps.isEmpty)
        XCTAssertTrue(plan.notes.first?.contains("install it yourself") ?? false)
    }
}

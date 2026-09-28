import Foundation
import XCTest
@testable import UllageCore

/// Token savers: detected from the transcript, claims kept apart from
/// measurements, and switches that put back exactly what they took out.
final class TokenSaverTests: XCTestCase {
    private func parse(_ line: String) -> ParsedLine? {
        ClaudeCodeParser.parse(line: Data(line.utf8), context: LineContext(sourceFile: "t.jsonl", fallbackSessionId: "s1"))
    }

    // MARK: - Parser

    /// Shape observed on Claude Code 2.1.207: rtk's hook, rtk itself missing.
    func testHookAttachmentBecomesHookEvent() throws {
        let line = #"{"parentUuid":"p","isSidechain":false,"attachment":{"type":"hook_success","hookName":"PreToolUse:Bash","toolUseID":"toolu_1","hookEvent":"PreToolUse","content":"","stdout":"","stderr":"[rtk] WARNING: rtk is not installed or not in PATH.\n","exitCode":0,"command":"/Users/me/.claude/hooks/rtk-rewrite.sh","durationMs":31},"type":"attachment","uuid":"u1","timestamp":"2026-07-11T19:42:19.128Z","cwd":"/p","sessionId":"s1"}"#
        guard case .event(let event)? = parse(line) else { return XCTFail("expected an event") }
        XCTAssertEqual(event.kind, EventKind.hook.rawValue)
        let run = try XCTUnwrap(HookRun(detail: event.detail))
        XCTAssertEqual(run.hookEvent, "PreToolUse")
        XCTAssertEqual(run.toolUseId, "toolu_1")
        XCTAssertTrue(run.failed, "rtk exits 0 but says it is missing")
        XCTAssertNil(run.rewrittenCommand)
        XCTAssertEqual(TokenSaver.saver(forHookCommand: run.command), .rtk)
    }

    func testRewriteIsReadFromUpdatedInput() throws {
        let stdout = #"{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"updatedInput\":{\"command\":\"rtk git status\"}}}"#
        let line = #"{"attachment":{"type":"hook_success","hookEvent":"PreToolUse","toolUseID":"toolu_2","stdout":"\#(stdout)","exitCode":0,"command":"rtk hook claude"},"type":"attachment","uuid":"u2","timestamp":"2026-07-11T19:42:19.128Z","sessionId":"s1"}"#
        guard case .event(let event)? = parse(line) else { return XCTFail("expected an event") }
        XCTAssertEqual(HookRun(detail: event.detail)?.rewrittenCommand, "rtk git status")
    }

    func testSlashCommandIsAnEventButQuotedTextIsNot() throws {
        let command = #"{"type":"user","message":{"role":"user","content":"<command-name>/caveman</command-name>\n            <command-message>caveman</command-message>\n            <command-args>ultra</command-args>"},"uuid":"u3","timestamp":"2026-09-22T19:51:10.066Z","sessionId":"s1"}"#
        guard case .event(let event)? = parse(command) else { return XCTFail("expected an event") }
        XCTAssertEqual(SlashCommand(detail: event.detail), SlashCommand(name: "caveman", args: "ultra"))

        let quoted = #"{"type":"user","message":{"role":"user","content":"why does <command-name>/caveman</command-name> do that"},"uuid":"u4","timestamp":"2026-09-22T19:51:10.066Z","sessionId":"s1"}"#
        XCTAssertNil(parse(quoted))
    }

    func testMatching() {
        XCTAssertTrue(TokenSaver.rtk.matches(hookCommand: "rtk hook claude"))
        XCTAssertTrue(TokenSaver.rtk.matches(hookCommand: "/Users/me/.claude/hooks/rtk-rewrite.sh"))
        XCTAssertFalse(TokenSaver.rtk.matches(hookCommand: "bash ~/hooks/artkit.sh"))
        XCTAssertTrue(TokenSaver.caveman.matches(pluginKey: "caveman@caveman"))
        XCTAssertTrue(TokenSaver.caveman.matches(skillOrCommand: "/caveman:compress"))
        XCTAssertFalse(TokenSaver.caveman.matches(skillOrCommand: "cavemanly"))
        XCTAssertTrue(TokenSaver.headroom.matches(mcpServer: "headroom"))
    }

    // MARK: - Report

    private func call(_ ts: String, output: Int = 100, agent: String? = nil) -> CallRow {
        CallRow(dedupeKey: "m-\(ts)", ts: ts, agentId: agent, sessionId: "s1", cwd: "/repo",
                output: output, contextTokens: 1000, sourceFile: "t.jsonl")
    }

    private func hookEvent(_ id: String, command: String, toolUseId: String? = nil, rewrite: String? = nil, stderr: String? = nil) -> EventRow {
        EventRow(id: id, sessionId: "s1", ts: "2026-09-01T10:00:05.000Z", kind: EventKind.hook.rawValue,
                 detail: HookRun(hookEvent: "PreToolUse", command: command, toolUseId: toolUseId,
                                 exitCode: 0, rewrittenCommand: rewrite, stderr: stderr).detailJSON)
    }

    func testReportCountsRunsRewritesFailuresAndOverlap() {
        let tools = [
            ToolCallRow(id: "b1", callId: "m", sessionId: "s1", ts: "2026-09-01T10:00:06.000Z", name: "Bash", kind: "builtin"),
            ToolCallRow(id: "b2", callId: "m", sessionId: "s1", ts: "2026-09-01T10:00:07.000Z", name: "Bash", kind: "builtin"),
            ToolCallRow(id: "h1", callId: "m", sessionId: "s1", ts: "2026-09-01T10:00:08.000Z",
                        name: "mcp__headroom__headroom_compress", kind: "mcp", mcpServer: "headroom"),
        ]
        let events = [
            hookEvent("e1", command: "rtk hook claude", toolUseId: "b1", rewrite: "rtk git status"),
            hookEvent("e2", command: "tokenade hook pre", toolUseId: "b1"),
            hookEvent("e3", command: "rtk hook claude", toolUseId: "b2", stderr: "rtk: command not found"),
        ]
        let env = SessionEnvRow(sessionId: "s1", capturedAt: "x", mcpServers: #"["headroom","neon"]"#)
        let report = SaverReport.build(sessionId: "s1", calls: [call("2026-09-01T10:00:00.000Z")],
                                       toolCalls: tools, events: events, sessionEnv: env, ledger: [])
        XCTAssertEqual(report.bashCalls, 2)
        XCTAssertEqual(report.usage(.rtk).hookRuns, 2)
        XCTAssertEqual(report.usage(.rtk).rewrites, 1)
        XCTAssertEqual(report.usage(.rtk).failedRuns, 1)
        XCTAssertFalse(report.usage(.rtk).broken)
        XCTAssertEqual(report.usage(.headroom).mcpCalls, 1)
        XCTAssertFalse(report.usage(.headroom).idle)
        XCTAssertEqual(report.doubleHookedCalls, 1)
        XCTAssertEqual(report.visible.map(\.saver), [.rtk, .tokenade, .headroom], "fixed order, caveman absent")
    }

    func testLedgerMatchesByPlaceAndTimeAndStaysAClaim() {
        let at = { (s: String) in Timestamps.date(from: s)! }
        let ledger = [
            LedgerEntry(saver: .rtk, ts: at("2026-09-01T10:01:00Z"), cwd: "/repo", command: "git status --short",
                        beforeTokens: 400, afterTokens: 100, savedTokens: 300),
            LedgerEntry(saver: .rtk, ts: at("2026-09-01T10:02:00Z"), cwd: "/repo/sub", command: "git status",
                        beforeTokens: 200, afterTokens: 100, savedTokens: 100),
            // Elsewhere, and later than the session plus slack.
            LedgerEntry(saver: .rtk, ts: at("2026-09-01T10:01:00Z"), cwd: "/other", command: "ls",
                        beforeTokens: 50, afterTokens: 10, savedTokens: 40),
            LedgerEntry(saver: .rtk, ts: at("2026-09-01T11:00:00Z"), cwd: "/repo", command: "ls",
                        beforeTokens: 50, afterTokens: 10, savedTokens: 40),
        ]
        let calls = [call("2026-09-01T10:00:00.000Z"), call("2026-09-01T10:03:00.000Z")]
        let report = SaverReport.build(sessionId: "s1", calls: calls, toolCalls: [], events: [], sessionEnv: nil, ledger: ledger)
        let match = report.usage(.rtk).ledger
        XCTAssertEqual(match?.entries, 2)
        XCTAssertEqual(match?.savedTokens, 400)
        XCTAssertEqual(match?.groups.map(\.command), ["git status"])
        XCTAssertEqual(match?.reduction ?? 0, 400.0 / 600.0, accuracy: 0.001)
    }

    func testCommandKey() {
        XCTAssertEqual(SaverReport.commandKey("rtk git log -n 5"), "git log")
        XCTAssertEqual(SaverReport.commandKey("ls -la"), "ls")
        XCTAssertEqual(SaverReport.commandKey("FOO=1 cargo test --release"), "cargo test")
        XCTAssertEqual(SaverReport.commandKey("/usr/bin/git diff"), "git diff")
    }

    // MARK: - Ledgers

    func testLenientDates() {
        let expected = Timestamps.date(from: "2026-07-11T12:32:00.123Z")
        XCTAssertEqual(SaverLedgers.lenientDate("2026-07-11T12:32:00.123456789+00:00"), expected)
        XCTAssertEqual(SaverLedgers.lenientDate("2026-07-11T14:32:00.123+02:00"), expected)
        XCTAssertEqual(SaverLedgers.lenientDate("2026-07-11 12:32:00"), Timestamps.date(from: "2026-07-11T12:32:00Z"))
    }

    func testRtkLedgerIsReadReadOnly() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rtk-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.db")
        do {
            let db = try SQLiteDatabase(path: url.path)
            try db.execute("""
            CREATE TABLE commands (id INTEGER PRIMARY KEY, timestamp TEXT NOT NULL, original_cmd TEXT NOT NULL,
              rtk_cmd TEXT NOT NULL, input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL,
              saved_tokens INTEGER NOT NULL, savings_pct REAL NOT NULL, exec_time_ms INTEGER DEFAULT 0, project_path TEXT DEFAULT '');
            INSERT INTO commands VALUES (1,'2026-07-11T12:32:00.123456789+00:00','git status','rtk git status',400,100,300,75.0,5,'/repo');
            INSERT INTO commands VALUES (2,'not a date','ls','rtk ls',1,1,0,0,0,'');
            """)
        }
        let entries = SaverLedgers.rtkEntries(at: url)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.savedTokens, 300)
        XCTAssertEqual(entries.first?.cwd, "/repo")
        XCTAssertTrue(SaverLedgers.rtkEntries(at: root.appendingPathComponent("missing.db")).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("missing.db").path))
    }

    func testTokenadeLedgerToleratesUnknownShapes() {
        let jsonl = """
        {"ts":"2026-09-01T10:00:00Z","cwd":"/repo","command":"git diff","before":900,"after":300}
        {"timestamp":1788256800000,"project":"/repo","saved_tokens":50}
        {"nothing":"useful"}
        not json
        """
        let entries = SaverLedgers.tokenadeEntries(jsonl: Data(jsonl.utf8), since: nil)
        XCTAssertEqual(entries.map(\.savedTokens), [600, 50])
        XCTAssertEqual(entries.first?.saver, .tokenade)
    }

    // MARK: - caveman comparison

    func testComparisonSplitsTurnsBySignal() {
        var turns: [OutputComparison.Turn] = []
        for i in 0..<30 { turns.append(.init(sessionId: "a", ts: String(format: "2026-09-01T10:%02d:00.000Z", i), output: 600)) }
        for i in 30..<55 { turns.append(.init(sessionId: "a", ts: String(format: "2026-09-01T10:%02d:00.000Z", i), output: 200)) }
        let events = [
            EventRow(id: "c1", sessionId: "a", ts: "2026-09-01T10:29:30.000Z", kind: EventKind.command.rawValue,
                     detail: SlashCommand(name: "caveman", args: "full").detailJSON),
            EventRow(id: "c2", sessionId: "a", ts: "2026-09-01T10:52:30.000Z", kind: EventKind.command.rawValue,
                     detail: SlashCommand(name: "caveman", args: "off").detailJSON),
        ]
        let comparison = OutputComparison.build(turns: turns, signals: OutputComparison.signals(events: events, toolCalls: []))
        XCTAssertEqual(comparison?.withTurns, 23)
        XCTAssertEqual(comparison?.withMedian, 200)
        XCTAssertEqual(comparison?.withoutTurns, 32)
        XCTAssertEqual(comparison?.withoutMedian, 600)
        XCTAssertNil(OutputComparison.build(turns: Array(turns.prefix(25)), signals: []), "too few turns either side")
    }

    // MARK: - Switches

    func testHookIsParkedAndRestoredExactly() throws {
        var settings: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    ["matcher": "Bash", "hooks": [
                        ["type": "command", "command": "rtk hook claude", "timeout": 5],
                        ["type": "command", "command": "~/hooks/audit.sh"],
                    ]],
                ],
                "Stop": [["hooks": [["type": "command", "command": "say done"]]]],
            ],
            "model": "opus",
        ]
        var claudeJSON: [String: Any] = [:]
        var parked: [TokenSaver: ParkedSaver] = [:]

        let off = try SaverSwitchboard.apply(.rtk, on: false, settings: &settings, claudeJSON: &claudeJSON, parked: &parked)
        XCTAssertTrue(off.settingsChanged)
        XCTAssertEqual(SaverSwitchboard.state(of: .rtk, settings: settings, claudeJSON: claudeJSON, parked: parked[.rtk]), .off)
        let remaining = (((settings["hooks"] as? [String: Any])?["PreToolUse"] as? [Any])?.first as? [String: Any])?["hooks"] as? [Any]
        XCTAssertEqual(remaining?.count, 1, "the other hook in the same entry stays")

        _ = try SaverSwitchboard.apply(.rtk, on: true, settings: &settings, claudeJSON: &claudeJSON, parked: &parked)
        XCTAssertNil(parked[.rtk])
        XCTAssertEqual(SaverSwitchboard.state(of: .rtk, settings: settings, claudeJSON: claudeJSON, parked: nil), .on)
        let restored = ((((settings["hooks"] as? [String: Any])?["PreToolUse"] as? [Any])?.first as? [String: Any])?["hooks"] as? [Any])?
            .compactMap { ($0 as? [String: Any])?["command"] as? String }
        XCTAssertEqual(Set(restored ?? []), ["rtk hook claude", "~/hooks/audit.sh"])
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: settings["model"] as Any, options: .fragmentsAllowed),
                       try JSONSerialization.data(withJSONObject: "opus", options: .fragmentsAllowed))
    }

    func testPluginFlagAndMcpServer() throws {
        var settings: [String: Any] = ["enabledPlugins": ["caveman@caveman": true, "other@x": true]]
        var claudeJSON: [String: Any] = ["mcpServers": ["headroom": ["command": "headroom", "args": ["mcp"]], "Neon": ["url": "u"]],
                                         "numStartups": 12]
        var parked: [TokenSaver: ParkedSaver] = [:]

        _ = try SaverSwitchboard.apply(.caveman, on: false, settings: &settings, claudeJSON: &claudeJSON, parked: &parked)
        XCTAssertEqual((settings["enabledPlugins"] as? [String: Any])?["caveman@caveman"] as? Bool, false)
        XCTAssertNil(parked[.caveman], "a plugin flag parks nothing")

        let off = try SaverSwitchboard.apply(.headroom, on: false, settings: &settings, claudeJSON: &claudeJSON, parked: &parked)
        XCTAssertTrue(off.claudeJSONChanged)
        XCTAssertEqual((claudeJSON["mcpServers"] as? [String: Any])?.keys.sorted(), ["Neon"])
        XCTAssertEqual(claudeJSON["numStartups"] as? Int, 12)
        _ = try SaverSwitchboard.apply(.headroom, on: true, settings: &settings, claudeJSON: &claudeJSON, parked: &parked)
        XCTAssertEqual((claudeJSON["mcpServers"] as? [String: Any])?.keys.sorted(), ["Neon", "headroom"])

        XCTAssertThrowsError(try SaverSwitchboard.apply(.rtk, on: false, settings: &settings, claudeJSON: &claudeJSON, parked: &parked))
    }

    func testSwitchboardWritesBackupsAndParkedFile() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("switch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent("settings.json")
        try #"{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"rtk hook claude"}]}]}}"#
            .write(to: settings, atomically: true, encoding: .utf8)
        let board = SaverSwitchboard(settingsURL: settings, claudeJSONURL: root.appendingPathComponent(".claude.json"),
                                     parkedURL: root.appendingPathComponent("support/parked-savers.json"))
        XCTAssertEqual(board.state(of: .rtk), .on)
        try board.set(.rtk, on: false)
        XCTAssertEqual(board.state(of: .rtk), .off)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("support/backups").path).count, 1)
        try board.set(.rtk, on: true)
        XCTAssertEqual(board.state(of: .rtk), .on)
        XCTAssertEqual(board.state(of: .headroom), .notInstalled)
    }

    // MARK: - Panel

    func testPanelShowsInstalledOrTracedSaversOnly() {
        var broken = SaverUsage(saver: .rtk)
        broken.hookRuns = 3
        broken.failedRuns = 3
        broken.failureMessage = "[rtk] WARNING: rtk is not installed or not in PATH. Hook cannot rewrite commands."
        var idle = SaverUsage(saver: .headroom)
        idle.mcpConfigured = true
        let report = SaverSessionReport(sessionId: "s1", cwd: "/repo", bashCalls: 10,
                                        usages: [broken, SaverUsage(saver: .tokenade), SaverUsage(saver: .caveman), idle],
                                        doubleHookedCalls: 0)
        let panel = SaverPanel.build(report: report,
                                     states: [.rtk: .notInstalled, .tokenade: .notInstalled, .caveman: .off, .headroom: .on],
                                     comparison: nil)
        XCTAssertEqual(panel.rows.map(\.saver), [.rtk, .caveman, .headroom])
        XCTAssertEqual(panel.rows[0].metric, "not running")
        XCTAssertEqual(panel.rows[0].note, "WARNING: rtk is not installed or not in PATH")
        XCTAssertFalse(panel.rows[0].canSwitch)
        XCTAssertEqual(panel.rows[2].metric, "idle")
        XCTAssertEqual(panel.rows[2].metricTone, .warning)
        XCTAssertNil(panel.warning)
    }

    func testPanelMarksClaimsAndWarnsOnOverlap() {
        var rtk = SaverUsage(saver: .rtk)
        rtk.hookRuns = 5
        rtk.rewrites = 4
        rtk.ledger = LedgerMatch(entries: 4, savedTokens: 18_400, beforeTokens: 23_000, afterTokens: 4_600, groups: [])
        let report = SaverSessionReport(sessionId: "s1", cwd: "/repo", bashCalls: 9, usages: [rtk], doubleHookedCalls: 2)
        let panel = SaverPanel.build(report: report, states: [.rtk: .on, .tokenade: .on], comparison: nil)
        XCTAssertEqual(panel.rows.first?.metric, "≈18k")
        XCTAssertEqual(panel.rows.first?.line, "4 of 9 Bash calls rewritten · ≈80% smaller")
        XCTAssertEqual(panel.rows.first?.note, TokenSaver.rtk.savingSource)
        XCTAssertTrue(panel.warning?.contains("2 Bash calls") == true)
    }

    // MARK: - Install and uninstall

    func testPackageManagerFromResolvedPath() {
        XCTAssertEqual(PackageManager.owning(resolvedPath: "/opt/homebrew/Cellar/rtk/0.9/bin/rtk"), .homebrew)
        XCTAssertEqual(PackageManager.owning(resolvedPath: "/Users/me/.local/pipx/venvs/headroom-ai/bin/headroom"), .pipx)
        XCTAssertEqual(PackageManager.owning(resolvedPath: "/Users/me/.local/share/uv/tools/headroom-ai/bin/headroom"), .uv)
        XCTAssertEqual(PackageManager.owning(resolvedPath: "/Users/me/.nvm/versions/node/v22/lib/node_modules/@tokenade/cli/bin/tokenade"), .npm)
        XCTAssertEqual(PackageManager.owning(resolvedPath: "/Users/me/.local/bin/rtk"), .script)
    }

    func testInstallPlanSkipsWhatIsThere() {
        let none = SaverInstallation(binary: nil, manager: nil, wired: false)
        let fresh = SaverInstaller.installPlan(.rtk, current: none, available: ["brew", "curl"])
        XCTAssertEqual(fresh.steps.map(\.command), ["brew install rtk", "rtk init -g"])

        let binaryOnly = SaverInstallation(binary: "/opt/homebrew/bin/rtk", manager: .homebrew, wired: false)
        XCTAssertEqual(SaverInstaller.installPlan(.rtk, current: binaryOnly, available: []).steps.map(\.command), ["rtk init -g"])

        let tokenade = SaverInstaller.installPlan(.tokenade, current: none, available: [])
        XCTAssertFalse(tokenade.isRunnable)
        XCTAssertEqual(tokenade.missing, ["npm (Node.js)"])
        XCTAssertTrue(SaverInstaller.installPlan(.tokenade, current: none, available: ["npm"]).needsPerson)

        let done = SaverInstallation(binary: "/x/headroom", manager: .pipx, wired: true)
        XCTAssertTrue(SaverInstaller.installPlan(.headroom, current: done, available: ["uv", "claude"]).steps.isEmpty)
    }

    func testUninstallUsesTheManagerThatInstalledIt() {
        let headroom = SaverInstallation(binary: "/Users/me/.local/bin/headroom", manager: .pipx, wired: true)
        XCTAssertEqual(SaverInstaller.uninstallPlan(.headroom, current: headroom, available: ["claude", "pipx"]).steps.map(\.command),
                       ["claude mcp remove --scope user headroom", "pipx uninstall headroom-ai"])
        let rtk = SaverInstallation(binary: "/Users/me/.local/bin/rtk", manager: .script, wired: true)
        XCTAssertEqual(SaverInstaller.uninstallPlan(.rtk, current: rtk, available: []).steps.map(\.command),
                       ["rtk init -g --uninstall", "rm '/Users/me/.local/bin/rtk'"])
        let caveman = SaverInstallation(binary: nil, manager: nil, wired: true)
        XCTAssertEqual(SaverInstaller.uninstallPlan(.caveman, current: caveman, available: []).missing, ["claude"])
    }

    func testScriptStopsOnFailureAndQuotes() {
        let plan = SaverInstaller.installPlan(.caveman, current: SaverInstallation(binary: nil, manager: nil, wired: false),
                                              available: ["claude"])
        let script = SaverInstaller.script(for: plan, shell: "/bin/zsh")
        XCTAssertTrue(script.hasPrefix("#!/bin/zsh -il\n"))
        XCTAssertTrue(script.contains("set -e"))
        XCTAssertTrue(script.contains("\nclaude plugin install caveman@caveman\n"))
        XCTAssertEqual(SaverInstaller.shellQuote("it's"), "'it'\\''s'")
    }

    func testWhichAndInstallationFromDisk() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("which-" + UUID().uuidString)
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rtk = bin.appendingPathComponent("rtk")
        try "#!/bin/sh\n".write(to: rtk, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rtk.path)
        let plugins = root.appendingPathComponent("installed_plugins.json")
        try #"{"version":2,"plugins":{"caveman@caveman":[{}]}}"#.write(to: plugins, atomically: true, encoding: .utf8)
        let board = SaverSwitchboard(settingsURL: root.appendingPathComponent("settings.json"),
                                     claudeJSONURL: root.appendingPathComponent(".claude.json"),
                                     parkedURL: root.appendingPathComponent("parked.json"))
        let installer = SaverInstaller(searchPaths: [bin.path], installedPluginsURL: plugins, switchboard: board)
        XCTAssertEqual(installer.which("rtk"), rtk.path)
        XCTAssertNil(installer.which("tokenade"))
        XCTAssertTrue(installer.installation(of: .rtk).isInstalled)
        XCTAssertFalse(installer.installation(of: .rtk).wired)
        XCTAssertTrue(installer.installation(of: .caveman).isInstalled)
        XCTAssertFalse(installer.installation(of: .headroom).isInstalled)
    }

    func testPanelOffersWhatIsNotInstalled() {
        let panel = SaverPanel.build(report: nil, states: [.headroom: .on], comparison: nil, installed: [.headroom, .rtk])
        XCTAssertEqual(panel.rows.map(\.saver), [.rtk, .headroom])
        XCTAssertEqual(panel.rows.first?.line, "Installed, not set up in Claude Code")
        XCTAssertTrue(panel.rows.allSatisfy(\.isInstalled))
        XCTAssertEqual(panel.installable, [.tokenade, .caveman])
        XCTAssertFalse(SaverPanel.build(report: nil, states: [:], comparison: nil).isEmpty, "nothing installed still offers installs")
    }
}

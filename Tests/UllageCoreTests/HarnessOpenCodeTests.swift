import Foundation
import XCTest
@testable import UllageCore

/// OpenCode's store is SQLite. The fixture is built with the CREATE TABLE
/// statements of OpenCode's migrations (packages/core/src/database/migration/
/// 20260127222353_familiar_lady_ursula.ts plus later ALTERs), and rows shaped
/// like what `session/processor.ts` and the projector write. No real prompt
/// text anywhere.
final class HarnessOpenCodeTests: XCTestCase {
    static let schema = """
    CREATE TABLE `project` (`id` text PRIMARY KEY, `worktree` text NOT NULL, `vcs` text, `name` text,
      `icon_url` text, `icon_color` text, `time_created` integer NOT NULL, `time_updated` integer NOT NULL,
      `time_initialized` integer, `sandboxes` text NOT NULL);
    CREATE TABLE `session` (`id` text PRIMARY KEY, `project_id` text NOT NULL, `parent_id` text, `slug` text NOT NULL,
      `directory` text NOT NULL, `title` text NOT NULL, `version` text NOT NULL, `share_url` text,
      `summary_additions` integer, `summary_deletions` integer, `summary_files` integer, `summary_diffs` text,
      `revert` text, `permission` text, `time_created` integer NOT NULL, `time_updated` integer NOT NULL,
      `time_compacting` integer, `time_archived` integer, `workspace_id` text, `path` text, `agent` text, `model` text,
      `cost` real DEFAULT 0 NOT NULL, `tokens_input` integer DEFAULT 0 NOT NULL, `metadata` text,
      CONSTRAINT `fk_session_project_id_project_id_fk` FOREIGN KEY (`project_id`) REFERENCES `project`(`id`) ON DELETE CASCADE);
    CREATE TABLE `message` (`id` text PRIMARY KEY, `session_id` text NOT NULL, `time_created` integer NOT NULL,
      `time_updated` integer NOT NULL, `data` text NOT NULL,
      CONSTRAINT `fk_message_session_id_session_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session`(`id`) ON DELETE CASCADE);
    CREATE TABLE `part` (`id` text PRIMARY KEY, `message_id` text NOT NULL, `session_id` text NOT NULL,
      `time_created` integer NOT NULL, `time_updated` integer NOT NULL, `data` text NOT NULL,
      CONSTRAINT `fk_part_message_id_message_id_fk` FOREIGN KEY (`message_id`) REFERENCES `message`(`id`) ON DELETE CASCADE);
    CREATE INDEX `message_session_time_created_id_idx` ON `message` (`session_id`,`time_created`,`id`);
    CREATE INDEX `part_message_id_id_idx` ON `part` (`message_id`,`id`);
    """

    // MARK: - Fixture

    final class Fixture {
        let workspace: TempWorkspace
        let url: URL
        let db: SQLiteDatabase

        init() throws {
            workspace = try TempWorkspace()
            let dir = workspace.root.appendingPathComponent("opencode", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            url = dir.appendingPathComponent("opencode.db")
            db = try SQLiteDatabase(path: url.path)
            try db.execute(HarnessOpenCodeTests.schema)
            try db.run("INSERT INTO project VALUES ('prj', '/w/proj', 'git', NULL, NULL, NULL, 0, 0, NULL, '[]');")
            try session("ses_root", parent: nil)
            try session("ses_child", parent: "ses_root")
        }

        func session(_ id: String, parent: String?) throws {
            try db.run(
                "INSERT INTO session (id, project_id, parent_id, slug, directory, title, version, time_created, time_updated) VALUES (?1, 'prj', ?2, 's', '/w/proj', 't', '1.14.0', 0, 0);",
                [.text(id), .string(parent)])
        }

        func message(_ id: String, session: String, at ms: Int, _ json: String) throws {
            try db.run("INSERT INTO message VALUES (?1, ?2, ?3, ?3, ?4);", [.text(id), .text(session), .integer(Int64(ms)), .text(json)])
        }

        func part(_ id: String, message: String, session: String, at ms: Int, _ json: String) throws {
            try db.run("INSERT INTO part VALUES (?1, ?2, ?3, ?4, ?4, ?5);",
                       [.text(id), .text(message), .text(session), .integer(Int64(ms)), .text(json)])
        }

        static func assistant(model: String = "claude-sonnet-4-5", provider: String = "anthropic", agent: String = "build",
                              created: Int, completed: Int? = nil, summary: Bool = false, parent: String = "msg_u1", finish: String? = "tool-calls",
                              tokens: String = Fixture.tokens(0, 0, 0, 0, 0)) -> String {
            let done = completed.map { ",\"completed\":\($0)" } ?? ""
            let fin = finish.map { ",\"finish\":\"\($0)\"" } ?? ""
            return """
            {"role":"assistant","time":{"created":\(created)\(done)},"parentID":"\(parent)","modelID":"\(model)",\
            "providerID":"\(provider)","mode":"\(agent)","agent":"\(agent)","path":{"cwd":"/w/proj","root":"/w/proj"},\
            "summary":\(summary),"cost":0,"tokens":\(tokens),"variant":"high"\(fin)}
            """
        }

        static func tokens(_ input: Int, _ output: Int, _ reasoning: Int, _ read: Int, _ write: Int) -> String {
            "{\"input\":\(input),\"output\":\(output),\"reasoning\":\(reasoning),\"cache\":{\"read\":\(read),\"write\":\(write)}}"
        }

        static func stepFinish(_ tokens: String) -> String {
            "{\"type\":\"step-finish\",\"reason\":\"tool-calls\",\"cost\":0.01,\"tokens\":\(tokens)}"
        }

        static func tool(_ name: String, status: String, input: String, output: String = "", metadata: String = "{}", start: Int) -> String {
            let result = status == "error"
                ? "\"error\":\"\(output)\""
                : "\"output\":\"\(output)\",\"title\":\"t\",\"metadata\":\(metadata)"
            return """
            {"type":"tool","callID":"toolu_\(name)","tool":"\(name)","state":{"status":"\(status)","input":\(input),\
            \(result),"time":{"start":\(start),"end":\(start + 5)}}}
            """
        }

        /// A main thread of four calls around a compaction, one subagent, an
        /// aborted message, one legacy message, and two malformed rows.
        func populate() throws {
            try message("msg_u1", session: "ses_root", at: 500, #"{"role":"user","time":{"created":500},"agent":"build","model":{"providerID":"anthropic","modelID":"claude-sonnet-4-5"}}"#)

            // One message, two steps (= two model calls).
            try message("msg_a1", session: "ses_root", at: 600,
                        Fixture.assistant(created: 600, completed: 2_100, tokens: Fixture.tokens(20, 30, 0, 1_200, 0)))
            try part("prt_a1_1", message: "msg_a1", session: "ses_root", at: 610, #"{"type":"step-start"}"#)
            try part("prt_a1_2", message: "msg_a1", session: "ses_root", at: 700,
                     Fixture.tool("read", status: "completed", input: #"{"filePath":"/w/proj/a.swift"}"#,
                                  output: String(repeating: "x", count: 400), start: 700))
            try part("prt_a1_3", message: "msg_a1", session: "ses_root", at: 1_000,
                     Fixture.stepFinish(Fixture.tokens(10, 50, 5, 1_000, 200)))
            try part("prt_a1_4", message: "msg_a1", session: "ses_root", at: 1_100,
                     Fixture.tool("task", status: "completed",
                                  input: #"{"description":"find things","prompt":"p","subagent_type":"explore"}"#,
                                  output: "done",
                                  metadata: #"{"parentSessionId":"ses_root","sessionId":"ses_child","model":{"modelID":"gpt-5","providerID":"openai"}}"#,
                                  start: 1_100))
            try part("prt_a1_5", message: "msg_a1", session: "ses_root", at: 2_000,
                     Fixture.stepFinish(Fixture.tokens(20, 30, 0, 1_200, 0)))
            try part("prt_a1_6", message: "msg_a1", session: "ses_root", at: 2_001, #"{"type":"text","text":"(scrubbed)"}"#)

            // The subagent, in its own child session.
            try message("msg_c1", session: "ses_child", at: 1_200,
                        Fixture.assistant(model: "gpt-5", provider: "openai", agent: "explore", created: 1_200, completed: 1_500))
            try part("prt_c1_1", message: "msg_c1", session: "ses_child", at: 1_300,
                     Fixture.tool("github_create_issue", status: "error", input: #"{"title":"x"}"#, output: "denied", start: 1_300))
            try part("prt_c1_2", message: "msg_c1", session: "ses_child", at: 1_500,
                     Fixture.stepFinish(Fixture.tokens(5, 10, 0, 0, 0)))

            // Compaction: the user message carries the marker, the summary
            // message is the model call that wrote the summary.
            try message("msg_u2", session: "ses_root", at: 2_500, #"{"role":"user","time":{"created":2500},"agent":"build","model":{"providerID":"anthropic","modelID":"claude-sonnet-4-5"}}"#)
            try part("prt_u2_1", message: "msg_u2", session: "ses_root", at: 2_500, #"{"type":"compaction","auto":true,"overflow":false}"#)
            try message("msg_s", session: "ses_root", at: 2_600,
                        Fixture.assistant(agent: "compaction", created: 2_600, completed: 3_000, summary: true, parent: "msg_u2", finish: "stop"))
            try part("prt_s_1", message: "msg_s", session: "ses_root", at: 3_000,
                     Fixture.stepFinish(Fixture.tokens(1_300, 400, 0, 0, 0)))

            try message("msg_a3", session: "ses_root", at: 3_500, Fixture.assistant(created: 3_500, completed: 4_000))
            try part("prt_a3_1", message: "msg_a3", session: "ses_root", at: 4_000,
                     Fixture.stepFinish(Fixture.tokens(300, 10, 0, 0, 100)))

            // Aborted: no step, zero tokens. Not a request.
            try message("msg_a4", session: "ses_root", at: 4_500, Fixture.assistant(created: 4_500, finish: nil))

            // Older shape: usage on the message, no step-finish part.
            try message("msg_a5", session: "ses_root", at: 5_000,
                        Fixture.assistant(created: 5_000, completed: 5_100, finish: "stop", tokens: Fixture.tokens(7, 8, 0, 450, 0)))

            // Malformed rows are skipped, not fatal.
            try message("msg_bad", session: "ses_root", at: 5_200, "not json")
            try part("prt_bad", message: "msg_a5", session: "ses_root", at: 5_200, "{")
        }
    }

    // MARK: - Tests

    func testTokenMappingStepsAndCacheSplit() throws {
        let fixture = try Fixture()
        try fixture.populate()
        try fixture.workspace.ingestor.ingestFile(at: fixture.url)
        let store = fixture.workspace.store

        let main = try store.calls(sessionId: "ses_root")
        XCTAssertEqual(main.map(\.dedupeKey), ["opencode:prt_a1_3", "opencode:prt_a1_5", "opencode:prt_s_1", "opencode:prt_a3_1", "opencode:msg_a5"])
        let first = main[0]
        XCTAssertEqual(first.vendor, Vendor.opencode)
        XCTAssertEqual([first.input, first.output, first.cacheRead, first.cacheWrite], [10, 50, 1_000, 200])
        XCTAssertEqual(first.reasoning, 5)
        XCTAssertEqual(first.contextTokens, 1_210)
        XCTAssertEqual(first.windowLimit, 200_000)
        XCTAssertEqual(first.model, "claude-sonnet-4-5")
        XCTAssertEqual(first.effort, "high")
        XCTAssertEqual(first.cwd, "/w/proj")
        XCTAssertEqual(first.project, "proj")
        XCTAssertEqual(first.ts, "1970-01-01T00:00:01.000Z")
        XCTAssertEqual(first.confidence, Confidence.exact.rawValue)
        XCTAssertNil(first.agentId)

        XCTAssertEqual(main.map(\.contextTokens), [1_210, 1_220, 1_300, 400, 457])
        XCTAssertEqual(main[1].contextDelta, 10)
        XCTAssertEqual(main[2].contextDelta, 80)
        XCTAssertNil(main[3].contextDelta, "first turn after the compaction")
        XCTAssertEqual(main[4].contextDelta, 57)

        let events = try store.events(sessionId: "ses_root", kind: EventKind.compaction.rawValue, scope: .all)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.ts, "1970-01-01T00:00:03.001Z")
        XCTAssertEqual(events.first?.detail, #"{"auto":true,"overflow":false}"#)
    }

    func testSubagentIsItsOwnStreamUnderTheRootSession() throws {
        let fixture = try Fixture()
        try fixture.populate()
        try fixture.workspace.ingestor.ingestFile(at: fixture.url)
        let store = fixture.workspace.store

        let child = try store.calls(sessionId: "ses_root", scope: .agent("ses_child"))
        XCTAssertEqual(child.count, 1)
        XCTAssertEqual(child.first?.agentId, "ses_child")
        XCTAssertEqual(child.first?.agent, "explore")
        XCTAssertEqual(child.first?.contextTokens, 5)
        XCTAssertNil(child.first?.windowLimit, "unknown model gets no window, never the fallback")
        XCTAssertTrue(try store.calls(sessionId: "ses_child", scope: .all).isEmpty)

        let agents = try store.agents(sessionId: "ses_root")
        let agent = try XCTUnwrap(agents.first { $0.agentId == "ses_child" })
        XCTAssertEqual(agent.agentType, "explore")
        XCTAssertNil(agent.parentAgentId)
    }

    func testToolCalls() throws {
        let fixture = try Fixture()
        try fixture.populate()
        try fixture.workspace.ingestor.ingestFile(at: fixture.url)
        let tools = try fixture.workspace.store.toolCalls(sessionId: "ses_root")
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })

        let read = try XCTUnwrap(byName["read"])
        XCTAssertEqual(read.callId, "opencode:prt_a1_3")
        XCTAssertEqual(read.kind, ToolKind.builtin.rawValue)
        XCTAssertEqual(read.target, "/w/proj/a.swift")
        XCTAssertEqual(read.resultTokens, 100)
        XCTAssertEqual(read.isError, false)

        let task = try XCTUnwrap(byName["task"])
        XCTAssertEqual(task.callId, "opencode:prt_a1_5", "a tool belongs to the step that finishes after it")
        XCTAssertEqual(task.kind, ToolKind.agent.rawValue)
        XCTAssertEqual(task.target, "find things")

        let mcp = try XCTUnwrap(byName["github_create_issue"])
        XCTAssertEqual(mcp.kind, ToolKind.mcp.rawValue)
        XCTAssertEqual(mcp.mcpServer, "github")
        XCTAssertEqual(mcp.isError, true)

        XCTAssertEqual(OpenCodeReader.classify(toolName: "apply_patch").kind, .builtin)
        XCTAssertEqual(OpenCodeReader.classify(toolName: "skill").kind, .skill)
        XCTAssertEqual(OpenCodeReader.classify(toolName: "mytool").kind, .builtin)
    }

    func testReReadIsIdempotent() throws {
        let fixture = try Fixture()
        try fixture.populate()
        let reader = OpenCodeReader()
        let context = LineContext(sourceFile: fixture.url.path, fallbackSessionId: "x")
        XCTAssertEqual(reader.read(file: fixture.url, context: context), reader.read(file: fixture.url, context: context))

        try fixture.workspace.ingestor.ingestFile(at: fixture.url)
        // A new step makes OpenCode's file change; everything is re-read.
        try fixture.message("msg_a6", session: "ses_root", at: 6_000, Fixture.assistant(created: 6_000))
        try fixture.part("prt_a6_1", message: "msg_a6", session: "ses_root", at: 6_100,
                         Fixture.stepFinish(Fixture.tokens(1, 1, 0, 500, 0)))
        try fixture.workspace.ingestor.ingestFile(at: fixture.url)
        try fixture.workspace.ingestor.ingestFile(at: fixture.url)

        let store = fixture.workspace.store
        XCTAssertEqual(try store.calls(sessionId: "ses_root", scope: .all).count, 7)
        XCTAssertEqual(try store.calls(sessionId: "ses_root").map(\.turnIndex), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(try store.toolCalls(sessionId: "ses_root").count, 3)
        XCTAssertEqual(try store.events(sessionId: "ses_root", kind: EventKind.compaction.rawValue, scope: .all).count, 1)
    }

    func testMissingGarbageOrForeignDatabaseYieldsNothing() throws {
        let workspace = try TempWorkspace()
        let reader = OpenCodeReader()
        let missing = workspace.root.appendingPathComponent("opencode/opencode.db")
        XCTAssertTrue(reader.read(file: missing, context: LineContext(sourceFile: missing.path, fallbackSessionId: "x")).isEmpty)

        let garbage = try workspace.write("opencode.db", lines: ["this is not sqlite"])
        XCTAssertTrue(reader.read(file: garbage, context: LineContext(sourceFile: garbage.path, fallbackSessionId: "x")).isEmpty)

        let foreignURL = workspace.root.appendingPathComponent("other.db")
        let foreign = try SQLiteDatabase(path: foreignURL.path)
        try foreign.execute("CREATE TABLE message (id text, body text);")
        XCTAssertTrue(reader.read(file: foreignURL, context: LineContext(sourceFile: foreignURL.path, fallbackSessionId: "x")).isEmpty)
    }

    func testOwnsOnlyOpenCodeDatabases() {
        let env: [String: String] = [:]
        XCTAssertTrue(OpenCodePaths.isOpenCodeDatabase("/u/.local/share/opencode/opencode.db", environment: env))
        XCTAssertTrue(OpenCodePaths.isOpenCodeDatabase("/u/.local/share/opencode/opencode-dev.db", environment: env))
        XCTAssertFalse(OpenCodePaths.isOpenCodeDatabase("/u/.local/share/opencode/log/direct/1-2.jsonl", environment: env))
        XCTAssertFalse(OpenCodePaths.isOpenCodeDatabase("/u/.local/share/opencode/storage/message/ses/msg.json", environment: env))
        XCTAssertFalse(OpenCodePaths.isOpenCodeDatabase("/u/.local/share/rtk/history.db", environment: env))
        XCTAssertFalse(OpenCodePaths.isOpenCodeDatabase("/u/.claude/projects/x/s.jsonl", environment: env))
        XCTAssertFalse(OpenCodePaths.isOpenCodeDatabase("/u/elsewhere/opencode.db", environment: env))
        XCTAssertTrue(OpenCodePaths.isOpenCodeDatabase("/data/custom.db", environment: ["OPENCODE_DB": "/data/custom.db"]))

        XCTAssertEqual(Harness.owning("/u/.local/share/opencode/opencode.db-wal"), .opencode)
        XCTAssertEqual(Harness.owning("/u/.claude/projects/x/s.jsonl"), .claudeCode)
    }

    func testPathsHonorXDGAndOverride() {
        XCTAssertEqual(OpenCodePaths.databaseURL(environment: ["XDG_DATA_HOME": "/x"])?.path, "/x/opencode/opencode.db")
        XCTAssertEqual(OpenCodePaths.roots(environment: ["XDG_DATA_HOME": "/x"]).map(\.path), ["/x/opencode"])
        XCTAssertEqual(OpenCodePaths.databaseURL(environment: ["XDG_DATA_HOME": "/x", "OPENCODE_DB": "alt.db"])?.path,
                       "/x/opencode/alt.db")
        XCTAssertEqual(OpenCodePaths.databaseURL(environment: ["OPENCODE_DB": "/abs/o.db"])?.path, "/abs/o.db")
        XCTAssertNil(OpenCodePaths.databaseURL(environment: ["OPENCODE_DB": ":memory:"]))
    }

    func testCapabilitiesAreHonest() {
        let caps = Harness.opencode.capabilities
        XCTAssertEqual(caps.occupancy, .everyCall)
        XCTAssertEqual(caps.window, .lookup)
        XCTAssertTrue(caps.cacheSplit)
        XCTAssertTrue(caps.subagents)
        XCTAssertFalse(caps.verifiedOnDisk, "no OpenCode data on the Mac this was written on")
        XCTAssertFalse(caps.planLimits)
        XCTAssertFalse(Harness.opencode.owns("/a/b.jsonl"))
        XCTAssertTrue(Harness.opencode.reingestsWholeFile)
    }
}

import Foundation
import XCTest
@testable import UllageCore

/// M8 — a subagent is its own context window.
///
/// The fixtures mirror what Claude Code writes: a main transcript whose `Agent`
/// results name the children, and one file per child carrying the *parent's*
/// session id. Everything asserted here would be wrong if the two were merged.
final class AgentTests: XCTestCase {
    static let mainFixture = "agents-main.jsonl"
    static let childFixtures = [
        "agents-child-explore.jsonl",
        "agents-child-general.jsonl",
        "agents-child-nested.jsonl",
    ]
    static let sessionId = "sess-agents"

    @discardableResult
    private func ingestAll(_ workspace: TempWorkspace, childrenFirst: Bool = false) throws -> IngestStats {
        let order = childrenFirst
            ? Self.childFixtures + [Self.mainFixture]
            : [Self.mainFixture] + Self.childFixtures
        var stats = IngestStats()
        for fixture in order {
            stats = stats + (try workspace.ingestor.ingestFile(at: try workspace.copyFixture(fixture)))
        }
        return stats
    }

    // MARK: - Streams

    func testEachAgentGetsItsOwnTurnNumberingAndDeltas() throws {
        let workspace = try TempWorkspace()
        try ingestAll(workspace)
        let store = workspace.store

        let main = try store.calls(sessionId: Self.sessionId)
        XCTAssertEqual(main.map(\.dedupeKey), ["msg_m01", "msg_m02", "msg_m03"])
        XCTAssertEqual(main.map(\.turnIndex), [0, 1, 2])
        XCTAssertEqual(main.map(\.contextTokens), [21_010, 21_518, 21_822])
        XCTAssertEqual(main.map(\.contextDelta), [nil, 508, 304])
        XCTAssertTrue(main.allSatisfy { $0.agentId == nil })

        let explore = try store.calls(sessionId: Self.sessionId, scope: .agent("a-explore-1"))
        XCTAssertEqual(explore.map(\.turnIndex), [0, 1])
        XCTAssertEqual(explore.map(\.contextTokens), [12_001, 12_503])
        // The child compacted; that boundary belongs to the child's window and
        // must not null a delta on the parent's.
        XCTAssertEqual(explore.map(\.contextDelta), [nil, nil])
        XCTAssertEqual(explore.map(\.agent), ["Explore", "Explore"])

        let general = try store.calls(sessionId: Self.sessionId, scope: .agent("a-general-2"))
        XCTAssertEqual(general.map(\.turnIndex), [0, 1])
        XCTAssertEqual(general.map(\.contextDelta), [nil, 301])

        let nested = try store.calls(sessionId: Self.sessionId, scope: .agent("a-nested-3"))
        XCTAssertEqual(nested.map(\.turnIndex), [0, 1])
        XCTAssertEqual(nested.map(\.contextTokens), [6_501, 6_702])
        XCTAssertEqual(nested.map(\.contextDelta), [nil, 201])

        // Nine calls in the session, three of them the main thread's.
        XCTAssertEqual(try store.calls(sessionId: Self.sessionId, scope: .all).count, 9)
    }

    func testAgentWindowsNeverDriveTheGauge() throws {
        let workspace = try TempWorkspace()
        try ingestAll(workspace)

        XCTAssertEqual(try workspace.store.latestCall()?.dedupeKey, "msg_m03")

        // The common live case: the parent is blocked on an agent, so the newest
        // row in the database belongs to a window that is not the session's.
        let stillWorking = """
        {"parentUuid":"e-a2","isSidechain":true,"agentId":"a-explore-1","attributionAgent":"Explore",\
        "userType":"external","cwd":"/Users/dev/portal","sessionId":"sess-agents","version":"2.1.252",\
        "type":"assistant","uuid":"e-a3","timestamp":"2026-03-02T12:09:00.000Z",\
        "message":{"id":"msg_e03","type":"message","role":"assistant","model":"claude-sonnet-4-5-20250929",\
        "content":[{"type":"text","text":"one more thing"}],"stop_reason":"end_turn",\
        "usage":{"input_tokens":3,"cache_creation_input_tokens":900,"cache_read_input_tokens":12503,"output_tokens":40}}}

        """
        try workspace.append("agents-child-explore.jsonl", text: stillWorking)
        try workspace.ingestor.ingestFile(at: workspace.root.appendingPathComponent("agents-child-explore.jsonl"))

        let latest = try XCTUnwrap(try workspace.store.latestCall())
        XCTAssertEqual(latest.dedupeKey, "msg_m03")
        XCTAssertEqual(latest.contextTokens, 21_822)
        // …while the agent's own stream did move on.
        XCTAssertEqual(
            try workspace.store.latestCall(sessionId: Self.sessionId, scope: .agent("a-explore-1"))?.dedupeKey,
            "msg_e03"
        )
    }

    // MARK: - The tree

    func testSpawnTreeIsBuiltFromWhatBothSidesRecorded() throws {
        let workspace = try TempWorkspace()
        try ingestAll(workspace)
        let tree = try workspace.store.agentTree(sessionId: Self.sessionId)

        XCTAssertEqual(tree.count, 3)
        XCTAssertEqual(tree.roots.map(\.agent.agentId), ["a-explore-1", "a-general-2"])
        XCTAssertEqual(tree.flattened.map(\.depth), [0, 0, 1])

        let explore = tree.roots[0].agent
        // The label is the description one agent wrote for another — the whole
        // point of the tree, and unrecoverable from anywhere else.
        XCTAssertEqual(explore.label, "Map the intake flow")
        XCTAssertEqual(explore.displayName, "Map the intake flow")
        XCTAssertEqual(explore.agentType, "Explore")
        XCTAssertEqual(explore.status, "completed")
        XCTAssertNil(explore.statusLabel)           // a completed run says nothing
        XCTAssertFalse(explore.isUnfinished)
        XCTAssertEqual(explore.calls, 2)
        XCTAssertEqual(explore.lastContextTokens, 12_503)
        XCTAssertEqual(explore.peakContextTokens, 12_503)
        XCTAssertEqual(explore.windowLimit, 200_000)
        XCTAssertEqual(explore.toolCalls, 1)
        XCTAssertEqual(explore.reportedToolUses, 7)
        XCTAssertEqual(explore.durationMs, 61_000)
        XCTAssertEqual(try XCTUnwrap(explore.occupancy), 12_503.0 / 200_000.0, accuracy: 0.0001)

        let general = tree.roots[1]
        XCTAssertEqual(general.agent.label, "Audit the API surface")
        XCTAssertEqual(general.agent.agentType, "general-purpose")
        XCTAssertEqual(general.children.map(\.agent.agentId), ["a-nested-3"])

        // An agent spawned by an agent: the parent is the stream that made the
        // `Agent` call, not the session.
        let nested = general.children[0].agent
        XCTAssertEqual(nested.parentAgentId, "a-general-2")
        XCTAssertEqual(nested.label, "Check the migrations")
        XCTAssertEqual(nested.agentType, "Explore")
        XCTAssertEqual(nested.status, "completed")
        XCTAssertEqual(nested.lastContextTokens, 6_702)
    }

    func testTreeIsTheSameWhicheverFileIsIngestedFirst() throws {
        let forward = try TempWorkspace()
        try ingestAll(forward)
        let backward = try TempWorkspace()
        try ingestAll(backward, childrenFirst: true)

        XCTAssertEqual(
            try forward.store.agents(sessionId: Self.sessionId),
            try backward.store.agents(sessionId: Self.sessionId)
        )
    }

    func testAChildWithoutItsParentTranscriptIsStillAnAgent() throws {
        let workspace = try TempWorkspace()
        // Only the child: the parent's transcript aged out of ~/.claude, or has
        // not been read yet. Identity survives; the label does not exist.
        try workspace.ingestor.ingestFile(at: try workspace.copyFixture("agents-child-explore.jsonl"))

        let tree = try workspace.store.agentTree(sessionId: Self.sessionId)
        let agent = try XCTUnwrap(tree.roots.first?.agent)
        XCTAssertEqual(agent.agentId, "a-explore-1")
        XCTAssertEqual(agent.agentType, "Explore")
        XCTAssertNil(agent.label)
        XCTAssertEqual(agent.displayName, "Explore")
        XCTAssertNil(agent.status)
        XCTAssertTrue(agent.isUnfinished)
        XCTAssertEqual(agent.statusLabel, "no result recorded")
        XCTAssertEqual(agent.calls, 2)
    }

    func testAnOrphanedParentIdIsShownAtTheRootRatherThanDropped() {
        let child = AgentSummary(agentId: "b", sessionId: "s", parentAgentId: "gone", firstTs: "2")
        let tree = AgentTree.build(sessionId: "s", agents: [child])
        XCTAssertEqual(tree.roots.map(\.agent.agentId), ["b"])
    }

    func testAParentCycleDoesNotRecurseForever() {
        let a = AgentSummary(agentId: "a", sessionId: "s", parentAgentId: "b", firstTs: "1")
        let b = AgentSummary(agentId: "b", sessionId: "s", parentAgentId: "a", firstTs: "2")
        let tree = AgentTree.build(sessionId: "s", agents: [a, b])
        XCTAssertEqual(tree.count, 2)
    }

    // MARK: - Sessions and composition

    func testSessionSummaryCountsAgentsAndKeepsTheMainThreadsWindow() throws {
        let workspace = try TempWorkspace()
        try ingestAll(workspace)

        let summary = try XCTUnwrap(try workspace.store.recentSessions(limit: 10).first)
        XCTAssertEqual(summary.sessionId, Self.sessionId)
        XCTAssertEqual(summary.project, "portal")
        XCTAssertEqual(summary.calls, 3)          // main-thread turns only
        XCTAssertEqual(summary.agents, 3)
        XCTAssertEqual(summary.lastContextTokens, 21_822)
        XCTAssertEqual(summary.windowLimit, 1_000_000)

        let totals = try XCTUnwrap(try workspace.store.sessionTotals().first)
        XCTAssertEqual(totals.agents, 3)
        XCTAssertEqual(totals.calls, 9)           // every stream's turns are real calls
        XCTAssertEqual(totals.lastContextTokens, 21_822)
    }

    func testCompositionCanBeScopedToOneAgent() throws {
        let workspace = try TempWorkspace()
        try ingestAll(workspace)

        let session = try XCTUnwrap(try workspace.store.composition(sessionId: Self.sessionId))
        XCTAssertEqual(session.contextTokens, 21_822)

        let agent = try XCTUnwrap(
            try workspace.store.composition(sessionId: Self.sessionId, scope: .agent("a-nested-3"))
        )
        XCTAssertEqual(agent.contextTokens, 6_702)
        XCTAssertEqual(agent.baseline, 6_501)
    }

    func testSpawnsAreClassifiedAsAgentsWithTheirDescription() throws {
        let workspace = try TempWorkspace()
        try ingestAll(workspace)

        let spawns = try workspace.store.toolCalls(sessionId: Self.sessionId).filter { $0.kind == "agent" }
        XCTAssertEqual(spawns.map(\.name), ["Agent", "Agent", "Agent"])
        XCTAssertEqual(
            Set(spawns.compactMap(\.target)),
            ["Map the intake flow", "Audit the API surface", "Check the migrations"]
        )
    }

    // MARK: - The sidecar

    /// `agent-<id>.meta.json`, which Claude Code writes beside every subagent
    /// transcript. It is the only source of the agent's name that survives a
    /// parent transcript being deleted, a background agent whose result only
    /// ever said "launched", and a fork that replays the spawn elsewhere.
    private func writeSubagentTranscript(
        _ workspace: TempWorkspace,
        fixture: String,
        agentId: String,
        metadata: String
    ) throws -> URL {
        let directory = workspace.root.appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let transcript = directory.appendingPathComponent("agent-\(agentId).jsonl")
        try FileManager.default.copyItem(at: Fixtures.url(fixture), to: transcript)
        try metadata.write(
            to: directory.appendingPathComponent("agent-\(agentId).meta.json"),
            atomically: true,
            encoding: .utf8
        )
        return transcript
    }

    func testSidecarNamesAnAgentWhoseParentTranscriptIsMissing() throws {
        let workspace = try TempWorkspace()
        let transcript = try writeSubagentTranscript(
            workspace,
            fixture: "agents-child-explore.jsonl",
            agentId: "a-explore-1",
            metadata: #"{"agentType":"Explore","description":"Map the intake flow","toolUseId":"toolu_spawn1","spawnDepth":1}"#
        )
        try workspace.ingestor.ingestFile(at: transcript)

        let agent = try XCTUnwrap(try workspace.store.agents(sessionId: Self.sessionId).first)
        XCTAssertEqual(agent.label, "Map the intake flow")
        XCTAssertEqual(agent.agentType, "Explore")
        XCTAssertEqual(agent.calls, 2)
        // The spawning turn is not in the database, so the parent is unknown —
        // not guessed.
        XCTAssertNil(agent.parentAgentId)
        XCTAssertNil(agent.status)
    }

    func testParentIsResolvedWhicheverSideArrivesFirst() throws {
        let workspace = try TempWorkspace()
        // The grandchild, named only by its sidecar, ingested before anything
        // that could say which stream spawned it.
        let transcript = try writeSubagentTranscript(
            workspace,
            fixture: "agents-child-nested.jsonl",
            agentId: "a-nested-3",
            metadata: #"{"agentType":"Explore","description":"Check the migrations","toolUseId":"toolu_spawn3","spawnDepth":2}"#
        )
        try workspace.ingestor.ingestFile(at: transcript)
        XCTAssertNil(try workspace.store.agents(sessionId: Self.sessionId).first?.parentAgentId)

        // Its parent's transcript arrives later and the edge appears, because
        // the tree resolves it on read rather than freezing it at ingest.
        try workspace.ingestor.ingestFile(at: try workspace.copyFixture("agents-child-general.jsonl"))
        let nested = try XCTUnwrap(
            try workspace.store.agents(sessionId: Self.sessionId).first { $0.agentId == "a-nested-3" }
        )
        XCTAssertEqual(nested.parentAgentId, "a-general-2")
    }

    func testSidecarIsOnlyLookedForBesideSubagentTranscripts() {
        XCTAssertEqual(
            AgentMetadata.sidecarPath(forTranscript: "/x/sess/subagents/agent-a1.jsonl"),
            "/x/sess/subagents/agent-a1.meta.json"
        )
        XCTAssertNil(AgentMetadata.sidecarPath(forTranscript: "/x/sess.jsonl"))
        XCTAssertNil(AgentMetadata.read(besideTranscript: "/x/sess/subagents/agent-nope.jsonl"))
    }

    // MARK: - Repair

    func testRenumberingRebuildsExactlyWhatTheIngestorWrote() throws {
        let workspace = try TempWorkspace()
        try ingestAll(workspace)
        let before = try workspace.store.calls(sessionId: Self.sessionId, scope: .all)

        // What a pre-v2 database looks like: one counter for every stream, and
        // deltas taken between prompts that never followed each other.
        try workspace.store.database.run("UPDATE call SET turn_index = NULL, context_delta = 9999;")
        try workspace.store.renumberStreams(sessionId: Self.sessionId)

        XCTAssertEqual(try workspace.store.calls(sessionId: Self.sessionId, scope: .all), before)
    }

    /// The upgrade path: a database written before agents were a stream, where
    /// every agent's turns were numbered into the session's one counter.
    func testMigratingAPreV2DatabaseRecoversTheStreams() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ullage-migrate-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("v1.db").path
        let subagentFile = root.appendingPathComponent("sess/subagents/agent-a1.jsonl").path
        let mainFile = root.appendingPathComponent("sess.jsonl").path

        // A v1 database, written by hand: no agent_id, and one turn counter
        // shared by the main thread and the subagent.
        do {
            let database = try SQLiteDatabase(path: path)
            try database.execute(Store.schemaV1)
            try database.execute("PRAGMA user_version=1;")
            func insert(_ key: String, _ ts: String, _ sidechain: Int, _ turn: Int, _ context: Int, _ delta: Int?, _ file: String) throws {
                try database.run(
                    """
                    INSERT INTO call (dedupe_key, ts, vendor, session_id, context_tokens,
                                      window_limit, turn_index, context_delta, is_sidechain,
                                      source_file, confidence, parser_version)
                    VALUES (?1,?2,'claude-code','sess',?3,200000,?4,?5,?6,?7,'exact',2);
                    """,
                    [.text(key), .text(ts), .integer(Int64(context)), .integer(Int64(turn)),
                     .int(delta), .integer(Int64(sidechain)), .text(file)]
                )
            }
            try insert("m1", "2026-03-02T12:00:00.000Z", 0, 0, 10_000, nil, mainFile)
            try insert("m2", "2026-03-02T12:00:10.000Z", 0, 1, 11_000, 1_000, mainFile)
            try insert("s1", "2026-03-02T12:00:20.000Z", 1, 2, 3_000, -8_000, subagentFile)
            try insert("s2", "2026-03-02T12:00:30.000Z", 1, 3, 3_500, 500, subagentFile)
            try insert("m3", "2026-03-02T12:00:40.000Z", 0, 4, 12_000, 8_500, mainFile)
        }

        let store = try Store(path: path)     // migrates on open

        let main = try store.calls(sessionId: "sess")
        XCTAssertEqual(main.map(\.dedupeKey), ["m1", "m2", "m3"])
        XCTAssertEqual(main.map(\.turnIndex), [0, 1, 2])
        // The −8,000 and +8,500 were differences between two different windows.
        XCTAssertEqual(main.map(\.contextDelta), [nil, 1_000, 1_000])

        let agent = try store.calls(sessionId: "sess", scope: .agent("a1"))
        XCTAssertEqual(agent.map(\.dedupeKey), ["s1", "s2"])
        XCTAssertEqual(agent.map(\.turnIndex), [0, 1])
        XCTAssertEqual(agent.map(\.contextDelta), [nil, 500])

        // And the transcripts are queued to be read again, so the spawn tree
        // can be recovered from lines already read past.
        XCTAssertNil(try store.cursor(forPath: mainFile))
        XCTAssertNil(try store.cursor(forPath: subagentFile))
    }

    func testAgentIdIsRecoverableFromASubagentPath() {
        XCTAssertEqual(
            Store.agentId(fromTranscriptPath: "/x/projects/slug/sess/subagents/agent-a86066d140435af09.jsonl"),
            "a86066d140435af09"
        )
        XCTAssertNil(Store.agentId(fromTranscriptPath: "/x/projects/slug/sess.jsonl"))
        XCTAssertNil(Store.agentId(fromTranscriptPath: "/x/projects/slug/sess/subagents/notes.jsonl"))
    }

    // MARK: - Grouping

    func testProjectGroupsOrderByRecencyAndKeepUnknownsSeparate() {
        let sessions = [
            SessionSummary(sessionId: "s1", project: "portal", lastTs: "2026-03-02T12:00:00Z",
                           lastContextTokens: 1, calls: 1, agents: 2),
            SessionSummary(sessionId: "s2", project: "ullage", lastTs: "2026-03-02T13:00:00Z",
                           lastContextTokens: 1, calls: 1),
            SessionSummary(sessionId: "s3", project: "portal", lastTs: "2026-03-02T14:00:00Z",
                           lastContextTokens: 1, calls: 1, agents: 1),
            SessionSummary(sessionId: "s4", project: nil, lastTs: "2026-03-02T11:00:00Z",
                           lastContextTokens: 1, calls: 1),
        ]
        let groups = ProjectGroup.build(sessions: sessions)
        XCTAssertEqual(groups.map(\.project), ["portal", "ullage", ProjectGroup.unknownProject])
        XCTAssertEqual(groups[0].sessions.map(\.sessionId), ["s3", "s1"])
        XCTAssertEqual(groups[0].agents, 3)
    }
}

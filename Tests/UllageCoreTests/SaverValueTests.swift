import Foundation
import XCTest
@testable import UllageCore

/// What a context tool is worth: claims placed on the calls they name and
/// carried forward, comparisons kept to one period and one harness, and every
/// figure graded so a claim never reads as a measurement.
final class SaverValueTests: XCTestCase {
    private let at = { (s: String) in Timestamps.date(from: s)! }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ullage-value-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - rtk's ledger

    /// rtk's own schema (history.db, rtk 0.x): a row per command, and a row
    /// per Bash call its hook saw, naming Claude Code's session and call.
    private func rtkDatabase(wal: Bool = false) throws -> URL {
        let url = try temporaryDirectory().appendingPathComponent("history.db")
        try writeRtk(at: url, wal: wal)
        return url
    }

    /// Its own function so the connection is closed (and the WAL
    /// checkpointed away) before anyone reads the file.
    private func writeRtk(at url: URL, wal: Bool) throws {
        let db = try SQLiteDatabase(path: url.path)
        if wal { try db.execute("PRAGMA journal_mode=WAL;") }
        defer { if wal { try? db.execute("PRAGMA wal_checkpoint(TRUNCATE);") } }
        try db.execute("""
            CREATE TABLE commands (id INTEGER PRIMARY KEY, timestamp TEXT NOT NULL, original_cmd TEXT NOT NULL,
              rtk_cmd TEXT NOT NULL, input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL,
              saved_tokens INTEGER NOT NULL, savings_pct REAL NOT NULL, exec_time_ms INTEGER DEFAULT 0, project_path TEXT DEFAULT '');
            CREATE TABLE hook_decisions (id INTEGER PRIMARY KEY, timestamp TEXT NOT NULL, session_id TEXT NOT NULL,
              tool_use_id TEXT NOT NULL, project_path TEXT DEFAULT '', raw_cmd TEXT NOT NULL, decision TEXT NOT NULL,
              rewritten_cmd TEXT, rtk_version TEXT NOT NULL);
            INSERT INTO hook_decisions (timestamp, session_id, tool_use_id, project_path, raw_cmd, decision, rewritten_cmd, rtk_version) VALUES
              ('2026-09-01T10:00:00.000000+00:00', 's1', 'toolu_a', '/repo', 'cd sub && grep -n x .', 'ask', 'cd sub && rtk grep -n x .', '0.1'),
              ('2026-09-01T10:00:05.000000+00:00', 's2', 'toolu_b', '/repo', 'git status', 'ask', 'rtk git status', '0.1'),
              ('2026-09-01T10:00:06.000000+00:00', 's1', 'toolu_c', '/repo', 'ls | wc -l', 'defer', NULL, '0.1');
            INSERT INTO commands (timestamp, original_cmd, rtk_cmd, input_tokens, output_tokens, saved_tokens, savings_pct, project_path) VALUES
              ('2026-09-01T10:00:01.123456789+00:00', 'grep -n x .', 'rtk grep', 400, 100, 300, 75, '/repo/sub'),
              ('2026-09-01T10:00:07.000000+00:00', 'git status', 'rtk git status', 200, 50, 150, 75, '/repo'),
              ('2026-09-01T10:00:08.000000+00:00', 'cargo test', 'rtk cargo test', 900, 100, 800, 88, '/repo'),
              ('2026-09-01T11:00:00.000000+00:00', 'grep -n y .', 'rtk grep', 40, 10, 30, 75, '/repo');
            """)
    }

    func testRtkCommandsLandOnTheBashCallTheirRewriteNamed() throws {
        let entries = SaverLedgers.rtkEntries(at: try rtkDatabase())
        XCTAssertEqual(entries.count, 4)
        let byCommand = Dictionary(uniqueKeysWithValues: entries.map { ($0.command ?? "", $0) })
        XCTAssertEqual(byCommand["grep -n x ."]?.toolUseId, "toolu_a", "ran in a subfolder after a cd: still the call's")
        XCTAssertEqual(byCommand["grep -n x ."]?.sessionId, "s1")
        XCTAssertEqual(byCommand["git status"]?.toolUseId, "toolu_b")
        XCTAssertNil(byCommand["cargo test"]?.toolUseId, "no rewrite ran `rtk cargo`")
        XCTAssertNil(byCommand["grep -n y ."]?.toolUseId, "an hour after the last grep rewrite")
        XCTAssertEqual(Set(entries.map(\.id)).count, 4, "ids are stable and distinct")
    }

    /// A WAL database with no `-shm` (rtk not running) refuses a read-only
    /// open; the reader falls back to reading it as immutable.
    func testRtkLedgerReadsWhenRtkIsNotRunning() throws {
        let url = try rtkDatabase(wal: true)
        // rtk's bundled SQLite deletes both on close; Apple's keeps them, so
        // put the file in the state rtk leaves it in (checkpointed on close).
        try? FileManager.default.removeItem(atPath: url.path + "-wal")
        try? FileManager.default.removeItem(atPath: url.path + "-shm")
        XCTAssertThrowsError(try SaverLedgers.readRtk(at: url, since: nil, immutable: false), "the plain read-only open fails")
        XCTAssertEqual(SaverLedgers.rtkEntries(at: url).count, 4)
    }

    private func decision(_ ts: String, _ session: String, _ call: String, _ rewritten: String) -> SaverLedgers.RtkDecision {
        SaverLedgers.RtkDecision(ts: at(ts), sessionId: session, toolUseId: call, rewritten: rewritten)
    }

    private func command(_ ts: String, _ original: String) -> LedgerEntry {
        LedgerEntry(saver: .rtk, ts: at(ts), cwd: "/repo", command: original, beforeTokens: 10, afterTokens: 5, savedTokens: 5)
    }

    /// The hook decides before the command runs and rtk logs it when it
    /// ends, so a rewrite stamped after a command is never its owner.
    func testARewriteAfterTheCommandIsNotItsOwner() {
        var entries = [command("2026-09-01T10:00:10Z", "ls packages")]
        SaverLedgers.attribute(&entries, verbs: ["ls"], to: [
            decision("2026-09-01T10:00:02Z", "s1", "early", "rtk ls packages"),
            decision("2026-09-01T10:00:10.500Z", "s2", "late", "rtk ls Sources"),
        ])
        XCTAssertEqual(entries[0].toolUseId, "early")
    }

    func testTheVerbIsRtksOwnAndARewriteOwnsOnlyAsManyAsItRuns() {
        XCTAssertEqual(SaverLedgers.rtkVerb("rtk read src/a.swift"), "read")
        XCTAssertEqual(SaverLedgers.rtkVerb("rtk:toml swift build"), "swift")
        XCTAssertNil(SaverLedgers.rtkVerb("cat a"))
        // Two `cat`s logged as `rtk read`: one rewrite ran one, an older one ran one.
        var entries = [command("2026-09-01T10:00:05Z", "cat a.swift"), command("2026-09-01T10:00:06Z", "cat b.swift")]
        SaverLedgers.attribute(&entries, verbs: ["read", "read"], to: [
            decision("2026-09-01T10:00:01Z", "s1", "one", "rtk read b.swift"),
            decision("2026-09-01T10:00:04Z", "s1", "two", "rtk read a.swift"),
        ])
        XCTAssertEqual(entries.map(\.toolUseId), ["two", "one"], "each by its argument; `two` runs only one")
        var three = [command("2026-09-01T10:00:05Z", "ls x"), command("2026-09-01T10:00:06Z", "ls y"), command("2026-09-01T10:00:07Z", "ls z")]
        SaverLedgers.attribute(&three, verbs: ["ls", "ls", "ls"], to: [decision("2026-09-01T10:00:01Z", "s1", "both", "rtk ls x; rtk ls y")])
        XCTAssertEqual(three.map(\.toolUseId), ["both", "both", nil], "a rewrite running two owns two")
    }

    func testAProxyRowGoesToTheOneSessionWithTheNearestTurn() throws {
        let store = try Store.inMemory()
        try store.upsert(call: call("2026-09-01T10:00:00.000Z", session: "a"))
        try store.upsert(call: call("2026-09-01T10:00:08.000Z", session: "b"))
        let entry = LedgerEntry(saver: .headroom, ts: at("2026-09-01T10:00:06Z"), cwd: nil, command: "proxied request",
                                beforeTokens: nil, afterTokens: nil, savedTokens: 500, id: "h:1")
        let far = LedgerEntry(saver: .headroom, ts: at("2026-09-01T11:00:00Z"), cwd: nil, command: "proxied request",
                              beforeTokens: nil, afterTokens: nil, savedTokens: 9, id: "h:2")
        let placed = store.place([entry, far])
        XCTAssertEqual(placed.map(\.sessionId), ["b", nil])
        let reports = ["a", "b"].map { id in
            SaverReport.build(sessionId: id, calls: [call(id == "a" ? "2026-09-01T10:00:00.000Z" : "2026-09-01T10:00:08.000Z", session: id)],
                              toolCalls: [], events: [], sessionEnv: nil, ledger: placed)
        }
        XCTAssertEqual(reports.map { $0.usage(.headroom).ledgerEntries.count }, [0, 1], "counted in one session, not both")
    }

    func testRunsMatchesAWholeRtkCommand() {
        XCTAssertTrue(SaverLedgers.runs("grep", in: "cd x && rtk grep -n a ."))
        XCTAssertTrue(SaverLedgers.runs("git", in: "rtk git status"))
        XCTAssertFalse(SaverLedgers.runs("git", in: "rtk gitk"))
        XCTAssertFalse(SaverLedgers.runs("grep", in: "echo artk grep"))
    }

    // MARK: - Headroom's proxy log

    func testHeadroomRunningTotalBecomesOneClaimPerRequest() {
        let json = #"{"schema_version":2,"history":[{"timestamp":"2026-06-08T17:48:09Z","total_tokens_saved":2313,"total_input_tokens":13430},{"timestamp":"2026-06-08T17:48:19Z","total_tokens_saved":3000,"total_input_tokens":28835},{"timestamp":"2026-06-08T17:49:00Z","total_tokens_saved":3000},{"timestamp":"bad","total_tokens_saved":9}]}"#
        let entries = SaverLedgers.headroomEntries(json: Data(json.utf8), since: nil)
        XCTAssertEqual(entries.map(\.savedTokens), [2313, 687], "first point from zero; no step, no claim")
        XCTAssertTrue(entries.allSatisfy { $0.cwd == nil }, "a proxy names no folder")
        XCTAssertEqual(entries.map(\.afterTokens), [13430, 15405], "what it sent since the previous point")
        XCTAssertEqual(entries.map(\.beforeTokens), [13430 + 2313, 15405 + 687])
        let since = SaverLedgers.headroomEntries(json: Data(json.utf8), since: at("2026-06-08T17:48:10Z"))
        XCTAssertEqual(since.map(\.savedTokens), [687])
    }

    func testTrimmedHeadroomHistoryDoesNotCountItsFirstPoint() {
        let points = (0..<SaverLedgers.headroomHistoryCap).map { i in
            #"{"timestamp":"\#(Timestamps.string(from: Date(timeIntervalSince1970: 1_780_000_000 + Double(i))))","total_tokens_saved":\#(1_000_000 + i * 10)}"#
        }
        let json = #"{"history":[\#(points.joined(separator: ","))]}"#
        let entries = SaverLedgers.headroomEntries(json: Data(json.utf8), since: nil)
        XCTAssertEqual(entries.count, SaverLedgers.headroomHistoryCap - 1)
        XCTAssertEqual(entries.first?.savedTokens, 10, "not the million saved before the trimmed history began")
    }

    // MARK: - Matching to a session

    private func call(_ ts: String, session: String = "s1", agent: String? = nil, context: Int = 1000) -> CallRow {
        CallRow(dedupeKey: "m-\(session)-\(agent ?? "")-\(ts)", ts: ts, agentId: agent, sessionId: session, cwd: "/repo",
                contextTokens: context, sourceFile: "t.jsonl")
    }

    func testANamedSessionBeatsFolderAndTime() {
        let ledger = [
            LedgerEntry(saver: .rtk, ts: at("2026-09-01T09:00:00Z"), cwd: "/elsewhere", command: "ls",
                        beforeTokens: 10, afterTokens: 5, savedTokens: 5, id: "rtk:1", sessionId: "s1", toolUseId: "t1"),
            LedgerEntry(saver: .rtk, ts: at("2026-09-01T10:01:00Z"), cwd: "/repo", command: "ls",
                        beforeTokens: 10, afterTokens: 5, savedTokens: 7, id: "rtk:2", sessionId: "s2", toolUseId: "t2"),
        ]
        let calls = [call("2026-09-01T10:00:00.000Z"), call("2026-09-01T10:03:00.000Z")]
        let report = SaverReport.build(sessionId: "s1", calls: calls, toolCalls: [], events: [], sessionEnv: nil, ledger: ledger)
        XCTAssertEqual(report.usage(.rtk).ledgerEntries.map(\.id), ["rtk:1"],
                       "outside the session's span and folder, but it names s1; the other names s2")
    }

    func testAProxyClaimMatchesTheTurnItWasSentWith() {
        let ledger = [
            LedgerEntry(saver: .headroom, ts: at("2026-09-01T10:00:20Z"), cwd: nil, command: "proxied request",
                        beforeTokens: nil, afterTokens: nil, savedTokens: 500, id: "h:1"),
            LedgerEntry(saver: .headroom, ts: at("2026-09-01T10:01:30Z"), cwd: nil, command: "proxied request",
                        beforeTokens: nil, afterTokens: nil, savedTokens: 900, id: "h:2"),
        ]
        let calls = [call("2026-09-01T10:00:00.000Z"), call("2026-09-01T10:03:00.000Z")]
        let report = SaverReport.build(sessionId: "s1", calls: calls, toolCalls: [], events: [], sessionEnv: nil, ledger: ledger)
        XCTAssertEqual(report.usage(.headroom).ledgerEntries.map(\.id), ["h:1"], "the second is 90 s from any turn")
        XCTAssertTrue(report.usage(.headroom).ran, "a matched proxy claim means it ran")
    }

    func testOneClaimMatchedToTwoSessionsCountsOnceOverARange() {
        let entry = LedgerEntry(saver: .headroom, ts: at("2026-09-01T10:00:05Z"), cwd: nil, command: "proxied request",
                                beforeTokens: nil, afterTokens: nil, savedTokens: 500, id: "h:1")
        let reports = ["s1", "s2"].map { id in
            SaverReport.build(sessionId: id, calls: [call("2026-09-01T10:00:00.000Z", session: id)],
                              toolCalls: [], events: [], sessionEnv: nil, ledger: [entry])
        }
        XCTAssertEqual(reports.map { $0.usage(.headroom).ledgerEntries.count }, [1, 1])
        let detail = SaverDetail.build(saver: .headroom, range: .week, reports: reports)
        XCTAssertEqual(detail.ledger?.savedTokens, 500)
        XCTAssertNil(detail.carried, "a per-request claim is never carried forward")
    }

    // MARK: - Placing and carrying

    func testPlacementCountsLaterPromptsInItsOwnStreamUpToACompaction() throws {
        let store = try Store.inMemory()
        for ts in ["10:00", "10:01", "10:02", "10:03", "10:05", "10:06"] {
            try store.upsert(call: call("2026-09-01T\(ts):00.000Z"))
        }
        // A subagent's turns are its own stream.
        try store.upsert(call: call("2026-09-01T10:01:30.000Z", agent: "a1"))
        try store.upsert(call: call("2026-09-01T10:02:30.000Z", agent: "a1"))
        _ = try store.insert(event: EventRow(id: "e1", sessionId: "s1", ts: "2026-09-01T10:04:00.000Z", kind: EventKind.compaction.rawValue))
        try store.upsert(toolCall: ToolCallRow(id: "t1", callId: "m-s1--2026-09-01T10:01:00.000Z", sessionId: "s1",
                                               ts: "2026-09-01T10:01:00.000Z", name: "Bash", kind: "bash",
                                               target: "rtk git status", resultTokens: 50))
        try store.upsert(toolCall: ToolCallRow(id: "t2", callId: "m-s1-a1-2026-09-01T10:01:30.000Z", sessionId: "s1",
                                               ts: "2026-09-01T10:01:30.000Z", name: "Bash", kind: "bash", target: "ls"))
        let placements = try store.placements(toolUseIds: ["t1", "t2", "missing"])
        XCTAssertEqual(placements["t1"]?.prompts, 2, "10:02 and 10:03; the compaction at 10:04 ends it")
        XCTAssertEqual(placements["t1"]?.resultTokens, 50)
        XCTAssertEqual(placements["t2"]?.prompts, 1, "the agent's own next turn, not the parent's")
        XCTAssertNil(placements["missing"])
    }

    func testCarriedClaimMultipliesEachCallsClaimByItsPrompts() {
        func entry(_ id: String, _ call: String?, saved: Int, after: Int) -> LedgerEntry {
            LedgerEntry(saver: .rtk, ts: at("2026-09-01T10:00:00Z"), cwd: "/repo", command: "ls",
                        beforeTokens: saved + after, afterTokens: after, savedTokens: saved, id: id, toolUseId: call)
        }
        let entries = [
            entry("1", "a", saved: 100, after: 40), // one command, simple call: checkable
            entry("2", "b", saved: 50, after: 10), entry("3", "b", saved: 30, after: 10), // two commands in one call
            entry("4", nil, saved: 999, after: 1),  // never placed
        ]
        let placements: [String: CarriedClaim.Placement] = [
            "a": .init(prompts: 10, resultTokens: 44, command: "cd sub && ls 2>&1"),
            "b": .init(prompts: 3, resultTokens: 25, command: "ls && git status"),
        ]
        let carried = CarriedClaim.build(entries: entries, placements: placements)
        XCTAssertEqual(carried?.promptTokens, 100 * 10 + 80 * 3)
        XCTAssertEqual(carried?.placedEntries, 3)
        XCTAssertEqual(carried?.entries, 4)
        XCTAssertEqual(carried?.placedSaved, 180)
        XCTAssertEqual(carried?.meanPrompts ?? 0, 6.5, accuracy: 0.001)
        XCTAssertEqual(carried?.checkedCalls, 1, "only the single-command call")
        XCTAssertEqual(carried?.claimedAfter, 40)
        XCTAssertEqual(carried?.seenAfter, 44)
        XCTAssertEqual(carried?.agreement ?? 0, 40.0 / 44.0, accuracy: 0.001)
        XCTAssertNil(CarriedClaim.build(entries: [entries[3]], placements: placements))
    }

    func testOnlyTheSameCommandIsChecked() {
        let row = LedgerEntry(saver: .rtk, ts: at("2026-09-01T10:00:00Z"), cwd: "/repo", command: "cat Harness.swift",
                              beforeTokens: 2351, afterTokens: 2351, savedTokens: 0, id: "1", toolUseId: "a")
        let fiveFiles = CarriedClaim.Placement(prompts: 3, resultTokens: 6886, command: "cd /x && cat Harness.swift CodexParser.swift")
        XCTAssertEqual(CarriedClaim.build(entries: [row], placements: ["a": fiveFiles])?.checkedCalls, 0,
                       "rtk logged one file of the call's two")
        let same = CarriedClaim.Placement(prompts: 3, resultTokens: 2400, command: "cd /x && cat 'Harness.swift' 2>&1")
        XCTAssertEqual(CarriedClaim.build(entries: [row], placements: ["a": same])?.checkedCalls, 1)
    }

    func testSingleCommand() {
        XCTAssertTrue(CarriedClaim.isSingleCommand("grep -n x ."))
        XCTAssertTrue(CarriedClaim.isSingleCommand("cd ~/repo && git status 2>&1"))
        XCTAssertFalse(CarriedClaim.isSingleCommand("grep x | head"))
        XCTAssertFalse(CarriedClaim.isSingleCommand("ls; cat a"))
        XCTAssertFalse(CarriedClaim.isSingleCommand("echo $(date)"))
        XCTAssertFalse(CarriedClaim.isSingleCommand("cd a && ls && cat b"))
    }

    // MARK: - With and without

    func testComparisonNeedsEnoughOnEachSide() {
        let samples = { (n: Int, value: Int) in (0..<n).map { SaverComparison.Sample(sessionId: "s\(value)-\($0)", value: value + $0) } }
        XCTAssertNil(SaverComparison.build(.firstPrompt, with: samples(4, 100), without: samples(9, 50)))
        let c = SaverComparison.build(.firstPrompt, with: samples(5, 100), without: samples(5, 50), scope: .everywhere)
        XCTAssertEqual(c?.with.median, 102)
        XCTAssertEqual(c?.without.median, 52)
        XCTAssertEqual(c?.scope, .everywhere)
    }

    func testComparisonKeepsBothSidesToThePeriodTheyShare() {
        var samples = Store.ComparisonSamples()
        // The tool ran on even days from the 20th. First prompts grew for
        // everyone on the 20th (a new Claude Code), tool or not.
        let on = { (id: String) in (Int(id.dropFirst()) ?? 0) >= 20 && (Int(id.dropFirst()) ?? 0) % 2 == 0 }
        for day in 1...30 {
            let id = "s\(day)"
            samples.sessions.append(id)
            samples.firstPrompt[id] = on(id) ? 60_000 : (day >= 20 ? 58_000 : 40_000)
            samples.started[id] = String(format: "2026-09-%02dT10:00:00.000Z", day)
        }
        let c = samples.split(.firstPrompt, samples.firstPrompt, by: on, scope: .folder)
        XCTAssertEqual(c?.with.count, 5, "20th–28th; the 30th is after the last session without it")
        XCTAssertEqual(c?.without.count, 5, "21st–29th, not the month before the tool")
        XCTAssertEqual(c?.without.median, 58_000, "not 40k: the older version's prompts are left out")
    }

    func testStoreComparesFirstPromptsWithinOneHarness() throws {
        let store = try Store.inMemory()
        // Twelve Claude sessions in /repo, alternating: Headroom loaded (bigger
        // first prompt) and not. Six of each, five of each in the shared period.
        for i in 0..<12 {
            let id = "c\(i)"
            let ts = String(format: "2026-09-%02dT10:00:00.000Z", 10 + i)
            try store.upsert(call: CallRow(dedupeKey: "k\(i)", ts: ts, sessionId: id, cwd: "/repo",
                                           contextTokens: i % 2 == 0 ? 30_000 : 22_000, turnIndex: 0, sourceFile: "f"))
            if i % 2 == 0 {
                try store.upsert(sessionEnv: SessionEnvRow(sessionId: id, capturedAt: ts, mcpServers: #"["headroom"]"#))
            }
        }
        // Codex sessions in the same folder never count.
        for i in 0..<6 {
            try store.upsert(call: CallRow(dedupeKey: "x\(i)", ts: String(format: "2026-09-%02dT11:00:00.000Z", 10 + i),
                                           vendor: Vendor.codex, sessionId: "x\(i)", cwd: "/repo",
                                           contextTokens: 5_000, turnIndex: 0, sourceFile: "f"))
        }
        let detail = try store.saverDetail(.headroom, range: .month, sessionId: "c11", ledger: [],
                                           now: at("2026-09-25T00:00:00Z"))
        let first = try XCTUnwrap(detail.comparisons.first { $0.metric == .firstPrompt })
        XCTAssertEqual(first.with.median, 30_000)
        XCTAssertEqual(first.without.median, 22_000)
        XCTAssertEqual(first.without.count, 5, "the Codex sessions are another harness")
        XCTAssertEqual(first.scope, .folder)
        XCTAssertEqual(detail.value.comparisons.first?.evidence, .compared)
    }

    // MARK: - Value figures

    private func detail(_ saver: TokenSaver, configure: (inout SaverDetail) -> Void) -> SaverDetail {
        var detail = SaverDetail.build(saver: saver, range: .session, reports: [])
        configure(&detail)
        return detail
    }

    func testAnOutputFiltersClaimIsGradedAndCarried() {
        let value = detail(.rtk) {
            $0.ledger = LedgerMatch(entries: 10, savedTokens: 26_000, beforeTokens: 80_000, afterTokens: 54_000, groups: [])
            $0.carried = CarriedClaim(placedEntries: 9, entries: 10, placedSaved: 25_000, promptTokens: 3_400_000,
                                      meanPrompts: 48, checkedCalls: 7, claimedAfter: 1_600, seenAfter: 1_610)
            $0.comparisons = [SaverComparison(metric: .firstPrompt, with: .init(median: 53_000, count: 5, sessions: 5),
                                              without: .init(median: 52_000, count: 5, sessions: 5))]
        }.value
        XCTAssertEqual(value.benefits.map(\.evidence), [.claimed, .derived])
        XCTAssertEqual(value.benefits[0].value, "≈26k")
        XCTAssertEqual(value.benefits[0].label, "Bash output")
        XCTAssertTrue(value.benefits[0].detail.contains("matches the transcript on 7 single-command calls"))
        XCTAssertFalse(value.benefits[0].warning, "1,600 vs 1,610 matches")
        XCTAssertEqual(value.benefits[1].value, "≈3.4M")
        XCTAssertTrue(value.benefits[1].secondary, "drawn small, after the claim it multiplies")
        XCTAssertTrue(value.benefits[1].detail.contains("9 of 10 commands matched to a call"))
        XCTAssertTrue(value.costs.isEmpty, "a comparison is neither a saving nor a cost")
        XCTAssertEqual(value.comparisons.map(\.label), ["First prompt"])
        XCTAssertEqual(value.comparisons[0].value, "53k with · 52k without", "no ≈, no difference")
        XCTAssertTrue(value.comparisons[0].detail.contains("few sessions"))
        XCTAssertTrue(value.comparisons[0].detail.contains("no clear difference"))
    }

    func testTooFewChecksShowNoCheck() {
        let value = detail(.rtk) {
            $0.ledger = LedgerMatch(entries: 1, savedTokens: 100, beforeTokens: 200, afterTokens: 100, groups: [])
            $0.carried = CarriedClaim(placedEntries: 1, entries: 1, placedSaved: 100, promptTokens: 0,
                                      meanPrompts: 0, checkedCalls: 2, claimedAfter: 17, seenAfter: 17)
        }.value
        XCTAssertEqual(value.benefits.map(\.evidence), [.claimed])
        XCTAssertFalse(value.benefits[0].detail.contains("transcript"), "two calls agreeing says nothing")
    }

    func testADisagreeingAfterIsAWarning() {
        let value = detail(.rtk) {
            $0.ledger = LedgerMatch(entries: 1, savedTokens: 100, beforeTokens: 200, afterTokens: 100, groups: [])
            $0.carried = CarriedClaim(placedEntries: 1, entries: 1, placedSaved: 100, promptTokens: 0,
                                      meanPrompts: 0, checkedCalls: 3, claimedAfter: 100, seenAfter: 300)
        }.value
        XCTAssertEqual(value.benefits.map(\.evidence), [.claimed], "no prompts, no carried figure")
        XCTAssertTrue(value.benefits[0].warning)
        XCTAssertTrue(value.benefits[0].detail.contains("doesn't match the transcript (≈100 vs ≈300)"))
    }

    func testAPerRequestClaimIsNotCalledOutput() {
        let value = detail(.headroom) {
            $0.ledger = LedgerMatch(entries: 129, savedTokens: 90_000, beforeTokens: nil, afterTokens: nil, groups: [])
            $0.sessionsIdle = 1
        }.value
        XCTAssertEqual(value.benefits.map(\.label), ["Requests"])
        XCTAssertTrue(value.benefits[0].detail.contains("129 requests"))
        XCTAssertEqual(value.costs.map(\.label), ["Loaded, never used"])
        XCTAssertEqual(value.costs[0].value, "this session")
        XCTAssertTrue(value.costs[0].warning)
    }

    func testMemoryAndReplyStyleFigures() {
        let memory = detail(TokenSaver(BuiltinTools.claudeMem)) {
            $0.injectedBytes = 8_000
            $0.sessionsInjected = 2
        }.value
        XCTAssertEqual(memory.costs.map(\.value), ["≈1.0k"], "8,000 bytes over two sessions, ÷ 4")
        XCTAssertTrue(memory.benefits.isEmpty, "no comparison yet, so no benefit is claimed for it")

        let reply = detail(.caveman) {
            $0.comparisons = [SaverComparison(OutputComparison(withMedian: 300, withTurns: 40, withSessions: 3,
                                                               withoutMedian: 700, withoutTurns: 90, withoutSessions: 6))]
        }.value
        XCTAssertTrue(reply.benefits.isEmpty)
        XCTAssertEqual(reply.comparisons.map(\.label), ["Output per reply"])
        XCTAssertEqual(reply.comparisons[0].value, "300 with · 700 without")
        XCTAssertEqual(reply.comparisons[0].evidence, .compared)
        XCTAssertFalse(reply.comparisons[0].detail.contains("few sessions"), "40 and 90 replies")
    }

    func testEvidenceMarksAndLegend() {
        XCTAssertEqual(Evidence.claimed.mark, "≈")
        XCTAssertEqual(Evidence.derived.mark, "≈")
        XCTAssertEqual(Evidence.compared.mark, "")
        let figures = [ValueFigure(.cost, "a", "1", .compared, ""), ValueFigure(.benefit, "b", "≈2", .claimed, "")]
        XCTAssertEqual(Evidence.legend(for: figures), [Evidence.claimed.explanation, Evidence.compared.explanation],
                       "fixed order, each once")
    }

    func testOverviewKeepsRegistryOrderAndNamesTheQuiet() {
        let details = [
            detail(.rtk) { $0.ledger = LedgerMatch(entries: 1, savedTokens: 10, beforeTokens: nil, afterTokens: nil, groups: []) },
            detail(.tokenade) { _ in },
            detail(.headroom) { $0.sessionsIdle = 3 },
        ]
        let overview = SaverValue.overview(details)
        XCTAssertEqual(overview.shown.map(\.saver), [.rtk, .headroom])
        XCTAssertEqual(overview.quiet, [.tokenade])
    }
}

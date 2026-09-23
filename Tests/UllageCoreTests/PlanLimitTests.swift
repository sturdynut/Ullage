import Foundation
import XCTest
@testable import UllageCore

/// Plan limits: the usage endpoint's body, Codex's on-disk readings, the store's
/// newest-wins rule, and the display rules — all without a network or a UI.
final class PlanLimitTests: XCTestCase {
    private let observed = "2026-09-23T04:00:00.000Z"

    /// Trimmed from a real response (2026-09-23). The code-named keys are kept
    /// on purpose: they must be ignored, not break the parse.
    private let usageBody = """
    {
      "five_hour": {"utilization": 73.0, "resets_at": "2026-09-23T06:50:00.313012+00:00"},
      "seven_day": {"utilization": 29.0, "resets_at": "2026-09-28T08:00:00.313033+00:00"},
      "seven_day_opus": null,
      "nimbus_quill": {"utilization": 0.0, "resets_at": null},
      "extra_usage": {"is_enabled": false},
      "limits": [
        {"kind": "session", "group": "session", "percent": 73, "severity": "normal",
         "resets_at": "2026-09-23T06:50:00.313012+00:00", "scope": null, "is_active": true},
        {"kind": "weekly_all", "group": "weekly", "percent": 29, "severity": "normal",
         "resets_at": "2026-09-28T08:00:00.313033+00:00", "scope": null, "is_active": false},
        {"kind": "weekly_scoped", "group": "weekly", "percent": 42, "severity": "normal",
         "resets_at": "2026-09-28T08:00:00.313195+00:00",
         "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}, "is_active": false}
      ]
    }
    """

    // MARK: Claude

    func testUsageBodyBecomesOneRowPerLimit() {
        let rows = ClaudeUsageParser.parse(Data(usageBody.utf8), observedAt: observed)
        XCTAssertEqual(rows.map(\.label), ["5-hour", "Weekly", "Weekly · Fable"])
        XCTAssertEqual(rows.map(\.usedPercent), [73, 29, 42])
        XCTAssertEqual(rows.map(\.limitKey), ["session", "weekly_all", "weekly_scoped:Fable"])
        XCTAssertEqual(rows.map(\.isScoped), [false, false, true])
        XCTAssertEqual(rows[0].windowMinutes, 300)
        XCTAssertEqual(rows[1].windowMinutes, 10_080)
        // Microsecond, offset-bearing timestamps are normalised like every other ts.
        XCTAssertEqual(rows[0].resetsAt, "2026-09-23T06:50:00.313Z")
        XCTAssertTrue(rows.allSatisfy { $0.source == PlanLimitSource.api && $0.vendor == Vendor.claudeCode })
    }

    func testFallsBackToTheTopLevelWindowsWithoutALimitsList() {
        let body = #"{"five_hour": {"utilization": 12.5, "resets_at": "2026-09-23T06:50:00Z"}, "seven_day": null}"#
        let rows = ClaudeUsageParser.parse(Data(body.utf8), observedAt: observed)
        XCTAssertEqual(rows.map(\.limitKey), ["five_hour"])
        XCTAssertEqual(rows.first?.usedPercent, 12.5)
    }

    func testAnUnknownShapeYieldsNothingRatherThanThrowing() {
        XCTAssertEqual(ClaudeUsageParser.parse(Data("not json".utf8), observedAt: observed), [])
        XCTAssertEqual(ClaudeUsageParser.parse(Data(#"{"limits": [{"kind": 3}]}"#.utf8), observedAt: observed), [])
    }

    func testCredentialBlobParsesAndExpires() {
        let blob = #"{"claudeAiOauth": {"accessToken": "tok", "expiresAt": 1790145617784, "subscriptionType": "max"}}"#
        let token = ClaudeOAuthToken.parse(Data(blob.utf8))
        XCTAssertEqual(token?.accessToken, "tok")
        XCTAssertEqual(token?.subscriptionType, "max")
        XCTAssertEqual(token?.isExpired(now: Date(timeIntervalSince1970: 1_790_145_000)), false)
        XCTAssertEqual(token?.isExpired(now: Date(timeIntervalSince1970: 1_790_146_000)), true)
        XCTAssertNil(ClaudeOAuthToken.parse(Data(#"{"other": {}}"#.utf8)))
    }

    func testAnExpiredTokenIsNeverSent() {
        let token = ClaudeOAuthToken(accessToken: "tok", expiresAt: Date(timeIntervalSince1970: 0), subscriptionType: nil)
        XCTAssertThrowsError(try ClaudeUsageClient.fetch(token: token)) {
            XCTAssertEqual($0 as? ClaudeUsageError, .tokenExpired)
        }
    }

    // MARK: Codex

    private func rateLimits(limitId: String? = "codex", primary: Double = 9, secondary: Double = 68) -> [String: Any] {
        var limits: [String: Any] = [
            "primary": ["used_percent": primary, "window_minutes": 300, "resets_at": 1_790_146_000],
            "secondary": ["used_percent": secondary, "window_minutes": 10_080, "resets_at": 1_790_416_067],
            "credits": ["has_credits": false],
        ]
        if let limitId { limits["limit_id"] = limitId }
        return limits
    }

    func testCodexRateLimitsNameTheirWindows() {
        let rows = CodexRateLimits.parse(rateLimits(), observedAt: observed)
        XCTAssertEqual(rows.map(\.label), ["5-hour", "Weekly"])
        XCTAssertEqual(rows.map(\.limitKey), ["codex:primary", "codex:secondary"])
        XCTAssertEqual(rows[0].resetsAt, Timestamps.string(from: Date(timeIntervalSince1970: 1_790_146_000)))
        XCTAssertEqual(rows[0].source, PlanLimitSource.transcript)
        XCTAssertFalse(rows[0].isScoped)
    }

    func testPerModelCodexLimitIsScopedAndSortsAfterThePlan() {
        let scoped = CodexRateLimits.parse(rateLimits(limitId: "base_model_inference"), observedAt: observed)
        XCTAssertTrue(scoped.allSatisfy(\.isScoped))
        XCTAssertEqual(scoped.first?.label, "5-hour · base_model_inference")
        let plan = CodexRateLimits.parse(rateLimits(), observedAt: observed)
        let ordered = PlanLimitFormatter.displays(for: scoped + plan, now: Date(timeIntervalSince1970: 1_790_140_000))
        XCTAssertEqual(ordered.map(\.limitKey).prefix(2), ["codex:primary", "codex:secondary"])
    }

    func testTokenCountLineCarriesLimitsWithOrWithoutACall() {
        let parser = CodexParser()
        let context = LineContext(sourceFile: "/x/rollout-abc.jsonl", fallbackSessionId: "s")
        func line(_ info: Any) -> Data {
            try! JSONSerialization.data(withJSONObject: [
                "type": "event_msg", "ordinal": 5, "timestamp": "2026-09-23T03:47:16.316Z",
                "payload": ["type": "token_count", "info": info, "rate_limits": rateLimits()],
            ] as [String: Any])
        }
        let withUsage = parser.parse(line: line(["last_token_usage": ["input_tokens": 100, "output_tokens": 5]]), context: context)
        guard case .call(let call)? = withUsage else { return XCTFail("expected a call") }
        XCTAssertEqual(call.planLimits.count, 2)
        XCTAssertEqual(call.planLimits.first?.observedAt, "2026-09-23T03:47:16.316Z")

        guard case .planLimits(let limits)? = parser.parse(line: line(NSNull()), context: context) else {
            return XCTFail("a usage-free line still reports limits")
        }
        XCTAssertEqual(limits.count, 2)
    }

    // MARK: Store

    private func row(_ key: String, used: Double, at observedAt: String, vendor: String = Vendor.codex, source: String = PlanLimitSource.transcript) -> PlanLimitRow {
        PlanLimitRow(vendor: vendor, limitKey: key, label: key, usedPercent: used,
                     resetsAt: nil, windowMinutes: 300, observedAt: observedAt, source: source)
    }

    func testAnOlderReadingNeverOverwritesANewerOne() throws {
        let store = try Store.inMemory()
        try store.upsert(planLimit: row("codex:primary", used: 40, at: "2026-09-23T04:00:00.000Z"))
        // Codex files are re-read from the top: the older line arrives second.
        try store.upsert(planLimit: row("codex:primary", used: 10, at: "2026-09-23T03:00:00.000Z"))
        XCTAssertEqual(try store.planLimits().map(\.usedPercent), [40])
        try store.upsert(planLimit: row("codex:primary", used: 55, at: "2026-09-23T05:00:00.000Z"))
        XCTAssertEqual(try store.planLimits().map(\.usedPercent), [55])
    }

    func testAFetchReplacesThatVendorsFetchedLimitsOnly() throws {
        let store = try Store.inMemory()
        try store.upsert(planLimit: row("codex:primary", used: 9, at: observed))
        try store.replacePlanLimits(vendor: Vendor.claudeCode, source: PlanLimitSource.api, with: [
            row("session", used: 70, at: observed, vendor: Vendor.claudeCode, source: PlanLimitSource.api),
            row("weekly_scoped:Opus", used: 5, at: observed, vendor: Vendor.claudeCode, source: PlanLimitSource.api),
        ])
        try store.replacePlanLimits(vendor: Vendor.claudeCode, source: PlanLimitSource.api, with: [
            row("session", used: 72, at: observed, vendor: Vendor.claudeCode, source: PlanLimitSource.api),
        ])
        let keys = try store.planLimits().map { "\($0.vendor)/\($0.limitKey)" }.sorted()
        XCTAssertEqual(keys, ["claude-code/session", "codex/codex:primary"])
    }

    func testWindowUsageKeepsTheFourCountersApart() throws {
        let store = try Store.inMemory()
        for (index, ts) in ["2026-09-23T01:00:00.000Z", "2026-09-23T03:00:00.000Z"].enumerated() {
            try store.upsert(call: CallRow(
                dedupeKey: "m\(index)", ts: ts, vendor: Vendor.claudeCode, sessionId: "s",
                input: 1, output: 10, cacheRead: 100, cacheWrite: 1_000,
                contextTokens: 1_101, sourceFile: "s.jsonl"
            ))
        }
        let usage = try store.windowUsage(vendor: Vendor.claudeCode, since: "2026-09-23T02:00:00.000Z")
        XCTAssertEqual(usage, Store.WindowUsage(calls: 1, input: 1, output: 10, cacheRead: 100, cacheWrite: 1_000))
        XCTAssertEqual(try store.windowUsage(vendor: Vendor.codex, since: "2026-09-23T00:00:00.000Z").calls, 0)
    }

    // MARK: Display

    func testAReadingFromBeforeTheResetSaysNothingAboutNow() {
        let now = Date(timeIntervalSince1970: 1_790_150_000)
        var limit = row("codex:primary", used: 90, at: Timestamps.string(from: now.addingTimeInterval(-7_200)))
        limit.resetsAt = Timestamps.string(from: now.addingTimeInterval(-60))
        let display = PlanLimitFormatter.displays(for: [limit], now: now)[0]
        XCTAssertTrue(display.hasResetSinceReading)
        XCTAssertNil(display.usedFraction)
        XCTAssertNil(display.windowStart)
        XCTAssertEqual(PlanLimitFormatter.caption(for: display, now: now), "reset since last reading")
    }

    func testCaptionShowsWhatIsLeftWhenItResetsAndHowOldTheReadingIs() {
        let now = Date(timeIntervalSince1970: 1_790_150_000)
        var limit = row("codex:primary", used: 73.6, at: Timestamps.string(from: now.addingTimeInterval(-3_000)))
        limit.resetsAt = Timestamps.string(from: now.addingTimeInterval(2 * 3_600 + 600))
        let display = PlanLimitFormatter.displays(for: [limit], now: now)[0]
        // Floored like every other percentage: 26.4% left reads 26%.
        XCTAssertEqual(PlanLimitFormatter.caption(for: display, now: now), "26% left · resets in 2h 10m · as of 50m ago")
        XCTAssertEqual(display.windowStart, now.addingTimeInterval(2 * 3_600 + 600 - 300 * 60))
        XCTAssertFalse(display.isWarning)

        limit.observedAt = Timestamps.string(from: now)
        limit.usedPercent = 90
        let fresh = PlanLimitFormatter.displays(for: [limit], now: now)[0]
        XCTAssertFalse(fresh.isStale)
        XCTAssertTrue(fresh.isWarning)
        XCTAssertEqual(PlanLimitFormatter.caption(for: fresh, now: now), "10% left · resets in 2h 10m")
    }

    func testDurationUsesTwoUnitsAtMost() {
        XCTAssertEqual(PlanLimitFormatter.duration(20), "<1m")
        XCTAssertEqual(PlanLimitFormatter.duration(45 * 60), "45m")
        XCTAssertEqual(PlanLimitFormatter.duration(2 * 3_600), "2h")
        XCTAssertEqual(PlanLimitFormatter.duration(2 * 3_600 + 10 * 60 + 59), "2h 10m")
        XCTAssertEqual(PlanLimitFormatter.duration(4 * 86_400 + 3 * 3_600 + 59 * 60), "4d 3h")
        XCTAssertEqual(PlanLimitFormatter.duration(-5), "<1m")
    }
}

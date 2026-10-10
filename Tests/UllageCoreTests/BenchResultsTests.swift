import XCTest
@testable import UllageCore

final class BenchResultsTests: XCTestCase {
    private func row(_ setup: String, _ task: String, cost: Double, at: String = "2026-10-07T10:00:00Z",
                     versions: [String: String] = [:], error: Bool = false) -> String {
        let versionJSON = versions.map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",")
        return #"{"setup":"\#(setup)","task":"\#(task)","model":"sonnet","at":"\#(at)","cost":\#(cost),"score":1,"is_error":\#(error),"versions":{\#(versionJSON)},"tokens":{"sent":1000}}"#
    }

    func testCostChangeIsPerTaskAgainstBaseThenAveraged() {
        let rows = [
            row("base", "t1", cost: 1.0), row("base", "t1", cost: 1.0), row("base", "t2", cost: 2.0),
            row("rtk", "t1", cost: 0.8, versions: ["rtk": "0.51.0"]), row("rtk", "t2", cost: 2.4, versions: ["rtk": "0.51.0"]),
            row("rtk+caveman", "t1", cost: 0.1),
        ].compactMap(BenchRow.parse)
        let verdicts = BenchResults.verdicts(rows: rows, installed: ["rtk": "0.51.0"])
        XCTAssertEqual(verdicts.map(\.tool), ["rtk"], "stacks are not a tool's own verdict")
        XCTAssertEqual(verdicts[0].costChange, 0, accuracy: 1e-9, "−20% on t1 and +20% on t2")
        XCTAssertFalse(verdicts[0].isStale)
        XCTAssertEqual(BenchResults.line(verdicts[0]), "±0% cost vs plain · sonnet, 2 runs, 2026-10-07 · 0.51.0")
    }

    func testANewerInstalledVersionMarksTheMeasurementStale() {
        let rows = [row("base", "t1", cost: 1.0), row("rtk", "t1", cost: 0.9, versions: ["rtk": "0.51.0"])].compactMap(BenchRow.parse)
        let verdict = BenchResults.verdicts(rows: rows, installed: ["rtk": "0.52.0"])[0]
        XCTAssertTrue(verdict.isStale)
        XCTAssertEqual(BenchResults.line(verdict), "−10% cost vs plain · sonnet, 1 run, 2026-10-07 · 0.51.0 · 0.52.0 installed since: re-run")

        let unrecorded = BenchResults.verdicts(rows: [row("base", "t1", cost: 1.0), row("rtk", "t1", cost: 1.1)].compactMap(BenchRow.parse),
                                               installed: ["rtk": "0.52.0"])[0]
        XCTAssertTrue(BenchResults.line(unrecorded).hasSuffix("version not recorded, 0.52.0 installed: re-run"))
    }

    func testOnlyTheLatestVersionsRunsCount() {
        let rows = [
            row("base", "t1", cost: 1.0),
            row("rtk", "t1", cost: 3.0, at: "2026-09-01T00:00:00Z", versions: ["rtk": "0.40.0"]),
            row("rtk", "t1", cost: 0.5, at: "2026-10-07T00:00:00Z", versions: ["rtk": "0.51.0"]),
        ].compactMap(BenchRow.parse)
        let verdict = BenchResults.verdicts(rows: rows, installed: [:])[0]
        XCTAssertEqual(verdict.measuredVersion, "0.51.0")
        XCTAssertEqual(verdict.costChange, -0.5, accuracy: 1e-9)
    }

    func testFailedAndMalformedRowsAreSkipped() {
        XCTAssertNil(BenchRow.parse(row("rtk", "t1", cost: 1, error: true)))
        XCTAssertNil(BenchRow.parse("not json"))
        XCTAssertNil(BenchRow.parse(#"{"setup":"rtk"}"#))
    }

    func testVersionFromToolOutput() {
        XCTAssertEqual(BenchResults.version(in: "rtk 0.51.0"), "0.51.0")
        XCTAssertEqual(BenchResults.version(in: "CodeGraph v1.6.2\n"), "1.6.2")
        XCTAssertEqual(BenchResults.version(in: "tokenade 1.1.22 (darwin-arm64)"), "1.1.22")
        XCTAssertEqual(BenchResults.version(in: "headroom, version 0.22.4-beta.1"), "0.22.4-beta.1")
        XCTAssertNil(BenchResults.version(in: "usage: tool [options]"))
    }
}

import Foundation

/// What `scripts/bench-savers` measured for each tool: a whole session's cost
/// with the tool against the same task without it, on the same model. A
/// ledger says what a tool kept out; this says what the sessions cost.
///
/// Each result row names the versions it ran, so a measurement taken before
/// the tool changed says so instead of standing for the version installed now.
public struct BenchRow: Equatable {
    public var setup: String
    public var task: String
    public var model: String
    public var at: String
    public var cost: Double
    public var sent: Int
    public var score: Double
    /// Tool id → version string, as `ullage savers config` reported it.
    public var versions: [String: String]

    /// One line of `results/*.jsonl`; nil for a failed run or a malformed line.
    public static func parse(_ line: String) -> BenchRow? {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (object["is_error"] as? Bool) != true,
              let setup = object["setup"] as? String, let task = object["task"] as? String,
              let model = object["model"] as? String,
              let cost = (object["cost"] as? NSNumber)?.doubleValue,
              let sent = ((object["tokens"] as? [String: Any])?["sent"] as? NSNumber)?.intValue, sent > 0
        else { return nil }
        return BenchRow(setup: setup, task: task, model: model, at: object["at"] as? String ?? "",
                        cost: cost, sent: sent, score: (object["score"] as? NSNumber)?.doubleValue ?? 0,
                        versions: object["versions"] as? [String: String] ?? [:])
    }
}

public struct BenchVerdict: Equatable {
    public var tool: String
    public var model: String
    /// Mean over tasks of (cost with ÷ cost without) − 1; −0.1 is 10% cheaper.
    public var costChange: Double
    public var runs: Int
    /// The latest run's date, `YYYY-MM-DD`.
    public var measuredOn: String
    /// The version those runs used; nil when the rows predate recording it.
    public var measuredVersion: String?
    /// Set when the installed version differs from the measured one.
    public var installedVersion: String?

    public var isStale: Bool {
        guard let installedVersion else { return false }
        return measuredVersion != installedVersion
    }
}

public enum BenchResults {
    /// The tool alone (not stacks), per model, against base on the tasks
    /// both have runs for. A tool's newest version wins when it has several.
    public static func verdicts(rows: [BenchRow], installed: [String: String]) -> [BenchVerdict] {
        var verdicts: [BenchVerdict] = []
        let tools = Set(rows.map(\.setup)).filter { $0 != "base" && !$0.contains("+") }
        for model in Set(rows.map(\.model)).sorted() {
            let byModel = rows.filter { $0.model == model }
            for tool in tools.sorted() {
                var mine = byModel.filter { $0.setup == tool }
                guard !mine.isEmpty else { continue }
                let latest = mine.map(\.at).max() ?? ""
                let version = mine.first(where: { $0.at == latest })?.versions[tool]
                mine = mine.filter { $0.versions[tool] == version }
                var ratios: [Double] = []
                for task in Set(mine.map(\.task)) {
                    let with = mine.filter { $0.task == task }.map(\.cost)
                    let without = byModel.filter { $0.setup == "base" && $0.task == task }.map(\.cost)
                    guard let w = mean(with), let wo = mean(without), wo > 0 else { continue }
                    ratios.append(w / wo - 1)
                }
                guard let change = mean(ratios) else { continue }
                verdicts.append(BenchVerdict(tool: tool, model: model, costChange: change, runs: mine.count,
                                             measuredOn: String(latest.prefix(10)), measuredVersion: version,
                                             installedVersion: installed[tool]))
            }
        }
        return verdicts
    }

    /// `rtk  −3% cost vs plain · sonnet, 18 runs, 2026-10-07 · 0.51.0`, with
    /// what changed since when the installed version is not the one measured.
    public static func line(_ verdict: BenchVerdict) -> String {
        let percent = Int((verdict.costChange * 100).rounded())
        var text = "\(percent > 0 ? "+" : percent < 0 ? "−" : "±")\(abs(percent))% cost vs plain · \(verdict.model), \(verdict.runs) run\(verdict.runs == 1 ? "" : "s"), \(verdict.measuredOn)"
        if let measured = verdict.measuredVersion { text += " · \(measured)" }
        if verdict.isStale, let now = verdict.installedVersion {
            text += verdict.measuredVersion == nil
                ? " · version not recorded, \(now) installed: re-run"
                : " · \(now) installed since: re-run"
        }
        return text
    }

    /// The first `x.y` or `x.y.z` in a `--version` output: `rtk 0.51.0`,
    /// `CodeGraph v1.6.2`, `tokenade 1.1.22 (darwin-arm64)`.
    public static func version(in output: String) -> String? {
        guard let range = output.range(of: #"\d+\.\d+(\.\d+)?([-+][0-9A-Za-z.]+)?"#, options: .regularExpression) else { return nil }
        return String(output[range])
    }

    /// Where `bench.sh` also appends its rows, so the app and CLI find them
    /// without knowing where the repo is.
    public static func url(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        ClaudePaths.defaultDatabaseURL(environment: environment).deletingLastPathComponent()
            .appendingPathComponent("bench-results.jsonl")
    }

    public static func load(from url: URL) -> [BenchRow] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { BenchRow.parse(String($0)) }
    }

    private static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}

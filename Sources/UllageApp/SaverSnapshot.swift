#if os(macOS)
import Foundation
import UllageCore

/// Everything the Context tools window shows for one range, read in one pass.
struct SaverPageData {
    var details: [SaverDetail]
    var summary: SavingsSummary?
}

struct SaverSnapshot {
    struct Comparison {
        var timestamp: Date
        var cwd: String
        var value: [TokenSaver: OutputComparison]
    }

    var states: (at: Date, states: [TokenSaver: SaverSwitchState])?
    var installs: [TokenSaver: SaverInstallation] = [:]
    var ledger: (at: Date, entries: [LedgerEntry])?
    var cachedComparison: Comparison?
    var report: SaverSessionReport?
    var comparison: [TokenSaver: OutputComparison] = [:]

    static func read(path: String, sessionId: String?, environment: [String: String],
                     cached: Self?, cacheInterval: TimeInterval) throws -> Self {
        let now = Date()
        let store = try Store(path: path)
        var data = cached ?? Self()
        data.refreshStates(environment: environment, now: now, cacheInterval: cacheInterval)
        if data.ledger.map({ now.timeIntervalSince($0.at) > cacheInterval }) ?? true {
            data.ledger = (now, store.ledger(since: now.addingTimeInterval(-31 * 86_400), environment: environment))
        }
        data.report = try sessionId.map { try store.saverReport(sessionId: $0, ledger: data.ledger?.entries ?? []) }
        data.comparison = try data.readComparison(store: store, now: now, cacheInterval: cacheInterval)
        return data
    }

    private mutating func refreshStates(environment: [String: String], now: Date, cacheInterval: TimeInterval) {
        guard states.map({ now.timeIntervalSince($0.at) > cacheInterval }) ?? true else { return }
        let switchboard = SaverSwitchboard(environment: environment)
        let installer = SaverInstaller(environment: environment, switchboard: switchboard)
        states = (now, switchboard.states())
        installs = Dictionary(uniqueKeysWithValues: TokenSaver.allCases.map { ($0, installer.installation(of: $0)) })
    }

    private mutating func readComparison(store: Store, now: Date,
                                         cacheInterval: TimeInterval) throws -> [TokenSaver: OutputComparison] {
        guard let cwd = report?.cwd else { return [:] }
        if let cached = cachedComparison, cached.cwd == cwd,
           now.timeIntervalSince(cached.timestamp) < cacheInterval * 5 {
            return cached.value
        }
        let since = Timestamps.string(from: now.addingTimeInterval(-30 * 86_400))
        let value = try store.outputComparisons(cwd: cwd, since: since)
        cachedComparison = Comparison(timestamp: now, cwd: cwd, value: value)
        return value
    }
}
#endif

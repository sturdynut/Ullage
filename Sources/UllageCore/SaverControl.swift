import Foundation

/// Token savers for `ullage serve`: the panel the phone draws, and the
/// actions it can take — the same switchboard and installer the menu bar app
/// uses, so the two can never disagree about what a switch or an install does.
///
/// The app keeps its own per-popover state (pending notes cleared when the
/// popover closes). A page has no "close", so here a note lives for
/// `noteLifetime` and an Undo for as long as its note does.
public final class SaverControl {
    public enum Failure: Error, CustomStringConvertible {
        case needsPerson(TokenSaver)
        case notRunnable(String)
        case unsupported

        public var description: String {
            switch self {
            case .needsPerson(let saver):
                return "\(saver.displayName) needs someone at the Mac for part of this (a sign-in or a prompt). Start it from the menu bar there."
            case .notRunnable(let why): return why
            case .unsupported: return "Installing needs Terminal, which only a Mac has."
            }
        }
    }

    public static let noteLifetime: TimeInterval = 15 * 60
    static let cacheLifetime: TimeInterval = 60

    private let switchboard: SaverSwitchboard
    private let installer: SaverInstaller
    private let lock = NSLock()

    private var notes: [TokenSaver: (text: String, at: Date)] = [:]
    private var undo: [TokenSaver: (previous: Bool, at: Date)] = [:]
    private var runs: [TokenSaver: (plan: InstallPlan, marker: URL, started: Date)] = [:]
    private var cached: (at: Date, states: [TokenSaver: SaverSwitchState], installed: Set<TokenSaver>, ledger: [LedgerEntry])?
    private var comparison: (at: Date, cwd: String, value: [TokenSaver: OutputComparison])?

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let board = SaverSwitchboard(environment: environment)
        self.switchboard = board
        self.installer = SaverInstaller(environment: environment, switchboard: board)
    }

    // MARK: - Reading

    public func panel(store: Store, sessionId: String?, now: Date = Date()) throws -> SaverPanel {
        lock.lock()
        defer { lock.unlock() }
        collectFinishedRuns(now: now)
        if cached.map({ now.timeIntervalSince($0.at) > Self.cacheLifetime }) ?? true {
            cached = (now, switchboard.states(),
                      Set(TokenSaver.allCases.filter { installer.installation(of: $0).isInstalled }),
                      SaverLedgers.load(since: now.addingTimeInterval(-31 * 86_400)))
        }
        let report = try sessionId.map { try store.saverReport(sessionId: $0, ledger: cached?.ledger ?? []) }
        var outputComparisons: [TokenSaver: OutputComparison] = [:]
        if let cwd = report?.cwd {
            if let c = comparison, c.cwd == cwd, now.timeIntervalSince(c.at) < Self.cacheLifetime * 5 {
                outputComparisons = c.value
            } else {
                outputComparisons = try store.outputComparisons(cwd: cwd, since: Timestamps.string(from: now.addingTimeInterval(-30 * 86_400)))
                comparison = (now, cwd, outputComparisons)
            }
        }
        notes = notes.filter { now.timeIntervalSince($0.value.at) < Self.noteLifetime || runs[$0.key] != nil }
        undo = undo.filter { now.timeIntervalSince($0.value.at) < Self.noteLifetime }
        return SaverPanel.build(report: report, states: cached?.states ?? [:], comparisons: outputComparisons,
                                installed: cached?.installed ?? [],
                                pending: notes.mapValues(\.text), undoable: Set(undo.keys))
    }

    public func plan(_ saver: TokenSaver, _ action: SaverAction) -> InstallPlan {
        installer.plan(saver, action)
    }

    // MARK: - Acting (only ever from a request a person made)

    public func set(_ saver: TokenSaver, on: Bool, now: Date = Date()) throws {
        lock.lock()
        defer { lock.unlock() }
        try switchboard.set(saver, on: on)
        if let previous = undo[saver], previous.previous == on {
            undo[saver] = nil
            notes[saver] = nil
        } else {
            undo[saver] = (!on, now)
            notes[saver] = (on ? SaverPanel.onNextSession : SaverPanel.offNextSession, now)
        }
        cached = nil
    }

    public func undo(_ saver: TokenSaver, now: Date = Date()) throws {
        let previous: Bool? = { lock.lock(); defer { lock.unlock() }; return undo[saver]?.previous }()
        guard let previous else { return }
        try set(saver, on: previous, now: now)
    }

    /// Runs the plan in a Terminal window on the Mac, where it can be watched,
    /// with the same script and exit marker as the menu bar app. A plan that
    /// needs a person (a browser sign-in) is refused: nobody is at the Mac.
    public func run(_ saver: TokenSaver, _ action: SaverAction, now: Date = Date()) throws {
        let plan = installer.plan(saver, action)
        guard plan.isRunnable else {
            throw Failure.notRunnable(plan.missing.isEmpty ? (plan.notes.first ?? "Nothing to do.")
                                      : "Needs \(plan.missing.joined(separator: " and ")) on the Mac.")
        }
        guard !plan.needsPerson else { throw Failure.needsPerson(saver) }
        #if os(macOS)
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let files = try SaverInstaller.writeCommandFile(for: plan, shell: shell)
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [files.script.path]
        try open.run()
        lock.lock()
        defer { lock.unlock() }
        runs[saver] = (plan, files.marker, now)
        notes[saver] = ("\(action == .install ? "Installing" : "Uninstalling") \(saver.displayName) in Terminal on the Mac…", now)
        undo[saver] = nil
        cached = nil
        #else
        throw Failure.unsupported
        #endif
    }

    /// Called with the lock held.
    private func collectFinishedRuns(now: Date) {
        for (saver, run) in runs {
            if let status = SaverInstaller.finishedStatus(marker: run.marker) {
                try? FileManager.default.removeItem(at: run.marker)
                notes[saver] = (SaverInstaller.outcome(of: run.plan, status: status), now)
                runs[saver] = nil
                cached = nil
            } else if now.timeIntervalSince(run.started) > 30 * 60 {
                notes[saver] = nil
                runs[saver] = nil
            }
        }
    }
}

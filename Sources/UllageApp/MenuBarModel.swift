#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import UllageCore

/// Owns the collector and publishes what the menu bar draws.
///
/// Two SQLite connections on the same file: the tailer writes on its own queue,
/// this object reads on the main actor. WAL mode allows exactly that, and it is
/// why the model never shares the ingestor's connection.
@MainActor
final class MenuBarModel: ObservableObject {
    static let shared = MenuBarModel()

    /// What the popover is looking at. Held steady while the popover is open.
    @Published private(set) var state: MenuBarState = MenuBarFormatter.state(for: nil)
    /// What the menu bar item shows: always whichever session spoke last (or
    /// the pinned one). It keeps following even while the popover is frozen.
    @Published private(set) var menuBarState: MenuBarState = MenuBarFormatter.state(for: nil)
    @Published private(set) var errorMessage: String?
    @Published private(set) var isWatching = false
    @Published private(set) var databasePath: String = ClaudePaths.defaultDatabaseURL().path

    // M5 — the popover's extra inputs. `selection` is the only thing the user
    // sets; everything else is re-read from the database on every refresh.
    @Published var selection: SessionSelection = .automatic {
        didSet {
            guard selection != oldValue else { return }
            // Agents belong to a session; picking another one starts at its
            // main thread.
            focus = .mainThread
            heldSessionId = nil
            refresh()
        }
    }

    /// The session the popover latched onto when it opened.
    ///
    /// "Most recent" means the popover's subject can change under the pointer
    /// whenever another session takes a turn — the header, the chart and the
    /// agent list all swapping mid-read, which is what made the agents section
    /// appear and vanish. While the popover is open it follows one session and
    /// updates that session's numbers; the menu bar keeps following the latest.
    private var heldSessionId: String?
    private var popoverIsOpen = false

    func popoverDidOpen() {
        popoverIsOpen = true
        heldSessionId = nil      // re-latch onto whatever is current right now
        saverStates = nil        // an install may have finished in Terminal
        refresh()
        fetchClaudeLimits()
    }

    func popoverDidClose() {
        popoverIsOpen = false
        heldSessionId = nil
        // Keep "Installing… in Terminal" for runs still going; drop the rest.
        saverPending = saverPending.filter { installWatches[$0.key] != nil }
        saverUndo = [:]
        for saver in resultsShown { saverResults[saver] = nil }
        resultsShown = []
    }
    @Published private(set) var sessions: [SessionSummary] = []
    /// The picker's shape: sessions under the project they ran in.
    @Published private(set) var projects: [ProjectGroup] = []
    /// The agents the shown session spawned, and which stream the popover is
    /// looking at. The menu bar title never follows this — a subagent's window
    /// is not the session's — but everything inside the popover does.
    @Published private(set) var agents: AgentTree?
    @Published private(set) var focus: AgentScope = .mainThread
    @Published private(set) var focusedAgent: AgentSummary?
    @Published private(set) var history: ContextHistory?
    @Published private(set) var composition: ContextComposition?
    /// Where Remote Control last attached the shown session on claude.ai:
    /// the place to `/clear`, `/compact` or run a skill in it.
    @Published private(set) var remoteURL: URL?
    /// True when a pinned session vanished and the display fell back.
    @Published private(set) var pinFellBack = false

    static let pickerLimit = 12

    // MARK: Plan limits

    /// Every plan limit on record, Codex's from its transcripts and Claude's
    /// from Anthropic when that is switched on.
    @Published private(set) var planLimits: [PlanLimitDisplay] = []
    /// What Ullage itself saw in each plan-wide limit's window, by display id.
    @Published private(set) var planLimitUsage: [String: Store.WindowUsage] = [:]
    @Published private(set) var claudeLimitsError: String?

    static let checksClaudeLimitsKey = "checksClaudePlanLimits"
    static let claudeLimitsInterval: TimeInterval = 5 * 60

    /// Off by default: it is the one request Ullage makes on its own — Claude
    /// Code's token to Anthropic, the same place Claude Code sends it.
    @Published var checksClaudeLimits = UserDefaults.standard.bool(forKey: MenuBarModel.checksClaudeLimitsKey) {
        didSet {
            guard checksClaudeLimits != oldValue else { return }
            UserDefaults.standard.set(checksClaudeLimits, forKey: Self.checksClaudeLimitsKey)
            if checksClaudeLimits {
                fetchClaudeLimits(force: true)
            } else {
                // A number that is no longer being checked must not sit there
                // looking current.
                // Its own connection: the tailer's belongs to the tailer's queue.
                try? Store(path: databasePath)
                    .replacePlanLimits(vendor: Vendor.claudeCode, source: PlanLimitSource.api, with: [])
                claudeLimitsError = nil
                refresh()
            }
        }
    }

    private var lastClaudeFetch: Date?
    private var claudeFetchInFlight = false
    private var claudeLimitsTimer: Timer?

    func fetchClaudeLimits(force: Bool = false) {
        guard checksClaudeLimits, !claudeFetchInFlight else { return }
        if !force, let last = lastClaudeFetch, Date().timeIntervalSince(last) < 60 { return }
        claudeFetchInFlight = true
        lastClaudeFetch = Date()
        let path = databasePath
        Task.detached {
            let failure: String?
            do {
                // Its own connection: the fetch blocks for up to the timeout,
                // and it must hold neither the reader nor the tailer's writer.
                try ClaudeUsageClient.refresh(into: try Store(path: path))
                failure = nil
            } catch {
                failure = "\(error)"
            }
            await MainActor.run {
                self.claudeFetchInFlight = false
                self.claudeLimitsError = failure
                self.refresh()
            }
        }
    }

    // MARK: Token savers

    @Published private(set) var savers = SaverPanel()
    /// What was done to each saver while the popover has been open — shown on
    /// that saver's own row, and forgotten when the popover closes (by then
    /// the config itself says it, see `SaverPanel.build`).
    private var saverPending: [TokenSaver: String] = [:]
    /// The state each switched saver was in before this popover changed it —
    /// what Undo puts back. Forgotten with `saverPending`.
    private var saverUndo: [TokenSaver: Bool] = [:]
    /// Terminal runs still going, each with the marker its script writes its
    /// exit status to when it ends.
    private var installWatches: [TokenSaver: (plan: InstallPlan, marker: URL, started: Date)] = [:]
    private var installTimer: Timer?
    /// How a finished run went. Unlike `saverPending` it survives the popover
    /// closing — a run often ends while it is closed — and is dropped once it
    /// has been seen: on the close after an open that showed it.
    private var saverResults: [TokenSaver: String] = [:]
    private var resultsShown: Set<TokenSaver> = []
    static let installWatchLimit: TimeInterval = 30 * 60

    private let switchboard = SaverSwitchboard()
    private lazy var installer = SaverInstaller(switchboard: switchboard)
    private var saverInstalls: [TokenSaver: SaverInstallation] = [:]
    // Other programs' files and a 30-day scan: re-read on a slower clock than
    // the 15-second refresh, and at once after a switch.
    private var saverStates: (at: Date, states: [TokenSaver: SaverSwitchState])?
    private var saverLedger: (at: Date, entries: [LedgerEntry])?
    private var saverComparison: (at: Date, cwd: String, value: OutputComparison?)?
    static let saverCacheInterval: TimeInterval = 60

    /// Writes Claude Code's user config. Only ever from the user's own click.
    func setSaver(_ saver: TokenSaver, on: Bool) {
        do {
            try switchboard.set(saver, on: on)
            if saverUndo[saver] == on {
                // Back where it started: nothing is pending any more.
                saverUndo[saver] = nil
                saverPending[saver] = nil
            } else {
                saverUndo[saver] = !on
                saverPending[saver] = on ? SaverPanel.onNextSession : SaverPanel.offNextSession
            }
        } catch {
            saverPending[saver] = "Couldn't switch: \(error)"
        }
        saverStates = nil
        refresh()
    }

    /// One saver over a range, for the Token savers window. Anchored on the
    /// session the popover is showing. A 30-day range reads every session in
    /// it, so the window asks for this on a change, not on every redraw.
    func saverDetail(_ saver: TokenSaver, range: SaverRange) -> SaverDetail? {
        guard let readStore else { return nil }
        let ledger = saverLedger?.entries ?? SaverLedgers.load(since: Date().addingTimeInterval(-31 * 86_400))
        return try? readStore.saverDetail(saver, range: range, sessionId: state.sessionId, ledger: ledger)
    }

    func saverSwitchState(_ saver: TokenSaver) -> SaverSwitchState {
        saverStates?.states[saver] ?? .notInstalled
    }

    func saverIsInstalled(_ saver: TokenSaver) -> Bool {
        saverInstalls[saver]?.isInstalled ?? false || saverSwitchState(saver) != .notInstalled
    }

    /// Puts a switch back the way it was before this popover changed it.
    func undoSaver(_ saver: TokenSaver) {
        guard let previous = saverUndo[saver] else { return }
        setSaver(saver, on: previous)
    }

    func installPlan(_ saver: TokenSaver, _ action: SaverAction) -> InstallPlan {
        installer.plan(saver, action)
    }

    /// Runs a plan the user has read and confirmed, in Terminal: the steps are
    /// the tools' own commands, and some (a browser sign-in, Homebrew) need a
    /// person at a real terminal.
    func run(_ plan: InstallPlan) {
        do {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let files = try SaverInstaller.writeCommandFile(for: plan, shell: shell)
            NSWorkspace.shared.open(files.script)
            saverPending[plan.saver] = "\(plan.action == .install ? "Installing" : "Uninstalling") \(plan.saver.displayName) in Terminal…"
            saverResults[plan.saver] = nil
            installWatches[plan.saver] = (plan, files.marker, Date())
            watchInstalls()
        } catch {
            saverPending[plan.saver] = "Couldn't start Terminal: \(error)"
        }
        saverStates = nil
        refresh()
    }

    /// Polls the markers every two seconds while any run is going; stops by
    /// itself when none is.
    private func watchInstalls() {
        guard installTimer == nil else { return }
        installTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkInstalls() }
        }
    }

    private func checkInstalls() {
        var finished = false
        for (saver, watch) in installWatches {
            if let status = SaverInstaller.finishedStatus(marker: watch.marker) {
                try? FileManager.default.removeItem(at: watch.marker)
                saverResults[saver] = SaverInstaller.outcome(of: watch.plan, status: status)
                resultsShown.remove(saver)
                saverPending[saver] = nil
                installWatches[saver] = nil
                finished = true
            } else if Date().timeIntervalSince(watch.started) > Self.installWatchLimit {
                // Left open or abandoned; the row stops claiming it is running.
                saverPending[saver] = nil
                installWatches[saver] = nil
                finished = true
            }
        }
        if installWatches.isEmpty {
            installTimer?.invalidate()
            installTimer = nil
        }
        if finished {
            saverStates = nil
            refresh()
        }
    }

    private func refreshSavers(store: Store, sessionId: String?) throws {
        let now = Date()
        if saverStates.map({ now.timeIntervalSince($0.at) > Self.saverCacheInterval }) ?? true {
            saverStates = (now, switchboard.states())
            saverInstalls = Dictionary(uniqueKeysWithValues: TokenSaver.allCases.map { ($0, installer.installation(of: $0)) })
        }
        if saverLedger.map({ now.timeIntervalSince($0.at) > Self.saverCacheInterval }) ?? true {
            saverLedger = (now, SaverLedgers.load(since: now.addingTimeInterval(-31 * 86_400)))
        }
        let report = try sessionId.map { try store.saverReport(sessionId: $0, ledger: saverLedger?.entries ?? []) }
        var comparison: OutputComparison?
        if let cwd = report?.cwd {
            if let cached = saverComparison, cached.cwd == cwd, now.timeIntervalSince(cached.at) < Self.saverCacheInterval * 5 {
                comparison = cached.value
            } else {
                let since = Timestamps.string(from: now.addingTimeInterval(-30 * 86_400))
                comparison = try store.outputComparison(cwd: cwd, since: since)
                saverComparison = (now, cwd, comparison)
            }
        }
        savers = SaverPanel.build(report: report, states: saverStates?.states ?? [:], comparison: comparison,
                                  installed: Set(saverInstalls.filter { $0.value.isInstalled }.keys),
                                  pending: saverPending.merging(saverResults) { _, result in result },
                                  undoable: Set(saverUndo.keys))
        if popoverIsOpen { resultsShown.formUnion(saverResults.keys) }
    }

    private var readStore: Store?
    private var tailer: SessionTailer?
    private var refreshTimer: Timer?

    private init() {}

    func start() {
        guard tailer == nil else { return }
        do {
            let path = ClaudePaths.defaultDatabaseURL().path
            databasePath = path
            let writeStore = try Store(path: path)
            // Left behind by two writers numbering the same stream; see
            // `Ingestor.assignTurn`. Nothing to do on a clean database.
            _ = try? writeStore.repairDuplicateTurns()
            readStore = try Store(path: path)

            let tailer = SessionTailer(ingestor: Ingestor(store: writeStore))
            tailer.onIngest = { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            tailer.onError = { [weak self] error in
                Task { @MainActor in self?.errorMessage = "\(error)" }
            }
            try tailer.start(roots: TranscriptSources.roots())
            self.tailer = tailer
            isWatching = true
            refresh()

            // The display has to go idle on its own: no turn completing means no
            // file event to prompt a redraw, and a stale number is the one thing
            // worse than no number.
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            // The endpoint rate-limits; five minutes is plenty for windows
            // measured in hours and days.
            claudeLimitsTimer = Timer.scheduledTimer(withTimeInterval: Self.claudeLimitsInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.fetchClaudeLimits(force: true) }
            }
            fetchClaudeLimits(force: true)
        } catch {
            errorMessage = "\(error)"
            isWatching = false
        }
    }

    /// Look at one agent's window instead of the session's. Assigning `focus`
    /// directly would re-enter `refresh` from inside itself, so selection goes
    /// through here.
    func focus(on scope: AgentScope) {
        guard focus != scope else { return }
        focus = scope
        refresh()
    }

    func refresh() {
        guard let readStore else { return }
        do {
            let latest = try readStore.latestCall()
            let resolved = try SessionSelection.resolve(selection, latestOverall: latest) {
                try readStore.latestCall(sessionId: $0)
            }
            menuBarState = MenuBarFormatter.state(for: resolved)

            var shown = resolved
            if selection == .automatic, popoverIsOpen {
                if let held = heldSessionId, let stillThere = try readStore.latestCall(sessionId: held) {
                    shown = stillThere
                } else {
                    heldSessionId = resolved?.sessionId
                }
            }
            pinFellBack = selection.pinnedSessionId != nil && shown?.sessionId != selection.pinnedSessionId
            state = MenuBarFormatter.state(for: shown)
            sessions = try readStore.recentSessions(limit: Self.pickerLimit)
            projects = ProjectGroup.build(sessions: sessions)

            let tree = try shown.map { try readStore.agentTree(sessionId: $0.sessionId) }
            agents = tree
            // A focus that this session has no agent for — the session changed
            // under us, or the agent's rows have not been ingested yet — falls
            // back to the main thread rather than showing an empty chart.
            if case .agent(let agentId) = focus,
               tree?.flattened.contains(where: { $0.agent.agentId == agentId }) != true {
                focus = .mainThread
            }
            focusedAgent = {
                guard case .agent(let agentId) = focus else { return nil }
                return tree?.flattened.first { $0.agent.agentId == agentId }?.agent
            }()

            history = try shown.map { try readStore.contextHistory(sessionId: $0.sessionId, scope: focus) }
            composition = try shown.flatMap { try readStore.composition(sessionId: $0.sessionId, scope: focus) }
            remoteURL = try shown.flatMap { try readStore.remoteURL(sessionId: $0.sessionId) }.flatMap(URL.init(string:))
            try refreshSavers(store: readStore, sessionId: shown?.sessionId)

            let limits = PlanLimitFormatter.displays(for: try readStore.planLimits())
            planLimits = limits
            var usage: [String: Store.WindowUsage] = [:]
            for limit in limits {
                guard let start = limit.windowStart else { continue }
                usage[limit.id] = try readStore.windowUsage(vendor: limit.vendor, since: Timestamps.string(from: start))
            }
            planLimitUsage = usage
            errorMessage = nil
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Full re-sweep of the transcript tree, off the main thread: on a large
    /// backlog this is seconds of work, not milliseconds.
    func refreshNow() {
        guard let tailer else { return }
        Task.detached {
            _ = tailer.sweepNow()
            await MainActor.run { self.refresh() }
        }
    }

    /// Selects the database itself rather than opening its folder — "show in
    /// Finder" means the file is highlighted when you get there.
    func openDatabaseFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: databasePath)])
    }
}
#endif

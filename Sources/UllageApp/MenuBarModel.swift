#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import UllageCore

@MainActor
final class MenuBarModel: ObservableObject {
    static let shared = MenuBarModel()

    /// What the popover is looking at. Held steady while the popover is open.
    @Published private(set) var state: MenuBarState = MenuBarFormatter.state(for: nil)
    /// What the menu bar item shows: always whichever session spoke last (or
    /// the pinned one). It keeps following even while the popover is frozen.
    @Published private(set) var menuBarState: MenuBarState = MenuBarFormatter.state(for: nil)
    @Published var errorMessage: String?
    /// The main window's page. The popover's rows set it before opening the
    /// window, so a row lands on its own page.
    @Published var windowPage: MainPage = .overview
    @Published var isWatching = false
    @Published var isRestarting = false
    @Published private(set) var databasePath: String = ClaudePaths.defaultDatabaseURL().path

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
        invalidateSaverStates() // an install may have finished in Terminal
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
    /// Where to type into the shown session: Remote Control on claude.ai, or
    /// the Codex app's thread. The place to `/clear`, `/compact` or run a skill.
    @Published private(set) var sessionLink: SessionLink?
    /// True when a pinned session vanished and the display fell back.
    @Published private(set) var pinFellBack = false

    static let pickerLimit = 12

    // MARK: Plan limits

    /// Every plan limit on record, Codex's from its transcripts and Claude's
    /// from Anthropic when that is switched on.
    @Published private(set) var planLimits: [PlanLimitDisplay] = []
    /// What Ullage itself saw in each plan-wide limit's window, by display id.
    @Published private(set) var planLimitUsage: [String: Store.WindowUsage] = [:]
    @Published var claudeLimitsError: String?

    static let checksClaudeLimitsKey = "checksClaudePlanLimits"
    static let claudeLimitsInterval: TimeInterval = 5 * 60

    /// Off by default: it is the one request Ullage makes on its own — Claude
    /// Code's token to Anthropic, the same place Claude Code sends it.
    @Published var checksClaudeLimits: Bool {
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

    var lastClaudeFetch: Date?
    var claudeFetchInFlight = false
    var claudeLimitsTimer: Timer?
    var claudeFetchTask: Task<Void, Never>?

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
    var installTimer: Timer?
    /// Install outcomes survive closing until they have been shown once.
    private var saverResults: [TokenSaver: String] = [:]
    private var resultsShown: Set<TokenSaver> = []
    static let installWatchLimit: TimeInterval = 30 * 60

    private let environment: [String: String]
    private let switchboard: SaverSwitchboard
    private lazy var installer = SaverInstaller(environment: environment, switchboard: switchboard)
    private var saverSnapshot: SaverSnapshot?
    private var saverStatesGeneration = UUID()
    private var saverRefreshPending = false
    var saverRefreshTask: Task<Void, Never>?
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
        invalidateSaverStates()
        refresh()
    }

    /// Every saver over a range, for the Context tools window. Anchored on
    /// the session the popover is showing. A range reads every session in it,
    /// and the comparisons up to 30 days of them, so it runs off the main
    /// thread on its own connection, and the window asks on a change, not on
    /// every redraw.
    func saverPage(range: SaverRange) async -> SaverPageData {
        let path = databasePath
        let sessionId = state.sessionId
        let cached = saverSnapshot?.ledger?.entries
        return await Task.detached(priority: .userInitiated) {
            guard let store = try? Store(path: path) else { return SaverPageData(details: [], summary: nil) }
            let ledger = cached ?? store.ledger(since: Date().addingTimeInterval(-31 * 86_400))
            let details = (try? store.saverDetails(range: range, sessionId: sessionId, ledger: ledger)) ?? []
            return SaverPageData(details: details, summary: try? store.savingsSummary(details, range: range))
        }.value
    }

    func saverSwitchState(_ saver: TokenSaver) -> SaverSwitchState {
        saverSnapshot?.states?.states[saver] ?? .notInstalled
    }

    func saverIsInstalled(_ saver: TokenSaver) -> Bool {
        saverSnapshot?.installs[saver]?.isInstalled ?? false || saverSwitchState(saver) != .notInstalled
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
        invalidateSaverStates()
        refresh()
    }

    /// Polls the markers every two seconds while any run is going; stops by
    /// itself when none is.
    private func watchInstalls() {
        guard installTimer == nil, !isStopping else { return }
        installTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isStopping else { return }
                self.checkInstalls()
            }
        }
    }

    private func checkInstalls() {
        var finished = false
        for (saver, watch) in installWatches {
            if let status = SaverInstaller.finishedStatus(marker: watch.marker) {
                try? FileManager.default.removeItem(at: watch.marker)
                saverResults[saver] = SaverInstaller.outcome(of: watch.plan, status: status, after: switchboard.state(of: saver))
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
            invalidateSaverStates()
            refresh()
        }
    }

    private func invalidateSaverStates() {
        saverSnapshot?.states = nil
        saverStatesGeneration = UUID()
    }

    private func refreshSavers(sessionId: String?) {
        guard !isStopping else { return }
        guard saverRefreshTask == nil else { saverRefreshPending = true; return }
        saverRefreshPending = false
        let generation = serviceGeneration
        let statesGeneration = saverStatesGeneration
        let path = databasePath
        let environment = environment
        let cached = saverSnapshot
        let cacheInterval = Self.saverCacheInterval
        saverRefreshTask = Task {
            let result = await Task.detached {
                Result { try SaverSnapshot.read(path: path, sessionId: sessionId, environment: environment,
                                                cached: cached, cacheInterval: cacheInterval) }
            }.value
            saverRefreshTask = nil
            guard generation == serviceGeneration, !isStopping else { return }
            guard statesGeneration == saverStatesGeneration, sessionId == state.sessionId else {
                refreshSavers(sessionId: state.sessionId)
                return
            }
            switch result {
            case .success(let data):
                saverSnapshot = data
                savers = SaverPanel.build(report: data.report, states: data.states?.states ?? [:],
                                          comparisons: data.comparison,
                                          installed: Set(data.installs.filter { $0.value.isInstalled }.keys),
                                          pending: saverPending.merging(saverResults) { _, result in result },
                                          undoable: Set(saverUndo.keys))
                if popoverIsOpen { resultsShown.formUnion(saverResults.keys) }
            case .failure(let error): errorMessage = "\(error)"
            }
            if saverRefreshPending { refreshSavers(sessionId: state.sessionId) }
        }
    }

    var readStore: Store?
    var tailer: SessionTailer?
    var refreshTimer: Timer?
    var refreshTask: Task<Void, Never>?
    var displayRefreshTask: Task<Void, Never>?
    private var displayRefreshPending = false
    var restartTask: Task<Void, Never>?
    var serviceGeneration = UUID()
    var isStopping = false
    let transcriptRoots: [URL]
    let makeWatcher: () -> DirectoryWatching

    init(
        databaseURL: URL = ClaudePaths.defaultDatabaseURL(),
        transcriptRoots: [URL] = TranscriptSources.roots(),
        checksClaudeLimits: Bool? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        makeWatcher: @escaping () -> DirectoryWatching = { makeDirectoryWatcher() }
    ) {
        databasePath = databaseURL.path
        self.transcriptRoots = transcriptRoots
        self.checksClaudeLimits = checksClaudeLimits ?? UserDefaults.standard.bool(forKey: Self.checksClaudeLimitsKey)
        self.makeWatcher = makeWatcher
        self.environment = environment
        switchboard = SaverSwitchboard(environment: environment)
    }
}

extension MenuBarModel {
    func focus(on scope: AgentScope) {
        guard focus != scope else { return }
        focus = scope
        refresh()
    }

    func refresh() {
        guard readStore != nil, !isStopping else { return }
        guard displayRefreshTask == nil else { displayRefreshPending = true; return }
        displayRefreshPending = false
        let generation = serviceGeneration
        let path = databasePath
        let selection = selection
        let focus = focus
        let held = heldSessionId
        let isOpen = popoverIsOpen
        let limit = Self.pickerLimit
        displayRefreshTask = Task {
            let result = await Task.detached {
                Result { try MenuBarSnapshot.read(path: path, selection: selection, focus: focus,
                                                  held: isOpen ? held : nil, limit: limit) }
            }.value
            displayRefreshTask = nil
            guard generation == serviceGeneration, readStore != nil, !isStopping else { return }
            guard selection == self.selection, focus == self.focus,
                  held == heldSessionId, isOpen == popoverIsOpen else {
                refresh()
                return
            }
            switch result {
            case .success(let data):
                menuBarState = data.menuBarState
                state = data.state
                pinFellBack = data.pinFellBack
                if selection == .automatic, isOpen { heldSessionId = data.state.sessionId }
                sessions = data.sessions
                projects = ProjectGroup.build(sessions: data.sessions)
                agents = data.agents
                self.focus = data.focus
                if case .agent(let id) = data.focus {
                    focusedAgent = data.agents?.flattened.first { $0.agent.agentId == id }?.agent
                } else { focusedAgent = nil }
                history = data.history
                composition = data.composition
                sessionLink = data.sessionLink
                planLimits = data.planLimits
                planLimitUsage = data.planLimitUsage
                refreshSavers(sessionId: data.state.sessionId)
                errorMessage = nil
            case .failure(let error): errorMessage = "\(error)"
            }
            if displayRefreshPending { refresh() }
        }
    }

    func refreshNow() {
        guard isWatching, !isStopping, refreshTask == nil, let tailer else { return }
        let generation = serviceGeneration
        refreshTask = Task {
            await Task.detached { _ = tailer.sweepNow() }.value
            guard generation == serviceGeneration else { return }
            refreshTask = nil
            refresh()
        }
    }

    /// Selects the database itself rather than opening its folder — "show in
    /// Finder" means the file is highlighted when you get there.
    func openDatabaseFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: databasePath)])
    }
}
#endif

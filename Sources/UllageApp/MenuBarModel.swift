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
        refresh()
    }

    func popoverDidClose() {
        popoverIsOpen = false
        heldSessionId = nil
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
    /// True when a pinned session vanished and the display fell back.
    @Published private(set) var pinFellBack = false

    static let pickerLimit = 12

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

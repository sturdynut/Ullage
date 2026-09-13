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

    @Published private(set) var state: MenuBarState = MenuBarFormatter.state(for: nil)
    @Published private(set) var errorMessage: String?
    @Published private(set) var isWatching = false
    @Published private(set) var databasePath: String = ClaudePaths.defaultDatabaseURL().path

    // M5 — the popover's extra inputs. `selection` is the only thing the user
    // sets; everything else is re-read from the database on every refresh.
    @Published var selection: SessionSelection = .automatic {
        didSet { if selection != oldValue { refresh() } }
    }
    @Published private(set) var sessions: [SessionSummary] = []
    @Published private(set) var history: ContextHistory?
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
            try tailer.start(roots: ClaudePaths.projectsDirectories())
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

    func refresh() {
        guard let readStore else { return }
        do {
            let latest = try readStore.latestCall()
            let shown = try SessionSelection.resolve(selection, latestOverall: latest) {
                try readStore.latestCall(sessionId: $0)
            }
            pinFellBack = selection.pinnedSessionId != nil && shown?.sessionId != selection.pinnedSessionId
            state = MenuBarFormatter.state(for: shown)
            sessions = try readStore.recentSessions(limit: Self.pickerLimit)
            history = try shown.map { try readStore.contextHistory(sessionId: $0.sessionId) }
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

    func openDatabaseFolder() {
        let url = URL(fileURLWithPath: databasePath).deletingLastPathComponent()
        NSWorkspace.shared.open(url)
    }
}
#endif

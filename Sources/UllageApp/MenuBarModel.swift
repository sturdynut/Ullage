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
            state = MenuBarFormatter.state(for: try readStore.latestCall())
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

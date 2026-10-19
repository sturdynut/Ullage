#if os(macOS)
import Foundation
import UllageCore

extension MenuBarModel {
    func start() {
        guard !isWatching else { return }
        restart()
    }

    @discardableResult
    func restart() -> Task<Void, Never>? {
        guard !isStopping else { return nil }
        if let restartTask { return restartTask }
        isRestarting = true
        let task = Task {
            await stopMonitoring()
            if !isStopping { await startMonitoring() }
            isRestarting = false
            restartTask = nil
        }
        restartTask = task
        return task
    }

    /// Quit waits for the current transition and all app-owned work to finish.
    func stop() async {
        isStopping = true
        installTimer?.invalidate()
        installTimer = nil
        await restartTask?.value
        await stopMonitoring()
    }

    private func stopMonitoring() async {
        serviceGeneration = UUID()
        isWatching = false
        refreshTimer?.invalidate()
        refreshTimer = nil
        claudeLimitsTimer?.invalidate()
        claudeLimitsTimer = nil
        // These synchronous operations don't cooperate with Task.cancel().
        // Drain them before releasing their stores or starting another writer.
        await refreshTask?.value
        await claudeFetchTask?.value
        await displayRefreshTask?.value
        await saverRefreshTask?.value
        refreshTask = nil
        claudeFetchTask = nil
        claudeFetchInFlight = false
        lastClaudeFetch = nil
        let previous = tailer
        tailer = nil
        await Task.detached { previous?.stop() }.value
        readStore = nil
    }

    private func startMonitoring() async {
        do {
            let writeStore = try Store(path: databasePath)
            // Left behind by two writers numbering the same stream; see
            // `Ingestor.assignTurn`. Nothing to do on a clean database.
            _ = try? writeStore.repairDuplicateTurns()
            readStore = try Store(path: databasePath)
            refresh()
            let generation = serviceGeneration
            let tailer = SessionTailer(ingestor: Ingestor(store: writeStore), watcher: makeWatcher())
            tailer.onIngest = { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.serviceGeneration == generation else { return }
                    self.refresh()
                }
            }
            tailer.onError = { [weak self] error in
                Task { @MainActor in
                    guard let self, self.serviceGeneration == generation else { return }
                    self.errorMessage = "\(error)"
                }
            }
            let roots = transcriptRoots
            do {
                try await Task.detached { try tailer.start(roots: roots) }.value
            } catch {
                await Task.detached { tailer.stop() }.value
                throw error
            }
            self.tailer = tailer
            guard !isStopping else { return }
            isWatching = true
            errorMessage = nil
            refresh()

            // The display has to go idle on its own: no turn completing means no
            // file event to prompt a redraw, and a stale number is the one thing
            // worse than no number.
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.serviceGeneration == generation else { return }
                    self.refresh()
                }
            }
            // The endpoint rate-limits; five minutes is plenty for windows
            // measured in hours and days.
            claudeLimitsTimer = Timer.scheduledTimer(
                withTimeInterval: Self.claudeLimitsInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.serviceGeneration == generation else { return }
                    self.fetchClaudeLimits(force: true)
                }
            }
            fetchClaudeLimits(force: true)
        } catch {
            readStore = nil
            errorMessage = "Monitoring stopped: \(error). Choose Restart Service to retry."
            isWatching = false
        }
    }

    func fetchClaudeLimits(force: Bool = false) {
        guard isWatching, !isStopping, checksClaudeLimits, !claudeFetchInFlight else { return }
        if !force, let last = lastClaudeFetch, Date().timeIntervalSince(last) < 60 { return }
        claudeFetchInFlight = true
        lastClaudeFetch = Date()
        let path = databasePath
        let generation = serviceGeneration
        claudeFetchTask = Task {
            let failure = await Task.detached { () -> String? in
                do {
                    // Its own connection: the fetch blocks for up to the timeout,
                    // and it must hold neither the reader nor the tailer's writer.
                    try ClaudeUsageClient.refresh(into: try Store(path: path))
                    return nil
                } catch {
                    return "\(error)"
                }
            }.value
            guard generation == serviceGeneration else { return }
            claudeFetchInFlight = false
            claudeFetchTask = nil
            claudeLimitsError = failure
            refresh()
        }
    }
}
#endif

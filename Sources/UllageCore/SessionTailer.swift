import Foundation

/// Watches the transcript tree and turns appends into rows.
///
/// All ingestion runs on one serial queue: `Store` is a single connection and
/// `Ingestor` carries per-session state, neither of which is thread-safe.
/// Safe to hand across threads: every piece of mutable state below is touched
/// only on `queue`, and the callbacks are set before `start`.
public final class SessionTailer: @unchecked Sendable {
    public let ingestor: Ingestor
    private let watcher: DirectoryWatching
    private let debounce: TimeInterval
    private let queue = DispatchQueue(label: "com.sturdynut.ullage.tailer")

    private var roots: [URL] = []
    private var pendingPaths = Set<String>()
    private var flushWorkItem: DispatchWorkItem?

    /// Called on the tailer's queue after every batch that produced rows.
    public var onIngest: ((IngestStats) -> Void)?
    public var onError: ((Error) -> Void)?

    public init(
        ingestor: Ingestor,
        watcher: DirectoryWatching = makeDirectoryWatcher(),
        debounce: TimeInterval = 0.25
    ) {
        self.ingestor = ingestor
        self.watcher = watcher
        self.debounce = debounce
    }

    deinit { watcher.stop() }

    /// Sweeps the tree once, then watches it. The initial sweep matters: the app
    /// is not always running, and anything appended while it was not is only
    /// picked up by reading from the stored cursor.
    public func start(roots: [URL]) throws {
        self.roots = roots
        queue.sync {
            do {
                var stats = IngestStats()
                for root in roots where FileManager.default.fileExists(atPath: root.path) {
                    stats = stats + (try ingestor.ingestDirectory(at: root))
                }
                if stats.callsUpserted > 0 { onIngest?(stats) }
            } catch {
                onError?(error)
            }
        }
        try watcher.start(paths: roots) { [weak self] paths in
            self?.enqueue(paths: paths)
        }
    }

    public func stop() {
        watcher.stop()
        queue.sync {
            flushWorkItem?.cancel()
            flushWorkItem = nil
            pendingPaths.removeAll()
        }
    }

    /// Coalesces events per path over the debounce window: a single turn can
    /// produce several writes, and re-ingesting on each one is wasted work.
    private func enqueue(paths: [String]) {
        queue.async {
            for path in paths where path.hasSuffix(".jsonl") {
                self.pendingPaths.insert(path)
            }
            guard !self.pendingPaths.isEmpty else { return }
            self.flushWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.flush() }
            self.flushWorkItem = work
            self.queue.asyncAfter(deadline: .now() + self.debounce, execute: work)
        }
    }

    private func flush() {
        let paths = pendingPaths
        pendingPaths.removeAll()
        flushWorkItem = nil
        guard !paths.isEmpty else { return }

        var stats = IngestStats()
        for path in paths.sorted() {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            do {
                stats = stats + (try ingestor.ingestFile(at: url))
            } catch {
                // One unreadable file must not stop the tailer.
                onError?(error)
            }
        }
        if stats.filesScanned > 0 { onIngest?(stats) }
    }

    /// Ingest everything now, off the watch path. Used by the menu bar's manual
    /// refresh and by tests that do not want to wait for a poll tick. Blocks on
    /// the tailer's queue, so never call it from `onIngest` or `onError`.
    @discardableResult
    public func sweepNow() -> IngestStats {
        queue.sync {
            var stats = IngestStats()
            for root in roots where FileManager.default.fileExists(atPath: root.path) {
                do {
                    stats = stats + (try ingestor.ingestDirectory(at: root))
                } catch {
                    onError?(error)
                }
            }
            return stats
        }
    }
}

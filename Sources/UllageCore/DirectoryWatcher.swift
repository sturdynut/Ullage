import Foundation
#if canImport(CoreServices)
import CoreServices
#endif

/// Tells the tailer that something under the watched roots changed. The paths
/// are a hint, not a contract: the tailer re-checks cursors regardless.
public protocol DirectoryWatching: AnyObject {
    func start(paths: [URL], onChange: @escaping ([String]) -> Void) throws
    func stop()
}

public enum WatcherError: Error, CustomStringConvertible {
    case couldNotStart(String)

    public var description: String {
        switch self {
        case .couldNotStart(let detail): return "could not start watching: \(detail)"
        }
    }
}

/// The watcher for the platform we are on: FSEvents on macOS, polling elsewhere.
public func makeDirectoryWatcher(pollInterval: TimeInterval = 1.0) -> DirectoryWatching {
    #if os(macOS)
    return FSEventsWatcher()
    #else
    return PollingWatcher(interval: pollInterval)
    #endif
}

#if os(macOS)
/// Native file-level FSEvents. Latency is 0.3s, so a completed turn reaches the
/// menu bar well inside the two seconds the plan asks for.
public final class FSEventsWatcher: DirectoryWatching {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.sturdynut.ullage.fsevents")
    private var onChange: (([String]) -> Void)?

    public init() {}

    deinit { stop() }

    public func start(paths: [URL], onChange: @escaping ([String]) -> Void) throws {
        stop()
        guard !paths.isEmpty else { throw WatcherError.couldNotStart("no paths to watch") }
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info, count > 0 else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            watcher.onChange?(paths)
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            flags
        ) else {
            throw WatcherError.couldNotStart("FSEventStreamCreate returned nil")
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            throw WatcherError.couldNotStart("FSEventStreamStart failed")
        }
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        self.onChange = nil
    }
}
#endif

/// mtime/size polling. Used off macOS and in tests, where it is the only way to
/// exercise the tailer deterministically.
public final class PollingWatcher: DirectoryWatching {
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "com.sturdynut.ullage.polling")
    private var timer: DispatchSourceTimer?
    private var fingerprints: [String: String] = [:]
    private var roots: [URL] = []

    public init(interval: TimeInterval = 1.0) {
        self.interval = interval
    }

    deinit { stop() }

    public func start(paths: [URL], onChange: @escaping ([String]) -> Void) throws {
        stop()
        guard !paths.isEmpty else { throw WatcherError.couldNotStart("no paths to watch") }
        roots = paths
        fingerprints = scan()   // the first tick reports changes, not everything

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let current = self.scan()
            var changed: [String] = []
            for (path, fingerprint) in current where self.fingerprints[path] != fingerprint {
                changed.append(path)
            }
            // A file that disappeared is also a change: its cursor is now stale.
            for path in self.fingerprints.keys where current[path] == nil {
                changed.append(path)
            }
            self.fingerprints = current
            if !changed.isEmpty { onChange(changed) }
        }
        self.timer = timer
        timer.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        fingerprints = [:]
    }

    private func scan() -> [String: String] {
        var result: [String: String] = [:]
        let manager = FileManager.default
        for root in roots {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory) else { continue }
            guard isDirectory.boolValue else {
                if let fingerprint = fingerprint(of: root.path) { result[root.path] = fingerprint }
                continue
            }
            guard let enumerator = manager.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                if let fingerprint = fingerprint(of: url.path) { result[url.path] = fingerprint }
            }
        }
        return result
    }

    private func fingerprint(of path: String) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)@\(mtime)"
    }
}

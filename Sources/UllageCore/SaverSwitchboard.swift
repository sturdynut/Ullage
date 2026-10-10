import Foundation

/// Switching token savers on and off in Claude Code's user config.
///
/// This is the one place Ullage writes to anything that is not its own. It
/// only ever runs when asked (a switch in the popover, `ullage savers
/// enable|disable`), it only touches the saver named, and nothing it removes is
/// thrown away: a hook or MCP server switched off is *parked* in Ullage's own
/// file, exactly as it was, and put back from there. Each file is backed up
/// before it is written.
///
/// What a switch changes:
///
/// - **rtk, Tokenade hooks** — their entries under `hooks` in
///   `~/.claude/settings.json`, matched by command.
/// - **Headroom, Tokenade MCP servers** — their `mcpServers` entries in
///   `~/.claude/settings.json` and `~/.claude.json` (user scope only).
/// - **caveman** — its `enabledPlugins` flag, which Claude Code already
///   understands; nothing is parked.
///
/// A running session keeps what it loaded; the change applies from the next.
/// Project-scoped config (`.claude/settings.json`, `.mcp.json`) is left alone.
public enum SaverSwitchState: String, Equatable {
    case on
    case off
    case notInstalled = "not installed"
}

/// What was taken out of the config for one saver, to be put back verbatim.
public struct ParkedSaver: Equatable {
    public struct Hook: Equatable {
        public var event: String
        public var matcher: String?
        /// The hook object as it was: `{"type":"command","command":…}`.
        public var hookJSON: String
    }

    public var hooks: [Hook] = []
    /// Server name → config JSON, per file.
    public var settingsMcp: [String: String] = [:]
    public var claudeJSONMcp: [String: String] = [:]
    public var parkedAt: String?

    public init() {}

    public var isEmpty: Bool { hooks.isEmpty && settingsMcp.isEmpty && claudeJSONMcp.isEmpty }
}

public struct SaverSwitchChange: Equatable {
    public var saver: TokenSaver
    public var on: Bool
    /// One line per edit, for `--dry-run` and the popover's confirmation.
    public var summary: [String]
    public var settingsChanged: Bool
    public var claudeJSONChanged: Bool
}

public enum SaverSwitchError: Error, CustomStringConvertible {
    case notInstalled(TokenSaver)
    case unreadable(String)

    public var description: String {
        switch self {
        case .notInstalled(let saver): return "\(saver.displayName) is not installed in Claude Code's user config"
        case .unreadable(let path): return "could not read \(path) as JSON; left it untouched"
        }
    }
}

public struct SaverSwitchboard {
    public let settingsURL: URL
    public let claudeJSONURL: URL
    /// Ullage's own file: `parked-savers.json` next to the database.
    public let parkedURL: URL
    let fileManager: FileManager

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        supportDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        let config = ClaudePaths.configDirectories(environment: environment)[0]
        self.settingsURL = config.appendingPathComponent("settings.json")
        // ~/.claude.json sits next to ~/.claude, not inside it.
        self.claudeJSONURL = config.deletingLastPathComponent().appendingPathComponent(".claude.json")
        let support = supportDirectory
            ?? ClaudePaths.defaultDatabaseURL(environment: environment).deletingLastPathComponent()
        self.parkedURL = support.appendingPathComponent("parked-savers.json")
        self.fileManager = fileManager
    }

    public init(settingsURL: URL, claudeJSONURL: URL, parkedURL: URL, fileManager: FileManager = .default) {
        self.settingsURL = settingsURL
        self.claudeJSONURL = claudeJSONURL
        self.parkedURL = parkedURL
        self.fileManager = fileManager
    }

    // MARK: - Reading

    public func state(of saver: TokenSaver) -> SaverSwitchState {
        let settings = (try? readObject(settingsURL)) ?? [:]
        let claudeJSON = (try? readObject(claudeJSONURL)) ?? [:]
        return Self.state(of: saver, settings: settings, claudeJSON: claudeJSON, parked: readParked()[saver])
    }

    public func states() -> [TokenSaver: SaverSwitchState] {
        let settings = (try? readObject(settingsURL)) ?? [:]
        let claudeJSON = (try? readObject(claudeJSONURL)) ?? [:]
        let parked = readParked()
        return Dictionary(uniqueKeysWithValues: TokenSaver.allCases.map {
            ($0, Self.state(of: $0, settings: settings, claudeJSON: claudeJSON, parked: parked[$0]))
        })
    }

    // MARK: - Writing

    /// Computes the change without writing it.
    public func plan(_ saver: TokenSaver, on: Bool) throws -> SaverSwitchChange {
        var settings = try readObject(settingsURL)
        var claudeJSON = try readObject(claudeJSONURL)
        var parked = readParked()
        return try Self.apply(saver, on: on, settings: &settings, claudeJSON: &claudeJSON, parked: &parked)
    }

    /// Re-reads every file immediately before writing — Claude Code rewrites
    /// `~/.claude.json` constantly, and a stale copy would undo its changes.
    @discardableResult
    public func set(_ saver: TokenSaver, on: Bool) throws -> SaverSwitchChange {
        var settings = try readObject(settingsURL)
        var claudeJSON = try readObject(claudeJSONURL)
        var parked = readParked()
        let change = try Self.apply(saver, on: on, settings: &settings, claudeJSON: &claudeJSON, parked: &parked)
        if change.settingsChanged { try write(settings, to: settingsURL) }
        if change.claudeJSONChanged { try write(claudeJSON, to: claudeJSONURL) }
        try writeParked(parked)
        return change
    }

    /// Everything this saver adds to Claude Code, switched on or parked, with
    /// plugin keys resolved to their newest cached version. The benchmark
    /// (`scripts/bench-savers`) loads exactly this into a session that
    /// ignores the user's own config, so each tool is measured alone.
    public func wiring(of saver: TokenSaver) -> [String: Any] {
        let settings = (try? readObject(settingsURL)) ?? [:]
        let claudeJSON = (try? readObject(claudeJSONURL)) ?? [:]
        var result = Self.wiring(of: saver, settings: settings, claudeJSON: claudeJSON, parked: readParked()[saver])
        let cache = settingsURL.deletingLastPathComponent().appendingPathComponent("plugins/cache")
        result["plugins"] = (result["plugins"] as? [String] ?? []).compactMap { key -> String? in
            let parts = key.split(separator: "@", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            let dir = cache.appendingPathComponent(parts[1]).appendingPathComponent(parts[0])
            let versions = (try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? []
            return versions.max(by: { $0.compare($1, options: .numeric) == .orderedAscending })
                .map { dir.appendingPathComponent($0).path }
        }
        return result
    }

    // MARK: - Pure transforms (tested without touching disk)

    /// `{"hooks": {event: [{matcher?, hooks: [hook]}]}, "mcp": {name: config},
    /// "plugins": [key]}`. A tool switched off contributes its parked copy;
    /// a plugin counts whether its flag is true or false.
    static func wiring(of saver: TokenSaver, settings: [String: Any], claudeJSON: [String: Any], parked: ParkedSaver?) -> [String: Any] {
        var hooks: [String: [Any]] = [:]
        for (event, value) in settings["hooks"] as? [String: Any] ?? [:] {
            for entry in (value as? [Any] ?? []).compactMap(JSONAccess.object) {
                let mine = (entry["hooks"] as? [Any] ?? []).compactMap(JSONAccess.object)
                    .filter { commandOf($0).map(saver.matches(hookCommand:)) ?? false }
                guard !mine.isEmpty else { continue }
                var group: [String: Any] = ["hooks": mine]
                group["matcher"] = entry["matcher"]
                hooks[event, default: []].append(group)
            }
        }
        var mcp: [String: Any] = [:]
        for object in [settings, claudeJSON] {
            let servers = object["mcpServers"] as? [String: Any] ?? [:]
            for name in mcpNames(saver, in: object) { mcp[name] = servers[name] }
        }
        if let parked {
            for hook in parked.hooks {
                var group: [String: Any] = ["hooks": [decode(hook.hookJSON) ?? [:]]]
                group["matcher"] = hook.matcher
                hooks[hook.event, default: []].append(group)
            }
            for (name, json) in parked.settingsMcp.merging(parked.claudeJSONMcp, uniquingKeysWith: { a, _ in a }) {
                mcp[name] = decode(json) ?? [:]
            }
        }
        let plugins = (settings["enabledPlugins"] as? [String: Any] ?? [:]).keys.filter(saver.matches(pluginKey:)).sorted()
        return ["hooks": hooks, "mcp": mcp, "plugins": plugins]
    }

    public static func state(
        of saver: TokenSaver, settings: [String: Any], claudeJSON: [String: Any], parked: ParkedSaver?
    ) -> SaverSwitchState {
        if let plugins = settings["enabledPlugins"] as? [String: Any],
           let key = plugins.keys.first(where: saver.matches(pluginKey:)) {
            return (plugins[key] as? Bool ?? false) ? .on : .off
        }
        let hooks = !matchingHooks(saver, in: settings).isEmpty
        let servers = !mcpNames(saver, in: settings).isEmpty || !mcpNames(saver, in: claudeJSON).isEmpty
        if hooks || servers { return .on }
        if let parked, !parked.isEmpty { return .off }
        return .notInstalled
    }

    static func apply(
        _ saver: TokenSaver, on: Bool,
        settings: inout [String: Any], claudeJSON: inout [String: Any],
        parked: inout [TokenSaver: ParkedSaver]
    ) throws -> SaverSwitchChange {
        var summary: [String] = []
        var settingsChanged = false, claudeJSONChanged = false

        // A plugin flag is the whole story when there is one.
        if var plugins = settings["enabledPlugins"] as? [String: Any],
           let key = plugins.keys.sorted().first(where: saver.matches(pluginKey:)) {
            if (plugins[key] as? Bool) != on {
                plugins[key] = on
                settings["enabledPlugins"] = plugins
                settingsChanged = true
                summary.append("settings.json: enabledPlugins.\(key) → \(on)")
            }
            return SaverSwitchChange(saver: saver, on: on, summary: summary,
                                     settingsChanged: settingsChanged, claudeJSONChanged: false)
        }

        if on {
            guard let entry = parked[saver], !entry.isEmpty else {
                if state(of: saver, settings: settings, claudeJSON: claudeJSON, parked: nil) == .on {
                    return SaverSwitchChange(saver: saver, on: on, summary: [], settingsChanged: false, claudeJSONChanged: false)
                }
                throw SaverSwitchError.notInstalled(saver)
            }
            for hook in entry.hooks {
                guard let object = decode(hook.hookJSON) else { continue }
                insertHook(object, event: hook.event, matcher: hook.matcher, into: &settings)
                settingsChanged = true
                summary.append("settings.json: restore \(hook.event) hook \(commandOf(object) ?? "")")
            }
            if !entry.settingsMcp.isEmpty {
                var servers = settings["mcpServers"] as? [String: Any] ?? [:]
                for (name, json) in entry.settingsMcp { servers[name] = decode(json) ?? [:] }
                settings["mcpServers"] = servers
                settingsChanged = true
                summary.append("settings.json: restore mcpServers \(entry.settingsMcp.keys.sorted().joined(separator: ", "))")
            }
            if !entry.claudeJSONMcp.isEmpty {
                var servers = claudeJSON["mcpServers"] as? [String: Any] ?? [:]
                for (name, json) in entry.claudeJSONMcp { servers[name] = decode(json) ?? [:] }
                claudeJSON["mcpServers"] = servers
                claudeJSONChanged = true
                summary.append(".claude.json: restore mcpServers \(entry.claudeJSONMcp.keys.sorted().joined(separator: ", "))")
            }
            parked[saver] = nil
        } else {
            var entry = parked[saver] ?? ParkedSaver()
            let removed = removeHooks(saver, from: &settings)
            for hook in removed {
                summary.append("settings.json: park \(hook.event) hook \(decode(hook.hookJSON).flatMap(commandOf) ?? "")")
            }
            entry.hooks += removed
            settingsChanged = settingsChanged || !removed.isEmpty
            for name in mcpNames(saver, in: settings) {
                var servers = settings["mcpServers"] as? [String: Any] ?? [:]
                entry.settingsMcp[name] = JSONAccess.jsonString(servers[name]) ?? "{}"
                servers[name] = nil
                settings["mcpServers"] = servers
                settingsChanged = true
                summary.append("settings.json: park mcpServers.\(name)")
            }
            for name in mcpNames(saver, in: claudeJSON) {
                var servers = claudeJSON["mcpServers"] as? [String: Any] ?? [:]
                entry.claudeJSONMcp[name] = JSONAccess.jsonString(servers[name]) ?? "{}"
                servers[name] = nil
                claudeJSON["mcpServers"] = servers
                claudeJSONChanged = true
                summary.append(".claude.json: park mcpServers.\(name)")
            }
            if summary.isEmpty && entry.isEmpty { throw SaverSwitchError.notInstalled(saver) }
            if !summary.isEmpty { entry.parkedAt = Timestamps.now() }
            parked[saver] = entry
        }
        return SaverSwitchChange(saver: saver, on: on, summary: summary,
                                 settingsChanged: settingsChanged, claudeJSONChanged: claudeJSONChanged)
    }

    /// `hooks.<Event>[].hooks[]` objects whose command belongs to the saver.
    static func matchingHooks(_ saver: TokenSaver, in settings: [String: Any]) -> [(event: String, command: String)] {
        guard let hooks = settings["hooks"] as? [String: Any] else { return [] }
        var found: [(String, String)] = []
        for (event, value) in hooks {
            for entry in (value as? [Any] ?? []).compactMap(JSONAccess.object) {
                for hook in (entry["hooks"] as? [Any] ?? []).compactMap(JSONAccess.object) {
                    if let command = commandOf(hook), saver.matches(hookCommand: command) { found.append((event, command)) }
                }
            }
        }
        return found
    }

    static func removeHooks(_ saver: TokenSaver, from settings: inout [String: Any]) -> [ParkedSaver.Hook] {
        guard var hooks = settings["hooks"] as? [String: Any] else { return [] }
        var removed: [ParkedSaver.Hook] = []
        for event in hooks.keys.sorted() {
            var entries: [Any] = []
            for item in hooks[event] as? [Any] ?? [] {
                guard var entry = JSONAccess.object(item) else { entries.append(item); continue }
                let matcher = entry["matcher"] as? String
                var kept: [Any] = []
                for hookItem in entry["hooks"] as? [Any] ?? [] {
                    if let hook = JSONAccess.object(hookItem), let command = commandOf(hook),
                       saver.matches(hookCommand: command) {
                        removed.append(ParkedSaver.Hook(event: event, matcher: matcher, hookJSON: JSONAccess.jsonString(hook) ?? "{}"))
                    } else {
                        kept.append(hookItem)
                    }
                }
                // An entry left with no hooks goes; one that had none stays as it was.
                if kept.isEmpty, !(entry["hooks"] as? [Any] ?? []).isEmpty { continue }
                entry["hooks"] = kept
                entries.append(entry)
            }
            if entries.isEmpty { hooks[event] = nil } else { hooks[event] = entries }
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        return removed
    }

    static func insertHook(_ hook: [String: Any], event: String, matcher: String?, into settings: inout [String: Any]) {
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var entries = hooks[event] as? [Any] ?? []
        if let index = entries.firstIndex(where: { (JSONAccess.object($0)?["matcher"] as? String) == matcher }),
           var entry = JSONAccess.object(entries[index]) {
            var list = entry["hooks"] as? [Any] ?? []
            list.append(hook)
            entry["hooks"] = list
            entries[index] = entry
        } else {
            var entry: [String: Any] = ["hooks": [hook]]
            if let matcher { entry["matcher"] = matcher }
            entries.append(entry)
        }
        hooks[event] = entries
        settings["hooks"] = hooks
    }

    static func mcpNames(_ saver: TokenSaver, in object: [String: Any]) -> [String] {
        (object["mcpServers"] as? [String: Any] ?? [:]).keys.filter(saver.matches(mcpServer:)).sorted()
    }

    static func commandOf(_ hook: [String: Any]) -> String? { hook["command"] as? String }

    static func decode(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Files

    func readObject(_ url: URL) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: url.path) else { return [:] }
        guard let data = fileManager.contents(atPath: url.path),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw SaverSwitchError.unreadable(url.path)
        }
        return object
    }

    func write(_ object: [String: Any], to url: URL) throws {
        let backups = parkedURL.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true)
        try fileManager.createDirectory(at: backups, withIntermediateDirectories: true)
        if let original = fileManager.contents(atPath: url.path) {
            let stamp = Timestamps.now().replacingOccurrences(of: ":", with: "-")
            let name = url.lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            try original.write(to: backups.appendingPathComponent("\(name).\(stamp).json"))
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    func readParked() -> [TokenSaver: ParkedSaver] {
        guard let root = try? readObject(parkedURL) else { return [:] }
        var result: [TokenSaver: ParkedSaver] = [:]
        for (key, value) in root {
            guard let saver = TokenSaver(rawValue: key), let object = JSONAccess.object(value) else { continue }
            var entry = ParkedSaver()
            entry.parkedAt = object["parked_at"] as? String
            for hook in (object["hooks"] as? [Any] ?? []).compactMap(JSONAccess.object) {
                guard let event = hook["event"] as? String, let body = JSONAccess.object(hook["hook"]) else { continue }
                entry.hooks.append(.init(event: event, matcher: hook["matcher"] as? String,
                                         hookJSON: JSONAccess.jsonString(body) ?? "{}"))
            }
            for (name, config) in object["settings_mcp"] as? [String: Any] ?? [:] {
                entry.settingsMcp[name] = JSONAccess.jsonString(config) ?? "{}"
            }
            for (name, config) in object["claude_json_mcp"] as? [String: Any] ?? [:] {
                entry.claudeJSONMcp[name] = JSONAccess.jsonString(config) ?? "{}"
            }
            result[saver] = entry
        }
        return result
    }

    func writeParked(_ parked: [TokenSaver: ParkedSaver]) throws {
        var root: [String: Any] = [:]
        for (saver, entry) in parked where !entry.isEmpty {
            var object: [String: Any] = [:]
            object["parked_at"] = entry.parkedAt
            object["hooks"] = entry.hooks.map { hook -> [String: Any] in
                var item: [String: Any] = ["event": hook.event, "hook": Self.decode(hook.hookJSON) ?? [:]]
                item["matcher"] = hook.matcher
                return item
            }
            object["settings_mcp"] = entry.settingsMcp.mapValues { Self.decode($0) ?? [:] }
            object["claude_json_mcp"] = entry.claudeJSONMcp.mapValues { Self.decode($0) ?? [:] }
            root[saver.rawValue] = object
        }
        try fileManager.createDirectory(at: parkedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: parkedURL, options: .atomic)
    }
}

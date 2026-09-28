import Foundation

/// A third-party tool that exists to spend fewer tokens.
///
/// They split by *what* they shrink, and that decides what Ullage can say
/// about them:
///
/// - **rtk** and **Tokenade** shrink what the model reads (tool output). Ullage
///   only ever sees the output *after* shrinking, so the saving itself cannot be
///   measured here — only the tool's own ledger can claim it, and it is shown
///   as that tool's claim (rule 6).
/// - **caveman** shrinks what the model writes. Output tokens are measured, so
///   turns with it and without it can be compared — a comparison of different
///   work, never a counterfactual saving.
/// - **Headroom** is an MCP server; it only saves anything when called. Whether
///   it was configured and whether it was called are both facts.
///
/// Detection comes from the transcript first: every hook Claude Code runs is
/// written down with its command, so a saver's hook is evidence it ran. Config
/// is only consulted for what is switched on *now*.
public enum TokenSaver: String, CaseIterable, Sendable {
    case rtk
    case tokenade
    case caveman
    case headroom

    public var displayName: String {
        switch self {
        case .rtk: return "rtk"
        case .tokenade: return "Tokenade"
        case .caveman: return "caveman"
        case .headroom: return "Headroom"
        }
    }

    public var shrinks: String {
        switch self {
        case .rtk: return "Bash output"
        case .tokenade: return "Bash and Read output, MCP tool lists"
        case .caveman: return "the model's replies"
        case .headroom: return "tool output, when called"
        }
    }

    /// Where a figure about this saver's saving comes from.
    public var savingSource: String {
        switch self {
        case .rtk: return "rtk's own estimate (bytes ÷ 4)"
        case .tokenade: return "Tokenade's own ledger; its method is not stated"
        case .caveman: return "measured output, with vs without — a comparison, not a saving"
        case .headroom: return "not measured"
        }
    }

    /// Does a hook command belong to this saver? Matched on the command text,
    /// which is what both `settings.json` and the transcript record.
    public func matches(hookCommand command: String) -> Bool {
        let lowered = command.lowercased()
        switch self {
        case .rtk:
            // A word, not a substring: "rtk" inside another word is not rtk.
            return lowered.range(of: #"(^|[\s/"'])rtk([\s\-_."']|$)"#, options: .regularExpression) != nil
        case .tokenade: return lowered.contains("tokenade")
        case .caveman: return lowered.contains("caveman")
        case .headroom: return lowered.contains("headroom")
        }
    }

    public func matches(mcpServer name: String) -> Bool {
        let lowered = name.lowercased()
        switch self {
        case .rtk, .caveman: return false
        case .tokenade: return lowered.contains("tokenade")
        case .headroom: return lowered.contains("headroom")
        }
    }

    /// `enabledPlugins` keys are `<plugin>@<marketplace>`.
    public func matches(pluginKey key: String) -> Bool {
        switch self {
        case .caveman: return key.lowercased().hasPrefix("caveman@")
        default: return false
        }
    }

    /// Skill tool targets and slash commands: `caveman`, `caveman:compress`,
    /// `caveman-commit`.
    public func matches(skillOrCommand name: String) -> Bool {
        let lowered = name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch self {
        case .caveman: return lowered == "caveman" || lowered.hasPrefix("caveman:") || lowered.hasPrefix("caveman-")
        default: return false
        }
    }

    public static func saver(forHookCommand command: String) -> TokenSaver? {
        allCases.first { $0.matches(hookCommand: command) }
    }
}

// MARK: - What the transcript records

/// One hook run, as Claude Code wrote it down in an `attachment` line.
/// Mirrors the `detail` of an `event` row of kind `hook`.
public struct HookRun: Equatable {
    public var hookEvent: String        // PreToolUse, SessionStart, …
    public var hookName: String?        // "PreToolUse:Bash", "SessionStart:startup"
    public var command: String
    /// The tool_use this hook ran for, when it ran for one.
    public var toolUseId: String?
    public var exitCode: Int?
    /// The command a PreToolUse hook replaced the model's with, when it did.
    public var rewrittenCommand: String?
    /// The first few hundred bytes of stderr — enough to say "not installed".
    public var stderr: String?

    public init(
        hookEvent: String, hookName: String? = nil, command: String, toolUseId: String? = nil,
        exitCode: Int? = nil, rewrittenCommand: String? = nil, stderr: String? = nil
    ) {
        self.hookEvent = hookEvent
        self.hookName = hookName
        self.command = command
        self.toolUseId = toolUseId
        self.exitCode = exitCode
        self.rewrittenCommand = rewrittenCommand
        self.stderr = stderr
    }

    static let stderrLimit = 300

    var detailObject: [String: Any] {
        var object: [String: Any] = ["event": hookEvent, "command": command]
        object["name"] = hookName
        object["tool_use_id"] = toolUseId
        object["exit_code"] = exitCode
        object["rewrite"] = rewrittenCommand
        object["stderr"] = stderr
        return object
    }

    public var detailJSON: String? { JSONAccess.jsonString(detailObject) }

    public init?(detail: String?) {
        guard let detail, let data = detail.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let event = JSONAccess.string(object, "event"),
              let command = JSONAccess.string(object, "command") else { return nil }
        self.init(
            hookEvent: event,
            hookName: JSONAccess.string(object, "name"),
            command: command,
            toolUseId: JSONAccess.string(object, "tool_use_id"),
            exitCode: JSONAccess.int(object, "exit_code"),
            rewrittenCommand: JSONAccess.string(object, "rewrite"),
            stderr: JSONAccess.string(object, "stderr")
        )
    }

    /// The hook ran but could not do its job — a non-zero exit, or the saver
    /// saying it is missing (rtk's hook exits 0 and warns on stderr).
    public var failed: Bool {
        if let exitCode, exitCode != 0 { return true }
        guard let stderr = stderr?.lowercased() else { return false }
        return stderr.contains("not installed") || stderr.contains("not found") || stderr.contains("not in path")
    }
}

/// A slash command the user typed. Mirrors the `detail` of an `event` row of
/// kind `command`.
public struct SlashCommand: Equatable {
    public var name: String             // without the leading slash
    public var args: String?

    public init(name: String, args: String? = nil) {
        self.name = name
        self.args = args
    }

    public var detailJSON: String? {
        var object: [String: Any] = ["name": name]
        object["args"] = args
        return JSONAccess.jsonString(object)
    }

    public init?(detail: String?) {
        guard let detail, let data = detail.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = JSONAccess.string(object, "name") else { return nil }
        self.init(name: name, args: JSONAccess.string(object, "args"))
    }
}

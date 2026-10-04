import Foundation

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
    /// Bytes the hook added to the model's context: `additionalContext` from
    /// its JSON, or the plain stdout of a SessionStart/UserPromptSubmit hook,
    /// which Claude Code adds to the context as is. A size, never the text.
    public var injectedBytes: Int?

    public init(
        hookEvent: String, hookName: String? = nil, command: String, toolUseId: String? = nil,
        exitCode: Int? = nil, rewrittenCommand: String? = nil, stderr: String? = nil, injectedBytes: Int? = nil
    ) {
        self.hookEvent = hookEvent
        self.hookName = hookName
        self.command = command
        self.toolUseId = toolUseId
        self.exitCode = exitCode
        self.rewrittenCommand = rewrittenCommand
        self.stderr = stderr
        self.injectedBytes = injectedBytes
    }

    static let stderrLimit = 300

    var detailObject: [String: Any] {
        var object: [String: Any] = ["event": hookEvent, "command": command]
        object["name"] = hookName
        object["tool_use_id"] = toolUseId
        object["exit_code"] = exitCode
        object["rewrite"] = rewrittenCommand
        object["stderr"] = stderr
        object["injected"] = injectedBytes
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
            stderr: JSONAccess.string(object, "stderr"),
            injectedBytes: JSONAccess.int(object, "injected")
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

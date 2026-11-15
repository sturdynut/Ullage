import Foundation

extension ClaudeCodeParser {
    // MARK: - Remote Control

    /// `attachment.type == "remote_session_change"` carries the claude.ai URL
    /// a Remote Control session can be driven from. Observed on 2.1.259.
    /// Only a claude.ai/code URL is kept: it is put behind a link.
    static func remoteSessionEvent(entry: [String: Any], rawLine: Data, context: LineContext) -> EventRow? {
        guard let attachment = JSONAccess.dict(entry, "attachment"),
              JSONAccess.string(attachment, "type") == "remote_session_change",
              let url = JSONAccess.string(attachment, "url"),
              url.hasPrefix("https://claude.ai/code/") else { return nil }
        return EventRow(
            id: eventID(kind: .remote, entry: entry, rawLine: rawLine, context: context),
            sessionId: sessionId(entry: entry, context: context),
            agentId: JSONAccess.string(entry, "agentId"),
            ts: timestamp(entry: entry, context: context),
            kind: EventKind.remote.rawValue,
            detail: url
        )
    }

    // MARK: - Hooks and slash commands

    /// Claude Code writes every hook it runs as an `attachment` line: which
    /// event, the command, the tool_use it ran for, exit code and output. That
    /// is the evidence a token saver (rtk, Tokenade, caveman) actually ran —
    /// config only says it was meant to. Observed on 2.1.207 through 2.1.280.
    static func hookEvent(entry: [String: Any], rawLine: Data, context: LineContext) -> EventRow? {
        guard let attachment = JSONAccess.dict(entry, "attachment"),
              let hookEvent = JSONAccess.string(attachment, "hookEvent"),
              let command = JSONAccess.string(attachment, "command"), !command.isEmpty else { return nil }
        let stderr = JSONAccess.string(attachment, "stderr").flatMap { text -> String? in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(HookRun.stderrLimit))
        }
        let run = HookRun(
            hookEvent: hookEvent,
            hookName: JSONAccess.string(attachment, "hookName"),
            command: command,
            toolUseId: JSONAccess.string(attachment, "toolUseID"),
            exitCode: JSONAccess.int(attachment, "exitCode"),
            rewrittenCommand: rewrittenCommand(stdout: JSONAccess.string(attachment, "stdout")),
            stderr: stderr,
            injectedBytes: injectedBytes(event: hookEvent, stdout: JSONAccess.string(attachment, "stdout"))
        )
        return EventRow(
            id: eventID(kind: .hook, entry: entry, rawLine: rawLine, context: context),
            sessionId: sessionId(entry: entry, context: context),
            agentId: JSONAccess.string(entry, "agentId"),
            ts: timestamp(entry: entry, context: context),
            kind: EventKind.hook.rawValue,
            detail: run.detailJSON
        )
    }

    /// A PreToolUse hook that rewrites a Bash command answers with
    /// `hookSpecificOutput.updatedInput.command`.
    static func rewrittenCommand(stdout: String?) -> String? {
        guard let stdout, let data = stdout.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let specific = JSONAccess.dict(root, "hookSpecificOutput")
        return JSONAccess.string(JSONAccess.dict(specific, "updatedInput"), "command")
    }

    /// What a hook put into the context, as a size: `additionalContext` in
    /// its JSON answer, or — for SessionStart and UserPromptSubmit, whose
    /// plain stdout Claude Code adds to the context — that stdout. A JSON
    /// answer without `additionalContext` (a `systemMessage` shown to the
    /// user, a rewrite) injects nothing.
    static func injectedBytes(event: String, stdout: String?) -> Int? {
        guard let stdout, !stdout.isEmpty else { return nil }
        if let data = stdout.data(using: .utf8),
           let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let context = JSONAccess.string(JSONAccess.dict(root, "hookSpecificOutput"), "additionalContext")
            return context.map { $0.utf8.count }
        }
        return ["SessionStart", "UserPromptSubmit"].contains(event) ? stdout.utf8.count : nil
    }

    /// `<command-name>/caveman</command-name> … <command-args>ultra</command-args>`
    /// as the whole content of a user line. Only a line that *starts* with the
    /// tag counts: the same text quoted in a prompt is not a command.
    static func slashCommandEvent(entry: [String: Any], rawLine: Data, context: LineContext) -> EventRow? {
        guard let message = JSONAccess.dict(entry, "message") else { return nil }
        let text: String?
        if let content = JSONAccess.string(message, "content") {
            text = content
        } else if let blocks = JSONAccess.list(message, "content"),
                  let first = blocks.compactMap(JSONAccess.object).first(where: {
                      JSONAccess.string($0, "type") == "text"
                  }) {
            text = JSONAccess.string(first, "text")
        } else {
            text = nil
        }
        guard let text, text.trimmingCharacters(in: .whitespaces).hasPrefix("<command-name>"),
              let name = tagValue("command-name", in: text) else { return nil }
        let bare = name.hasPrefix("/") ? String(name.dropFirst()) : name
        guard !bare.isEmpty else { return nil }
        let args = tagValue("command-args", in: text).flatMap { $0.isEmpty ? nil : $0 }
        return EventRow(
            id: eventID(kind: .command, entry: entry, rawLine: rawLine, context: context),
            sessionId: sessionId(entry: entry, context: context),
            agentId: JSONAccess.string(entry, "agentId"),
            ts: timestamp(entry: entry, context: context),
            kind: EventKind.command.rawValue,
            detail: SlashCommand(name: bare, args: args).detailJSON
        )
    }

    static func tagValue(_ tag: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"),
              let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex) else { return nil }
        return String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Events

    static func compactionEvent(
        entry: [String: Any],
        rawLine: Data,
        context: LineContext
    ) -> EventRow? {
        let metadata = JSONAccess.dict(entry, "compactMetadata")
        let isCompactSummary = JSONAccess.bool(entry, "isCompactSummary") ?? false
        let subtype = JSONAccess.string(entry, "subtype")
        guard metadata != nil || isCompactSummary || subtype == "compact_boundary" else {
            return nil
        }
        return EventRow(
            id: eventID(kind: .compaction, entry: entry, rawLine: rawLine, context: context),
            sessionId: sessionId(entry: entry, context: context),
            agentId: JSONAccess.string(entry, "agentId"),
            ts: timestamp(entry: entry, context: context),
            kind: EventKind.compaction.rawValue,
            detail: JSONAccess.jsonString(metadata) ?? JSONAccess.jsonString(entry)
        )
    }

    /// Deterministic so re-ingesting a file cannot duplicate events.
    static func eventID(
        kind: EventKind,
        entry: [String: Any],
        rawLine: Data,
        context: LineContext
    ) -> String {
        if let uuid = JSONAccess.string(entry, "uuid") { return "\(kind.rawValue):\(uuid)" }
        if let leaf = JSONAccess.string(entry, "leafUuid") { return "\(kind.rawValue):\(leaf)" }
        return "\(kind.rawValue):\(sessionId(entry: entry, context: context)):\(Hashing.fnv1a(rawLine))"
    }

    static func sessionId(entry: [String: Any], context: LineContext) -> String {
        JSONAccess.string(entry, "sessionId") ?? context.fallbackSessionId
    }

    static func timestamp(entry: [String: Any], context: LineContext) -> String {
        Timestamps.normalize(JSONAccess.string(entry, "timestamp"))
            ?? context.lastTimestamp
            ?? ""
    }
}

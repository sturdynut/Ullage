import Foundation

extension Vendor {
    public static let geminiCLI = "gemini-cli"
}

/// Where Google's Gemini CLI keeps its chat recordings.
///
/// `<runtime>/tmp/<project-slug>/chats/session-<yyyy-mm-ddThh-mm>-<shortId>.jsonl`
/// for a main session, `chats/<parentSessionId>/<subagentId>.jsonl` for a
/// subagent, and `session-….json` for sessions recorded before the JSONL
/// format. The runtime directory is `~/.gemini`; `GEMINI_CLI_HOME` replaces the
/// home directory it sits in, and under macOS Seatbelt (`SANDBOX=sandbox-exec`)
/// it moves to `~/.cache/.gemini` (gemini-cli `config/storage.ts:54-108`,
/// `utils/paths.ts:22-28`). Both are swept.
public enum GeminiPaths {
    public static func runtimeDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        let home: URL
        if let override = environment["GEMINI_CLI_HOME"], !override.isEmpty {
            home = URL(fileURLWithPath: ClaudePaths.expand(override), isDirectory: true)
        } else {
            home = ClaudePaths.homeDirectory()
        }
        return [
            home.appendingPathComponent(".gemini", isDirectory: true),
            home.appendingPathComponent(".cache/.gemini", isDirectory: true),
        ]
    }

    public static func tmpDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        runtimeDirectories(environment: environment).map { $0.appendingPathComponent("tmp", isDirectory: true) }
    }

    /// True only for a chat recording: `…/.gemini/tmp/<slug>/chats/session-*.json[l]`
    /// or `…/.gemini/tmp/<slug>/chats/<parent>/<id>.jsonl`. Nothing else under
    /// `~/.gemini` (Antigravity, settings, logs, checkpoints) is claimed.
    public static func isGeminiTranscript(_ path: String) -> Bool {
        guard let range = path.range(of: "/.gemini/tmp/") else { return false }
        let rest = path[range.upperBound...].split(separator: "/").map(String.init)
        // <slug>/chats/<file>  or  <slug>/chats/<parent>/<file>
        guard rest.count == 3 || rest.count == 4, rest[1] == "chats", let file = rest.last else { return false }
        if rest.count == 3 {
            return file.hasPrefix("session-") && (file.hasSuffix(".jsonl") || file.hasSuffix(".json"))
        }
        return file.hasSuffix(".jsonl")
    }

    /// The working directory for a recording, from the `.project_root` marker
    /// the project registry writes into the slug directory
    /// (`config/projectRegistry.ts:375-400`), else a reverse lookup in
    /// `<runtime>/projects.json`. On macOS both hold the *lower-cased* path
    /// (`utils/paths.ts:347-352`). Nil for legacy hash-named directories.
    static func cwd(forTranscript path: String) -> String? {
        guard let range = path.range(of: "/.gemini/tmp/") else { return nil }
        let runtime = String(path[path.startIndex..<range.lowerBound]) + "/.gemini"
        guard let slug = path[range.upperBound...].split(separator: "/").first.map(String.init) else { return nil }
        let marker = runtime + "/tmp/" + slug + "/.project_root"
        if let data = FileManager.default.contents(atPath: marker),
           let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }
        if let data = FileManager.default.contents(atPath: runtime + "/projects.json"),
           let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let projects = root["projects"] as? [String: Any] {
            return projects.first(where: { ($0.value as? String) == slug })?.key
        }
        return nil
    }
}

/// Shared shape of Gemini `Part` lists, used by Gemini CLI and Qwen Code.
enum GeminiContent {
    /// Length estimate of a tool result (rule 6: never a real count). A
    /// `functionResponse` carries its payload under `response.output` or
    /// `response.error`, which the generic estimator does not look inside.
    static func resultTokens(_ parts: Any?) -> Int? {
        guard let parts else { return nil }
        let list = (parts as? [Any]) ?? [parts]
        let flattened: [Any] = list.map { part in
            guard let dict = part as? [String: Any],
                  let response = JSONAccess.dict(JSONAccess.dict(dict, "functionResponse"), "response") else { return part }
            return ["output": response["output"] as Any, "text": response["error"] as Any, "content": response["content"] as Any]
        }
        return ClaudeCodeParser.estimateTokens(of: flattened)
    }

    /// The identifying argument of a tool call: a path, a command, a query.
    static func target(args: [String: Any]?) -> String? {
        for key in ["file_path", "absolute_path", "dir_path", "path", "command", "pattern", "query", "url", "agent_name", "subagent_type", "name", "prompt"] {
            if let value = JSONAccess.string(args, key) {
                return String(value.prefix(ClaudeCodeParser.targetLimit))
            }
        }
        return nil
    }
}

/// Reads one Gemini CLI chat recording as a whole document.
///
/// The JSONL file is an append-only log, not a list of turns
/// (gemini-cli `services/chatRecordingService.ts`): a message is appended
/// whole every time it changes — first without tokens, then again once the
/// response's usage arrives (`recordMessageTokens`, :1087-1116), and again
/// as tool calls are merged into it (:1118-1180). `{"$set":…}` updates
/// metadata, `{"$patch":…}` rewrites history (tool results, removals,
/// reordering), and `{"$rewindTo":id}` drops a tail. So the file is replayed
/// like the CLI's own loader does (:302-547) and each message id's final
/// version becomes one row; the dedupe key is the message id, so a re-read
/// rewrites the same rows.
///
/// Token semantics follow the Gemini API: `tokens.input` is
/// `promptTokenCount`, which *includes* `cached` (`cachedContentTokenCount`),
/// so the prompt is split back into an uncached remainder plus cache reads.
/// `tool` (`toolUsePromptTokenCount`, prompts of server-side tools such as
/// search grounding) is outside `promptTokenCount` and outside the window the
/// CLI tracks (`core/client.ts` subtracts only `promptTokenCount` from
/// `tokenLimit`), so it is not counted. No cache writes are reported.
///
/// A rewound or removed message stays a row: the request was made and its
/// counts are real, only the conversation moved on.
public struct GeminiCLIReader: TranscriptDocumentReader {
    public static let version = 1

    public init() {}

    private enum Slot {
        case message(String)
        case historyRewrite(String)
    }

    public func read(file: URL, context: LineContext) -> [ParsedLine] {
        guard let data = FileManager.default.contents(atPath: file.path) else { return [] }
        return parse(data: data, context: context, cwd: GeminiPaths.cwd(forTranscript: context.sourceFile))
    }

    /// Pure entry point for tests: the file's bytes, plus the cwd resolved
    /// from the project registry.
    func parse(data: Data, context: LineContext, cwd: String?) -> [ParsedLine] {
        var messages: [String: [String: Any]] = [:]
        var slots: [Slot] = []
        var metadata: [String: Any] = [:]

        func absorb(message record: [String: Any]) {
            guard let id = JSONAccess.string(record, "id") else { return }
            if let previous = messages[id] {
                var merged = record
                // A later append never drops tokens or model on purpose.
                for key in ["tokens", "model", "toolCalls"] where merged[key] == nil || merged[key] is NSNull {
                    if let value = previous[key] { merged[key] = value }
                }
                messages[id] = merged
            } else {
                messages[id] = record
                slots.append(.message(id))
            }
        }

        func applyPatch(_ patch: [String: Any]) {
            guard let id = JSONAccess.string(patch, "id"), var message = messages[id],
                  let toolPatches = JSONAccess.list(patch, "toolCalls"),
                  var calls = JSONAccess.list(message, "toolCalls") else { return }
            for case let toolPatch as [String: Any] in toolPatches {
                guard let toolId = JSONAccess.string(toolPatch, "id"), toolPatch.keys.contains("result") else { continue }
                for index in calls.indices {
                    guard var call = calls[index] as? [String: Any], JSONAccess.string(call, "id") == toolId else { continue }
                    call["result"] = toolPatch["result"]
                    calls[index] = call
                }
            }
            message["toolCalls"] = calls
            messages[id] = message
        }

        var records: [[String: Any]] = []
        if file(isLegacy: context.sourceFile),
           let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            records = [root]
        } else {
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                if let record = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] {
                    records.append(record)
                }
            }
        }

        for record in records {
            if record["$rewindTo"] is String {
                continue   // the calls before and after were both made
            } else if let patch = JSONAccess.dict(record, "$patch") {
                applyPatch(patch)
                for case let update as [String: Any] in JSONAccess.list(patch, "updates") ?? [] { applyPatch(update) }
                let removed = (JSONAccess.list(patch, "removeIds") ?? []).compactMap { $0 as? String }
                if let first = removed.first { slots.append(.historyRewrite(first)) }
            } else if let set = JSONAccess.dict(record, "$set") {
                for (key, value) in set where key != "messages" { metadata[key] = value }
                for case let message as [String: Any] in JSONAccess.list(set, "messages") ?? [] { absorb(message: message) }
            } else if JSONAccess.string(record, "id") != nil, JSONAccess.string(record, "type") != nil {
                absorb(message: record)
            } else if JSONAccess.string(record, "sessionId") != nil {
                // The opening metadata line, or a whole legacy `.json` record.
                for (key, value) in record where key != "messages" { metadata[key] = value }
                for case let message as [String: Any] in JSONAccess.list(record, "messages") ?? [] { absorb(message: message) }
            }
        }

        // Identity. A subagent lives in chats/<parentSessionId>/<id>.jsonl and
        // shares its parent's session; its own id names its stream (rule 1).
        let url = URL(fileURLWithPath: context.sourceFile)
        let parentDir = url.deletingLastPathComponent().lastPathComponent
        let isSubagent = parentDir != "chats" || JSONAccess.string(metadata, "kind") == "subagent"
        let ownId = JSONAccess.string(metadata, "sessionId") ?? context.fallbackSessionId
        let sessionId = isSubagent && parentDir != "chats" ? parentDir : ownId
        let agentId: String? = isSubagent ? ownId : nil
        let project = cwd.map { URL(fileURLWithPath: $0).lastPathComponent }

        var out: [ParsedLine] = []
        var spawns: [ToolResultObservation] = []
        var pendingRewrite: String?
        var lastTs = Timestamps.normalize(JSONAccess.string(metadata, "startTime")) ?? context.fileModified ?? ""

        for slot in slots {
            switch slot {
            case .historyRewrite(let firstRemoved):
                pendingRewrite = pendingRewrite ?? firstRemoved
            case .message(let id):
                guard let message = messages[id] else { continue }
                lastTs = Timestamps.normalize(JSONAccess.string(message, "timestamp")) ?? lastTs
                guard JSONAccess.string(message, "type") == "gemini",
                      let tokens = JSONAccess.dict(message, "tokens") else { continue }
                let prompt = JSONAccess.intOrZero(tokens, "input")
                let output = JSONAccess.intOrZero(tokens, "output")
                guard prompt > 0 || output > 0 else { continue }

                // Emitted only once a call follows it, so a re-read of a file
                // ending in a rewrite never leaves a stale boundary pending.
                if let removed = pendingRewrite {
                    out.append(.event(EventRow(
                        id: "\(Vendor.geminiCLI):compaction:\(sessionId):\(agentId ?? "main"):\(removed)",
                        sessionId: sessionId, agentId: agentId, ts: lastTs,
                        kind: EventKind.compaction.rawValue,
                        detail: #"{"source":"$patch.removeIds"}"#
                    )))
                    pendingRewrite = nil
                }

                let cached = min(JSONAccess.intOrZero(tokens, "cached"), prompt)
                let model = JSONAccess.string(message, "model")
                let dedupeKey = "\(Vendor.geminiCLI):\(sessionId):\(id)"
                var tools: [ToolCallRow] = []
                for case let tool as [String: Any] in JSONAccess.list(message, "toolCalls") ?? [] {
                    guard let toolId = JSONAccess.string(tool, "id") else { continue }
                    let name = JSONAccess.string(tool, "name") ?? "tool"
                    let rowId = "\(Vendor.geminiCLI):\(sessionId):\(toolId)"
                    let spawned = JSONAccess.string(tool, "agentId")
                    let (kind, server) = GeminiCLIReader.classify(name, spawnsAgent: spawned != nil)
                    let status = JSONAccess.string(tool, "status")
                    let isError: Bool? = status.map { $0 == "error" }
                    let resultTokens = GeminiContent.resultTokens(tool["result"] is NSNull ? nil : tool["result"])
                    let args = JSONAccess.dict(tool, "args")
                    tools.append(ToolCallRow(
                        id: rowId, callId: dedupeKey, sessionId: sessionId,
                        ts: Timestamps.normalize(JSONAccess.string(tool, "timestamp")) ?? lastTs,
                        name: name, kind: kind.rawValue, mcpServer: server,
                        target: GeminiContent.target(args: args),
                        resultTokens: resultTokens, isError: isError,
                        parserVersion: GeminiCLIReader.version
                    ))
                    if let spawned {
                        spawns.append(ToolResultObservation(
                            toolUseId: rowId, resultTokens: resultTokens ?? 0, isError: isError ?? false,
                            agent: AgentSpawnInfo(
                                agentId: spawned, sessionId: sessionId,
                                agentType: JSONAccess.string(args, "agent_name") ?? name,
                                status: status
                            )
                        ))
                    }
                }

                let call = CallRow(
                    dedupeKey: dedupeKey,
                    ts: lastTs,
                    vendor: Vendor.geminiCLI,
                    agentId: agentId,
                    sessionId: sessionId,
                    project: project,
                    cwd: cwd,
                    model: model,
                    input: prompt - cached,
                    output: output,
                    cacheRead: cached,
                    cacheWrite: 0,
                    reasoning: JSONAccess.int(tokens, "thoughts"),
                    contextTokens: prompt,
                    windowLimit: WindowLimits.knownLimit(for: model),
                    sourceFile: context.sourceFile,
                    confidence: Confidence.exact.rawValue,
                    parserVersion: GeminiCLIReader.version
                )
                out.append(.call(ParsedCall(call: call, toolCalls: tools, claudeVersion: nil)))
            }
        }
        // After every tool row exists, so each spawn finds its invocation.
        if !spawns.isEmpty { out.append(.toolResults(spawns)) }
        return out
    }

    private func file(isLegacy path: String) -> Bool { path.hasSuffix(".json") }

    /// `mcp_<server>_<tool>` (gemini-cli `tools/mcp-tool.ts:37-73`; the server
    /// segment has no underscore), `activate_skill`, and any call that
    /// started a subagent (`invoke_agent`, or a record carrying `agentId`).
    static func classify(_ name: String, spawnsAgent: Bool) -> (ToolKind, String?) {
        if spawnsAgent || name == "invoke_agent" { return (.agent, nil) }
        if name == "activate_skill" { return (.skill, nil) }
        if name.hasPrefix("mcp_") {
            let rest = name.dropFirst("mcp_".count)
            let server = rest.split(separator: "_", maxSplits: 1).first.map(String.init)
            return (.mcp, server)
        }
        return (.builtin, nil)
    }
}

extension Harness {
    public static let geminiCLI = Harness(
        id: Vendor.geminiCLI, name: "Gemini CLI",
        capabilities: .init(
            occupancy: .everyCall, window: .lookup, cacheSplit: true, subagents: true, toolResults: true,
            compaction: true,
            notes: [
                "Gemini CLI reports cached input but not cache writes.",
                "Gemini CLI writes no compression marker; any history rewrite that removes messages is shown as a compaction.",
                "Project names come from Gemini CLI's project registry, which lower-cases paths on macOS.",
            ]
        ),
        roots: { GeminiPaths.tmpDirectories(environment: $0) },
        owns: GeminiPaths.isGeminiTranscript,
        reading: .document({ GeminiCLIReader() })
    )
}

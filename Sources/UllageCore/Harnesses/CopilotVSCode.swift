import Foundation

extension Vendor {
    public static let copilotVSCode = "copilot-vscode"
}

/// Where VS Code keeps Copilot Chat sessions. Per editor user directory
/// (`~/Library/Application Support/Code/User` on macOS, `~/.config/Code/User`
/// on Linux, likewise for Insiders and VSCodium):
///
/// - `workspaceStorage/<hash>/chatSessions/<sessionId>.json|.jsonl` — the chat
///   model, a whole document (`.json`, older) or a mutation log (`.jsonl`);
///   `workspaceStorage/<hash>/workspace.json` names the folder.
/// - `globalStorage/emptyWindowChatSessions/<sessionId>.json|.jsonl` — chats
///   from a window with no folder open.
/// - `…/GitHub.copilot-chat/debug-logs/<sessionId>/main.jsonl` (workspace or
///   global storage) — Copilot Chat's opt-in agent debug log, one line per
///   model call; subagents in `<label>-<childSessionId>.jsonl` beside it.
///
/// VS Code's own `VSCODE_APPDATA` and `VSCODE_PORTABLE` relocate the tree.
public enum CopilotVSCodePaths {
    static let products = ["Code", "Code - Insiders", "VSCodium"]

    public static func userDirectories(environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        if let portable = environment["VSCODE_PORTABLE"], !portable.isEmpty {
            return [URL(fileURLWithPath: ClaudePaths.expand(portable), isDirectory: true)
                .appendingPathComponent("user-data/User", isDirectory: true)]
        }
        let appData: URL
        if let override = environment["VSCODE_APPDATA"], !override.isEmpty {
            appData = URL(fileURLWithPath: ClaudePaths.expand(override), isDirectory: true)
        } else {
            #if os(macOS)
            appData = ClaudePaths.homeDirectory().appendingPathComponent("Library/Application Support", isDirectory: true)
            #else
            if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
                appData = URL(fileURLWithPath: ClaudePaths.expand(xdg), isDirectory: true)
            } else {
                appData = ClaudePaths.homeDirectory().appendingPathComponent(".config", isDirectory: true)
            }
            #endif
        }
        return products.map { appData.appendingPathComponent($0, isDirectory: true).appendingPathComponent("User", isDirectory: true) }
    }

    public static func roots(environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        userDirectories(environment: environment).flatMap { user in [
            user.appendingPathComponent("workspaceStorage", isDirectory: true),
            user.appendingPathComponent("globalStorage/emptyWindowChatSessions", isDirectory: true),
            user.appendingPathComponent("globalStorage/github.copilot-chat/debug-logs", isDirectory: true),
        ] }
    }

    enum Kind { case chatSession, debugLog }

    /// Which Copilot file `path` is, judged by fixed path segments only, so it
    /// never claims a VS Code fork's files (Cursor's are under `Cursor/User`).
    static func kind(of path: String) -> Kind? {
        let parts = path.split(separator: "/").map(String.init)
        guard let user = parts.lastIndex(of: "User"), user >= 1, user + 1 < parts.count,
              products.contains(parts[user - 1]) || parts[user - 1] == "user-data" else { return nil }
        let storage = parts[user + 1]
        guard storage == "workspaceStorage" || storage == "globalStorage" else { return nil }
        let file = parts[parts.count - 1]
        let parent = parts.count >= 2 ? parts[parts.count - 2] : ""
        let isJSONL = file.hasSuffix(".jsonl")
        if isJSONL || file.hasSuffix(".json") {
            if storage == "workspaceStorage", parent == "chatSessions", parts.count - 2 == user + 3 { return .chatSession }
            if storage == "globalStorage", parent == "emptyWindowChatSessions", parts.count - 2 == user + 2 { return .chatSession }
        }
        if isJSONL, parts.count >= 4, parts[parts.count - 3] == "debug-logs",
           parts[parts.count - 4].lowercased() == "github.copilot-chat" { return .debugLog }
        return nil
    }

    public static func isCopilotFile(_ path: String) -> Bool { kind(of: path) != nil }

    /// The debug logs that would hold `sessionId`'s calls, for a chat session
    /// file at `chatPath`: beside it in the same workspace's storage, or in
    /// global storage (Copilot's fallback when there is no workspace).
    static func debugLogs(forSession sessionId: String, chatPath: String) -> [URL] {
        let chat = URL(fileURLWithPath: chatPath)
        var candidates: [URL] = []
        let parts = chatPath.split(separator: "/").map(String.init)
        if let user = parts.lastIndex(of: "User"), user + 1 < parts.count {
            let userDir = URL(fileURLWithPath: "/" + parts[...user].joined(separator: "/"), isDirectory: true)
            if parts[user + 1] == "workspaceStorage" {
                candidates.append(chat.deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("GitHub.copilot-chat/debug-logs/\(sessionId)/main.jsonl"))
            }
            candidates.append(userDir.appendingPathComponent("globalStorage/github.copilot-chat/debug-logs/\(sessionId)/main.jsonl"))
        }
        return candidates
    }
}

/// Reads both Copilot Chat stores, routed by path.
///
/// **Chat sessions** give one reading per user request: VS Code persists
/// `promptTokens` beside each request, which Copilot Chat sets from the
/// `prompt_tokens` of the *latest* model call of the request's tool loop
/// (cached tokens included, no split). That is one call's prompt — a real
/// occupancy reading — but only one per request. The window is taken only
/// from `contextUsage.tokenLimit` when VS Code wrote it: Copilot serves models
/// under its own limits, so a vendor's window looked up by name would be the
/// wrong denominator.
///
/// **Debug logs**, when the user has turned them on, give every model call
/// with cached tokens split out. When a session has one, its request readings
/// are dropped in its favour, so the two never count the same calls twice.
public struct CopilotVSCodeReader: TranscriptDocumentReader {
    public static let version = 1

    public init() {}

    public func read(file: URL, context: LineContext) -> [ParsedLine] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        switch CopilotVSCodePaths.kind(of: file.path) {
        case .chatSession?:
            guard let document = Self.document(from: data, jsonl: file.pathExtension == "jsonl") else { return [] }
            return Self.chatSession(document, file: file, context: context)
        case .debugLog?:
            return Self.debugLog(data, file: file, context: context)
        case nil:
            return []
        }
    }

    // MARK: - Chat session document

    /// The session as VS Code would rebuild it. A `.jsonl` is a mutation log
    /// (`objectMutationLog.ts`): `kind` 0 is the whole state, 1 sets a value
    /// at path `k`, 2 pushes `v` onto the array at `k` after truncating it to
    /// `i`, 3 deletes `k`. A line that cannot be applied is skipped.
    static func document(from data: Data, jsonl: Bool) -> [String: Any]? {
        guard jsonl else {
            return (try? JSONSerialization.jsonObject(with: data, options: [.mutableContainers])) as? [String: Any]
        }
        var state: NSMutableDictionary?
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            guard let entry = (try? JSONSerialization.jsonObject(with: Data(line), options: [.mutableContainers])) as? NSDictionary,
                  let kind = (entry["kind"] as? NSNumber)?.intValue else { continue }
            if kind == 0 {
                state = entry["v"] as? NSMutableDictionary
                continue
            }
            guard let state, let path = entry["k"] as? [Any], !path.isEmpty else { continue }
            guard let parent = walk(state, path.dropLast()) else { continue }
            let last = path[path.count - 1]
            switch kind {
            case 1: assign(parent, key: last, value: entry["v"])
            case 3: assign(parent, key: last, value: nil)
            case 2:
                let existing = value(in: parent, key: last) as? NSMutableArray ?? NSMutableArray()
                if let start = (entry["i"] as? NSNumber)?.intValue, start >= 0, start < existing.count {
                    existing.removeObjects(in: NSRange(location: start, length: existing.count - start))
                }
                if let values = entry["v"] as? [Any] { existing.addObjects(from: values) }
                assign(parent, key: last, value: existing)
            default: continue
            }
        }
        return state as? [String: Any]
    }

    private static func walk(_ root: Any, _ path: ArraySlice<Any>) -> Any? {
        var current: Any = root
        for key in path {
            guard let next = value(in: current, key: key) else { return nil }
            current = next
        }
        return current
    }

    private static func value(in container: Any, key: Any) -> Any? {
        if let dict = container as? NSDictionary, let k = key as? String { return dict[k] }
        if let array = container as? NSArray, let i = (key as? NSNumber)?.intValue, i >= 0, i < array.count { return array[i] }
        return nil
    }

    private static func assign(_ container: Any, key: Any, value: Any?) {
        if let dict = container as? NSMutableDictionary, let k = key as? String {
            if let value, !(value is NSNull) { dict[k] = value } else { dict.removeObject(forKey: k) }
        } else if let array = container as? NSMutableArray, let i = (key as? NSNumber)?.intValue, i >= 0 {
            let item: Any = value ?? NSNull()
            if i < array.count { array[i] = item } else if i == array.count { array.add(item) }
        }
    }

    static func chatSession(_ doc: [String: Any], file: URL, context: LineContext) -> [ParsedLine] {
        let session = JSONAccess.string(doc, "sessionId") ?? context.fallbackSessionId
        let cwd = JSONAccess.string(doc, "workingDirectory").flatMap(path(fromURI:))
            ?? workspaceFolder(besideChatFile: file)
        let project = cwd.map { URL(fileURLWithPath: $0).lastPathComponent }

        // Prefer every-call readings when the debug log has them.
        let hasDebugLog = CopilotVSCodePaths.debugLogs(forSession: session, chatPath: file.path)
            .contains { debugLogHasCalls($0) }

        var out: [ParsedLine] = []
        for (index, item) in (JSONAccess.list(doc, "requests") ?? []).enumerated() {
            guard let request = item as? [String: Any] else { continue }
            let requestId = JSONAccess.string(request, "requestId") ?? "\(index)"
            let ts = CopilotTools.isoTimestamp(epochMs: JSONAccess.double(request, "timestamp"))
                ?? CopilotTools.isoTimestamp(epochMs: JSONAccess.double(request, "responseTimestamp"))
                ?? context.fileModified ?? ""
            let metadata = JSONAccess.dict(JSONAccess.dict(request, "result"), "metadata")

            if !(JSONAccess.list(metadata, "summaries") ?? []).isEmpty || JSONAccess.dict(metadata, "summary") != nil {
                out.append(.event(EventRow(
                    id: "copilot-vscode:compaction:\(session):\(requestId)",
                    sessionId: session, ts: ts, kind: EventKind.compaction.rawValue, detail: nil)))
            }
            if hasDebugLog { continue }

            let dedupeKey = "copilot-vscode:\(session):\(requestId)"
            // The latest call's whole prompt, cached tokens included.
            let prompt = positive(JSONAccess.int(request, "promptTokens")) ?? positive(JSONAccess.int(metadata, "promptTokens"))
            let output = positive(JSONAccess.int(request, "completionTokens")) ?? positive(JSONAccess.int(metadata, "outputTokens")) ?? 0
            let window = prompt == nil ? nil : positive(JSONAccess.int(JSONAccess.dict(request, "contextUsage"), "tokenLimit"))
            let model = JSONAccess.string(metadata, "resolvedModel") ?? JSONAccess.string(request, "modelId").map(stripVendor)
            let effort = JSONAccess.string(JSONAccess.dict(request, "modelConfiguration"), "reasoningEffort")

            let call = CallRow(
                dedupeKey: dedupeKey,
                ts: ts,
                vendor: Vendor.copilotVSCode,
                sessionId: session,
                project: project,
                cwd: cwd,
                model: model,
                input: prompt ?? 0,       // not split: Copilot persists no cached count here
                output: output,
                cacheRead: 0, cacheWrite: 0,
                effort: effort,
                contextTokens: prompt ?? 0,
                windowLimit: window,
                sourceFile: context.sourceFile,
                confidence: (prompt == nil ? Confidence.unmeasured : .exact).rawValue,
                parserVersion: version
            )
            out.append(.call(ParsedCall(
                call: call,
                toolCalls: toolCalls(request: request, metadata: metadata, callId: dedupeKey, session: session, ts: ts),
                claudeVersion: nil)))
        }
        return out
    }

    /// Tool invocations as VS Code rendered them (`toolInvocationSerialized`
    /// parts), with targets from Copilot's own `toolCallRounds` when present.
    static func toolCalls(request: [String: Any], metadata: [String: Any]?, callId: String, session: String, ts: String) -> [ToolCallRow] {
        var arguments: [String: Any] = [:]
        for round in JSONAccess.list(metadata, "toolCallRounds") ?? [] {
            for call in JSONAccess.list(round as? [String: Any], "toolCalls") ?? [] {
                guard let call = call as? [String: Any], let id = JSONAccess.string(call, "id") else { continue }
                arguments[baseToolCallId(id)] = call["arguments"]
            }
        }
        var rows: [ToolCallRow] = []
        var seen = Set<String>()
        for part in JSONAccess.list(request, "response") ?? [] {
            guard let part = part as? [String: Any], JSONAccess.string(part, "kind") == "toolInvocationSerialized",
                  let id = JSONAccess.string(part, "toolCallId"), seen.insert(id).inserted else { continue }
            let source = JSONAccess.dict(part, "source")
            let isMCP = JSONAccess.string(source, "type") == "mcp"
            rows.append(ToolCallRow(
                id: "copilot-vscode:\(session):\(id)",
                callId: callId, sessionId: session, ts: ts,
                name: JSONAccess.string(part, "toolId") ?? "tool",
                kind: (isMCP ? ToolKind.mcp : .builtin).rawValue,
                mcpServer: isMCP ? (JSONAccess.string(source, "serverLabel") ?? JSONAccess.string(source, "label")) : nil,
                target: CopilotTools.target(arguments: arguments[baseToolCallId(id)]),
                parserVersion: version))
        }
        return rows
    }

    /// VS Code appends `__vscode-<n>` to a model's tool-call id for uniqueness.
    static func baseToolCallId(_ id: String) -> String {
        id.components(separatedBy: "__vscode-").first ?? id
    }

    /// `copilot/gpt-4.1` → `gpt-4.1`: VS Code ids carry the provider.
    static func stripVendor(_ modelId: String) -> String {
        modelId.split(separator: "/").last.map(String.init) ?? modelId
    }

    static func workspaceFolder(besideChatFile file: URL) -> String? {
        let json = file.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("workspace.json")
        guard let data = try? Data(contentsOf: json),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let folder = JSONAccess.string(object, "folder") else { return nil }
        return path(fromURI: folder)
    }

    static func path(fromURI uri: String) -> String? {
        guard let url = URL(string: uri), url.isFileURL else { return nil }
        return url.path.isEmpty ? nil : url.path
    }

    private static func positive(_ value: Int?) -> Int? { value.flatMap { $0 > 0 ? $0 : nil } }

    private static func debugLogHasCalls(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return !debugLog(data, file: url, context: LineContext(sourceFile: url.path, fallbackSessionId: ""))
            .filter { if case .call = $0 { return true } else { return false } }
            .isEmpty
    }

    // MARK: - Debug log

    /// `IDebugLogEntry` lines: `{ts, dur, sid, type, name, spanId, status, attrs}`.
    /// An `llm_request` carries `attrs.inputTokens` (the whole prompt, OpenAI
    /// `prompt_tokens`), `attrs.cachedTokens` and `attrs.outputTokens`.
    /// `tool_call` lines follow the call that requested them.
    static func debugLog(_ data: Data, file: URL, context: LineContext) -> [ParsedLine] {
        let session = file.deletingLastPathComponent().lastPathComponent
        let isMain = file.lastPathComponent == "main.jsonl"
        var calls: [ParsedCall] = []
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            guard let entry = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let spanId = JSONAccess.string(entry, "spanId") else { continue }
            let attrs = JSONAccess.dict(entry, "attrs")
            let ts = CopilotTools.isoTimestamp(epochMs: JSONAccess.double(entry, "ts")) ?? context.fileModified ?? ""
            switch JSONAccess.string(entry, "type") ?? "" {
            case "llm_request":
                guard JSONAccess.string(entry, "status") != "error",
                      isConversationCall(debugName: JSONAccess.string(attrs, "debugName")),
                      let total = positive(JSONAccess.int(attrs, "inputTokens")) else { continue }
                let cached = min(total, max(0, JSONAccess.intOrZero(attrs, "cachedTokens")))
                let call = CallRow(
                    dedupeKey: "copilot-vscode:\(session):\(spanId)",
                    ts: ts,
                    vendor: Vendor.copilotVSCode,
                    agentId: isMain ? nil : (JSONAccess.string(entry, "sid") ?? file.deletingPathExtension().lastPathComponent),
                    sessionId: session,
                    model: JSONAccess.string(attrs, "model").map(stripVendor),
                    input: total - cached,
                    output: JSONAccess.intOrZero(attrs, "outputTokens"),
                    cacheRead: cached,
                    cacheWrite: 0,   // the log records cache reads only
                    contextTokens: total,
                    windowLimit: nil, // the log names the output cap, not the window
                    sourceFile: context.sourceFile,
                    confidence: Confidence.exact.rawValue,
                    parserVersion: version
                )
                calls.append(ParsedCall(call: call, toolCalls: [], claudeVersion: nil))
            case "tool_call":
                guard let last = calls.indices.last, let name = JSONAccess.string(entry, "name") else { continue }
                let callId = calls[last].call.dedupeKey
                calls[last].toolCalls.append(ToolCallRow(
                    id: "copilot-vscode:\(session):\(spanId)",
                    callId: callId, sessionId: session, ts: ts, name: name,
                    kind: (name.hasPrefix("mcp_") ? ToolKind.mcp : .builtin).rawValue,
                    target: CopilotTools.target(arguments: JSONAccess.string(attrs, "args")),
                    isError: JSONAccess.string(entry, "status").map { $0 == "error" },
                    parserVersion: version))
            default:
                continue
            }
        }
        return calls.map { .call($0) }
    }

    /// The conversation's own calls are named `<location>/<intent>` (e.g.
    /// `panel/agent`, `tool/runSubagent-x`); helpers such as `title`,
    /// `progressMessages` or `summarizeConversationHistory` have no slash and
    /// are not part of the context being measured.
    static func isConversationCall(debugName: String?) -> Bool {
        guard let debugName else { return true }
        return debugName.contains("/")
    }
}

extension Harness {
    public static let copilotVSCode = Harness(
        id: Vendor.copilotVSCode, name: "Copilot (VS Code)",
        capabilities: .init(
            occupancy: .perRequest, window: .reported, cacheSplit: false, compaction: true, effort: true,
            notes: [
                "Copilot records one reading per request (the last model call of its tool loop), so the chart has fewer points.",
                "A window is shown only when VS Code saved one beside the request; Copilot's limits differ from the model vendors', so none is looked up.",
                "Cached tokens are not split out unless Copilot's debug log (github.copilot.chat.agentDebugLog.fileLogging.enabled) is on; then every call is read from it instead.",
                "A request's output tokens are the total across its calls.",
            ]),
        roots: { CopilotVSCodePaths.roots(environment: $0) },
        owns: CopilotVSCodePaths.isCopilotFile,
        reading: .document({ CopilotVSCodeReader() })
    )
}

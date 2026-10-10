import Foundation

extension Vendor {
    public static let cline = "cline"
    public static let rooCode = "roo-code"
    public static let kiloCode = "kilo-code"
}

/// Cline and its two forks, Roo Code and Kilo Code, keep each task as a folder
/// of whole JSON documents rewritten in place:
/// `<storage>/tasks/<taskId>/ui_messages.json` (what the webview shows, one
/// `api_req_started` message per model call with its token counts),
/// `api_conversation_history.json` (the prompt sent) and, for Cline,
/// `task_metadata.json`. `<storage>` is the extension's VS Code global storage
/// in any VS Code-family editor, or a standalone directory. See
/// docs/harnesses/cline.md.
public enum ClineFamilyPaths {
    /// Editors whose user data follows VS Code's layout.
    public static let editors = ["Code", "Code - Insiders", "Cursor", "Windsurf", "VSCodium", "Trae"]

    /// `~/Library/Application Support/<editor>/User` (macOS) or
    /// `$XDG_CONFIG_HOME/<editor>/User` (Linux).
    static func editorUserDirectories(environment: [String: String]) -> [URL] {
        let home = ClaudePaths.homeDirectory()
        #if os(macOS)
        let base = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        #else
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ClaudePaths.expand($0), isDirectory: true) }
            ?? home.appendingPathComponent(".config", isDirectory: true)
        #endif
        return editors.map { base.appendingPathComponent($0, isDirectory: true).appendingPathComponent("User", isDirectory: true) }
    }

    /// `<editor>/User/globalStorage/<extension id>` for every editor.
    public static func globalStorageDirectories(extensionId: String, environment: [String: String]) -> [URL] {
        editorUserDirectories(environment: environment).map {
            $0.appendingPathComponent("globalStorage", isDirectory: true).appendingPathComponent(extensionId, isDirectory: true)
        }
    }

    /// Roo Code and Kilo Code can move their storage with a VS Code setting
    /// (`roo-cline.customStoragePath`). Read from each editor's settings.json,
    /// which is JSONC, so the one string value is matched rather than parsed.
    static func customStorageDirectories(setting: String, environment: [String: String]) -> [URL] {
        let pattern = "\"" + NSRegularExpression.escapedPattern(for: setting) + "\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var result: [URL] = []
        for user in editorUserDirectories(environment: environment) {
            let settings = user.appendingPathComponent("settings.json")
            guard let text = try? String(contentsOf: settings, encoding: .utf8) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  let valueRange = Range(match.range(at: 1), in: text) else { continue }
            let value = text[valueRange].replacingOccurrences(of: "\\\\", with: "\\")
            guard !value.isEmpty else { continue }
            result.append(URL(fileURLWithPath: ClaudePaths.expand(value), isDirectory: true))
        }
        return result
    }

    static func tasks(_ storage: [URL]) -> [URL] {
        storage.map { $0.appendingPathComponent("tasks", isDirectory: true) }
    }

    /// `…/tasks/<id>/ui_messages.json` under one of `storage`, or under any
    /// directory named for `extensionId`.
    static func isTaskFile(_ path: String, extensionId: String, storage: [URL]) -> Bool {
        guard isTaskShape(path) else { return false }
        if path.contains("/\(extensionId)/tasks/") { return true }
        return storage.contains { path.hasPrefix($0.standardizedFileURL.path + "/tasks/") }
    }

    /// `…/tasks/<id>/ui_messages.json`.
    static func isTaskShape(_ path: String) -> Bool {
        guard path.hasSuffix("/ui_messages.json") else { return false }
        let parts = path.split(separator: "/")
        return parts.count >= 3 && parts[parts.count - 3] == "tasks"
    }

    // MARK: Cline

    /// Cline's own data directory: `CLINE_DATA_DIR`, else `$CLINE_DIR/data`,
    /// else `~/.cline/data` (cline/cline apps/vscode/src/shared/storage/storage-context.ts:93).
    public static func clineDataDirectory(environment: [String: String]) -> URL {
        if let dir = environment["CLINE_DATA_DIR"], !dir.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(fileURLWithPath: ClaudePaths.expand(dir), isDirectory: true)
        }
        let clineDir = environment["CLINE_DIR"].flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: ClaudePaths.expand($0), isDirectory: true) }
            ?? ClaudePaths.homeDirectory().appendingPathComponent(".cline", isDirectory: true)
        return clineDir.appendingPathComponent("data", isDirectory: true)
    }

    /// Cline 4.1+ (the SDK): `CLINE_SESSION_DATA_DIR`, else `<data>/sessions`
    /// (sdk/packages/shared/src/storage/paths.ts:187).
    public static func clineSessionsDirectory(environment: [String: String]) -> URL {
        if let dir = environment["CLINE_SESSION_DATA_DIR"], !dir.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(fileURLWithPath: ClaudePaths.expand(dir), isDirectory: true)
        }
        return clineDataDirectory(environment: environment).appendingPathComponent("sessions", isDirectory: true)
    }

    static func clineRoots(environment: [String: String]) -> [URL] {
        tasks(globalStorageDirectories(extensionId: ClineFlavor.cline.extensionId, environment: environment)
              + [clineDataDirectory(environment: environment)])
            + [clineSessionsDirectory(environment: environment)]
    }

    static func ownsCline(_ path: String) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        if path.hasSuffix(".messages.json") {
            let parts = path.split(separator: "/")
            guard parts.count >= 3 else { return false }
            if path.contains("/.cline/data/sessions/") { return true }
            let sessions = clineSessionsDirectory(environment: environment).standardizedFileURL.path
            return path.hasPrefix(sessions + "/")
        }
        return isTaskFile(path, extensionId: ClineFlavor.cline.extensionId, storage: [clineDataDirectory(environment: environment)])
            || (isTaskShape(path) && path.contains("/.cline/data/tasks/"))
    }

    // MARK: Roo Code and Kilo Code

    /// Roo Code's own CLI runs the extension against a VS Code shim whose
    /// global storage is `~/.vscode-mock/global-storage`
    /// (RooCodeInc/Roo-Code packages/vscode-shim/src/context/ExtensionContext.ts:83).
    static func rooCliStorage() -> URL {
        ClaudePaths.homeDirectory().appendingPathComponent(".vscode-mock/global-storage", isDirectory: true)
    }

    static let customStorage: [String: [URL]] = {
        let environment = ProcessInfo.processInfo.environment
        return [
            ClineFlavor.rooCode.vendor: customStorageDirectories(setting: "roo-cline.customStoragePath", environment: environment),
            ClineFlavor.kiloCode.vendor: customStorageDirectories(setting: "kilo-code.customStoragePath", environment: environment),
        ]
    }()

    static func storage(for flavor: ClineFlavor, environment: [String: String]) -> [URL] {
        var dirs = globalStorageDirectories(extensionId: flavor.extensionId, environment: environment)
        if flavor.vendor == Vendor.rooCode { dirs.append(rooCliStorage()) }
        if let settingKey = flavor.customStorageSetting {
            dirs += customStorageDirectories(setting: settingKey, environment: environment)
        }
        return dirs
    }

    static func ownsFork(_ path: String, flavor: ClineFlavor) -> Bool {
        if flavor.vendor == Vendor.rooCode, isTaskShape(path), path.contains("/.vscode-mock/global-storage/tasks/") { return true }
        return isTaskFile(path, extensionId: flavor.extensionId, storage: customStorage[flavor.vendor] ?? [])
    }
}

/// What differs between Cline, Roo Code and Kilo Code when reading the same
/// `ui_messages.json` shape.
public struct ClineFlavor: Sendable {
    public enum InputSemantics: Sendable {
        /// Cline: `tokensIn` is the uncached remainder (its own context figure
        /// sums all four), except for providers that pass the OpenAI
        /// `prompt_tokens` through unchanged together with a cached count.
        case cline
        /// Roo Code / Kilo Code: `tokensIn` is the whole prompt, cache
        /// included, since `cutoffMs`; before it, Anthropic-protocol requests
        /// recorded the uncached remainder.
        case total(cutoffMs: Double)
    }

    public let vendor: String
    public let extensionId: String
    public let customStorageSetting: String?
    public let semantics: InputSemantics

    public static let cline = ClineFlavor(
        vendor: Vendor.cline, extensionId: "saoudrizwan.claude-dev", customStorageSetting: nil, semantics: .cline)
    /// Roo Code 3.29.5 (2025-11-01, RooCodeInc/Roo-Code#8954) switched
    /// `tokensIn` to `totalInputTokens`.
    public static let rooCode = ClineFlavor(
        vendor: Vendor.rooCode, extensionId: "rooveterinaryinc.roo-cline", customStorageSetting: "roo-cline.customStoragePath",
        semantics: .total(cutoffMs: 1_761_955_200_000))
    /// Kilo Code took the same change in v4.119.0 (2025-11-12).
    public static let kiloCode = ClineFlavor(
        vendor: Vendor.kiloCode, extensionId: "kilocode.kilo-code", customStorageSetting: "kilo-code.customStoragePath",
        semantics: .total(cutoffMs: 1_762_905_600_000))

    /// Classic Cline providers that report OpenAI `prompt_tokens` (cache
    /// included) alongside a cached count, so `tokensIn` there is the whole
    /// prompt. From cline/cline v3.89.2 apps/vscode/src/core/api/providers.
    static let clineTotalInputProviders: Set<String> = [
        "openai", "litellm", "doubao", "fireworks", "hicap", "lmstudio", "qwen", "xai", "zai",
    ]

    /// The four counters from one `api_req_started` payload.
    func split(tokensIn: Int, cacheReads: Int, cacheWrites: Int, providerId: String?, apiProtocol: String?, tsMs: Double)
        -> (input: Int, cacheRead: Int, cacheWrite: Int) {
        let cached = cacheReads + cacheWrites
        // Below the cached count it cannot be a total; equal or no cache, the
        // two readings give the same context.
        guard cached > 0, tokensIn >= cached else { return (tokensIn, cacheReads, cacheWrites) }
        let isTotal: Bool
        switch semantics {
        case .cline:
            isTotal = providerId.map { Self.clineTotalInputProviders.contains($0) } ?? false
        case .total(let cutoff):
            isTotal = !(tsMs < cutoff && apiProtocol == "anthropic")
        }
        return isTotal ? (tokensIn - cached, cacheReads, cacheWrites) : (tokensIn, cacheReads, cacheWrites)
    }
}

/// Reads a classic task's `ui_messages.json` (plus the sibling files that hold
/// the model and working directory) into one call per `api_req_started`.
public struct ClineTaskReader: TranscriptDocumentReader {
    public static let version = 1

    public let flavor: ClineFlavor

    public init(flavor: ClineFlavor) { self.flavor = flavor }

    public func read(file: URL, context: LineContext) -> [ParsedLine] {
        guard let data = try? Data(contentsOf: file),
              let messages = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return [] }
        let taskDir = file.deletingLastPathComponent()
        let taskId = taskDir.lastPathComponent
        let side = SideInfo.load(taskDir: taskDir, taskId: taskId, flavor: flavor)
        let vendor = flavor.vendor

        // `ts` is the webview's list key, unique within a task.
        let requestTimes: [Double] = messages.compactMap { item in
            guard let m = item as? [String: Any], JSONAccess.string(m, "say") == "api_req_started" else { return nil }
            return JSONAccess.double(m, "ts")
        }

        var out: [ParsedLine] = []
        var pending: ParsedCall?
        var lastRequestTs: Double?
        var requestOrdinal = -1
        var contentSinceRequest = false
        var deletedRange: String?
        var seenRange = false

        func flush() {
            if let call = pending { out.append(.call(call)) }
            pending = nil
        }

        func compaction(at tsMs: Double, detail: [String: Any]) {
            let event = EventRow(
                id: "\(vendor):\(taskId):compaction:\(Int64(tsMs))",
                sessionId: taskId,
                ts: Self.iso(tsMs),
                kind: EventKind.compaction.rawValue,
                detail: JSONAccess.jsonString(detail)
            )
            out.append(.event(event))
        }

        for item in messages {
            guard let m = item as? [String: Any], let ts = JSONAccess.double(m, "ts") else { continue }
            if JSONAccess.bool(m, "partial") == true { continue }
            let type = JSONAccess.string(m, "type")
            let say = JSONAccess.string(m, "say")
            let ask = JSONAccess.string(m, "ask")
            let kind = type == "ask" ? ask : say

            // Cline stamps the truncation range in force on every message; it
            // changes during a request's setup, after its api_req_started.
            if flavor.semantics.isCline {
                let range = JSONAccess.list(m, "conversationHistoryDeletedRange").flatMap(JSONAccess.jsonString)
                if seenRange, range != deletedRange, range != nil {
                    compaction(at: (lastRequestTs ?? ts) - 1, detail: ["trigger": "truncation"])
                }
                deletedRange = range
                seenRange = true
            }

            if say == "api_req_started" {
                flush()
                requestOrdinal += 1
                lastRequestTs = ts
                contentSinceRequest = false
                let nextTs = requestOrdinal + 1 < requestTimes.count ? requestTimes[requestOrdinal + 1] : .infinity
                pending = makeCall(message: m, ts: ts, nextTs: nextTs, taskId: taskId, side: side, sourceFile: context.sourceFile)
                continue
            }

            if say == "condense_context" || say == "sliding_window_truncation" {
                var detail: [String: Any] = ["trigger": say == "condense_context" ? "condense" : "truncation"]
                for key in ["prevContextTokens", "newContextTokens"] {
                    if let n = JSONAccess.int(JSONAccess.dict(m, "contextCondense"), key) { detail[key] = n }
                }
                if say == "condense_context", JSONAccess.dict(m, "contextCondense") == nil { continue }
                // Automatic condensing runs inside a request's setup, right
                // after its api_req_started: that call already sees the
                // smaller window. A manual one lands between requests.
                let at = (!contentSinceRequest && lastRequestTs != nil) ? lastRequestTs! - 1 : ts
                compaction(at: at, detail: detail)
                continue
            }

            if let tool = toolCall(message: m, kind: kind, ts: ts, taskId: taskId) {
                contentSinceRequest = true
                if pending != nil {
                    pending!.toolCalls.append(ToolCallRow(
                        id: tool.id, callId: pending!.call.dedupeKey, sessionId: taskId, ts: tool.ts, name: tool.name,
                        kind: tool.kind, mcpServer: tool.server, target: tool.target, parserVersion: Self.version))
                }
                continue
            }
            if ["text", "reasoning", "completion_result", "command_output", "error"].contains(kind ?? "") || type == "ask" {
                contentSinceRequest = true
            }
        }
        flush()
        return out
    }

    private func makeCall(message m: [String: Any], ts: Double, nextTs: Double, taskId: String, side: SideInfo, sourceFile: String) -> ParsedCall? {
        guard let text = JSONAccess.string(m, "text"),
              let info = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return nil }
        // A placeholder (request in flight, or cancelled before any usage)
        // carries no counts; it is read again on the next rewrite.
        guard info["tokensIn"] != nil || info["tokensOut"] != nil else { return nil }
        let modelInfo = JSONAccess.dict(m, "modelInfo")
        let providerId = JSONAccess.string(modelInfo, "providerId") ?? side.providerId(before: nextTs)
        let model = JSONAccess.string(modelInfo, "modelId") ?? side.model(before: nextTs)
        let tokensIn = max(0, JSONAccess.intOrZero(info, "tokensIn"))
        let split = flavor.split(
            tokensIn: tokensIn,
            cacheReads: max(0, JSONAccess.intOrZero(info, "cacheReads")),
            cacheWrites: max(0, JSONAccess.intOrZero(info, "cacheWrites")),
            providerId: providerId,
            apiProtocol: JSONAccess.string(info, "apiProtocol") ?? JSONAccess.string(m, "apiProtocol"),
            tsMs: ts
        )
        let contextTokens = split.input + split.cacheRead + split.cacheWrite
        let call = CallRow(
            dedupeKey: "\(flavor.vendor):\(taskId):\(Int64(ts))",
            ts: Self.iso(ts),
            vendor: flavor.vendor,
            sessionId: taskId,
            project: side.cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
            cwd: side.cwd,
            model: model,
            input: split.input,
            output: max(0, JSONAccess.intOrZero(info, "tokensOut")),
            cacheRead: split.cacheRead,
            cacheWrite: split.cacheWrite,
            contextTokens: contextTokens,
            windowLimit: WindowLimits.knownLimit(for: model),
            stopReason: JSONAccess.string(info, "cancelReason"),
            sourceFile: sourceFile,
            confidence: Confidence.exact.rawValue,
            parserVersion: Self.version
        )
        return ParsedCall(call: call, toolCalls: [], claudeVersion: nil)
    }

    private struct Tool { var id, ts, name, kind: String; var server, target: String? }

    private func toolCall(message m: [String: Any], kind: String?, ts: Double, taskId: String) -> Tool? {
        let id = "\(flavor.vendor):\(taskId):tool:\(Int64(ts))"
        let iso = Self.iso(ts)
        let text = JSONAccess.string(m, "text")
        let payload = text.flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        switch kind {
        case "tool":
            guard let name = JSONAccess.string(payload, "tool") else { return nil }
            let toolKind: ToolKind
            switch name {
            case "skill", "useSkill": toolKind = .skill
            case "newTask": toolKind = .agent
            default: toolKind = .builtin
            }
            return Tool(id: id, ts: iso, name: name, kind: toolKind.rawValue, server: nil, target: JSONAccess.string(payload, "path"))
        case "command":
            return Tool(id: id, ts: iso, name: "command", kind: ToolKind.builtin.rawValue, server: nil,
                        target: text.map { String($0.prefix(ClaudeCodeParser.targetLimit)) })
        case "use_mcp_server":
            let server = JSONAccess.string(payload, "serverName")
            let isResource = JSONAccess.string(payload, "type") == "access_mcp_resource"
            let tool = isResource ? "resource" : (JSONAccess.string(payload, "toolName") ?? "tool")
            return Tool(id: id, ts: iso, name: "mcp__\(server ?? "unknown")__\(tool)", kind: ToolKind.mcp.rawValue, server: server,
                        target: isResource ? JSONAccess.string(payload, "uri") : nil)
        case "browser_action_launch":
            return Tool(id: id, ts: iso, name: "browser_action", kind: ToolKind.builtin.rawValue, server: nil, target: text)
        default:
            return nil
        }
    }

    static func iso(_ ms: Double) -> String {
        Timestamps.string(from: Date(timeIntervalSince1970: ms / 1000))
    }
}

extension ClineFlavor.InputSemantics {
    var isCline: Bool { if case .cline = self { return true } else { return false } }
}

/// Model and working directory, which `ui_messages.json` does not always carry.
struct SideInfo {
    /// (ms, model, provider), ascending.
    var models: [(ts: Double, model: String, provider: String?)] = []
    var cwd: String?
    var taskModel: String?

    func model(before ts: Double) -> String? {
        models.last(where: { $0.ts < ts })?.model ?? models.first?.model ?? taskModel
    }

    func providerId(before ts: Double) -> String? {
        models.last(where: { $0.ts < ts })?.provider ?? models.first?.provider
    }

    static func load(taskDir: URL, taskId: String, flavor: ClineFlavor) -> SideInfo {
        var info = SideInfo()
        if flavor.semantics.isCline {
            // task_metadata.json `model_usage`: one entry each time the model,
            // provider or mode changed (ModelContextTracker.ts:10).
            if let meta = json(taskDir.appendingPathComponent("task_metadata.json")) as? [String: Any] {
                for case let entry as [String: Any] in JSONAccess.list(meta, "model_usage") ?? [] {
                    guard let ts = JSONAccess.double(entry, "ts"), let model = JSONAccess.string(entry, "model_id") else { continue }
                    info.models.append((ts, model, JSONAccess.string(entry, "model_provider_id")))
                }
            }
            // `<storage>/state/taskHistory.json`: the HistoryItem with the
            // task's starting cwd and model.
            let history = taskDir.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("state/taskHistory.json")
            if let items = json(history) as? [Any] {
                for case let item as [String: Any] in items where JSONAccess.string(item, "id") == taskId {
                    info.cwd = JSONAccess.string(item, "cwdOnTaskInitialization")
                    info.taskModel = JSONAccess.string(item, "modelId")
                }
            }
        } else if let item = json(taskDir.appendingPathComponent("history_item.json")) as? [String: Any] {
            info.cwd = JSONAccess.string(item, "workspace")
        }

        // The prompt itself: Roo and Kilo write `<model>id</model>` into the
        // environment details of every request; all three name the workspace
        // in the first one.
        if let history = json(taskDir.appendingPathComponent("api_conversation_history.json")) as? [Any] {
            for case let message as [String: Any] in history where JSONAccess.string(message, "role") == "user" {
                let texts = textBlocks(message)
                if info.cwd == nil, let cwd = texts.lazy.compactMap(workspace(in:)).first { info.cwd = cwd }
                if !flavor.semantics.isCline, let ts = JSONAccess.double(message, "ts"),
                   let model = texts.lazy.compactMap({ capture(modelPattern, in: $0) }).last {
                    info.models.append((ts, model, nil))
                }
            }
        }
        info.models.sort { $0.ts < $1.ts }
        return info
    }

    static func json(_ url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    static func textBlocks(_ message: [String: Any]) -> [String] {
        if let s = message["content"] as? String { return [s] }
        return (JSONAccess.list(message, "content") ?? []).compactMap { ($0 as? [String: Any]).flatMap { JSONAccess.string($0, "text") } }
    }

    static let modelPattern = try? NSRegularExpression(pattern: "<model>([^<\\n]+)</model>")
    static let workspacePattern = try? NSRegularExpression(pattern: "# Current (?:Working|Workspace) Directory \\(([^)\\n]+)\\) Files")

    static func workspace(in text: String) -> String? {
        guard let path = capture(workspacePattern, in: text), path.hasPrefix("/") else { return nil }
        return path
    }

    static func capture(_ regex: NSRegularExpression?, in text: String) -> String? {
        guard let regex,
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let value = text[range].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}

/// Cline 4.1+ reads either shape: a classic task, or an SDK session.
struct ClineReader: TranscriptDocumentReader {
    func read(file: URL, context: LineContext) -> [ParsedLine] {
        file.lastPathComponent.hasSuffix(".messages.json")
            ? ClineSessionReader().read(file: file, context: context)
            : ClineTaskReader(flavor: .cline).read(file: file, context: context)
    }
}

extension Harness {
    public static let cline = Harness(
        id: Vendor.cline, name: "Cline",
        capabilities: .init(occupancy: .everyCall, window: .lookup, cacheSplit: true, subagents: true, compaction: true,
                            notes: [
                                "Cline records no window; it comes from the model name, so a model Ullage doesn't know shows no gauge.",
                                "Tasks from before Cline wrote the model per message show no gauge unless task_metadata.json names it.",
                            ]),
        roots: { ClineFamilyPaths.clineRoots(environment: $0) },
        owns: ClineFamilyPaths.ownsCline,
        reading: .document({ ClineReader() })
    )

    public static let rooCode = Harness(
        id: Vendor.rooCode, name: "Roo Code",
        capabilities: .init(occupancy: .everyCall, window: .lookup, cacheSplit: true, compaction: true,
                            notes: [
                                "The model is read from the environment details Roo Code puts in each prompt; the window comes from it.",
                                "A subtask is its own task, so it appears as its own session.",
                            ]),
        roots: { ClineFamilyPaths.tasks(ClineFamilyPaths.storage(for: .rooCode, environment: $0)) },
        owns: { ClineFamilyPaths.ownsFork($0, flavor: .rooCode) },
        reading: .document({ ClineTaskReader(flavor: .rooCode) })
    )

    public static let kiloCode = Harness(
        id: Vendor.kiloCode, name: "Kilo Code",
        capabilities: .init(occupancy: .everyCall, window: .lookup, cacheSplit: true, compaction: true,
                            notes: [
                                "Only tasks from Kilo Code 5 and earlier; Kilo Code 7 keeps sessions in its own database, not read here.",
                                "The model is read from the environment details in each prompt; the window comes from it.",
                            ]),
        roots: { ClineFamilyPaths.tasks(ClineFamilyPaths.storage(for: .kiloCode, environment: $0)) },
        owns: { ClineFamilyPaths.ownsFork($0, flavor: .kiloCode) },
        reading: .document({ ClineTaskReader(flavor: .kiloCode) })
    )
}

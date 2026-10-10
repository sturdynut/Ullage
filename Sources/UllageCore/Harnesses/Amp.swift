import Foundation

extension Vendor {
    public static let amp = "amp"
}

/// Where Amp (Sourcegraph) kept its local thread mirror:
/// `~/.local/share/amp/threads/<T-id>.json`. `AMP_DATA_DIR` is Amp's own
/// override and takes a comma-separated list; `XDG_DATA_HOME/amp` is used when
/// set. Amp builds from 2026-03-31 on keep threads on ampcode.com and no longer
/// write this folder, so only older threads are found.
public enum AmpPaths {
    public static func dataDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        if let override = environment["AMP_DATA_DIR"], !override.isEmpty {
            return override.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { URL(fileURLWithPath: ClaudePaths.expand($0), isDirectory: true) }
        }
        if let xdg = environment["XDG_DATA_HOME"], !xdg.isEmpty {
            return [URL(fileURLWithPath: ClaudePaths.expand(xdg), isDirectory: true).appendingPathComponent("amp", isDirectory: true)]
        }
        return [ClaudePaths.homeDirectory().appendingPathComponent(".local/share/amp", isDirectory: true)]
    }

    public static func threadsDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        dataDirectories(environment: environment).map { $0.appendingPathComponent("threads", isDirectory: true) }
    }

    public static func isAmpThread(_ path: String) -> Bool {
        guard path.hasSuffix(".json") else { return false }
        if path.contains("/.local/share/amp/threads/") { return true }
        return threadsDirectories().contains { path.hasPrefix($0.standardizedFileURL.path + "/") }
    }
}

/// Reads one Amp thread file, a JSON document Amp rewrites whole.
///
/// The per-request record is `usageLedger.events[]`: `tokens{input, output}`,
/// `model`, `timestamp`, and `toMessageId`, the assistant message it billed.
/// Cache counts are not on the event; they are on that message's `usage`
/// (`cacheReadInputTokens`, `cacheCreationInputTokens`), whose `inputTokens`
/// is the uncached remainder (Anthropic semantics: `totalInputTokens` is the
/// sum of the three). An event joined to its message is an exact row. One that
/// cannot be joined has no cache counts, so its prompt size is unknown: it is
/// kept as `estimated` with no window rather than read as a small prompt.
/// Threads without a ledger fall back to each assistant message's `usage`.
public struct AmpThreadReader: TranscriptDocumentReader {
    public static let version = 1

    public init() {}

    public func read(file: URL, context: LineContext) -> [ParsedLine] {
        guard let data = try? Data(contentsOf: file),
              let thread = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        return Self.parse(thread: thread, context: context)
    }

    static func parse(thread: [String: Any], context: LineContext) -> [ParsedLine] {
        let session = JSONAccess.string(thread, "id") ?? context.fallbackSessionId
        let cwd = Self.cwd(thread)
        let created = JSONAccess.double(thread, "created").map { Timestamps.string(from: Date(timeIntervalSince1970: $0 / 1000)) }
        let fallbackTs = created ?? context.fileModified ?? ""

        // Assistant messages by `messageId`, with their array position as the
        // fallback id, and the tool results that follow them.
        struct Message { var key: String; var body: [String: Any] }
        var assistants: [Message] = []
        var byId: [String: Int] = [:]
        var results: [ToolResultObservation] = []
        for (index, item) in (JSONAccess.list(thread, "messages") ?? []).enumerated() {
            guard let message = item as? [String: Any] else { continue }
            switch JSONAccess.string(message, "role") ?? "" {
            case "assistant":
                let id = JSONAccess.string(message, "messageId")
                if let id { byId[id] = assistants.count }
                assistants.append(Message(key: id ?? "i\(index)", body: message))
            case "user":
                results += toolResults(message)
            default:
                continue
            }
        }

        var out: [ParsedLine] = []
        let events = (JSONAccess.dict(thread, "usageLedger").flatMap { JSONAccess.list($0, "events") } ?? [])
            .compactMap { $0 as? [String: Any] }

        if !events.isEmpty {
            for (index, event) in events.enumerated() {
                let tokens = JSONAccess.dict(event, "tokens")
                let input = max(0, JSONAccess.intOrZero(tokens, "input"))
                let output = max(0, JSONAccess.intOrZero(tokens, "output"))
                let target = JSONAccess.string(event, "toMessageId")
                let joined = target.flatMap { byId[$0] }.map { assistants[$0] }
                let usage = JSONAccess.dict(joined?.body, "usage")
                guard input > 0 || output > 0 || usage != nil else { continue }

                // Keyed by the billed message when there is one, so a thread
                // that gains a ledger later keeps the same rows.
                let key = target.map { "m\($0)" } ?? JSONAccess.string(event, "id").map { "e\($0)" } ?? "e#\(index)"
                let model = JSONAccess.string(event, "model") ?? JSONAccess.string(usage, "model")
                let ts = Timestamps.normalize(JSONAccess.string(event, "timestamp") ?? JSONAccess.string(usage, "timestamp")) ?? fallbackTs
                out.append(call(
                    session: session, key: key, ts: ts, model: model, cwd: cwd,
                    input: input, output: output,
                    cacheRead: usage.map { max(0, JSONAccess.intOrZero($0, "cacheReadInputTokens")) },
                    cacheWrite: usage.map { max(0, JSONAccess.intOrZero($0, "cacheCreationInputTokens")) },
                    message: joined?.body, context: context
                ))
            }
        } else {
            for message in assistants {
                guard let usage = JSONAccess.dict(message.body, "usage") else { continue }
                let input = max(0, JSONAccess.intOrZero(usage, "inputTokens"))
                let output = max(0, JSONAccess.intOrZero(usage, "outputTokens"))
                let cacheRead = max(0, JSONAccess.intOrZero(usage, "cacheReadInputTokens"))
                let cacheWrite = max(0, JSONAccess.intOrZero(usage, "cacheCreationInputTokens"))
                guard input + output + cacheRead + cacheWrite > 0 else { continue }
                let model = JSONAccess.string(usage, "model") ?? JSONAccess.string(message.body, "model")
                let ts = Timestamps.normalize(JSONAccess.string(usage, "timestamp") ?? JSONAccess.string(message.body, "timestamp")) ?? fallbackTs
                out.append(call(
                    session: session, key: "m\(message.key)", ts: ts, model: model, cwd: cwd,
                    input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite,
                    message: message.body, context: context
                ))
            }
        }
        if !results.isEmpty { out.append(.toolResults(results)) }
        return out
    }

    /// `env.initial.trees[0].uri`, a `file://` URL, when the thread has one.
    static func cwd(_ thread: [String: Any]) -> String? {
        let trees = JSONAccess.dict(JSONAccess.dict(thread, "env"), "initial").flatMap { JSONAccess.list($0, "trees") }
        guard let tree = trees?.first as? [String: Any], let uri = JSONAccess.string(tree, "uri"),
              let url = URL(string: uri), url.isFileURL else { return nil }
        return url.path.isEmpty ? nil : url.path
    }

    private static func call(
        session: String, key: String, ts: String, model: String?, cwd: String?,
        input: Int, output: Int, cacheRead: Int?, cacheWrite: Int?,
        message: [String: Any]?, context: LineContext
    ) -> ParsedLine {
        let dedupeKey = "amp:\(session):\(key)"
        let measured = cacheRead != nil && cacheWrite != nil
        let read = cacheRead ?? 0
        let write = cacheWrite ?? 0
        var toolCalls: [ToolCallRow] = []
        for (index, item) in (JSONAccess.list(message, "content") ?? []).enumerated() {
            guard let block = item as? [String: Any], JSONAccess.string(block, "type") == "tool_use" else { continue }
            let name = JSONAccess.string(block, "name") ?? "tool"
            let classification = ClaudeCodeParser.classify(toolName: name)
            let input = JSONAccess.dict(block, "input")
            // Amp's Bash takes `cmd`; its file tools take `path`.
            let target = JSONAccess.string(input, "cmd").map { String($0.prefix(ClaudeCodeParser.targetLimit)) }
                ?? ClaudeCodeParser.target(forTool: name, input: input)
            toolCalls.append(ToolCallRow(
                id: JSONAccess.string(block, "id") ?? "\(dedupeKey):\(index)",
                callId: dedupeKey, sessionId: session, ts: ts, name: name,
                kind: classification.kind.rawValue, mcpServer: classification.server, target: target,
                parserVersion: AmpThreadReader.version
            ))
        }
        let row = CallRow(
            dedupeKey: dedupeKey,
            ts: ts,
            vendor: Vendor.amp,
            sessionId: session,
            project: cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
            cwd: cwd,
            model: model,
            input: input,
            output: output,
            cacheRead: read,
            cacheWrite: write,
            contextTokens: input + read + write,
            windowLimit: measured ? WindowLimits.knownLimit(for: model) : nil,
            sourceFile: context.sourceFile,
            confidence: (measured ? Confidence.exact : Confidence.estimated).rawValue,
            parserVersion: AmpThreadReader.version
        )
        return .call(ParsedCall(call: row, toolCalls: toolCalls, claudeVersion: nil))
    }

    /// `tool_result` blocks on a user message: `toolUseID`, and `run.status`
    /// / `run.result`. Sizes are length estimates (rule 6).
    private static func toolResults(_ message: [String: Any]) -> [ToolResultObservation] {
        (JSONAccess.list(message, "content") ?? []).compactMap { item in
            guard let block = item as? [String: Any], JSONAccess.string(block, "type") == "tool_result",
                  let id = JSONAccess.string(block, "toolUseID") ?? JSONAccess.string(block, "tool_use_id") else { return nil }
            let run = JSONAccess.dict(block, "run")
            return ToolResultObservation(
                toolUseId: id,
                resultTokens: ClaudeCodeParser.estimateTokens(of: run?["result"] ?? block["content"]),
                isError: JSONAccess.string(run, "status") == "error"
            )
        }
    }
}

extension Harness {
    public static let amp = Harness(
        id: Vendor.amp, name: "Amp",
        capabilities: .init(
            occupancy: .everyCall, window: .lookup, cacheSplit: true, toolResults: true,
            notes: [
                "Amp stopped writing threads to disk on 2026-03-31 (they live on ampcode.com now), so only older threads appear.",
                "A usage record Amp couldn't tie to its message has no cache counts and is shown without a gauge.",
            ]
        ),
        roots: { AmpPaths.threadsDirectories(environment: $0) },
        owns: AmpPaths.isAmpThread,
        reading: .document({ AmpThreadReader() })
    )
}

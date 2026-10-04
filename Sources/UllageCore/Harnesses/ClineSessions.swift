import Foundation

/// Cline 4.1+ (the Cline SDK, shared by the VS Code extension and the CLI)
/// keeps a session as `<sessions>/<sessionId>/<sessionId>.messages.json`, a
/// JSON document rewritten whole on every turn, beside a `<sessionId>.json`
/// manifest. A subagent's messages sit in the root session's folder as
/// `<agentId>.messages.json`. Each assistant message carries its own model and
/// that one model call's usage (`metrics`). See docs/harnesses/cline.md.
public struct ClineSessionReader: TranscriptDocumentReader {
    public static let version = 1

    public init() {}

    public func read(file: URL, context: LineContext) -> [ParsedLine] {
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        // buildMessagesFilePayload (sdk/packages/core/src/services/session-data.ts:334)
        // writes `{version, agent, sessionId, origin, messages}`; the reader
        // also accepts a bare array (runtime-host-support.ts:62).
        let payload = root as? [String: Any]
        guard let messages = (root as? [Any]) ?? JSONAccess.list(payload, "messages") else { return [] }

        let dir = file.deletingLastPathComponent()
        let sessionId = dir.lastPathComponent
        let stem = String(file.lastPathComponent.dropLast(".messages.json".count))
        // Rule 1: a subagent is its own window under its root session.
        let agentId: String? = stem == sessionId ? nil : stem
        let agentType = agentId == nil ? nil : JSONAccess.string(payload, "agent")

        let manifest = SideInfo.json(dir.appendingPathComponent("\(sessionId).json")) as? [String: Any]
        let cwd = JSONAccess.string(manifest, "cwd")
        let manifestModel = JSONAccess.string(manifest, "model")
        let stream = agentId ?? "main"

        var out: [ParsedLine] = []
        var lastTs = context.fileModified ?? ""
        for (index, item) in messages.enumerated() {
            guard let m = item as? [String: Any] else { continue }
            let metadata = JSONAccess.dict(m, "metadata")
            let tsMs = JSONAccess.double(m, "ts")
            let ts = tsMs.map(ClineTaskReader.iso) ?? lastTs
            lastTs = ts
            let id = JSONAccess.string(m, "id") ?? "\(index)"

            // compaction-shared.ts:42 — the summary that replaces history.
            if JSONAccess.string(metadata, "kind") == "compaction_summary" {
                var detail: [String: Any] = ["trigger": "compaction_summary"]
                if let before = JSONAccess.int(metadata, "tokensBefore") { detail["tokensBefore"] = before }
                let at = JSONAccess.double(metadata, "generatedAt").map(ClineTaskReader.iso) ?? ts
                out.append(.event(EventRow(
                    id: "\(Vendor.cline):\(sessionId):\(stream):compaction:\(id)", sessionId: sessionId, agentId: agentId,
                    ts: at, kind: EventKind.compaction.rawValue, detail: JSONAccess.jsonString(detail))))
                continue
            }

            guard JSONAccess.string(m, "role") == "assistant", JSONAccess.bool(metadata, "displayOnly") != true else { continue }
            let model = JSONAccess.string(JSONAccess.dict(m, "modelInfo"), "id") ?? manifestModel
            let dedupeKey = "\(Vendor.cline):\(sessionId):\(stream):\(id)"

            var call: CallRow
            if let metrics = JSONAccess.dict(m, "metrics") {
                // The SDK's `inputTokens` is the whole prompt, cache included
                // (apps/vscode/src/sdk/message-translator.ts:98-101).
                let cacheRead = max(0, JSONAccess.intOrZero(metrics, "cacheReadTokens"))
                let cacheWrite = max(0, JSONAccess.intOrZero(metrics, "cacheWriteTokens"))
                let input = max(0, JSONAccess.intOrZero(metrics, "inputTokens") - cacheRead - cacheWrite)
                call = CallRow(
                    dedupeKey: dedupeKey, ts: ts, vendor: Vendor.cline, agent: agentType, agentId: agentId,
                    sessionId: sessionId, project: cwd.map { URL(fileURLWithPath: $0).lastPathComponent }, cwd: cwd,
                    model: model, input: input, output: max(0, JSONAccess.intOrZero(metrics, "outputTokens")),
                    cacheRead: cacheRead, cacheWrite: cacheWrite,
                    contextTokens: input + cacheRead + cacheWrite,
                    windowLimit: WindowLimits.knownLimit(for: model),
                    sourceFile: context.sourceFile, confidence: Confidence.exact.rawValue, parserVersion: Self.version)
            } else {
                // No usage reported for this turn: activity only (rule 3).
                call = CallRow(
                    dedupeKey: dedupeKey, ts: ts, vendor: Vendor.cline, agent: agentType, agentId: agentId,
                    sessionId: sessionId, project: cwd.map { URL(fileURLWithPath: $0).lastPathComponent }, cwd: cwd,
                    model: model, contextTokens: 0, windowLimit: nil,
                    sourceFile: context.sourceFile, confidence: Confidence.unmeasured.rawValue, parserVersion: Self.version)
            }

            var tools: [ToolCallRow] = []
            for (blockIndex, item) in (JSONAccess.list(m, "content") ?? []).enumerated() {
                guard let block = item as? [String: Any], JSONAccess.string(block, "type") == "tool_use",
                      let name = JSONAccess.string(block, "name") else { continue }
                let input = JSONAccess.dict(block, "input")
                // MCP tools are `<server>__<tool>` (extensions/mcp/name-transform.ts:24).
                let parts = name.components(separatedBy: "__")
                let isMcp = parts.count >= 2 && !parts[0].isEmpty
                let kind: ToolKind = isMcp ? .mcp : (name == "skills" ? .skill : (name == "spawn_agent" ? .agent : .builtin))
                tools.append(ToolCallRow(
                    id: JSONAccess.string(block, "id") ?? "\(dedupeKey):\(blockIndex)",
                    callId: dedupeKey, sessionId: sessionId, ts: ts, name: name, kind: kind.rawValue,
                    mcpServer: isMcp ? parts[0] : nil, target: Self.target(input), parserVersion: Self.version))
            }
            out.append(.call(ParsedCall(call: call, toolCalls: tools, claudeVersion: nil)))
        }
        return out
    }

    /// A file path or command, when the input names one.
    static func target(_ input: [String: Any]?) -> String? {
        guard let input else { return nil }
        if let path = JSONAccess.string(input, "path") { return path }
        for key in ["files", "file_paths", "paths", "commands"] {
            if let list = JSONAccess.list(input, key), let first = list.first {
                if let s = first as? String { return String(s.prefix(ClaudeCodeParser.targetLimit)) }
                if let path = (first as? [String: Any]).flatMap({ JSONAccess.string($0, "path") }) { return path }
            }
            if let s = JSONAccess.string(input, key) { return String(s.prefix(ClaudeCodeParser.targetLimit)) }
        }
        return JSONAccess.string(input, "command").map { String($0.prefix(ClaudeCodeParser.targetLimit)) }
    }
}

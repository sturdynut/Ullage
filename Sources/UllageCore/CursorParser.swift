import Foundation

/// Parses Cursor agent-CLI transcripts
/// (`~/.cursor/projects/<slug>/agent-transcripts/<id>/<id>.jsonl`).
///
/// Cursor is a server-backed IDE: the usage accounting and context window live
/// on its servers, not on disk. The local transcript is content only — user and
/// assistant messages and tool calls, with no token counts, no model, and no
/// timestamps. So Cursor rows are **activity only**: turns and tools, timed by
/// the file's modification date, with no occupancy. `confidence = unmeasured`
/// and `window_limit = nil` mark them, and `latestCall()` skips window-less rows
/// so a Cursor session never drives the menu bar gauge.
public final class CursorParser: TranscriptLineParser {
    public static let version = 1

    private var turn = 0

    public init() {}

    public func parse(line: Data, context: LineContext) -> ParsedLine? {
        guard let root = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            return nil
        }
        // Only assistant turns become calls; user prompts and turn_ended carry
        // no activity Ullage records.
        guard JSONAccess.string(root, "role") == "assistant" else { return nil }

        let session = context.fallbackSessionId
        let ts = context.fileModified ?? context.lastTimestamp ?? ""
        let ordinal = turn
        turn += 1

        let dedupeKey = "cursor:\(session):\(ordinal)"
        let content = JSONAccess.list(JSONAccess.dict(root, "message"), "content") ?? []
        var toolCalls: [ToolCallRow] = []
        for (index, item) in content.enumerated() {
            guard let block = item as? [String: Any],
                  JSONAccess.string(block, "type") == "tool_use" else { continue }
            let name = JSONAccess.string(block, "name") ?? "tool"
            let id = JSONAccess.string(block, "id") ?? "\(dedupeKey):\(index)"
            toolCalls.append(ToolCallRow(
                id: id,
                callId: dedupeKey,
                sessionId: session,
                ts: ts,
                name: name,
                kind: (name.contains("__") ? ToolKind.mcp : .builtin).rawValue,
                mcpServer: nil,
                target: nil,
                resultTokens: nil,   // Cursor logs no result sizes
                isError: nil,
                parserVersion: CursorParser.version
            ))
        }

        let call = CallRow(
            dedupeKey: dedupeKey,
            ts: ts,
            vendor: Vendor.cursor,
            sessionId: session,
            project: project(from: context.sourceFile),
            cwd: nil,
            model: nil,                 // not in the transcript
            input: 0, output: 0, cacheRead: 0, cacheWrite: 0,
            reasoning: nil,
            webSearch: nil,
            contextTokens: 0,           // no token data; occupancy is nil
            windowLimit: nil,
            sourceFile: context.sourceFile,
            confidence: Confidence.unmeasured.rawValue,
            parserVersion: CursorParser.version
        )
        return .call(ParsedCall(call: call, toolCalls: toolCalls, claudeVersion: nil))
    }

    /// The project is only recoverable from the directory slug Cursor encodes
    /// the workspace into: `.../projects/<slug>/agent-transcripts/...`. It is a
    /// sanitized path, so the best honest label is its trailing segment.
    func project(from sourceFile: String) -> String? {
        let parts = sourceFile.split(separator: "/").map(String.init)
        guard let index = parts.firstIndex(of: "projects"), index + 1 < parts.count else { return nil }
        let slug = parts[index + 1]
        // Trailing token after the last "-" is usually the workspace leaf.
        return slug.split(separator: "-").last.map(String.init) ?? slug
    }
}

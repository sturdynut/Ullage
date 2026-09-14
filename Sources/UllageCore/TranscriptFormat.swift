import Foundation

/// A per-file transcript parser. Reference type because some formats (Codex)
/// carry state across lines within a file.
public protocol TranscriptLineParser: AnyObject {
    func parse(line: Data, context: LineContext) -> ParsedLine?
}

/// Which harness wrote a transcript, and how to read it.
public enum TranscriptFormat {
    case claudeCode
    case codex
    case cursor

    /// Routes a file by path. Codex rollouts live under `.codex/sessions`,
    /// Cursor agent transcripts under `.cursor/**/agent-transcripts`; everything
    /// else is treated as Claude Code.
    public static func detect(path: String) -> TranscriptFormat {
        if CodexPaths.isCodexTranscript(path) { return .codex }
        if CursorPaths.isCursorTranscript(path) { return .cursor }
        return .claudeCode
    }

    /// Codex usage lines carry neither the model nor the working directory —
    /// those arrive on earlier `session_meta` and `turn_context` lines — so a
    /// resumed mid-file read would parse them blind. Re-read the whole file on
    /// every change instead; dedupe by ordinal keeps it idempotent. Claude
    /// Code lines are self-contained, so they stay incremental.
    public var reingestsWholeFile: Bool {
        switch self {
        case .claudeCode: return false
        case .codex, .cursor: return true
        }
    }

    public func makeParser() -> TranscriptLineParser {
        switch self {
        case .claudeCode: return ClaudeCodeLineParser()
        case .codex: return CodexParser()
        case .cursor: return CursorParser()
        }
    }
}

/// Stateless adapter over the existing Claude Code parser so both formats share
/// one ingest loop.
public final class ClaudeCodeLineParser: TranscriptLineParser {
    public init() {}
    public func parse(line: Data, context: LineContext) -> ParsedLine? {
        ClaudeCodeParser.parse(line: line, context: context)
    }
}

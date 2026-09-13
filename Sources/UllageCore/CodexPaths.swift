import Foundation

/// Where the OpenAI Codex CLI keeps its session rollouts.
///
/// `~/.codex/sessions/<yyyy>/<mm>/<dd>/rollout-<ts>-<session-id>.jsonl`, one
/// file per session. `CODEX_HOME` relocates the whole `~/.codex` tree.
public enum CodexPaths {
    public static func homeDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        if let override = environment["CODEX_HOME"], !override.isEmpty {
            return [URL(fileURLWithPath: ClaudePaths.expand(override), isDirectory: true)]
        }
        return [ClaudePaths.homeDirectory().appendingPathComponent(".codex", isDirectory: true)]
    }

    public static func sessionsDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        homeDirectories(environment: environment).map {
            $0.appendingPathComponent("sessions", isDirectory: true)
        }
    }

    /// True for a path under a Codex `sessions` tree. Ingestion routes these to
    /// the Codex parser; everything else is treated as Claude Code.
    public static func isCodexTranscript(_ path: String) -> Bool {
        path.contains("/.codex/sessions/") || path.contains("/codex/sessions/")
    }
}

/// Every transcript root Ullage watches: Claude Code projects plus Codex
/// sessions. One place so the tailer, the CLI and `info` agree.
public enum TranscriptSources {
    public static func roots(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        ClaudePaths.projectsDirectories(environment: environment)
            + CodexPaths.sessionsDirectories(environment: environment)
    }
}

import Foundation

/// Where the Cursor agent CLI keeps its transcripts:
/// `~/.cursor/projects/<slug>/agent-transcripts/<id>/<id>.jsonl`. `CURSOR_HOME`
/// relocates the tree.
public enum CursorPaths {
    public static func homeDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        if let override = environment["CURSOR_HOME"], !override.isEmpty {
            return [URL(fileURLWithPath: ClaudePaths.expand(override), isDirectory: true)]
        }
        return [ClaudePaths.homeDirectory().appendingPathComponent(".cursor", isDirectory: true)]
    }

    public static func projectsDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        homeDirectories(environment: environment).map {
            $0.appendingPathComponent("projects", isDirectory: true)
        }
    }

    public static func isCursorTranscript(_ path: String) -> Bool {
        path.contains("/.cursor/") && path.contains("/agent-transcripts/")
    }
}

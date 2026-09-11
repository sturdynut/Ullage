import Foundation

/// Where Claude Code keeps its transcripts, and where we keep the database.
public enum ClaudePaths {
    public static let bundleIdentifier = "com.sturdynut.ullage"

    /// `CLAUDE_CONFIG_DIR` wins over `~/.claude`.
    ///
    /// `CLAUDE_CONFIG_DIRS` (colon-delimited, multiple roots) also exists. It is
    /// out of scope for v1 but the API shape below returns a list so supporting
    /// it later is not a redesign.
    public static func configDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        if let single = environment["CLAUDE_CONFIG_DIR"], !single.isEmpty {
            return [URL(fileURLWithPath: expand(single), isDirectory: true)]
        }
        return [homeDirectory().appendingPathComponent(".claude", isDirectory: true)]
    }

    public static func projectsDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        configDirectories(environment: environment).map {
            $0.appendingPathComponent("projects", isDirectory: true)
        }
    }

    public static func defaultDatabaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["ULLAGE_DB"], !override.isEmpty {
            return URL(fileURLWithPath: expand(override))
        }
        #if os(macOS)
        let base = homeDirectory()
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        #else
        // Linux is only used to run the collector's tests and CLI.
        let base = environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: expand($0), isDirectory: true) }
            ?? homeDirectory().appendingPathComponent(".local/share", isDirectory: true)
        #endif
        return base
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("telemetry.db")
    }

    static func homeDirectory() -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// Claude Code's directory naming: non-alphanumerics become `-`, truncated
    /// to 200 characters with a hash of the full path appended if longer.
    /// Only needed to go from a cwd to a directory name; ingestion reads `cwd`
    /// off the entries themselves, which is authoritative.
    public static func sanitize(cwd: String) -> String {
        let mapped = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        guard mapped.count > 200 else { return mapped }
        return String(mapped.prefix(200)) + "-" + Hashing.fnv1a(cwd)
    }
}

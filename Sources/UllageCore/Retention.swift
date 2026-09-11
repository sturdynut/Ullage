import Foundation

/// Claude Code deletes transcripts older than `cleanupPeriodDays` at startup.
/// The default is 30 days, the deletion is silent, and pruned sessions are
/// unrecoverable — so every tool that touches the transcripts says something
/// about this until it is set.
public enum Retention {
    public static let recommendedDays = 3_650

    public enum Status: Equatable {
        case unset                  // defaults to 30 days
        case days(Int)
        case unreadable(String)

        public var isSafe: Bool {
            if case .days(let days) = self { return days >= 365 }
            return false
        }
    }

    public static func status(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> Status {
        guard let settings = ClaudePaths.configDirectories(environment: environment).first?
            .appendingPathComponent("settings.json") else { return .unset }
        guard fileManager.fileExists(atPath: settings.path) else { return .unset }
        guard let data = fileManager.contents(atPath: settings.path),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .unreadable(settings.path)
        }
        guard let days = JSONAccess.int(root, "cleanupPeriodDays") else { return .unset }
        return .days(days)
    }

    public static func warning(for status: Status) -> String? {
        switch status {
        case .days(let days) where days >= 365:
            return nil
        case .days(let days):
            return """
            cleanupPeriodDays is \(days): transcripts older than that are deleted at startup, \
            silently and unrecoverably. Raise it to \(recommendedDays) in ~/.claude/settings.json.
            """
        case .unset:
            return """
            cleanupPeriodDays is unset, so Claude Code deletes transcripts older than 30 days \
            at startup, silently and unrecoverably. Set { "cleanupPeriodDays": \(recommendedDays) } \
            in ~/.claude/settings.json.
            """
        case .unreadable(let path):
            return "could not read \(path) to check cleanupPeriodDays."
        }
    }
}

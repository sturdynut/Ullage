import Foundation

/// A snapshot of the configuration a session ran under. Mirrors `session_env`.
///
/// This is the most important table in the schema and the only one that is not
/// backfillable. Nothing on disk records which MCP servers were configured,
/// which skills existed, or what CLAUDE.md said when a session ran; that state
/// mutates constantly and leaves no history. It is the denominator for the
/// whole ghost-token question: MCP definitions and CLAUDE.md ride in the prompt
/// on every turn whether or not anything invokes them.
public struct SessionEnvRow: Equatable {
    public var sessionId: String
    public var capturedAt: String
    public var claudeVersion: String?
    public var mcpServers: String?      // JSON array of server names
    public var skills: String?          // JSON array of skill names
    public var claudeMdHash: String?
    public var claudeMdBytes: Int?
    public var claudeMdBody: String?    // full text, imports expanded

    public init(
        sessionId: String,
        capturedAt: String,
        claudeVersion: String? = nil,
        mcpServers: String? = nil,
        skills: String? = nil,
        claudeMdHash: String? = nil,
        claudeMdBytes: Int? = nil,
        claudeMdBody: String? = nil
    ) {
        self.sessionId = sessionId
        self.capturedAt = capturedAt
        self.claudeVersion = claudeVersion
        self.mcpServers = mcpServers
        self.skills = skills
        self.claudeMdHash = claudeMdHash
        self.claudeMdBytes = claudeMdBytes
        self.claudeMdBody = claudeMdBody
    }
}

public protocol SessionEnvironmentProviding {
    func snapshot(sessionId: String, cwd: String?, claudeVersion: String?) -> SessionEnvRow
}

/// Reads the configuration as it exists *now*.
///
/// For a live session that is the truth. For a transcript from three weeks ago
/// it is the best available answer and `captured_at` says so — which is exactly
/// why the backfill is time-sensitive rather than a nice-to-have.
public struct SessionEnvironmentProvider: SessionEnvironmentProviding {
    let configDirectories: [URL]
    let fileManager: FileManager

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        self.configDirectories = ClaudePaths.configDirectories(environment: environment)
        self.fileManager = fileManager
    }

    public func snapshot(sessionId: String, cwd: String?, claudeVersion: String?) -> SessionEnvRow {
        let memory = claudeMemory(cwd: cwd)
        return SessionEnvRow(
            sessionId: sessionId,
            capturedAt: Timestamps.now(),
            claudeVersion: claudeVersion,
            mcpServers: jsonArray(mcpServerNames(cwd: cwd)),
            skills: jsonArray(skillNames(cwd: cwd)),
            claudeMdHash: memory.map { SHA256.hexDigest($0) },
            claudeMdBytes: memory.map { $0.utf8.count },
            claudeMdBody: memory
        )
    }

    // MARK: - MCP servers

    /// Names only. The definitions are what ride in the prompt, but the names
    /// are enough to answer "what was configured" and keep the row small.
    func mcpServerNames(cwd: String?) -> [String] {
        var names = Set<String>()
        for url in mcpConfigFiles(cwd: cwd) {
            guard let data = fileManager.contents(atPath: url.path),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                continue
            }
            names.formUnion(serverNames(in: root))
            // ~/.claude.json keys its per-directory config under "projects".
            if let projects = root["projects"] as? [String: Any] {
                if let cwd, let project = projects[cwd] as? [String: Any] {
                    names.formUnion(serverNames(in: project))
                }
            }
        }
        return names.sorted()
    }

    private func serverNames(in object: [String: Any]) -> [String] {
        guard let servers = object["mcpServers"] as? [String: Any] else { return [] }
        return Array(servers.keys)
    }

    func mcpConfigFiles(cwd: String?) -> [URL] {
        var urls: [URL] = []
        for config in configDirectories {
            urls.append(config.appendingPathComponent("settings.json"))
            // ~/.claude.json sits next to ~/.claude, not inside it.
            urls.append(config.deletingLastPathComponent().appendingPathComponent(".claude.json"))
        }
        if let cwd {
            let project = URL(fileURLWithPath: cwd, isDirectory: true)
            urls.append(project.appendingPathComponent(".mcp.json"))
            urls.append(project.appendingPathComponent(".claude/settings.json"))
            urls.append(project.appendingPathComponent(".claude/settings.local.json"))
        }
        return urls.filter { fileManager.fileExists(atPath: $0.path) }
    }

    // MARK: - Skills

    func skillNames(cwd: String?) -> [String] {
        var directories = configDirectories.map { $0.appendingPathComponent("skills", isDirectory: true) }
        if let cwd {
            directories.append(
                URL(fileURLWithPath: cwd, isDirectory: true)
                    .appendingPathComponent(".claude/skills", isDirectory: true)
            )
        }
        var names = Set<String>()
        for directory in directories {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: directory.path) else { continue }
            for entry in entries {
                let skill = directory.appendingPathComponent(entry, isDirectory: true)
                if fileManager.fileExists(atPath: skill.appendingPathComponent("SKILL.md").path) {
                    names.insert(entry)
                }
            }
        }
        return names.sorted()
    }

    // MARK: - CLAUDE.md

    /// User memory plus every project CLAUDE.md from the repo root down to the
    /// working directory, in the order Claude Code loads them, with `@path`
    /// imports expanded inline.
    func claudeMemory(cwd: String?) -> String? {
        var sections: [String] = []
        for config in configDirectories {
            let userMemory = config.appendingPathComponent("CLAUDE.md")
            if let body = expand(fileAt: userMemory) {
                sections.append("<!-- \(userMemory.path) -->\n" + body)
            }
        }
        for url in projectMemoryFiles(cwd: cwd) {
            if let body = expand(fileAt: url) {
                sections.append("<!-- \(url.path) -->\n" + body)
            }
        }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }

    func projectMemoryFiles(cwd: String?) -> [URL] {
        guard let cwd else { return [] }
        var directories: [URL] = []
        var current = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL
        let home = ClaudePaths.homeDirectory().standardizedFileURL
        while true {
            directories.append(current)
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path || current.path == home.path || parent.path == "/" { break }
            current = parent
        }
        // Outermost first: a nested CLAUDE.md is loaded after, and overrides.
        return directories.reversed().flatMap { directory in
            [
                directory.appendingPathComponent("CLAUDE.md"),
                directory.appendingPathComponent(".claude/CLAUDE.md"),
            ]
        }.filter { fileManager.fileExists(atPath: $0.path) }
    }

    /// Expands `@relative/path` imports, depth-bounded and cycle-safe.
    func expand(fileAt url: URL, depth: Int = 0, seen: Set<String> = []) -> String? {
        guard depth < 5, !seen.contains(url.standardizedFileURL.path) else { return nil }
        guard let data = fileManager.contents(atPath: url.path),
              let text = String(data: data, encoding: .utf8) else { return nil }
        var seen = seen
        seen.insert(url.standardizedFileURL.path)

        var output: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let importPath = importTarget(in: String(line)) else {
                output.append(String(line))
                continue
            }
            let resolved = importPath.hasPrefix("~")
                ? URL(fileURLWithPath: ClaudePaths.expand(importPath))
                : (importPath.hasPrefix("/")
                    ? URL(fileURLWithPath: importPath)
                    : url.deletingLastPathComponent().appendingPathComponent(importPath))
            if let imported = expand(fileAt: resolved, depth: depth + 1, seen: seen) {
                output.append("<!-- imported: \(importPath) -->")
                output.append(imported)
            } else {
                output.append(String(line))
            }
        }
        return output.joined(separator: "\n")
    }

    /// A line whose only content is `@path`. Anything else — an email address,
    /// a mention inside prose, a code fence — is left alone.
    func importTarget(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("@"), trimmed.count > 1 else { return nil }
        let path = String(trimmed.dropFirst())
        guard !path.contains(" ") else { return nil }
        return path
    }

    private func jsonArray(_ values: [String]) -> String? {
        guard !values.isEmpty else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: values) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

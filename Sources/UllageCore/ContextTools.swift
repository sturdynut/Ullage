import Foundation

/// A third-party tool that helps keep the context window small: it shrinks
/// what the model reads (rtk, Tokenade), what it writes (caveman), or what it
/// needs to read at all (Serena, claude-context), or carries memory across
/// sessions (claude-mem).
///
/// Every tool is *described*, not hard-coded: a `ToolDescriptor` says how to
/// recognise it, what kind it is, where its own claims live, and how to
/// install and switch it. Everything downstream — the report, the popover
/// row, the window and phone pages, the CLI, the switches, the installer —
/// works from the list of descriptors, and branches on `kind`, never on which
/// tool. Built-in descriptors ship with Ullage; anyone can add one as a JSON
/// file in `~/.config/ullage/tools/` without rebuilding (`ToolRegistry`).
///
/// What Ullage can honestly say depends on the kind:
/// - **output filters** shrink what the model reads before Ullage sees it, so
///   their saving is only ever their own claim, labelled as theirs (rule 6);
/// - **reply style** tools change measured output, compared with and without;
/// - **on-demand, code search and memory** tools are MCP servers or hooks:
///   whether they were loaded, called, and how much they returned are facts.
public struct TokenSaver: Hashable, Identifiable, Sendable, CustomStringConvertible {
    public let descriptor: ToolDescriptor

    public init(_ descriptor: ToolDescriptor) { self.descriptor = descriptor }

    public var id: String { descriptor.id }
    public var description: String { descriptor.id }
    public var rawValue: String { descriptor.id }
    public var displayName: String { descriptor.name }
    public var kind: ToolDescriptor.Kind { descriptor.kind }
    /// What it shrinks or replaces, as a phrase: "Bash output".
    public var shrinks: String { descriptor.shrinks }
    /// Where a figure about this tool's effect comes from.
    public var savingSource: String { descriptor.claims?.source ?? descriptor.kind.defaultSource }

    /// Every tool the registry knows: built-ins, then the user's own.
    public static var allCases: [TokenSaver] { ToolRegistry.shared.tools }

    public init?(rawValue: String) {
        guard let tool = ToolRegistry.shared.tool(id: rawValue) else { return nil }
        self = tool
    }

    public static func == (a: TokenSaver, b: TokenSaver) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    // MARK: Matching (all from the descriptor's patterns)

    public func matches(hookCommand command: String) -> Bool {
        Self.any(descriptor.detect.hookCommand, command)
    }

    public func matches(mcpServer name: String) -> Bool {
        Self.any(descriptor.detect.mcpServer, name)
    }

    /// `enabledPlugins` keys are `<plugin>@<marketplace>`.
    public func matches(pluginKey key: String) -> Bool {
        Self.any(descriptor.detect.plugin, key)
    }

    /// Skill tool targets and slash commands, with or without the leading `/`.
    public func matches(skillOrCommand name: String) -> Bool {
        let bare = name.hasPrefix("/") ? String(name.dropFirst()) : name
        return Self.any(descriptor.detect.skill, bare)
    }

    /// `command` is a Bash tool target; its program is what's matched.
    public func matches(bashCommand command: String) -> Bool {
        guard !descriptor.detect.bash.isEmpty else { return false }
        return Self.any(descriptor.detect.bash, ToolTargets.program(of: command).split(separator: " ").first.map(String.init) ?? "")
    }

    public static func saver(forHookCommand command: String) -> TokenSaver? {
        allCases.first { $0.matches(hookCommand: command) }
    }

    /// Case-insensitive regular expressions; an invalid one matches nothing.
    static func any(_ patterns: [String], _ text: String) -> Bool {
        patterns.contains { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    // The built-ins by name, for code and tests that mean a specific tool.
    public static let rtk = TokenSaver(BuiltinTools.rtk)
    public static let tokenade = TokenSaver(BuiltinTools.tokenade)
    public static let caveman = TokenSaver(BuiltinTools.caveman)
    public static let headroom = TokenSaver(BuiltinTools.headroom)
}

/// Everything Ullage knows about one tool, as data. The JSON shape of a file
/// in `~/.config/ullage/tools/` is exactly this, keys as below.
public struct ToolDescriptor: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Rewrites or filters tool output before the model reads it (rtk).
        case outputFilter
        /// Changes how the model writes (caveman).
        case replyStyle
        /// An MCP server that only acts when called (Headroom).
        case onDemand
        /// Lets the agent find code without reading whole files (Serena).
        case codeSearch
        /// Carries context between sessions (claude-mem).
        case memory

        var defaultSource: String {
            switch self {
            case .outputFilter: return "the tool's own count"
            case .replyStyle: return "measured output, with vs without — a comparison, not a saving"
            case .onDemand, .codeSearch, .memory: return "calls and results counted from transcripts"
            }
        }
    }

    /// Case-insensitive regular expressions matched against what config and
    /// transcripts record.
    public struct Detect: Codable, Equatable, Sendable {
        public var hookCommand: [String] = []
        public var mcpServer: [String] = []
        public var plugin: [String] = []
        public var skill: [String] = []
        /// The program of a Bash command (`codegraph explore …` → `codegraph`),
        /// for tools agents run from the shell rather than as MCP tools.
        public var bash: [String] = []

        public init(hookCommand: [String] = [], mcpServer: [String] = [], plugin: [String] = [],
                    skill: [String] = [], bash: [String] = []) {
            self.hookCommand = hookCommand
            self.mcpServer = mcpServer
            self.plugin = plugin
            self.skill = skill
            self.bash = bash
        }

        enum CodingKeys: String, CodingKey { case hookCommand, mcpServer, plugin, skill, bash }

        // Every list optional in a descriptor file.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            hookCommand = try c.decodeIfPresent([String].self, forKey: .hookCommand) ?? []
            mcpServer = try c.decodeIfPresent([String].self, forKey: .mcpServer) ?? []
            plugin = try c.decodeIfPresent([String].self, forKey: .plugin) ?? []
            skill = try c.decodeIfPresent([String].self, forKey: .skill) ?? []
            bash = try c.decodeIfPresent([String].self, forKey: .bash) ?? []
        }
    }

    /// The tool's own record of what it saved, read by a registered adapter
    /// (`ClaimsReaders`): never a measurement, always labelled as the tool's.
    public struct Claims: Codable, Equatable, Sendable {
        /// Which adapter reads it, e.g. "rtk-history".
        public var reader: String
        /// "rtk's own estimate (bytes ÷ 4)".
        public var source: String
        /// For the legend: "rtk counts bytes ÷ 4".
        public var how: String
        /// True when each claim is about one API request (a proxy that
        /// compresses every prompt anew), not one tool result. A result's
        /// saving is kept out of every later prompt, so it can be carried
        /// forward; a request's is already per prompt and must not be.
        public var perRequest: Bool? = nil
    }

    public struct Install: Codable, Equatable, Sendable {
        /// The executable on PATH, when the tool has one.
        public var binary: String?
        /// Its package name, for uninstalling with whichever manager installed it.
        public var package: String?
        /// Ways to install the binary, in order of preference: the first whose
        /// `needs` is on this Mac is used.
        public var packages: [Package] = []
        /// Steps that wire it into Claude Code, run when it isn't wired yet.
        public var setup: [Step] = []
        /// Steps that unwire it, run before the package is removed.
        public var teardown: [Step] = []
        public var notes: [String] = []

        public init(binary: String? = nil, package: String? = nil, packages: [Package] = [], setup: [Step] = [],
                    teardown: [Step] = [], notes: [String] = []) {
            self.binary = binary
            self.package = package
            self.packages = packages
            self.setup = setup
            self.teardown = teardown
            self.notes = notes
        }

        enum CodingKeys: String, CodingKey { case binary, package, packages, setup, teardown, notes }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            binary = try c.decodeIfPresent(String.self, forKey: .binary)
            package = try c.decodeIfPresent(String.self, forKey: .package)
            packages = try c.decodeIfPresent([Package].self, forKey: .packages) ?? []
            setup = try c.decodeIfPresent([Step].self, forKey: .setup) ?? []
            teardown = try c.decodeIfPresent([Step].self, forKey: .teardown) ?? []
            notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
        }
    }

    public struct Package: Codable, Equatable, Sendable {
        /// brew | npm | uv | pipx | cargo | script
        public var manager: String
        public var command: String
        /// The tool that must exist to run `command`; defaults to the manager.
        public var needs: String?

        public init(manager: String, command: String, needs: String? = nil) {
            self.manager = manager
            self.command = command
            self.needs = needs
        }
    }

    public struct Step: Codable, Equatable, Sendable {
        public var command: String
        public var purpose: String
        public var interactive: Bool? = nil
        /// A tool the step needs on PATH (`claude`, the tool's own binary…).
        public var needs: String? = nil
        /// Run only when this is present: "binary" or "wired" (default).
        public var when: String? = nil

        public init(command: String, purpose: String, interactive: Bool? = nil, needs: String? = nil, when: String? = nil) {
            self.command = command
            self.purpose = purpose
            self.interactive = interactive
            self.needs = needs
            self.when = when
        }
    }

    public var id: String
    public var name: String
    public var kind: Kind
    public var shrinks: String
    /// One sentence for the help: what it does.
    public var about: String
    public var detect: Detect
    public var claims: Claims?
    public var install: Install?
}

/// The tools Ullage knows: the built-ins, plus every JSON descriptor in the
/// user's tools folder (a user file with a built-in's id replaces it).
public struct ToolRegistry: Sendable {
    public let tools: [TokenSaver]
    /// Files that could not be read as a descriptor, with why: shown by
    /// `ullage tools`, never a reason to fail.
    public let problems: [String]

    public static let shared = ToolRegistry.load()

    public func tool(id: String) -> TokenSaver? { tools.first { $0.id == id } }

    public static func toolsDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["ULLAGE_TOOLS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: ClaudePaths.expand(override), isDirectory: true)
        }
        let config = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: ClaudePaths.expand($0), isDirectory: true) }
            ?? ClaudePaths.homeDirectory().appendingPathComponent(".config", isDirectory: true)
        return config.appendingPathComponent("ullage/tools", isDirectory: true)
    }

    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> ToolRegistry {
        var byId: [String: ToolDescriptor] = [:]
        var order: [String] = []
        for descriptor in BuiltinTools.all {
            byId[descriptor.id] = descriptor
            order.append(descriptor.id)
        }
        var problems: [String] = []
        let directory = toolsDirectory(environment: environment)
        let files = ((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".json") }.sorted()
        for file in files {
            let url = directory.appendingPathComponent(file)
            guard let data = fileManager.contents(atPath: url.path) else { continue }
            do {
                let descriptor = try JSONDecoder().decode(ToolDescriptor.self, from: data)
                guard descriptor.id.range(of: "^[a-z0-9][a-z0-9_-]{0,40}$", options: .regularExpression) != nil else {
                    problems.append("\(file): id must be lowercase letters, digits, - or _")
                    continue
                }
                if byId[descriptor.id] == nil { order.append(descriptor.id) }
                byId[descriptor.id] = descriptor
            } catch {
                problems.append("\(file): \(error)")
            }
        }
        return ToolRegistry(tools: order.compactMap { byId[$0] }.map(TokenSaver.init), problems: problems)
    }
}

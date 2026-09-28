import Foundation

/// Installing and uninstalling token savers with each tool's *own* documented
/// commands — Ullage never reimplements an installer.
///
/// A plan is built from what is already there, so installing rtk when the
/// binary exists only wires the hook, and uninstalling Headroom removes it with
/// whichever package manager put it there (pipx, uv, Homebrew, …), found by
/// resolving the binary's path. Plans are data: the CLI prints them before
/// running, the app shows them before opening Terminal to run them, and
/// nothing runs without being asked.
public enum SaverAction: String, Equatable {
    case install
    case uninstall
}

public enum PackageManager: String, Equatable {
    case homebrew = "Homebrew"
    case cargo
    case npm
    case pipx
    case uv
    /// A standalone install script put it somewhere on PATH.
    case script = "install script"

    /// Which manager owns a binary, from where its symlink really points.
    public static func owning(resolvedPath path: String) -> PackageManager {
        if path.contains("/Cellar/") || path.contains("/Caskroom/") { return .homebrew }
        if path.contains("/pipx/venvs/") { return .pipx }
        if path.contains("/uv/tools/") { return .uv }
        if path.contains("/.cargo/bin/") { return .cargo }
        if path.contains("/node_modules/") { return .npm }
        return .script
    }
}

public struct InstallStep: Equatable {
    /// One shell line, exactly as it will run.
    public var command: String
    public var purpose: String
    /// Needs a person: a browser sign-in, a prompt.
    public var interactive: Bool

    public init(_ command: String, _ purpose: String, interactive: Bool = false) {
        self.command = command
        self.purpose = purpose
        self.interactive = interactive
    }
}

public struct InstallPlan: Equatable {
    public var saver: TokenSaver
    public var action: SaverAction
    public var steps: [InstallStep]
    /// Tools the plan needs that are not on this machine; the plan cannot run.
    public var missing: [String]
    public var notes: [String]

    public var isRunnable: Bool { missing.isEmpty && !steps.isEmpty }
    public var needsPerson: Bool { steps.contains(where: \.interactive) }
}

/// What is on disk for one saver, regardless of whether it is switched on.
public struct SaverInstallation: Equatable {
    /// The tool's binary, resolved through symlinks (nil for caveman, a plugin).
    public var binary: String?
    public var manager: PackageManager?
    /// Wired into Claude Code: hook, MCP server, or plugin present (on or off).
    public var wired: Bool

    public var isInstalled: Bool { binary != nil || wired }
}

public struct SaverInstaller {
    public static let cavemanPlugin = "caveman@caveman"

    /// Directories searched for binaries. A menu bar app launched from Finder
    /// gets a bare PATH, so the usual install locations are searched by name.
    let searchPaths: [String]
    let installedPluginsURL: URL
    let switchboard: SaverSwitchboard
    let fileManager: FileManager

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        switchboard: SaverSwitchboard? = nil,
        fileManager: FileManager = .default
    ) {
        self.searchPaths = Self.searchPaths(environment: environment, fileManager: fileManager)
        self.installedPluginsURL = ClaudePaths.configDirectories(environment: environment)[0]
            .appendingPathComponent("plugins/installed_plugins.json")
        self.switchboard = switchboard ?? SaverSwitchboard(environment: environment)
        self.fileManager = fileManager
    }

    init(searchPaths: [String], installedPluginsURL: URL, switchboard: SaverSwitchboard, fileManager: FileManager = .default) {
        self.searchPaths = searchPaths
        self.installedPluginsURL = installedPluginsURL
        self.switchboard = switchboard
        self.fileManager = fileManager
    }

    static func searchPaths(environment: [String: String], fileManager: FileManager) -> [String] {
        let home = ClaudePaths.homeDirectory().path
        var paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        paths += ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.cargo/bin",
                  "\(home)/.volta/bin", "\(home)/.bun/bin", "/usr/bin", "/bin"]
        // nvm keeps one bin per Node version; newest name last is close enough.
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? fileManager.contentsOfDirectory(atPath: nvm) {
            paths += versions.sorted().reversed().map { "\(nvm)/\($0)/bin" }
        }
        var seen = Set<String>()
        return paths.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The first executable named `name` on the search path.
    public func which(_ name: String) -> String? {
        for directory in searchPaths {
            let path = (directory as NSString).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    // MARK: - What is installed

    public func installation(of saver: TokenSaver) -> SaverInstallation {
        let wired = switchboard.state(of: saver) != .notInstalled
        switch saver {
        case .caveman:
            return SaverInstallation(binary: nil, manager: nil, wired: wired || cavemanPluginInstalled())
        case .rtk, .tokenade, .headroom:
            guard let path = which(binaryName(saver)) else {
                return SaverInstallation(binary: nil, manager: nil, wired: wired)
            }
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            return SaverInstallation(binary: path, manager: .owning(resolvedPath: resolved), wired: wired)
        }
    }

    func binaryName(_ saver: TokenSaver) -> String {
        switch saver {
        case .rtk: return "rtk"
        case .tokenade: return "tokenade"
        case .headroom: return "headroom"
        case .caveman: return "caveman"
        }
    }

    func cavemanPluginInstalled() -> Bool {
        guard let data = fileManager.contents(atPath: installedPluginsURL.path),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        let plugins = root["plugins"] as? [String: Any] ?? root
        return plugins.keys.contains(where: TokenSaver.caveman.matches(pluginKey:))
    }

    // MARK: - Plans

    public func plan(_ saver: TokenSaver, _ action: SaverAction) -> InstallPlan {
        let current = installation(of: saver)
        let tools = ["brew", "npm", "uv", "pipx", "claude", "cargo", "curl"]
        let available = Set(tools.filter { which($0) != nil })
        return action == .install
            ? Self.installPlan(saver, current: current, available: available)
            : Self.uninstallPlan(saver, current: current, available: available)
    }

    /// Pure: the steps from what is present and which tools exist.
    static func installPlan(_ saver: TokenSaver, current: SaverInstallation, available: Set<String>) -> InstallPlan {
        var steps: [InstallStep] = []
        var missing: [String] = []
        var notes: [String] = []
        switch saver {
        case .rtk:
            if current.binary == nil {
                if available.contains("brew") {
                    steps.append(InstallStep("brew install rtk", "Install rtk"))
                } else if available.contains("curl") {
                    steps.append(InstallStep(
                        "curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh",
                        "Install rtk with its install script"))
                } else {
                    missing.append("Homebrew or curl")
                }
            }
            if !current.wired {
                steps.append(InstallStep("rtk init -g", "Add rtk's hook to Claude Code"))
            }
        case .tokenade:
            if current.binary == nil {
                if available.contains("npm") {
                    steps.append(InstallStep("npm install -g @tokenade/cli", "Install Tokenade"))
                } else {
                    missing.append("npm (Node.js)")
                }
            }
            if !current.wired {
                steps.append(InstallStep("tokenade install", "Add Tokenade's hooks and MCP server"))
                steps.append(InstallStep("tokenade login", "Sign in to a free Tokenade account (opens a browser)", interactive: true))
                notes.append("Tokenade needs an account and sends usage totals to its dashboard.")
            }
        case .caveman:
            if !current.wired {
                if available.contains("claude") {
                    steps.append(InstallStep("claude plugin marketplace add JuliusBrussee/caveman", "Add caveman's marketplace"))
                    steps.append(InstallStep("claude plugin install \(cavemanPlugin)", "Install the caveman plugin"))
                } else {
                    missing.append("the claude CLI")
                }
            }
        case .headroom:
            if current.binary == nil {
                if available.contains("uv") {
                    steps.append(InstallStep("uv tool install --python 3.13 \"headroom-ai[mcp]\"", "Install Headroom"))
                } else if available.contains("pipx") {
                    steps.append(InstallStep("pipx install \"headroom-ai[mcp]\"", "Install Headroom"))
                } else {
                    missing.append("uv or pipx")
                }
            }
            if !current.wired {
                if available.contains("claude") {
                    steps.append(InstallStep("claude mcp add --scope user headroom -- headroom mcp serve",
                                             "Register Headroom's MCP server with Claude Code"))
                } else {
                    missing.append("the claude CLI")
                }
            }
        }
        if steps.isEmpty, missing.isEmpty { notes.append("\(saver.displayName) is already installed.") }
        notes.append("Applies to Claude Code sessions started afterwards.")
        return InstallPlan(saver: saver, action: .install, steps: steps, missing: missing, notes: notes)
    }

    static func uninstallPlan(_ saver: TokenSaver, current: SaverInstallation, available: Set<String>) -> InstallPlan {
        var steps: [InstallStep] = []
        var notes: [String] = []
        switch saver {
        case .rtk:
            if current.binary != nil {
                steps.append(InstallStep("rtk init -g --uninstall", "Remove rtk's hook and RTK.md from Claude Code"))
            } else if current.wired {
                notes.append("rtk's hook is still in settings.json but rtk itself is gone; switch it off to park the hook.")
            }
        case .tokenade:
            if current.binary != nil {
                steps.append(InstallStep("tokenade uninstall", "Remove Tokenade's hooks, MCP server and shell aliases"))
            }
        case .caveman:
            if current.wired {
                steps.append(InstallStep("claude plugin uninstall \(cavemanPlugin)", "Uninstall the caveman plugin"))
                steps.append(InstallStep("claude plugin marketplace remove caveman", "Remove caveman's marketplace"))
            }
        case .headroom:
            if current.wired {
                steps.append(InstallStep("claude mcp remove --scope user headroom",
                                         "Unregister Headroom's MCP server from Claude Code"))
            }
        }
        if let binary = current.binary, let manager = current.manager {
            let package: String
            switch saver {
            case .rtk: package = "rtk"
            case .tokenade: package = "@tokenade/cli"
            case .headroom: package = "headroom-ai"
            case .caveman: package = ""
            }
            switch manager {
            case .homebrew: steps.append(InstallStep("brew uninstall \(package)", "Remove the \(saver.displayName) binary"))
            case .cargo: steps.append(InstallStep("cargo uninstall \(package)", "Remove the \(saver.displayName) binary"))
            case .npm: steps.append(InstallStep("npm uninstall -g \(package)", "Remove \(saver.displayName)"))
            case .pipx: steps.append(InstallStep("pipx uninstall \(package)", "Remove \(saver.displayName)"))
            case .uv: steps.append(InstallStep("uv tool uninstall \(package)", "Remove \(saver.displayName)"))
            case .script: steps.append(InstallStep("rm \(shellQuote(binary))", "Remove the \(saver.displayName) binary an install script put there"))
            }
        }
        if steps.isEmpty { notes.append("\(saver.displayName) is not installed.") }
        let missing = steps.compactMap { step -> String? in
            let tool = String(step.command.split(separator: " ").first ?? "")
            let needed = ["brew", "npm", "uv", "pipx", "claude", "cargo"]
            return needed.contains(tool) && !available.contains(tool) ? tool : nil
        }
        return InstallPlan(saver: saver, action: .uninstall, steps: steps, missing: Array(Set(missing)).sorted(), notes: notes)
    }

    // MARK: - Running

    /// A script that runs the plan in a login shell, echoing each step, and
    /// stops at the first failure. Used as a Terminal `.command` by the app.
    public static func script(for plan: InstallPlan, shell: String = "/bin/zsh") -> String {
        var lines = [
            "#!\(shell) -il",
            "# Ullage: \(plan.action.rawValue) \(plan.saver.displayName). Each command is the tool's own.",
            "set -e",
            "clear",
            "echo \(shellQuote("Ullage — \(plan.action.rawValue) \(plan.saver.displayName)"))",
            "echo",
        ]
        for step in plan.steps {
            lines.append("echo \(shellQuote("→ " + step.purpose))")
            lines.append("echo \(shellQuote("  $ " + step.command))")
            lines.append(step.command)
            lines.append("echo")
        }
        lines.append("echo \(shellQuote("Done. \(plan.notes.last ?? "") You can close this window."))")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes the script as an executable `.command` in the temp directory;
    /// opening it runs it in Terminal.
    public static func writeCommandFile(for plan: InstallPlan, shell: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ullage-\(plan.action.rawValue)-\(plan.saver.rawValue)-\(UUID().uuidString.prefix(8)).command")
        try script(for: plan, shell: shell).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

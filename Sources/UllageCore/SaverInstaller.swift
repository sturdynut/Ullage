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

    /// A plugin's cached version, else what its binary's `--version` says.
    /// Bounded: a tool that hangs on `--version` costs five seconds, not the CLI.
    public func version(of saver: TokenSaver) -> String? {
        if let plugin = (switchboard.wiring(of: saver)["plugins"] as? [String])?.first {
            return URL(fileURLWithPath: plugin).lastPathComponent
        }
        guard let name = saver.descriptor.install?.binary, let path = which(name) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        guard (try? process.run()) != nil else { return nil }
        if done.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            return nil
        }
        return BenchResults.version(in: String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    public func installation(of saver: TokenSaver) -> SaverInstallation {
        let wired = switchboard.state(of: saver) != .notInstalled || pluginInstalled(saver)
        guard let name = saver.descriptor.install?.binary, let path = which(name) else {
            return SaverInstallation(binary: nil, manager: nil, wired: wired)
        }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return SaverInstallation(binary: path, manager: .owning(resolvedPath: resolved), wired: wired)
    }

    /// A Claude Code plugin counts as wired once installed, switched on or not.
    func pluginInstalled(_ saver: TokenSaver) -> Bool {
        guard !saver.descriptor.detect.plugin.isEmpty,
              let data = fileManager.contents(atPath: installedPluginsURL.path),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        let plugins = root["plugins"] as? [String: Any] ?? root
        return plugins.keys.contains(where: saver.matches(pluginKey:))
    }

    // MARK: - Plans

    public func plan(_ saver: TokenSaver, _ action: SaverAction) -> InstallPlan {
        let current = installation(of: saver)
        let recipe = saver.descriptor.install
        // Typed in pieces: as one expression it times out the Linux type checker.
        let managers: [String] = recipe?.packages.map { $0.needs ?? $0.manager } ?? []
        let stepNeeds: [String] = ((recipe?.setup ?? []) + (recipe?.teardown ?? [])).compactMap(\.needs)
        let wanted = Set(["brew", "npm", "npx", "uv", "pipx", "claude", "cargo", "curl"] + managers + stepNeeds)
        let available = Set(wanted.filter { which($0) != nil })
        return action == .install
            ? Self.installPlan(saver, current: current, available: available)
            : Self.uninstallPlan(saver, current: current, available: available)
    }

    /// Pure: the tool's recipe, minus what is already there, checked against
    /// which commands this Mac has.
    static func installPlan(_ saver: TokenSaver, current: SaverInstallation, available: Set<String>) -> InstallPlan {
        guard let recipe = saver.descriptor.install else {
            return InstallPlan(saver: saver, action: .install, steps: [], missing: [],
                               notes: ["Ullage doesn't know how to install \(saver.displayName); install it yourself and it will show up here."])
        }
        var steps: [InstallStep] = []
        var missing: [String] = []
        if let binary = recipe.binary, current.binary == nil {
            if let package = recipe.packages.first(where: { available.contains($0.needs ?? $0.manager) }) {
                steps.append(InstallStep(package.command, "Install \(saver.displayName)"))
            } else {
                let options = recipe.packages.map { readable($0.needs ?? $0.manager) }
                missing.append(options.isEmpty ? "a way to install \(binary)" : options.joined(separator: " or "))
            }
        }
        if !current.wired {
            for step in recipe.setup {
                // The tool's own binary is the package step's job, not a prerequisite.
                if let needs = step.needs, !available.contains(needs), needs != recipe.binary {
                    missing.append(readable(needs))
                }
                steps.append(InstallStep(step.command, step.purpose, interactive: step.interactive ?? false))
            }
        }
        var notes: [String] = []
        if steps.isEmpty, missing.isEmpty { notes.append("\(saver.displayName) is already installed.") }
        if !steps.isEmpty { notes += recipe.notes }
        notes.append("Applies to Claude Code sessions started afterwards.")
        return InstallPlan(saver: saver, action: .install, steps: steps, missing: unique(missing), notes: notes)
    }

    static func uninstallPlan(_ saver: TokenSaver, current: SaverInstallation, available: Set<String>) -> InstallPlan {
        let recipe = saver.descriptor.install
        var steps: [InstallStep] = []
        var missing: [String] = []
        var notes: [String] = []
        for step in recipe?.teardown ?? [] {
            let runs = step.when == "binary" ? current.binary != nil : current.wired
            guard runs else { continue }
            if let needs = step.needs, !available.contains(needs), needs != recipe?.binary {
                missing.append(needs)
            }
            steps.append(InstallStep(step.command, step.purpose, interactive: step.interactive ?? false))
        }
        if current.wired, current.binary == nil, recipe?.binary != nil,
           (recipe?.teardown ?? []).allSatisfy({ $0.when == "binary" }) {
            notes.append("\(saver.displayName)'s hook is still in Claude Code's settings but \(saver.displayName) itself is gone; switch it off to park it.")
        }
        if let binary = current.binary, let manager = current.manager {
            let package = recipe?.package ?? recipe?.binary ?? saver.id
            let removal: (String, String)
            switch manager {
            case .homebrew: removal = ("brew uninstall \(package)", "brew")
            case .cargo: removal = ("cargo uninstall \(package)", "cargo")
            case .npm: removal = ("npm uninstall -g \(package)", "npm")
            case .pipx: removal = ("pipx uninstall \(package)", "pipx")
            case .uv: removal = ("uv tool uninstall \(package)", "uv")
            case .script: removal = ("rm \(shellQuote(binary))", "")
            }
            if !removal.1.isEmpty, !available.contains(removal.1) { missing.append(removal.1) }
            steps.append(InstallStep(removal.0, manager == .script
                ? "Remove the \(saver.displayName) binary an install script put there"
                : "Remove \(saver.displayName)"))
        }
        if steps.isEmpty { notes.append("\(saver.displayName) is not installed.") }
        return InstallPlan(saver: saver, action: .uninstall, steps: steps, missing: unique(missing).sorted(), notes: notes)
    }

    /// How a missing command is named to a person.
    static func readable(_ tool: String) -> String {
        switch tool {
        case "brew": return "Homebrew"
        case "npm", "npx": return "npm (Node.js)"
        case "claude": return "the claude CLI"
        default: return tool
        }
    }

    private static func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }

    // MARK: - Running

    /// A script that runs the plan in a login shell, echoing each step, and
    /// stops at the first failure. Used as a Terminal `.command` by the app.
    /// `marker`, when given, receives the script's exit status however it
    /// ends — how Ullage learns an install in Terminal has finished, and
    /// whether it worked, without holding on to the process.
    public static func script(for plan: InstallPlan, shell: String = "/bin/zsh", marker: URL? = nil) -> String {
        var lines = [
            "#!\(shell) -il",
            "# Ullage: \(plan.action.rawValue) \(plan.saver.displayName). Each command is the tool's own.",
        ]
        if let marker { lines.append("trap 'echo $? > \(shellQuote(marker.path))' EXIT") }
        lines += [
            "set -e",
            "clear 2>/dev/null || true",
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
    public static func writeCommandFile(for plan: InstallPlan, shell: String) throws -> (script: URL, marker: URL) {
        let stem = "ullage-\(plan.action.rawValue)-\(plan.saver.rawValue)-\(UUID().uuidString.prefix(8))"
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        let url = directory.appendingPathComponent(stem + ".command")
        let marker = directory.appendingPathComponent(stem + ".status")
        try script(for: plan, shell: shell, marker: marker).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return (url, marker)
    }

    /// The exit status a finished script left in its marker, or nil while it
    /// is still running (or never started).
    public static func finishedStatus(marker: URL) -> Int32? {
        guard let data = FileManager.default.contents(atPath: marker.path),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// What a row says once a run has finished.
    /// `after` is the saver's state re-read from Claude Code's config once the
    /// commands finished. An exit status of 0 only says the tool's own command
    /// was happy: rtk's `init -g` declines to patch settings.json when nobody
    /// answers its prompt, and an uninstaller can leave its hook behind. The
    /// config says what actually changed, so it has the last word.
    public static func outcome(of plan: InstallPlan, status: Int32, after: SaverSwitchState? = nil) -> String {
        let name = plan.saver.displayName
        guard status == 0 else {
            return "\(plan.action == .install ? "Install" : "Uninstall") of \(name) stopped (exit \(status)) · see Terminal"
        }
        if let after, !tookEffect(plan.action, after: after) {
            return plan.action == .install
                ? "\(name)'s installer finished, but nothing was added to Claude Code · see Terminal"
                : "\(name)'s uninstaller finished, but it is still on in Claude Code"
        }
        switch (plan.action, after) {
        case (.install, .off?):
            return "\(name) installed · switched off"
        case (.install, _):
            return "\(name) installed · on from the next session"
        case (.uninstall, _):
            return "\(name) uninstalled · gone from the next session"
        }
    }

    /// An install leaves the saver in Claude Code's config; an uninstall
    /// leaves it not switched on. A copy Ullage parked while it was switched
    /// off is Ullage's own, so `off` counts as gone.
    public static func tookEffect(_ action: SaverAction, after: SaverSwitchState) -> Bool {
        action == .install ? after != .notInstalled : after != .on
    }

    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

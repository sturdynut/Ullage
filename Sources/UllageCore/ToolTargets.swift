import Foundation

/// What each tool was called on, grouped so the most-called things surface:
/// Bash by program (`git status` and `git diff` under `git`), file tools by
/// path, everything else by its target as recorded.
///
/// The grouping is for reading, not accounting — the tokens under a group are
/// the same length estimates as the tool's, just split by target.
public enum ToolTargets {
    public static let noTarget = "(no target)"

    /// Programs whose first argument is a subcommand worth keeping:
    /// `git status` and `git push` are different habits, `ls -la` and `ls` are not.
    static let subcommandPrograms: Set<String> = [
        "git", "swift", "npm", "pnpm", "yarn", "npx", "gh", "uv", "cargo", "docker",
        "brew", "kubectl", "go", "make", "bun", "pip", "poetry", "wrangler", "xcodebuild",
    ]

    public static let fileTools: Set<String> = ["Read", "Edit", "Write", "NotebookEdit", "MultiEdit"]

    public struct Called: Equatable, Identifiable {
        public var tool: String
        public var target: ContextComposition.TargetShare
        public var id: String { tool + "|" + target.name }
        /// A file path shortened to its last two components; anything else as recorded.
        public var displayName: String {
            ToolTargets.fileTools.contains(tool) ? ToolTargets.shortPath(target.name) : target.name
        }
    }

    /// The things called more than once across every tool, most-called first.
    public static func mostCalled(_ composition: ContextComposition, limit: Int = 6) -> [Called] {
        var all: [Called] = []
        for tool in composition.tools {
            for target in tool.targets where target.name != noTarget && target.calls > 1 {
                all.append(Called(tool: tool.name, target: target))
            }
        }
        all.sort { mostCalled($0.target, $1.target) }
        return Array(all.prefix(limit))
    }

    public static func group(tool: String, calls: [ToolCallRow]) -> [ContextComposition.TargetShare] {
        var groups: [String: [ToolCallRow]] = [:]
        for call in calls {
            groups[groupKey(tool: tool, target: call.target), default: []].append(call)
        }
        return groups.map { key, members in
            var share = share(name: key, members)
            // A program run with more than one distinct command opens to them.
            if tool == "Bash" || tool == "BashOutput" {
                let distinct = Dictionary(grouping: members) { $0.target ?? noTarget }
                if distinct.count > 1 {
                    share.members = distinct.map { self.share(name: $0.key, $0.value) }.sorted(by: mostCalled)
                }
            }
            return share
        }
        .sorted(by: mostCalled)
    }

    static func share(name: String, _ calls: [ToolCallRow]) -> ContextComposition.TargetShare {
        .init(
            name: name,
            calls: calls.count,
            resultTokens: calls.reduce(0) { $0 + ($1.resultTokens ?? 0) },
            errors: calls.filter { $0.isError == true }.count
        )
    }

    /// Most calls first, then most tokens, then name — stable between turns.
    static func mostCalled(_ a: ContextComposition.TargetShare, _ b: ContextComposition.TargetShare) -> Bool {
        if a.calls != b.calls { return a.calls > b.calls }
        if a.resultTokens != b.resultTokens { return a.resultTokens > b.resultTokens }
        return a.name < b.name
    }

    public static func groupKey(tool: String, target: String?) -> String {
        guard let target = target?.trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty else {
            return noTarget
        }
        if tool == "Bash" || tool == "BashOutput" { return program(of: target) }
        return fileTools.contains(tool) ? rangeFree(target) : target
    }

    /// `@<offset>+<limit>` after a Read target, either part omitted when absent.
    public static func rangeSuffix(offset: Int?, limit: Int?) -> String? {
        guard offset != nil || limit != nil else { return nil }
        return "@" + (offset.map(String.init) ?? "") + "+" + (limit.map(String.init) ?? "")
    }

    /// The path without its read range: what a file is grouped and named by.
    public static func rangeFree(_ target: String) -> String {
        guard let at = target.lastIndex(of: "@"), target[at...].dropFirst().contains("+"),
              target[at...].dropFirst().allSatisfy({ $0.isNumber || $0 == "+" }) else { return target }
        return String(target[..<at])
    }

    /// `cd ~/x && FOO=1 git status -s | head` → `git status`.
    ///
    /// The first simple command in the line that runs something: `cd` and
    /// bare assignments (`DB="…"; sqlite3 …`) are skipped, and quotes are
    /// respected so a quoted path with a space is one word.
    public static func program(of command: String) -> String {
        let firstLine = command.split(whereSeparator: \.isNewline).first.map(String.init) ?? command
        for statement in statements(firstLine) {
            var words = statement
            // Leading environment assignments and wrappers say nothing about the program.
            while let first = words.first,
                  isAssignment(first) || ["sudo", "time", "env", "exec", "nohup", "command"].contains(first) {
                words.removeFirst()
            }
            guard let head = words.first, head != "cd" else { continue }
            let name = head.hasPrefix("/") || head.hasPrefix("./") || head.hasPrefix("~/")
                ? (head as NSString).lastPathComponent
                : head
            if subcommandPrograms.contains(name),
               let sub = words.dropFirst().first(where: { !$0.hasPrefix("-") }) {
                return name + " " + sub
            }
            return name
        }
        return String(firstLine.prefix(40)).trimmingCharacters(in: .whitespaces)
    }

    /// `NAME=value`, where NAME is a shell identifier.
    static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        return word[..<equals].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// The line split into simple commands on `;`, `&&`, `||`, `|` and
    /// subshell parentheses, each
    /// split into words, with quoted text kept whole and its quotes dropped.
    /// Only the first command of a pipeline is kept: `swift test | grep` is a test run.
    static func statements(_ line: String) -> [[String]] {
        var statements: [[String]] = []
        var words: [String] = []
        var word = ""
        var quote: Character?
        var inPipeTail = false
        var index = line.startIndex

        func endWord() {
            if !word.isEmpty { words.append(word); word = "" }
        }
        func endStatement(pipe: Bool) {
            endWord()
            if !inPipeTail, !words.isEmpty { statements.append(words) }
            words = []
            inPipeTail = pipe
        }

        while index < line.endIndex {
            let char = line[index]
            let next = line.index(after: index)
            if let open = quote {
                if char == open { quote = nil } else { word.append(char) }
            } else if char == "\"" || char == "'" {
                quote = char
            } else if char == " " || char == "\t" {
                endWord()
            } else if char == ";" || char == "(" || char == ")" {
                // A subshell's parentheses bound its commands like `;` does.
                endStatement(pipe: false)
            } else if char == "&" || char == "|", next < line.endIndex, line[next] == char {
                endStatement(pipe: false)
                index = line.index(after: next)
                continue
            } else if char == "|" {
                endStatement(pipe: true)
            } else {
                word.append(char)
            }
            index = next
        }
        endStatement(pipe: false)
        return statements
    }

    /// `/Users/me/Code/Ullage/Sources/UllageCore/Store.swift` → `UllageCore/Store.swift`.
    public static func shortPath(_ path: String) -> String {
        let parts = path.split(separator: "/")
        return parts.count > 2 ? parts.suffix(2).joined(separator: "/") : path
    }
}

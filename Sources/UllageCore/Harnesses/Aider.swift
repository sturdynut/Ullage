import Foundation

extension Vendor {
    public static let aider = "aider"
}

/// Where Aider's chat histories are. Aider writes `.aider.chat.history.md` at
/// each git root (`aider/args.py` `--chat-history-file`) and keeps no global
/// list of repos (`~/.aider` holds analytics and caches only), so there is
/// nothing to discover from. `ULLAGE_AIDER_REPOS` lists repos (or history
/// files) to watch, colon-separated; `ullage ingest <file>` reads one directly.
public enum AiderPaths {
    public static let fileName = ".aider.chat.history.md"

    public static func historyFiles(environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        (environment["ULLAGE_AIDER_REPOS"] ?? "").split(separator: ":").compactMap { entry in
            let path = ClaudePaths.expand(String(entry).trimmingCharacters(in: .whitespaces))
            guard !path.isEmpty else { return nil }
            return path.hasSuffix(".md")
                ? URL(fileURLWithPath: path)
                : URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(fileName)
        }
    }

    public static func isAiderHistory(_ path: String) -> Bool { path.hasSuffix("/" + fileName) }
}

/// Reads an Aider chat history (Markdown, appended to, re-read whole).
///
/// A session starts at `# aider chat started at <local time>`
/// (`aider/io.py`). Aider echoes its tool output as `> ` blockquotes, which
/// carry the banner (`> Model: <name> with <format> edit format…`) and,
/// after each reply, the usage report
/// (`> Tokens: 12k sent, 1.5k cache write, 8k cache hit, 1.2k received.`,
/// `aider/coders/base_coder.py` `calculate_and_show_tokens_and_cost`).
///
/// Those figures are display strings rounded by `format_tokens` ("12k"), and
/// "sent" sums every completion behind one reply (retries, reflections), so
/// rows are `estimated` with no window: never a gauge.
public struct AiderReader: TranscriptDocumentReader {
    public static let version = 1

    public init() {}

    public func read(file: URL, context: LineContext) -> [ParsedLine] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        return Self.parse(text, path: file.path)
    }

    static let headerPrefix = "# aider chat started at "

    static func parse(_ text: String, path: String) -> [ParsedLine] {
        let cwd = (path as NSString).deletingLastPathComponent
        let project = URL(fileURLWithPath: cwd).lastPathComponent
        let pathHash = String(SHA256.hexDigest(path).prefix(8))

        var out: [ParsedLine] = []
        var session: String?
        var sessionTs = ""
        var model: String?
        var ordinal = 0
        var seen: [String: Int] = [:]

        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(headerPrefix) {
                guard let start = localDate(String(line.dropFirst(headerPrefix.count))) else {
                    session = nil
                    continue
                }
                sessionTs = Timestamps.string(from: start)
                var id = "aider-\(pathHash)-\(compact(start))"
                let repeats = seen[id, default: 0]
                seen[id] = repeats + 1
                if repeats > 0 { id += "-\(repeats)" }
                session = id
                model = nil
                ordinal = 0
                continue
            }
            guard let session else { continue }
            if let name = modelName(line) {
                model = name
            } else if line.hasPrefix("> Tokens: "), let usage = usage(line) {
                let input = max(0, usage.sent - usage.cacheHit - usage.cacheWrite)
                let call = CallRow(
                    dedupeKey: "aider:\(session):\(ordinal)", ts: sessionTs, vendor: Vendor.aider,
                    sessionId: session, project: project, cwd: cwd, model: model,
                    input: input, output: usage.received, cacheRead: usage.cacheHit, cacheWrite: usage.cacheWrite,
                    contextTokens: input + usage.cacheHit + usage.cacheWrite, windowLimit: nil,
                    sourceFile: path, confidence: Confidence.estimated.rawValue, parserVersion: version
                )
                out.append(.call(ParsedCall(call: call, toolCalls: [], claudeVersion: nil)))
                ordinal += 1
            } else if line == "#### /clear" || line == "#### /reset" {
                out.append(.event(EventRow(
                    id: "aider:\(session):clear:\(ordinal)", sessionId: session, ts: sessionTs,
                    kind: EventKind.clear.rawValue
                )))
            }
        }
        return out
    }

    struct Usage: Equatable {
        var sent = 0
        var cacheWrite = 0
        var cacheHit = 0
        var received = 0
    }

    /// `> Tokens: 12k sent, 1.5k cache write, 8k cache hit, 1.2k received. Cost: …`
    static func usage(_ line: String) -> Usage? {
        guard let body = line.components(separatedBy: "Tokens: ").dropFirst().first else { return nil }
        let report = body.components(separatedBy: " received").first.map { $0 + " received" } ?? body
        var usage = Usage()
        var found = Set<String>()
        for part in report.components(separatedBy: ", ") {
            let words = part.split(separator: " ", maxSplits: 1).map(String.init)
            guard words.count == 2, let value = tokens(words[0]) else { continue }
            switch words[1] {
            case "sent": usage.sent = value
            case "cache write": usage.cacheWrite = value
            case "cache hit": usage.cacheHit = value
            case "received": usage.received = value
            default: continue
            }
            found.insert(words[1])
        }
        return found.contains("sent") && found.contains("received") ? usage : nil
    }

    /// `format_tokens`: `834`, `1.2k`, `12k`.
    static func tokens(_ text: String) -> Int? {
        if text.hasSuffix("k"), let value = Double(text.dropLast()), value >= 0 { return Int((value * 1000).rounded()) }
        return Int(text).flatMap { $0 >= 0 ? $0 : nil }
    }

    /// `> Model: claude-sonnet-4-5 with diff edit format, prompt cache` or
    /// `> Main model: …` when a weak model is configured.
    static func modelName(_ line: String) -> String? {
        for prefix in ["> Model: ", "> Main model: "] where line.hasPrefix(prefix) {
            let rest = line.dropFirst(prefix.count)
            let name = rest.components(separatedBy: " with ").first?.trimmingCharacters(in: .whitespaces) ?? ""
            return name.isEmpty ? nil : name
        }
        return nil
    }

    /// Aider writes `datetime.now()` with no zone: the Mac's local time.
    static func localDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: text.trimmingCharacters(in: .whitespaces))
    }

    static func compact(_ date: Date) -> String {
        Timestamps.string(from: date).filter(\.isNumber).prefix(14).description
    }
}

extension Harness {
    public static let aider = Harness(
        id: Vendor.aider, name: "Aider",
        capabilities: .init(
            occupancy: .approximate, window: .none, cacheSplit: true, timestamps: false,
            notes: [
                "Aider writes token counts only as rounded display text (\"12k sent\"), so its figures are estimates and never fill the gauge.",
                "One reading per reply; \"sent\" adds up every request behind a reply, retries included.",
                "Aider records when a session started, not when each reply came, so a session's replies share its start time.",
                "Aider keeps no list of repos: set ULLAGE_AIDER_REPOS (colon-separated) or run `ullage ingest <repo>/.aider.chat.history.md`.",
            ]
        ),
        roots: { AiderPaths.historyFiles(environment: $0) },
        owns: AiderPaths.isAiderHistory,
        reading: .document { AiderReader() }
    )
}

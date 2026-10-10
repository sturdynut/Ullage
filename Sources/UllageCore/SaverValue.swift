import Foundation

// MARK: - Evidence

/// How a figure about a context tool is known. Every figure on the value
/// page carries one, and the grade decides how it is marked: a claim never
/// looks like a measurement, and a comparison never looks like a saving.
public enum Evidence: String, CaseIterable, Equatable, Codable {
    /// Read off the API's own counters.
    case measured
    /// Ullage's length estimate of text in the transcript (~4 bytes/token).
    case estimated
    /// The tool's own ledger, which Ullage can't check.
    case claimed
    /// Sessions with the tool against sessions without, in one folder.
    case compared
    /// A claim multiplied by a measured count (rule 10: never a counter).
    case derived

    /// The prefix a value carries: approximate figures get `≈`.
    public var mark: String {
        switch self {
        case .measured, .compared: return ""
        case .estimated, .claimed, .derived: return "≈"
        }
    }

    /// The short badge beside a figure.
    public var badge: String {
        switch self {
        case .measured: return "measured"
        case .estimated: return "estimate"
        case .claimed: return "its claim"
        case .compared: return "with vs without"
        case .derived: return "claim × prompts"
        }
    }

    /// One plain sentence: what the badge means and how far to trust it.
    public var explanation: String {
        switch self {
        case .measured: return "Measured: read off the API's own counters or the transcript."
        case .estimated: return "Estimate: Ullage's size of text in the transcript, about 4 bytes per token."
        case .claimed: return "Its claim: the tool's own count. Ullage never sees the output before it was shrunk, so it can't check the \"before\"; where a call ran one command, it checks the \"after\"."
        case .compared: return "With vs without: sessions where the tool left a trace against sessions where it didn't, over the days both had sessions. Different work, so the gap is neither a saving nor a cost."
        case .derived: return "Claim × prompts: the tool's claim counted again in each prompt the shrunk result stayed in. The prompt count is measured; the claim is not. A running total of tokens sent, not room in the window."
        }
    }

    /// The explanations for the grades that appear, in a fixed order.
    public static func legend(for figures: [ValueFigure]) -> [String] {
        let present = Set(figures.map(\.evidence))
        return allCases.filter(present.contains).map(\.explanation)
    }
}

// MARK: - With and without

/// One per-session (or per-reply) figure in sessions where a tool left a
/// trace against sessions where it didn't, in one folder. Both sides are
/// measured or estimated the same way; they are different work, so the gap
/// between them is never called a saving.
public struct SaverComparison: Equatable, Identifiable {
    public enum Metric: String, CaseIterable, Equatable {
        /// Output tokens per main-thread reply (reply-style tools).
        case outputPerReply
        /// The first main-thread prompt's context: what is loaded before any
        /// work. A tool's fixed cost — definitions, instructions, memory.
        case firstPrompt
        /// Tokens Read returned per session (code search tools).
        case readsPerSession
        /// Tokens Read, Grep, Glob and Bash returned before the first edit
        /// (memory tools, which aim to cut re-exploring).
        case exploreBeforeEdit

        public var title: String {
            switch self {
            case .outputPerReply: return "Output per reply"
            case .firstPrompt: return "First prompt"
            case .readsPerSession: return "File reads per session"
            case .exploreBeforeEdit: return "Exploring before the first edit"
            }
        }

        /// The first prompt and output come from the API's counters; result
        /// sizes are Ullage's length estimates (rule 6).
        public var evidenceOfSides: Evidence {
            switch self {
            case .outputPerReply, .firstPrompt: return .measured
            case .readsPerSession, .exploreBeforeEdit: return .estimated
            }
        }

        /// What one value is per, when it isn't the whole first prompt.
        public var per: String? {
            switch self {
            case .outputPerReply: return "per reply"
            case .firstPrompt: return nil
            case .readsPerSession, .exploreBeforeEdit: return "per session"
            }
        }

        /// Fewer than this on either side is too few to compare.
        public var minimum: Int { self == .outputPerReply ? OutputComparison.minimumTurns : 5 }

        /// Replies, or sessions.
        public var sample: String { self == .outputPerReply ? "replies" : "sessions" }
    }

    public struct Side: Equatable {
        public var median: Int
        public var count: Int
        public var sessions: Int
    }

    public struct Sample: Equatable {
        public var sessionId: String
        public var value: Int
        public init(sessionId: String, value: Int) {
            self.sessionId = sessionId
            self.value = value
        }
    }

    /// Where the sessions came from: the shown session's folder when it has
    /// enough of each, else every folder — more sessions, more confounded
    /// (each folder has its own CLAUDE.md and work), and said so.
    public enum Scope: String, Equatable {
        case folder = "this folder"
        case everywhere = "all folders"
    }

    /// Below this on either side, a comparison is shown but called thin.
    public static let fewBelow = 10

    public var metric: Metric
    public var with: Side
    public var without: Side
    public var scope: Scope = .folder
    public var id: String { metric.rawValue }

    /// Nil when either side has fewer than `metric.minimum` samples.
    public static func build(_ metric: Metric, with: [Sample], without: [Sample], scope: Scope = .folder) -> SaverComparison? {
        guard with.count >= metric.minimum, without.count >= metric.minimum else { return nil }
        func side(_ samples: [Sample]) -> Side {
            Side(median: OutputComparison.median(samples.map(\.value)), count: samples.count,
                 sessions: Set(samples.map(\.sessionId)).count)
        }
        var comparison = SaverComparison(metric: metric, with: side(with), without: side(without))
        comparison.scope = scope
        return comparison
    }

    /// caveman's per-reply comparison in the same shape.
    public init(_ output: OutputComparison) {
        self.init(metric: .outputPerReply,
                  with: Side(median: output.withMedian, count: output.withTurns, sessions: output.withSessions),
                  without: Side(median: output.withoutMedian, count: output.withoutTurns, sessions: output.withoutSessions))
    }

    public init(metric: Metric, with: Side, without: Side) {
        self.metric = metric
        self.with = with
        self.without = without
    }
}

// MARK: - A claim carried forward

/// What happened to the results a tool's claims are about.
///
/// A tool result enters every prompt after it until the context is
/// compacted or the session ends, so a token kept out of it is kept out of
/// each of those prompts — mostly as a cache read. The number of prompts is
/// measured; the token figure is the tool's claim times that count, so it is
/// `derived` and labelled as such, and never enters a counter (rule 10).
public struct CarriedClaim: Equatable {
    /// Where one Bash call sits in its stream, read from the transcript.
    public struct Placement: Equatable {
        /// Prompts that contained the call's result: later turns in the same
        /// stream, up to the next compaction.
        public var prompts: Int
        /// Ullage's length estimate of what reached the model.
        public var resultTokens: Int?
        /// The command as the model wrote it.
        public var command: String?
        public init(prompts: Int, resultTokens: Int?, command: String?) {
            self.prompts = prompts
            self.resultTokens = resultTokens
            self.command = command
        }
    }

    /// Ledger rows placed on a call in the transcript, and all rows.
    public var placedEntries: Int
    public var entries: Int
    /// The claim on placed rows only.
    public var placedSaved: Int
    /// Σ claimed saving × prompts it stayed out of.
    public var promptTokens: Int
    /// Mean prompts a placed result stayed in context for, weighted by call.
    public var meanPrompts: Double
    /// Calls simple enough to check the claim's "after" against the
    /// transcript: one rtk command, nothing else in the call's output.
    public var checkedCalls: Int
    public var claimedAfter: Int
    public var seenAfter: Int

    public static func build(entries: [LedgerEntry], placements: [String: Placement]) -> CarriedClaim? {
        let placed = entries.filter { $0.toolUseId.map { placements[$0] != nil } ?? false }
        guard !placed.isEmpty else { return nil }
        let byCall = Dictionary(grouping: placed) { $0.toolUseId ?? "" }
        var promptTokens = 0, prompts = 0, checked = 0, claimedAfter = 0, seenAfter = 0
        for (call, rows) in byCall {
            guard let placement = placements[call] else { continue }
            promptTokens += rows.reduce(0) { $0 + $1.savedTokens } * placement.prompts
            prompts += placement.prompts
            if rows.count == 1, let after = rows[0].afterTokens, let seen = placement.resultTokens,
               let command = placement.command, isSingleCommand(command),
               let logged = rows[0].command, normalized(logged) == normalized(command) {
                checked += 1
                claimedAfter += after
                seenAfter += seen
            }
        }
        return CarriedClaim(
            placedEntries: placed.count, entries: entries.count,
            placedSaved: placed.reduce(0) { $0 + $1.savedTokens },
            promptTokens: promptTokens,
            meanPrompts: Double(prompts) / Double(byCall.count),
            checkedCalls: checked, claimedAfter: claimedAfter, seenAfter: seenAfter
        )
    }

    /// A command as rtk logs it: no leading `cd`, no stderr redirect, no
    /// quotes (rtk records arguments unquoted), single spaces. A call is only
    /// checked when its command and the logged one are the same text — rtk
    /// logs `cat a b c` as `cat a`, and that row describes one file of three.
    static func normalized(_ command: String) -> String {
        var text = command.replacingOccurrences(of: #"^\s*cd\s+\S+\s*&&\s*"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s*2>(&1|/dev/null)"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"["']"#, with: "", options: .regularExpression)
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// One command, perhaps after a `cd` and with stderr folded in: its
    /// output is the whole result, so the two sizes describe the same text.
    static func isSingleCommand(_ command: String) -> Bool {
        var text = command.replacingOccurrences(of: #"^\s*cd\s+\S+\s*&&\s*"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s*2>(&1|/dev/null)"#, with: "", options: .regularExpression)
        return text.range(of: #"[;&|\n`]|\$\("#, options: .regularExpression) == nil
    }

    /// Fewer checked calls than this say nothing either way, so no check is shown.
    public static let minimumChecks = 3

    /// How closely the transcript agrees with the claimed "after", 0…1.
    public var agreement: Double? {
        guard checkedCalls > 0, max(claimedAfter, seenAfter) > 0 else { return nil }
        return Double(min(claimedAfter, seenAfter)) / Double(max(claimedAfter, seenAfter))
    }
}

// MARK: - Cost and benefit

/// One figure on a tool's value page.
public struct ValueFigure: Equatable, Identifiable {
    public enum Side: String, Equatable, Codable { case benefit, cost, comparison }

    public var side: Side
    /// "Kept out of Bash output".
    public var label: String
    /// "≈26k", "24.1k vs 21.3k".
    public var value: String
    public var evidence: Evidence
    /// Where it comes from and over what: "rtk's own count, 295 commands".
    public var detail: String
    public var warning = false
    /// Drawn small and left off the overview: a figure that explains another
    /// rather than standing on its own (a claim carried over later prompts).
    public var secondary = false
    public var id: String { side.rawValue + label }

    public init(_ side: Side, _ label: String, _ value: String, _ evidence: Evidence, _ detail: String, warning: Bool = false) {
        self.side = side
        self.label = label
        self.value = value
        self.evidence = evidence
        self.detail = detail
        self.warning = warning
    }
}

/// What one tool costs and what it does for the context, each figure graded.
///
/// Built from `SaverDetail`, by the tool's kind and the evidence available —
/// never by which tool it is. Cost and benefit are both context tokens, but
/// figures of different grades are never added or netted against each other.
public struct SaverValue: Equatable, Identifiable {
    public var saver: TokenSaver
    public var benefits: [ValueFigure]
    public var costs: [ValueFigure]
    /// With vs without: never under "keeps out" or "costs", because the gap
    /// between two groups of sessions is neither.
    public var comparisons: [ValueFigure] = []
    public var id: String { saver.rawValue }

    public var all: [ValueFigure] { benefits + costs + comparisons }
    public var isEmpty: Bool { all.isEmpty }

    public static func build(_ detail: SaverDetail) -> SaverValue {
        let saver = detail.saver
        var benefits: [ValueFigure] = []
        var costs: [ValueFigure] = []
        let name = saver.displayName
        func tokens(_ value: Int, _ evidence: Evidence) -> String { evidence.mark + TokenFormat.compact(value) }

        // What it says it kept out, checked where the transcript can, and
        // what that came to over the prompts after.
        if let ledger = detail.ledger, let claims = saver.descriptor.claims {
            let perRequest = claims.perRequest == true
            var facts = ["\(name)'s own figure, \(ledger.entries) \(perRequest ? "requests" : "commands")"]
            if let reduction = ledger.reduction { facts.append("≈\(Int((reduction * 100).rounded()))% smaller") }
            var disagrees = false
            if let carried = detail.carried, carried.checkedCalls >= CarriedClaim.minimumChecks, let agreement = carried.agreement {
                disagrees = agreement < 0.9
                facts.append(disagrees
                    ? "its \"after\" doesn't match the transcript (\(tokens(carried.claimedAfter, .claimed)) vs \(tokens(carried.seenAfter, .estimated))) on \(carried.checkedCalls) single-command calls"
                    : "its \"after\" matches the transcript on \(carried.checkedCalls) single-command calls")
            }
            let what = perRequest ? "Requests" : saver.shrinks.prefix(1).uppercased() + saver.shrinks.dropFirst()
            benefits.append(ValueFigure(.benefit, what, tokens(ledger.savedTokens, .claimed), .claimed,
                                        facts.joined(separator: " · "), warning: disagrees))
            if let carried = detail.carried, carried.promptTokens > 0 {
                let share = carried.placedEntries == carried.entries ? ""
                    : " · \(carried.placedEntries) of \(carried.entries) commands matched to a call"
                var resent = ValueFigure(.benefit, "Not re-sent in later prompts", tokens(carried.promptTokens, .derived), .derived,
                                         "kept out of each of the \(formatPrompts(carried.meanPrompts)) prompts after it, on average"
                                            + "\(share). A running total, mostly cache reads; not room in the window at any moment")
                resent.secondary = true
                benefits.append(resent)
            }
        }
        if saver.kind == .codeSearch, detail.resultTokens > 0 {
            benefits.append(ValueFigure(.benefit, "Returned by lookups instead of whole files", tokens(detail.resultTokens, .estimated),
                                        .estimated, "\(detail.mcpCalls + detail.bashRuns) lookups"))
        }

        // What it adds to the context.
        if saver.kind == .memory, detail.sessionsInjected > 0 {
            costs.append(ValueFigure(.cost, "Injected at session start",
                                     tokens(detail.injectedBytes / 4 / max(1, detail.sessionsInjected), .estimated), .estimated,
                                     "per session, sent with every turn after"))
        }
        if saver.kind == .onDemand, detail.resultTokens > 0 {
            costs.append(ValueFigure(.cost, "What its calls returned", tokens(detail.resultTokens, .estimated), .estimated,
                                     "\(detail.mcpCalls) calls"))
        }
        if detail.sessionsIdle > 0 {
            costs.append(ValueFigure(.cost, "Loaded, never used",
                                     detail.range == .session ? "this session" : "\(detail.sessionsIdle) sessions", .measured,
                                     "its tool definitions rode in every prompt anyway", warning: true))
        }
        if detail.failedRuns > 0 {
            costs.append(ValueFigure(.cost, "Hook runs that failed", detail.failedRuns.formatted(), .measured,
                                     "of \(detail.hookRuns)", warning: true))
        }
        if detail.doubleHookedCalls > 0 {
            costs.append(ValueFigure(.cost, "Bash calls two filters both rewrote", detail.doubleHookedCalls.formatted(), .measured,
                                     "each claims the whole saving on those; the claims overlap", warning: true))
        }

        // Neither a saving nor a cost: two groups of sessions, side by side.
        let comparisons = detail.comparisons.map(figure)
        return SaverValue(saver: saver, benefits: benefits, costs: costs, comparisons: comparisons)
    }

    /// A comparison as a figure: both medians, named, and how much to read
    /// into them.
    static func figure(_ comparison: SaverComparison) -> ValueFigure {
        let mark = comparison.metric.evidenceOfSides == .estimated ? "≈" : ""
        let value = mark + TokenFormat.compact(comparison.with.median) + " with · "
            + mark + TokenFormat.compact(comparison.without.median) + " without"
        var notes = [(comparison.metric.per.map { "Median \($0)" } ?? "Median")
            + ", \(comparison.with.count) \(comparison.metric.sample) with it and \(comparison.without.count) without",
            "\(comparison.scope.rawValue), over the days both had sessions"]
        if min(comparison.with.count, comparison.without.count) < SaverComparison.fewBelow { notes.append("few sessions") }
        let high = max(comparison.with.median, comparison.without.median)
        if high > 0, Double(abs(comparison.with.median - comparison.without.median)) <= 0.05 * Double(high) {
            notes.append("no clear difference")
        }
        return ValueFigure(.comparison, comparison.metric.title, value, .compared, notes.joined(separator: " · "))
    }

    /// The overview: tools with anything to show, in the registry's fixed
    /// order (never ranked — a claim and a comparison aren't comparable), and
    /// the names of those that left no trace.
    public static func overview(_ details: [SaverDetail]) -> (shown: [SaverValue], quiet: [TokenSaver]) {
        let values = details.map(\.value)
        return (values.filter { !$0.isEmpty }, values.filter(\.isEmpty).map(\.saver))
    }

    static func formatPrompts(_ value: Double) -> String {
        value >= 10 ? String(Int(value.rounded())) : String(format: "%.1f", value)
    }
}

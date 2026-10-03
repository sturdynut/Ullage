import Foundation

/// The plain-language help behind every ⓘ, in the popover and on the phone
/// page. One copy, here, so the two never explain the same chart differently.
///
/// Progressive disclosure: a topic is one line of context and then the
/// questions someone looking at it would ask, each collapsed until opened.
/// Nothing is shown that the reader did not ask about.
public struct HelpTopic: Codable, Equatable {
    public var title: String
    /// One sentence: what this is, before any question.
    public var intro: String
    public var entries: [HelpEntry]
}

/// One question, collapsed until opened.
public struct HelpEntry: Codable, Equatable {
    /// Drawn beside the question exactly as the chart draws it, when the
    /// question is about a mark on the chart.
    public enum Glyph: String, Codable {
        case line           // the blue context line
        case warningRule    // the dashed orange 85% line
        case compaction     // the dotted grey vertical line
        case rebuildCaused  // the orange triangle
        case rebuildOther   // the grey triangle
    }

    public var question: String
    public var glyph: Glyph?
    /// What it is.
    public var answer: String
    /// Why it matters, when there is a consequence worth saying.
    public var why: String?
    /// What you can do about it, when there is something.
    public var tip: String?

    public init(_ question: String, glyph: Glyph? = nil, answer: String, why: String? = nil, tip: String? = nil) {
        self.question = question
        self.glyph = glyph
        self.answer = answer
        self.why = why
        self.tip = tip
    }
}

public enum HelpText {
    public static let chart = HelpTopic(
        title: "The chart",
        intro: "How full the context window was after each turn. Touch or hover anywhere to read that turn.",
        entries: [
            HelpEntry("What's the blue line?", glyph: .line,
                      answer: "How much of the window each turn used. The space above it is what's left.",
                      why: "Everything under the line is sent again on every turn, so the higher it gets, the more each turn costs and the sooner the conversation is compacted (see the next question)."),
            HelpEntry("What's compaction?",
                      answer: "The context window has a fixed size. When it's nearly full, Claude Code or Codex replaces the conversation so far with a short summary and carries on from that. You can also ask for it yourself with /compact.",
                      why: "It's good because it frees room, so a long task can keep going, and every turn after it is smaller and cheaper. It's bad because the summary keeps the gist, not the details: exact code, error messages, file contents and instructions you gave early on can be lost, so the model may repeat work or need reminding.",
                      tip: "Compact at a natural break, like after finishing a step, rather than letting it happen mid-task. In Claude Code, /compact accepts a note on what to keep, e.g. /compact keep the API design decisions. For a new task, a fresh session is cleaner than a compacted one."),
            HelpEntry("What's the dashed orange line?", glyph: .warningRule,
                      answer: "Ullage's early warning at 85% of the window. It isn't the compaction point itself.",
                      why: "Claude Code and Codex both compact on their own when the window is nearly full, usually somewhere between 80% and 95%. Past this line, one is likely soon.",
                      tip: "If you're mid-task, it's a good moment to finish the current step and /compact yourself, so you choose what the summary keeps."),
            HelpEntry("Why does the line suddenly drop?", glyph: .compaction,
                      answer: "A compaction happened there: the conversation was summarised to make room. The dotted line marks where.",
                      why: "Turns after it are smaller and cheaper, but the model only has the summary of what came before."),
            HelpEntry("What's an orange triangle?", glyph: .rebuildCaused,
                      answer: "A cache rebuild you caused. The model or effort changed, or a command like /model ran, so that turn couldn't reuse the cached conversation and stored it all again.",
                      why: "Cached tokens cost a fraction of fresh ones. A rebuild pays full price for the whole conversation in one turn, often hundreds of thousands of tokens. Touch it to see how many."),
            HelpEntry("What's a grey triangle?", glyph: .rebuildOther,
                      answer: "The same kind of rebuild, but not caused by you: usually the cache expired during a break of over an hour.",
                      why: "It costs the same one turn, but it's expected after a break and there's nothing to change."),
            HelpEntry("How do I avoid cache rebuilds?",
                      answer: "Pick the model and effort at the start of a session instead of switching partway. If you need a different model, starting a new session costs less than switching a long one."),
        ]
    )

    public static let cache = HelpTopic(
        title: "Cache rebuilds",
        intro: "Turns that had to store the whole conversation again instead of reusing it.",
        entries: [
            HelpEntry("What's the cache?",
                      answer: "Between turns, the conversation is kept in a cache. A normal turn reads it, which is fast and much cheaper, and pays full price only for what's new."),
            HelpEntry("What does \"re-cached 2×\" mean?", glyph: .rebuildCaused,
                      answer: "Two turns in this session couldn't use the cache because of something the session did, like switching model.",
                      why: "Each one paid full price for the whole conversation at once. They're the orange triangles on the chart."),
            HelpEntry("Why aren't all rebuilds counted?", glyph: .rebuildOther,
                      answer: "Rebuilds after a break of over an hour, or with no visible cause, are shown in grey and left out of the count.",
                      why: "They're expected, not something to fix."),
        ]
    )

    public static let composition = HelpTopic(
        title: "Context composition",
        intro: "What fills the window right now.",
        entries: [
            HelpEntry("What's the baseline?",
                      answer: "What every turn starts with: the system prompt, tool definitions, skills, CLAUDE.md and your first message.",
                      why: "It's re-sent on every turn, so trimming CLAUDE.md or unused MCP servers saves on every turn of every session."),
            HelpEntry("What are tool results?",
                      answer: "What tools returned: files read, command output, search results.",
                      why: "Everything read stays in the window until it's compacted (the chart's help explains compaction), so large outputs keep costing on every later turn."),
            HelpEntry("What are output and other?",
                      answer: "Output is what the model wrote. Other is your messages, the model's thinking, and the margin of the estimates."),
            HelpEntry("What does ≈ mean?",
                      answer: "An estimate. Tool results are sized from their length (about 4 bytes per token) because the transcript doesn't count them. The other figures are measured."),
            HelpEntry("What's \"along for the ride\"?",
                      answer: "Tool results from long ago, and files read more than once, that are still in the window.",
                      why: "They're re-sent on every turn even if they're no longer needed. A compaction or a fresh session drops them."),
        ]
    )

    public static let session = HelpTopic(
        title: "Session information",
        intro: "The numbers behind this session's chart.",
        entries: [
            HelpEntry("What's \"re-sent per turn\"?",
                      answer: "Every turn sends the whole conversation again. This is how much the latest turn sent, compared with the first, and how much of it came from cache.",
                      why: "Long sessions cost more per turn. Starting fresh, or compacting, keeps each turn small."),
            HelpEntry("What's \"re-cached N×\"?", glyph: .rebuildCaused,
                      answer: "Cache rebuilds this session caused: the orange triangles on the chart.",
                      why: "Each paid full price for the whole conversation at once."),
            HelpEntry("What's \"last turn\"?",
                      answer: "How much the window grew on the latest turn: what the last request added."),
        ]
    )

    public static let agents = HelpTopic(
        title: "Agents",
        intro: "Subagents this session started.",
        entries: [
            HelpEntry("Why do agents have their own percentage?",
                      answer: "Each agent has its own context window, separate from the session's. Its percentage is about its own work."),
            HelpEntry("What does \"not finished\" mean?",
                      answer: "The session hasn't recorded a result for it yet: still running, started in the background, or its transcript was cleaned up."),
        ]
    )

    public static let savers = HelpTopic(
        title: "Token savers",
        intro: "Tools that try to use fewer tokens.",
        entries: [
            HelpEntry("What do these tools do?",
                      answer: "rtk and Tokenade shrink command output before the model reads it. caveman shortens the model's replies. Headroom compresses content when asked."),
            HelpEntry("What does a switch do?",
                      answer: "It turns the tool on or off in Claude Code's settings, from the next session. Undo puts it back."),
            HelpEntry("Can I trust \"≈ saved\"?",
                      answer: "It's the tool's own count, which Ullage can't check: Ullage only ever sees the output after it was shrunk."),
            HelpEntry("What does caveman's number mean?",
                      answer: "Replies with caveman on compared with replies without it, in this folder over 30 days.",
                      why: "Different replies did different work, so it's a comparison, not a measured saving."),
            HelpEntry("What does \"idle\" mean?",
                      answer: "The tool was loaded but never used this session.",
                      why: "Its tool definitions still took up room in every prompt."),
            HelpEntry("What happens when I install one?",
                      answer: "Ullage shows the tool's own install commands first, then runs them in Terminal on the Mac and reports how it went."),
        ]
    )

    public static let limits = HelpTopic(
        title: "Plan limits",
        intro: "How much of your subscription's allowance is left.",
        entries: [
            HelpEntry("What are these windows?",
                      answer: "Your plan's allowance resets on a schedule: every 5 hours, weekly, and per model. Each line is one of those."),
            HelpEntry("Why only percentages?",
                      answer: "That's all the providers report. Neither states a limit in tokens, so Ullage doesn't guess one."),
            HelpEntry("Why is a number faded?",
                      answer: "It's an old reading. \"Reset since last reading\" means the window has started over and the new figure isn't known yet."),
            HelpEntry("Where do these come from?",
                      answer: "Codex writes its limits into its own session files. Claude's appear only if \"Check Claude plan limits\" is on, in the ⋯ menu."),
        ]
    )

    /// Keyed by the section id the page uses, plus the chart and the cache.
    public static let all: [String: HelpTopic] = [
        "chart": chart, "cache": cache, "composition": composition, "session": session,
        "agents": agents, "savers": savers, "limits": limits,
    ]

    /// For the page, which reads the same text.
    public static var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(all) else { return "{}" }
        // Safe inside a <script>: no "</" can close the tag early.
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "</", with: "<\\/")
    }
}

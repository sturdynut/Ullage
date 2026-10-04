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
    // Style: American English, short sentences, plain words. Say what it is,
    // why it matters, and what to do, and nothing else. Every claim must be
    // true of the data Ullage shows.

    public static let chart = HelpTopic(
        title: "The chart",
        intro: "How full the context window was after each turn. Touch or hover over it to read a turn.",
        entries: [
            HelpEntry("What's the blue line?", glyph: .line,
                      answer: "How much of the context window each turn used. The space above it is what's left.",
                      why: "Each turn sends everything under the line again. The higher it goes, the more each turn costs and the sooner the conversation gets compacted."),
            HelpEntry("What's the dashed orange line?", glyph: .warningRule,
                      answer: "An early warning at 85% of the window. It isn't when compaction happens.",
                      why: "Claude Code and Codex compact on their own when the window is nearly full, usually between 80% and 95%. Once you're past this line, expect one soon.",
                      tip: "Finish your current step and run /compact yourself, so you decide when it happens."),
            HelpEntry("Why does the line suddenly drop?", glyph: .compaction,
                      answer: "The conversation was compacted there. The dotted line marks the spot.",
                      why: "Turns after it are smaller and cheaper, but the model only has a summary of what came before."),
            HelpEntry("What's an orange triangle?", glyph: .rebuildCaused,
                      answer: "A cache rebuild you caused. Switching the model or effort, or a command like /model, meant that turn couldn't use the cache, so it stored the whole conversation again.",
                      why: "Reading from the cache costs a fraction of normal input. A rebuild pays full price or more for the entire conversation in one turn. Touch it to see how many tokens."),
            HelpEntry("What's a grey triangle?", glyph: .rebuildOther,
                      answer: "A cache rebuild you didn't cause. Usually the cache expired during a break of more than an hour.",
                      why: "It costs the same, but it's expected after a break. There's nothing to fix."),
            HelpEntry("What's the cache?",
                      answer: "Between turns, the conversation is cached. Each turn reads the cache and pays full price only for what's new, which is much cheaper."),
            HelpEntry("How do I avoid cache rebuilds?",
                      answer: "Choose your model and effort when you start a session, not partway through. To use a different model, start a new session instead of switching in a long one."),
            HelpEntry("What's compaction?",
                      answer: "The context window has a fixed size. When it's nearly full, Claude Code or Codex replaces the conversation with a short summary and continues from there. You can also run /compact yourself. Only the conversation is summarized: the system prompt, tools, and CLAUDE.md or AGENTS.md are sent fresh every turn, so they're never lost.",
                      why: "It frees up room so a long task can continue, and the turns after it cost less. But a summary loses detail: exact code, error messages, file contents, and instructions you only typed in the chat. The model may repeat work or need reminding.",
                      tip: "Put instructions that should last in CLAUDE.md or AGENTS.md, not in the chat. Compact between steps, not in the middle of one. In Claude Code you can say what to keep, like /compact keep the API design decisions. For a new task, start a new session."),
        ]
    )

    public static let composition = HelpTopic(
        title: "Context",
        intro: "What's in the context window right now.",
        entries: [
            HelpEntry("What's the baseline?",
                      answer: "What every turn starts with: the system prompt, tool definitions, skills, and CLAUDE.md, plus your first message. After a compaction, the summary takes the first message's place.",
                      why: "It's sent on every turn. Trimming CLAUDE.md or removing MCP servers you don't use saves tokens on every turn of every session."),
            HelpEntry("What are tool results?",
                      answer: "What tools returned, like files read, command output, and search results.",
                      why: "They stay in the window until it's compacted, so a large output keeps costing on every turn after it."),
            HelpEntry("What are output and other?",
                      answer: "Output is what the model wrote. Other is everything else: your messages, tool inputs, and the error in the estimates."),
            HelpEntry("What does ≈ mean?",
                      answer: "It's an estimate. Transcripts don't count tool-result tokens, so Ullage estimates them from their length, about 4 bytes per token. Figures without ≈ are measured."),
            HelpEntry("What's \"along for the ride\"?",
                      answer: "Tool results from 50 or more turns ago, and files read more than once, that are still in the window.",
                      why: "They're sent on every turn even if they're no longer needed. Compacting or starting a new session clears them."),
        ]
    )

    public static let session = HelpTopic(
        title: "Session information",
        intro: "The numbers behind this session's chart.",
        entries: [
            HelpEntry("What's \"re-sent per turn\"?",
                      answer: "Each turn sends the whole conversation again. This shows how much the latest turn sent, how that compares with the first turn, and how much came from the cache.",
                      why: "The longer a session runs, the more each turn costs. Compacting or starting a new session brings it back down."),
            HelpEntry("What's \"re-cached\"?", glyph: .rebuildCaused,
                      answer: "How many cache rebuilds this session caused. They're the orange triangles on the chart.",
                      why: "Each one paid full price or more for the whole conversation in a single turn."),
            HelpEntry("What's \"last turn\"?",
                      answer: "How much the window grew on the most recent turn."),
        ]
    )

    public static let agents = HelpTopic(
        title: "Agents",
        intro: "Subagents this session started.",
        entries: [
            HelpEntry("Why does each agent have its own percentage?",
                      answer: "Each agent has its own context window, separate from the session's. Its percentage only reflects its own work."),
            HelpEntry("What does \"not finished\" mean?",
                      answer: "The session hasn't recorded a result for that agent yet. It may still be running, running in the background, or its transcript may have been deleted."),
        ]
    )

    public static let savers = HelpTopic(
        title: "Context tools",
        intro: "Tools that keep the context window smaller.",
        entries: [
            HelpEntry("What do these tools do?",
                      answer: "rtk and Tokenade shrink command output before the model reads it. caveman makes the model's replies shorter. Headroom compresses content when the model asks. Serena, codegraph and claude-context let the model look up code instead of reading whole files. claude-mem carries notes from past sessions into new ones."),
            HelpEntry("What do \"lookups\" mean?",
                      answer: "How many times the model used a code search tool, and roughly how much those lookups returned.",
                      why: "A lookup that returns a few hundred tokens can replace reading a file of several thousand."),
            HelpEntry("What does \"injected\" mean?",
                      answer: "Roughly how much a memory tool added to the context when the session started. It's estimated from the text's length.",
                      why: "It's sent with every turn after that, so it costs space for the whole session."),
            HelpEntry("Can I add a tool that isn't listed?",
                      answer: "Yes. Describe it in a JSON file in ~/.config/ullage/tools, and Ullage detects it, measures it and can switch it. Run ullage tools to check it loaded."),
            HelpEntry("What does a switch do?",
                      answer: "It turns the tool on or off in Claude Code's settings. The change applies to new sessions. Undo reverses it."),
            HelpEntry("Can I trust \"≈ saved\"?",
                      answer: "It's the tool's own count, and Ullage can't verify it. Ullage only sees the output after the tool has shrunk it."),
            HelpEntry("What does caveman's number mean?",
                      answer: "The typical reply length with caveman on, compared with replies without it, in this folder over the last 30 days.",
                      why: "Those replies did different work, so this is a comparison, not a measured saving."),
            HelpEntry("What does \"idle\" mean?",
                      answer: "The tool was loaded but never used in this session.",
                      why: "Its tool definitions still took up space in every prompt."),
            HelpEntry("What happens when I install one?",
                      answer: "Ullage shows you the tool's own install commands first. If you go ahead, they run in Terminal on your Mac, and Ullage shows whether they worked."),
        ]
    )

    public static let limits = HelpTopic(
        title: "Plan limits",
        intro: "How much of your plan's usage is left.",
        entries: [
            HelpEntry("What are these limits?",
                      answer: "Your plan's usage resets on a schedule, like every 5 hours, every week, or per model. Each row is one of these."),
            HelpEntry("Why are they percentages?",
                      answer: "That's all Anthropic and OpenAI report. Neither gives a limit in tokens, so Ullage doesn't guess one."),
            HelpEntry("Why is a number faded?",
                      answer: "It's an old reading. \"Reset since last reading\" means the limit has reset and Ullage doesn't have the new number yet."),
            HelpEntry("Where do these numbers come from?",
                      answer: "Codex saves its limits in its own session files. Claude's limits only appear if you turn on Check Claude plan limits in the ⋯ menu."),
        ]
    )

    /// The help sheet, in the order the page shows them: the chart first,
    /// then each section top to bottom. Each is a collapsible section of the
    /// one sheet the Explain button opens.
    public static let sections: [HelpTopic] = [chart, composition, session, agents, savers, limits]

    /// For the page, which reads the same text.
    public static var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(sections) else { return "[]" }
        // Safe inside a <script>: no "</" can close the tag early.
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "</", with: "<\\/")
    }
}

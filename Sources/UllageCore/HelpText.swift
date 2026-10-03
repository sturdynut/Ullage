import Foundation

/// The plain-language help behind every ⓘ, in the popover and on the phone
/// page. One copy, here, so the two never explain the same chart differently.
///
/// Written for someone who has never read the README: what they are looking
/// at, what the marks mean, and what (if anything) to do about it.
public struct HelpTopic: Codable, Equatable {
    public var title: String
    /// Short paragraphs; a line starting with "• " is a list item.
    public var lines: [String]
}

public enum HelpText {
    public static let chart = HelpTopic(title: "The chart", lines: [
        "How full the context window was after each turn. Higher means more of the window is used; the space above the line is what's left.",
        "• Blue line: how much of the window each turn used.",
        "• Dashed orange line: 85%. Past it, Claude Code will soon compact the conversation.",
        "• Dotted grey line: a compaction. The conversation was summarised, so the line drops.",
        "• ▲ Orange triangle: a cache rebuild you caused, by switching model or effort or running a command like /model. That turn re-stored most of the conversation at full price.",
        "• ▲ Grey triangle: a cache rebuild you didn't cause, usually because the session sat idle over an hour and the cache expired.",
        "Touch or hover anywhere on the chart to read that turn.",
    ])

    public static let cache = HelpTopic(title: "Cache rebuilds", lines: [
        "Between turns, the conversation is kept in a cache. A normal turn reads it, which is fast and much cheaper, and pays full price only for what's new.",
        "A rebuild is a turn that couldn't use the cache and stored most of the conversation again. On a long session that's hundreds of thousands of tokens in one turn.",
        "To avoid them: pick your model and effort at the start rather than switching mid-session. A break over an hour expires the cache anyway, and that's expected.",
    ])

    public static let composition = HelpTopic(title: "Context composition", lines: [
        "What fills the window right now, in four parts:",
        "• Baseline: what every turn starts with. The system prompt, tool definitions, skills, CLAUDE.md and your first message.",
        "• Tools: what tools returned (files read, command output, search results). Everything read stays in the window until it's compacted.",
        "• Output: what the model wrote.",
        "• Other: your messages, thinking, and the margin of the estimates.",
        "≈ marks an estimate. Tool results are sized by their length (about 4 bytes per token); the other figures are measured.",
        "\"Along for the ride\" lists results from long ago and files read more than once: still re-sent every turn, often no longer needed.",
    ])

    public static let session = HelpTopic(title: "Session information", lines: [
        "• Last turn: how much the window grew on the latest turn.",
        "• Re-sent per turn: every turn sends the whole conversation again. This is how much, compared with the first turn, and how much of it came from cache.",
        "• re-cached N×: cache rebuilds this session caused (see the chart's ▲).",
        "Long sessions cost more per turn. Starting fresh, or compacting, keeps each turn small.",
    ])

    public static let agents = HelpTopic(title: "Agents", lines: [
        "Subagents this session started. Each has its own context window, separate from the session's, so their percentages are about their own work.",
        "\"Not finished\" means the session hasn't recorded a result yet: still running, started in the background, or its transcript was cleaned up.",
    ])

    public static let savers = HelpTopic(title: "Token savers", lines: [
        "Tools that try to use fewer tokens: rtk and Tokenade shrink command output, caveman shortens the model's replies, Headroom compresses on request.",
        "• A switch turns one on or off in Claude Code's settings, from the next session. Undo puts it back.",
        "• ≈ saved is the tool's own count, which Ullage can't check.",
        "• caveman's figure compares replies with it on and off. Different work, so it's a comparison, not a saving.",
        "• \"idle\" means it was loaded but never used, and its tool definitions still took up room in every prompt.",
        "Install and Uninstall show the tool's own commands first and run them in Terminal on the Mac.",
    ])

    public static let limits = HelpTopic(title: "Plan limits", lines: [
        "How much of your subscription's allowance is left in each window (every 5 hours, weekly, and per model). Shown as a percentage because that's all the providers report.",
        "A faded number is an old reading. \"Reset since last reading\" means the window has started over and the new figure isn't known yet.",
        "Claude's limits appear only if \"Check Claude plan limits\" is on (the ⋯ menu). Codex's come from its own session files.",
    ])

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

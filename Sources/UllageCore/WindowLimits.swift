import Foundation

/// Context-window sizes keyed by model string.
///
/// Longest-prefix match, so unknown point releases of a known family still
/// resolve (`claude-sonnet-4-5-20250929` -> `claude-sonnet-4-5`). A single
/// hardcoded constant would make the headline number silently wrong for any
/// model with a different window.
public enum WindowLimits {
    /// Used when nothing matches. Wrong is possible; silent is not — callers
    /// can compare against this to tell "known" from "assumed".
    public static let fallback = 200_000

    /// Claude Code appends a bracketed suffix when a long-context variant is
    /// selected, e.g. `claude-sonnet-4-5-20250929[1m]`.
    static let suffixLimits: [String: Int] = [
        "1m": 1_000_000,
        "200k": 200_000,
    ]

    static let table: [String: Int] = [
        "claude-3-5-haiku": 200_000,
        "claude-3-5-sonnet": 200_000,
        "claude-3-7-sonnet": 200_000,
        "claude-haiku-4-5": 200_000,
        "claude-opus-4": 200_000,
        "claude-opus-4-1": 200_000,
        "claude-opus-4-5": 200_000,
        "claude-sonnet-4": 200_000,
        "claude-sonnet-4-5": 200_000,
    ]

    /// True when the model resolved against the table rather than the fallback.
    public static func isKnown(_ model: String?) -> Bool {
        guard let normalized = normalize(model) else { return false }
        return longestPrefixMatch(normalized) != nil
    }

    public static func limit(for model: String?) -> Int {
        guard let raw = model, !raw.isEmpty else { return fallback }
        if let suffix = bracketSuffix(raw), let limit = suffixLimits[suffix] { return limit }
        guard let normalized = normalize(raw) else { return fallback }
        return longestPrefixMatch(normalized) ?? fallback
    }

    private static func longestPrefixMatch(_ normalized: String) -> Int? {
        var best: (key: String, limit: Int)?
        for (key, limit) in table where normalized.hasPrefix(key) {
            if best == nil || key.count > best!.key.count {
                best = (key, limit)
            }
        }
        return best?.limit
    }

    private static func bracketSuffix(_ model: String) -> String? {
        guard let open = model.lastIndex(of: "["),
              let close = model.lastIndex(of: "]"),
              open < close else { return nil }
        return String(model[model.index(after: open)..<close]).lowercased()
    }

    /// Strips the shapes the same model arrives in from different providers:
    /// `us.anthropic.claude-sonnet-4-5-v1:0` (Bedrock), `anthropic/claude-...`
    /// (gateways), and any bracketed window suffix.
    static func normalize(_ model: String?) -> String? {
        guard var s = model?.lowercased(), !s.isEmpty else { return nil }
        if let open = s.firstIndex(of: "[") { s = String(s[s.startIndex..<open]) }
        if let slash = s.lastIndex(of: "/") { s = String(s[s.index(after: slash)...]) }
        for prefix in ["us.", "eu.", "apac.", "global."] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        if s.hasPrefix("anthropic.") { s = String(s.dropFirst("anthropic.".count)) }
        if let colon = s.firstIndex(of: ":") { s = String(s[s.startIndex..<colon]) }
        if s.hasSuffix("-v1") { s = String(s.dropLast(3)) }
        if s.hasSuffix("@") { s = String(s.dropLast()) }
        return s.isEmpty ? nil : s
    }
}

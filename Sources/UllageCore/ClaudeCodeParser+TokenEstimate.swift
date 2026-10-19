import Foundation

extension ClaudeCodeParser {
    /// Length-based estimate, never a real count. A Read of a large file is
    /// where context actually goes and this is the only handle on it without
    /// shipping a tokenizer. Always estimated, hence no `confidence` column.
    public static func estimateTokens(of content: Any?) -> Int {
        let characters = payloadCharacters(content)
        guard characters > 0 else { return 0 }
        return (characters + 3) / 4
    }

    /// Keys that carry a tool result's payload. Counting every string in the
    /// block would also count structural labels (`"type": "text"`), which
    /// inflates small results.
    static let payloadKeys = ["text", "content", "data", "output", "stdout", "stderr", "url"]

    static func payloadCharacters(_ value: Any?, depth: Int = 0) -> Int {
        guard depth < 12 else { return 0 }
        switch value {
        case var text as String:
            // Foundation JSON strings otherwise count graphemes through slow UTF-16 bridging.
            text.makeContiguousUTF8()
            return text.count
        case let array as [Any]:
            return array.reduce(0) { $0 + payloadCharacters($1, depth: depth + 1) }
        case let object as [String: Any]:
            return payloadKeys.reduce(0) { total, key in
                total + payloadCharacters(object[key], depth: depth + 1)
            }
        default:
            return 0
        }
    }
}

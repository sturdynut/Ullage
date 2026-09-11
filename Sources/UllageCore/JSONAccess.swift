import Foundation

/// Guarded accessors over `JSONSerialization` output.
///
/// Plan §9 trap 3: the transcript format is not a contract. Every field access
/// goes through here so a changed or missing key degrades to nil instead of
/// throwing and stalling ingestion.
enum JSONAccess {
    static func object(_ any: Any?) -> [String: Any]? { any as? [String: Any] }
    static func array(_ any: Any?) -> [Any]? { any as? [Any] }

    static func string(_ dict: [String: Any]?, _ key: String) -> String? {
        guard let value = dict?[key] else { return nil }
        if let s = value as? String { return s.isEmpty ? nil : s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    static func int(_ dict: [String: Any]?, _ key: String) -> Int? {
        guard let value = dict?[key] else { return nil }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    /// Missing counters default to 0 (plan §9 trap 3).
    static func intOrZero(_ dict: [String: Any]?, _ key: String) -> Int {
        int(dict, key) ?? 0
    }

    static func bool(_ dict: [String: Any]?, _ key: String) -> Bool? {
        guard let value = dict?[key] else { return nil }
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        if let s = value as? String { return s == "true" ? true : (s == "false" ? false : nil) }
        return nil
    }

    static func dict(_ dict: [String: Any]?, _ key: String) -> [String: Any]? {
        dict?[key] as? [String: Any]
    }

    static func list(_ dict: [String: Any]?, _ key: String) -> [Any]? {
        dict?[key] as? [Any]
    }

    static func jsonString(_ value: Any?) -> String? {
        guard let value else { return nil }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}

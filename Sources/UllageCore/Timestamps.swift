import Foundation

/// Timestamp handling kept in one place so `ts` is lexicographically sortable
/// in SQLite — `ORDER BY ts` is only correct if every row is normalised UTC
/// with the same number of fractional digits.
public enum Timestamps {
    /// `2025-09-01T12:34:56.789Z`
    public static let format = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"

    public static func normalize(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        // Fast path: already the shape Claude Code writes.
        if raw.count == 24, raw.hasSuffix("Z"), raw.contains(".") { return raw }
        // Same instant, no fractional part.
        if raw.count == 20, raw.hasSuffix("Z") {
            return String(raw.dropLast()) + ".000Z"
        }
        guard let date = date(from: raw) else { return raw }
        return string(from: date)
    }

    public static func date(from raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: raw) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    public static func string(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter.string(from: date)
    }

    public static func now() -> String { string(from: Date()) }
}

import Foundation

/// One item of a collapsed section's single line: `label value`, e.g.
/// `Claude 5h` `88%`, or a bare status like `Headroom idle`.
///
/// Every collapsed row in the popover is a list of these, drawn the same way:
/// the same separator, digits monospaced, and a warning colours the item that
/// needs attention, never the whole line.
public struct Readout: Equatable, Identifiable, Codable {
    public var label: String
    public var value: String?
    public var isWarning: Bool
    /// A reading too old to trust at a glance: drawn faint, not hidden.
    public var isMuted: Bool

    public init(_ label: String, _ value: String? = nil, warning: Bool = false, muted: Bool = false) {
        self.label = label
        self.value = value
        self.isWarning = warning
        self.isMuted = muted
    }

    public var id: String { label + "|" + (value ?? "") }

    /// Plain text, for width checks and accessibility.
    public static func line(_ items: [Readout]) -> String {
        items.map { [$0.label, $0.value].compactMap { $0 }.joined(separator: " ") }.joined(separator: separator)
    }

    public static let separator = " · "
}

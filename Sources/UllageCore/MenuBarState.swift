import Foundation

/// What the menu bar shows. Computed here rather than in the view so the rule
/// that matters — never show a stale number as if it were live — is testable
/// without a UI.
public struct MenuBarState: Equatable {
    public enum Status: Equatable {
        case empty      // nothing ingested yet
        case idle       // nothing recent; show a glyph, not a number
        case live
        case warning    // over the threshold
    }

    public var status: Status
    /// What goes in the menu bar itself.
    public var title: String
    public var occupancy: Double?
    public var contextTokens: Int?
    public var windowLimit: Int?
    public var sessionId: String?
    public var project: String?
    public var model: String?
    public var modelWindowIsAssumed: Bool
    public var lastActivity: Date?
    public var contextDelta: Int?

    public var isIdle: Bool { status == .idle || status == .empty }
}

public enum MenuBarFormatter {
    /// A number that looks live but is four hours old is worse than no number.
    /// 30 minutes is the plan's guess and stays a single constant so changing
    /// it is a one-line decision.
    public static let idleThreshold: TimeInterval = 30 * 60
    public static let warningThreshold = 0.85

    /// Dimmed glyph for "no recent activity". Deliberately not a percentage.
    public static let idleGlyph = "◌"
    public static let warningGlyph = "⚠︎"

    public static func state(for call: CallRow?, now: Date = Date()) -> MenuBarState {
        guard let call else {
            return MenuBarState(
                status: .empty,
                title: idleGlyph,
                occupancy: nil,
                contextTokens: nil,
                windowLimit: nil,
                sessionId: nil,
                project: nil,
                model: nil,
                modelWindowIsAssumed: false,
                lastActivity: nil,
                contextDelta: nil
            )
        }

        let timestamp = Timestamps.date(from: call.ts)
        let age = timestamp.map { now.timeIntervalSince($0) }
        let occupancy = call.occupancy
        let isIdle = (age ?? .greatestFiniteMagnitude) > idleThreshold

        let status: MenuBarState.Status
        let title: String
        if isIdle {
            status = .idle
            title = idleGlyph
        } else if let occupancy, occupancy >= warningThreshold {
            status = .warning
            title = percentage(occupancy) + " " + warningGlyph
        } else {
            status = .live
            title = occupancy.map(percentage) ?? idleGlyph
        }

        return MenuBarState(
            status: status,
            title: title,
            occupancy: occupancy,
            contextTokens: call.contextTokens,
            windowLimit: call.windowLimit,
            sessionId: call.sessionId,
            project: call.project,
            model: call.model,
            modelWindowIsAssumed: !WindowLimits.isKnown(call.model),
            lastActivity: timestamp,
            contextDelta: call.contextDelta
        )
    }

    /// Rounded down: 99% must not read as 100% while there is still room.
    public static func percentage(_ occupancy: Double) -> String {
        "\(Int(floor(occupancy * 100)))%"
    }
}

#if os(macOS)
import AppKit
import SwiftUI
import UllageCore

/// M5 — the popover behind the menu bar title: which session, how full, and
/// how it got there. Still no composition drill-down; that is the next slice.
struct PopoverContent: View {
    @ObservedObject var model: MenuBarModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            sessionPicker
            if let history = model.history {
                ContextChart(history: history)
                    .frame(height: 120)
            }
            if let composition = model.composition {
                CompositionView(composition: composition)
            }
            stats
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
            Divider()
            actions
        }
        .padding(14)
        .frame(width: 360)
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        let state = model.state
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(state.project ?? "No sessions ingested yet")
                    .font(.headline)
                    .lineLimit(1)
                if let modelName = state.model {
                    Text(modelName + (state.modelWindowIsAssumed ? "  · window assumed" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if state.status == .empty {
                Text(MenuBarFormatter.idleGlyph)
                    .font(.system(size: 26, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
            } else if let occupancy = state.occupancy {
                Text(MenuBarFormatter.percentage(occupancy))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(state.status == .warning ? Color.orange : (state.isIdle ? Color.secondary : Color.primary))
            }
        }
    }

    // MARK: Session picker

    private var sessionPicker: some View {
        HStack(spacing: 8) {
            Picker("Session", selection: $model.selection) {
                Text("Most recent").tag(SessionSelection.automatic)
                if !model.sessions.isEmpty {
                    Divider()
                }
                ForEach(model.sessions) { session in
                    Text(label(for: session)).tag(SessionSelection.pinned(session.sessionId))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            if model.pinFellBack {
                Text("pinned session has no turns; showing most recent")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func label(for session: SessionSummary) -> String {
        let project = session.project ?? "—"
        let when = Timestamps.date(from: session.lastTs)
            .map { Self.relative.localizedString(for: $0, relativeTo: Date()) } ?? ""
        let occupancy = session.occupancy.map(MenuBarFormatter.percentage) ?? "?"
        return "\(project) · \(session.sessionId.prefix(8)) · \(occupancy) · \(when)"
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    // MARK: Stats

    @ViewBuilder
    private var stats: some View {
        let state = model.state
        if state.status != .empty {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                if let context = state.contextTokens {
                    row("Context", "\(context.formatted()) / \(state.windowLimit?.formatted() ?? "?")")
                }
                if let delta = state.contextDelta {
                    row("Last turn", (delta >= 0 ? "+" : "") + delta.formatted())
                }
                if let history = model.history {
                    row("Turns", history.points.count.formatted()
                        + (history.compactionTurns.isEmpty ? "" : " · \(history.compactionTurns.count) compaction\(history.compactionTurns.count == 1 ? "" : "s")"))
                    row("Peak", history.peakContextTokens.formatted())
                }
                if let session = state.sessionId {
                    row("Session", String(session.prefix(8)))
                }
                if let last = state.lastActivity {
                    row(state.isIdle ? "Idle since" : "Last turn at",
                        last.formatted(date: .omitted, time: .standard))
                }
            }
            .font(.callout)
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }

    // MARK: Actions

    private var actions: some View {
        HStack {
            Button(model.isWatching ? "Refresh" : "Start watching") {
                if model.isWatching { model.refreshNow() } else { model.start() }
            }
            Button("History…") {
                openWindow(id: HistoryWindow.id)
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Reveal database") { model.openDatabaseFolder() }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .controlSize(.small)
    }
}
#endif

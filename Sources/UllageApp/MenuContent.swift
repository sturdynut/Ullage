#if os(macOS)
import AppKit
import SwiftUI
import UllageCore

/// The drop-down behind the menu bar title. Deliberately plain text: charts,
/// composition drill-down and multi-session views are all later milestones.
struct MenuContent: View {
    @ObservedObject var model: MenuBarModel

    var body: some View {
        if let errorMessage = model.errorMessage {
            Text("Error: \(errorMessage)")
        }

        switch model.state.status {
        case .empty:
            Text("No sessions ingested yet")
        case .idle:
            Text("Idle — no activity in the last \(Int(MenuBarFormatter.idleThreshold / 60)) minutes")
            detail
        case .live, .warning:
            detail
        }

        Divider()

        Button(model.isWatching ? "Refresh now" : "Start watching") {
            if model.isWatching { model.refreshNow() } else { model.start() }
        }
        Button("Reveal database in Finder") { model.openDatabaseFolder() }
        Divider()
        Button("Quit Ullage") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder
    private var detail: some View {
        let state = model.state
        if let project = state.project {
            Text("Project: \(project)")
        }
        if let context = state.contextTokens {
            Text("Context: \(context.formatted()) / \(state.windowLimit?.formatted() ?? "?")"
                 + (state.occupancy.map { "  (\(MenuBarFormatter.percentage($0)))" } ?? ""))
        }
        if let delta = state.contextDelta {
            Text("Last turn: \(delta >= 0 ? "+" : "")\(delta.formatted())")
        }
        if let modelName = state.model {
            Text("Model: \(modelName)" + (state.modelWindowIsAssumed ? "  (window assumed)" : ""))
        }
        if let session = state.sessionId {
            Text("Session: \(session.prefix(8))")
        }
        if let last = state.lastActivity {
            Text("Last turn at \(last.formatted(date: .omitted, time: .standard))")
        }
    }
}
#endif

#if os(macOS)
import AppKit
import SwiftUI
import UllageCore

extension PopoverContent {
    // MARK: Plan limits

    @ViewBuilder
    var planLimitsSection: some View {
        let hasClaude = model.planLimits.contains { $0.vendor == Vendor.claudeCode }
        if !model.planLimits.isEmpty || !model.checksClaudeLimits || model.claudeLimitsError != nil {
            if model.planLimits.isEmpty {
                SectionRule("Plan limits")
            } else {
                SectionLink("Plan limits", open: { open(.limits) }, summary: {
                    ReadoutLine(PlanLimitFormatter.summary(model.planLimits))
                })
            }
            if let error = model.claudeLimitsError {
                Text("Claude: " + error)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if !model.checksClaudeLimits, !hasClaude {
                Button("Show Claude's plan limits") { model.checksClaudeLimits = true }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help(Self.claudeLimitsExplanation)
            }
        }
    }

    static let claudeLimitsExplanation = """
    Asks Anthropic every 5 minutes, the way Claude Code's /usage does, using \
    Claude Code's own sign-in from the Keychain. Sends that token to \
    api.anthropic.com and nothing else. Turn off from the ⋯ menu.
    """

    // MARK: Actions

    /// One button for the thing you might actually want next; the app's own
    /// housekeeping goes behind a menu instead of standing at the same weight
    /// as the task.
    var actions: some View {
        HStack(spacing: 8) {
            Button("Open Ullage") { open(.overview) }
                .buttonStyle(.borderedProminent)
                .help("Everything here at full size: composition, session, agents, context tools, history and limits")
            Button("Dashboard…") {
                openWindow(DashboardWindow.id)
            }
            Spacer()
            // One way in to every explanation, opposite the main action.
            HelpButton()
        }
        .controlSize(.small)
    }

    var overflowMenu: some View {
        Menu {
            Button(model.isWatching ? "Refresh now" : "Start watching") {
                if model.isWatching { model.refreshNow() } else { model.start() }
            }
            .disabled(model.isRestarting)
            Button(model.isRestarting ? "Restarting…" : "Restart Service") { model.restart() }
                .disabled(model.isRestarting)
            Button("Show database in Finder") { model.openDatabaseFolder() }
            Divider()
            Toggle("Check Claude plan limits", isOn: $model.checksClaudeLimits)
                .help(Self.claudeLimitsExplanation)
            Divider()
            Button("Quit Ullage") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 11, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.tertiary)
        .help("Refresh, restart service, show the database, quit")
    }
}
#endif

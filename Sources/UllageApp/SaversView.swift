#if os(macOS)
import AppKit
import SwiftUI
import UllageCore

/// The popover's token savers: a switch, a headline and where the headline
/// comes from, per saver. Every decision is made in `SaverPanel`; this only
/// draws it.
struct SaversView: View {
    let panel: SaverPanel
    let message: String?
    let expanded: Bool
    let onSwitch: (TokenSaver, Bool) -> Void
    /// Install or uninstall, after the user has confirmed the exact commands.
    let onPlan: (TokenSaver, SaverAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if expanded {
                if let warning = panel.warning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(panel.rows) { row in
                    rowView(row)
                }
                if !panel.installable.isEmpty { installMenu }
            } else {
                summary
            }
            if let message {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func rowView(_ row: SaverPanel.Row) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Toggle(isOn: Binding(
                    get: { row.switchState == .on },
                    set: { onSwitch(row.saver, $0) }
                )) { EmptyView() }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .disabled(!row.canSwitch)
                    .help(row.canSwitch
                          ? "Switch \(row.saver.displayName) \(row.switchState == .on ? "off" : "on") in Claude Code's user config. \(SaverPanel.nextSessionNote.capitalizedFirst)."
                          : "Not installed in Claude Code's user config, so there is nothing to switch")
                    .accessibilityLabel("\(row.saver.displayName) enabled")
                Text(row.saver.displayName)
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 8)
                Text(row.metric)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(row.metricTone == .warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                if !row.metricCaption.isEmpty {
                    Text(row.metricCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if row.isInstalled {
                    Menu {
                        if row.switchState == .notInstalled {
                            Button("Set up \(row.saver.displayName)…") { onPlan(row.saver, .install) }
                        }
                        Button("Uninstall \(row.saver.displayName)…") { onPlan(row.saver, .uninstall) }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .foregroundStyle(.tertiary)
                    .help("Set up or uninstall \(row.saver.displayName) with its own commands")
                }
            }
            Group {
                Text(row.line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let note = row.note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.leading, 40)
            .fixedSize(horizontal: false, vertical: true)
        }
        .help(row.saver.savingSource)
    }

    private var installMenu: some View {
        HStack(spacing: 6) {
            Text(panel.rows.isEmpty ? "None installed." : "Not installed: "
                 + panel.installable.map(\.displayName).joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
            Menu("Install…") {
                ForEach(panel.installable, id: \.self) { saver in
                    Button("\(saver.displayName) — shrinks \(saver.shrinks)") { onPlan(saver, .install) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.caption)
            .help("Shows the tool's own install commands first; nothing runs until you confirm")
        }
    }

    private var summary: some View {
        let parts = panel.rows.isEmpty ? ["None installed"] : panel.rows.map { row in
            row.switchState == .off
                ? "\(row.saver.displayName) off"
                : "\(row.saver.displayName) \(row.metric)" + (row.metricCaption.isEmpty ? "" : " \(row.metricCaption)")
        }
        return Text(parts.joined(separator: "  ·  "))
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(panel.warning == nil ? .secondary : Color.orange)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

/// The exact commands, shown before anything runs. Returns true to go ahead.
enum InstallConfirmation {
    @MainActor
    static func confirm(_ plan: InstallPlan) -> Bool {
        let alert = NSAlert()
        let verb = plan.action == .install ? "Install" : "Uninstall"
        alert.messageText = "\(verb) \(plan.saver.displayName)?"
        var lines: [String] = []
        if !plan.missing.isEmpty {
            lines.append("Needs \(plan.missing.joined(separator: " and ")), which isn't on this Mac.")
        }
        for (index, step) in plan.steps.enumerated() {
            lines.append("\(index + 1). \(step.purpose)\n    \(step.command)")
        }
        if !plan.steps.isEmpty {
            lines.append("These are \(plan.saver.displayName)'s own commands. They run in Terminal, where you can watch them"
                         + (plan.needsPerson ? " and finish the sign-in." : "."))
        }
        lines += plan.notes
        alert.informativeText = lines.joined(separator: "\n\n")
        if plan.isRunnable {
            alert.addButton(withTitle: "Run in Terminal")
            alert.addButton(withTitle: "Cancel")
        } else {
            alert.addButton(withTitle: "OK")
        }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn && plan.isRunnable
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
#endif

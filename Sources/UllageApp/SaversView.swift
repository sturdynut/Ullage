#if os(macOS)
import AppKit
import SwiftUI
import UllageCore

/// The popover's token savers: a switch, a headline and where the headline
/// comes from, per saver. Every decision is made in `SaverPanel`; this only
/// draws it.
struct SaversView: View {
    let panel: SaverPanel
    let expanded: Bool
    let onSwitch: (TokenSaver, Bool) -> Void
    let onUndo: (TokenSaver) -> Void
    /// Install or uninstall, after the user has confirmed the exact commands.
    let onPlan: (TokenSaver, SaverAction) -> Void

    /// Wide enough for a mini switch, so rows align whichever control they show.
    private static let controlWidth: CGFloat = 32

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
                ForEach(panel.pendingInstalls, id: \.self) { note in
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !panel.installable.isEmpty { installMenu }
                ForEach(panel.legend, id: \.self) { line in
                    Text(line)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ReadoutLine(panel.summary)
            }
        }
    }

    private func rowView(_ row: SaverPanel.Row) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                control(for: row)
                    .frame(width: Self.controlWidth, alignment: .leading)
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
                if let pending = row.pending {
                    HStack(spacing: 6) {
                        Text(pending)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                        if row.canUndo {
                            Button("Undo") { onUndo(row.saver) }
                                .buttonStyle(.link)
                                .font(.caption)
                                .help("Put \(row.saver.displayName) back the way it was")
                        }
                    }
                }
                Text(row.line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let note = row.note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.leading, Self.controlWidth + 8)
            .fixedSize(horizontal: false, vertical: true)
        }
        .help(row.saver.savingSource)
    }

    /// A switch when there is something to switch; otherwise the action that
    /// would make one appear — never a dead, greyed-out switch.
    @ViewBuilder
    private func control(for row: SaverPanel.Row) -> some View {
        if row.canSwitch {
            Toggle(isOn: Binding(
                get: { row.switchState == .on },
                set: { onSwitch(row.saver, $0) }
            )) { EmptyView() }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help("Switch \(row.saver.displayName) \(row.switchState == .on ? "off" : "on") in Claude Code's user config. \(SaverPanel.nextSessionNote.capitalizedFirst).")
                .accessibilityLabel("\(row.saver.displayName) enabled")
        } else {
            Button(row.isInstalled ? "Set up" : "Install") { onPlan(row.saver, .install) }
                .buttonStyle(.link)
                .font(.caption)
                .fixedSize()
                .help(row.isInstalled
                      ? "\(row.saver.displayName) is on this Mac but not connected to Claude Code"
                      : "\(row.saver.displayName) ran in this session but isn't installed now")
        }
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
}

/// The exact commands, shown before anything runs. Returns true to go ahead.
enum InstallConfirmation {
    @MainActor
    static func confirm(_ plan: InstallPlan) -> Bool {
        let alert = NSAlert()
        let uninstalling = plan.action == .uninstall
        alert.messageText = "\(uninstalling ? "Uninstall" : "Install") \(plan.saver.displayName)?"
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
        guard plan.isRunnable else {
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return false
        }
        let run = alert.addButton(withTitle: uninstalling ? "Uninstall in Terminal" : "Install in Terminal")
        let cancel = alert.addButton(withTitle: "Cancel")
        if uninstalling {
            // Return must never remove anything: Cancel takes the default.
            alert.alertStyle = .warning
            run.hasDestructiveAction = true
            run.keyEquivalent = ""
            cancel.keyEquivalent = "\r"
        }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
#endif

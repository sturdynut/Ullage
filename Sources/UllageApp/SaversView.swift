#if os(macOS)
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

    private var summary: some View {
        let parts = panel.rows.map { row in
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

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
#endif

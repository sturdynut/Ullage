#if os(macOS)
import SwiftUI
import UllageCore

/// A collapsed section's single line. Every section draws its collapsed state
/// with this, so they all read alike: `label value`, one separator, digits
/// monospaced, orange on the item that needs attention and nowhere else.
///
/// Built as one `Text` so it truncates as a line at the popover's edge rather
/// than pushing items out of view; `Readout` order puts what matters first.
struct ReadoutLine: View {
    struct Item {
        var readout: Readout
        /// A colour swatch that ties the item to a chart (composition only).
        var dot: Color?
    }

    let items: [Item]

    init(_ readouts: [Readout]) {
        self.items = readouts.map { Item(readout: $0) }
    }

    init(items: [Item]) {
        self.items = items
    }

    var body: some View {
        items.enumerated().reduce(Text(verbatim: "")) { line, pair in
            let (index, item) = pair
            let readout = item.readout
            var text = line
            if index > 0 { text = Text("\(text)\(Text(verbatim: Readout.separator).foregroundStyle(.tertiary))") }
            if let dot = item.dot { text = Text("\(text)\(Text(verbatim: "● ").foregroundStyle(dot))") }
            let labelStyle: AnyShapeStyle = readout.isWarning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary)
            text = Text("\(text)\(Text(verbatim: readout.label).foregroundStyle(labelStyle))")
            if let value = readout.value {
                let valueStyle: AnyShapeStyle = readout.isWarning ? AnyShapeStyle(Color.orange)
                    : readout.isMuted ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary)
                text = Text("\(text)\(Text(verbatim: " " + value).foregroundStyle(valueStyle))")
            }
            return text
        }
        .font(.caption)
        .monospacedDigit()
        .lineLimit(1)
        .truncationMode(.tail)
        .accessibilityLabel(Readout.line(items.map(\.readout)))
    }
}
#endif

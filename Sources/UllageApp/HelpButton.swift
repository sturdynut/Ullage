#if os(macOS)
import SwiftUI
import UllageCore

/// "Explain": a short link that opens the plain-language explanation of what
/// it sits next to. A word in the accent colour, with a pointing-hand cursor,
/// reads as clickable where a small grey glyph did not.
/// The text is `HelpText`, the same the phone page shows.
struct HelpButton: View {
    let topics: [HelpTopic]
    @State private var showing = false

    init(_ topics: HelpTopic...) { self.topics = topics }

    var body: some View {
        Button { showing.toggle() } label: {
            Text("Explain")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        .help("What this shows, and what to do about it")
        .accessibilityLabel("Help: " + topics.map(\.title).joined(separator: ", "))
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(topics, id: \.title) { topic in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(topic.title).font(.headline)
                            Text(topic.intro).foregroundStyle(.secondary)
                            // Each question collapsed until asked: the answer
                            // to one thing at a time, not everything at once.
                            ForEach(topic.entries, id: \.question) { entry in
                                HelpQuestion(entry: entry)
                            }
                        }
                    }
                }
                .font(.callout)
                .padding(14)
            }
            .frame(width: 340)
            .frame(maxHeight: 520)
        }
    }
}

private struct HelpQuestion: View {
    let entry: HelpEntry
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.answer)
                if let why = entry.why {
                    (Text("Why it matters: ").fontWeight(.medium) + Text(why))
                        .foregroundStyle(.secondary)
                }
                if let tip = entry.tip {
                    (Text("What you can do: ").fontWeight(.medium) + Text(tip))
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
            .padding(.leading, entry.glyph == nil ? 0 : 34)
        } label: {
            HStack(spacing: 8) {
                if let glyph = entry.glyph {
                    HelpGlyph(glyph: glyph).frame(width: 26, height: 16)
                }
                Text(entry.question).fontWeight(.medium)
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { open.toggle() } }
        }
    }
}

/// A chart mark drawn the way `ContextChart` draws it, so the help shows the
/// thing you are looking at rather than a stand-in character.
struct HelpGlyph: View {
    let glyph: HelpEntry.Glyph

    var body: some View {
        Canvas { context, size in
            let mid = size.height / 2
            switch glyph {
            case .line:
                var fill = Path()
                fill.move(to: CGPoint(x: 0, y: size.height * 0.75))
                fill.addLine(to: CGPoint(x: size.width, y: size.height * 0.3))
                fill.addLine(to: CGPoint(x: size.width, y: size.height))
                fill.addLine(to: CGPoint(x: 0, y: size.height))
                context.fill(fill, with: .color(Color.accentColor.opacity(0.18)))
                var line = Path()
                line.move(to: CGPoint(x: 0, y: size.height * 0.75))
                line.addLine(to: CGPoint(x: size.width, y: size.height * 0.3))
                context.stroke(line, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            case .warningRule:
                var rule = Path()
                rule.move(to: CGPoint(x: 0, y: mid))
                rule.addLine(to: CGPoint(x: size.width, y: mid))
                context.stroke(rule, with: .color(Color.orange.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: [2, 4]))
            case .compaction:
                var rule = Path()
                rule.move(to: CGPoint(x: size.width / 2, y: 0))
                rule.addLine(to: CGPoint(x: size.width / 2, y: size.height))
                context.stroke(rule, with: .color(.secondary), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            case .rebuildCaused, .rebuildOther:
                let side: CGFloat = 10
                let origin = CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2)
                var triangle = Path()
                triangle.move(to: CGPoint(x: origin.x + side / 2, y: origin.y))
                triangle.addLine(to: CGPoint(x: origin.x + side, y: origin.y + side))
                triangle.addLine(to: CGPoint(x: origin.x, y: origin.y + side))
                triangle.closeSubpath()
                context.fill(triangle, with: .color(glyph == .rebuildCaused ? .orange : .secondary))
            }
        }
        .accessibilityHidden(true)
    }
}
#endif

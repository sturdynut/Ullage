#if os(macOS)
import SwiftUI
import UllageCore

/// An ⓘ that opens the plain-language explanation of what it sits next to.
/// The text is `HelpText`, the same the phone page shows.
struct HelpButton: View {
    let topics: [HelpTopic]
    @State private var showing = false

    init(_ topics: HelpTopic...) { self.topics = topics }

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tertiary)
        .help("What is this?")
        .accessibilityLabel("Help: " + topics.map(\.title).joined(separator: ", "))
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(topics, id: \.title) { topic in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(topic.title).font(.headline)
                            ForEach(Array(topic.lines.enumerated()), id: \.offset) { _, line in
                                if line.hasPrefix("• ") {
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text("•").foregroundStyle(.secondary)
                                        Text(String(line.dropFirst(2)))
                                    }
                                } else {
                                    Text(line).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
            }
            .frame(width: 320)
            .frame(maxHeight: 460)
        }
    }
}
#endif

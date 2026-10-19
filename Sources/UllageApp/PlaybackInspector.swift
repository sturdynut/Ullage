#if os(macOS)
import AppKit
import SwiftUI
import UllageCore

struct PlaybackInspector: View {
    let event: PlaybackEvent
    let snapshot: PlaybackRequestSnapshot?
    let isLoadingSnapshot: Bool
    @State private var isActivityExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(event.title).font(.headline).textSelection(.enabled)
                Spacer()
                Text(evidenceLabel)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text([event.agentId.map { "Agent \($0)" } ?? "Main thread", event.timestamp]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let usage = event.usage { usageReadout(usage) }
            if !event.text.isEmpty {
                DisclosureGroup(activityTitle, isExpanded: $isActivityExpanded) {
                    VStack(alignment: .leading, spacing: 6) {
                        PlaybackLiteralText(text: event.text)
                        if let path = event.sourcePath { sourceButton(path) }
                    }.padding(.top, 6)
                }
            }
            if event.snapshot != nil {
                DisclosureGroup("Recorded request contents") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(snapshot?.body == nil
                             ? "Request reference only. Contents must be available and readable in the selected folder."
                             : "Recorded request at this boundary. Thinking is redacted by the recorder; "
                             + "tool steps do not each have a context snapshot.")
                            .font(.caption).foregroundStyle(.secondary)
                        if isLoadingSnapshot {
                            ProgressView("Reading request…").controlSize(.small)
                        } else if let snapshot = snapshot ?? event.snapshot {
                            if let body = snapshot.body { PlaybackLiteralText(text: body) }
                            if let notice = snapshot.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                            sourceButton(snapshot.sourcePath)
                        }
                    }.padding(.top, 6)
                }
            } else {
                Text("Request contents unavailable at this step. A transcript records activity, "
                     + "not the complete context sent to the model.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var activityTitle: String {
        event.kind == .toolCall ? "Recorded tool input"
            : event.kind == .toolResult ? "Recorded tool result" : "Recorded activity"
    }

    private var evidenceLabel: String {
        guard event.snapshot != nil else { return event.source.rawValue + " · " + event.completeness.rawValue }
        if isLoadingSnapshot, snapshot == nil { return "Captured request · Loading contents" }
        guard let snapshot, snapshot.body != nil else { return "Captured request · Contents unavailable" }
        return snapshot.completeness == .redacted
            ? "Captured request · Thinking redacted" : "Captured request · Partial"
    }

    private func sourceButton(_ path: String) -> some View {
        Button("Show source in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }

    private func usageReadout(_ usage: PlaybackUsage) -> some View {
        let figures: [(String, Int?)] = [
            ("Context", usage.contextTokens), ("Window", usage.windowLimit),
            ("Input", usage.input), ("Cache read", usage.cacheRead),
            ("Cache write", usage.cacheWrite), ("Output", usage.output)
        ]
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) { usageFigures(figures) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], alignment: .leading, spacing: 10) {
                usageFigures(figures)
            }
        }
    }

    private func usageFigures(_ figures: [(String, Int?)]) -> some View {
        ForEach(figures, id: \.0) { label, value in
            if let value {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                    Text(value.formatted()).monospacedDigit()
                }
            }
        }
    }
}

struct PlaybackLiteralText: View {
    let text: String
    private static let previewLimit = 48_000

    var body: some View {
        let preview = String(text.prefix(Self.previewLimit))
        VStack(alignment: .leading, spacing: 4) {
            PlaybackTextView(text: preview)
                .frame(height: 170)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.1)))
            if text.utf8.count > preview.utf8.count {
                Text("Preview limited to \(Self.previewLimit.formatted()) characters. "
                     + "Inspect the original source for the remaining contents.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct PlaybackTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("Recorded contents")
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }
}
#endif

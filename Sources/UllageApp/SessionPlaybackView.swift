#if os(macOS)
import AppKit
import SwiftUI
import UllageCore

struct SessionPlaybackView: View {
    @ObservedObject var menu: MenuBarModel
    @StateObject private var model = PlaybackModel()
    @State private var recordingDirectory: URL?
    @State private var isVisible = false
    @State private var worker = PlaybackWorker()

    private var sessionId: String? {
        if case .pinned(let id) = menu.selection { return id }
        return menu.state.sessionId
    }
    private var readKey: String {
        "\(isVisible)|\(sessionId ?? "")|\(recordingDirectory?.path ?? "")"
    }

    var body: some View {
        PageCard {
            VStack(alignment: .leading, spacing: 14) {
                header
                if model.selection.sessionId != sessionId || model.isLoading {
                    ProgressView("Reading recorded activity…").controlSize(.small)
                } else if let error = model.errorMessage {
                    Text(error).foregroundStyle(.secondary)
                } else {
                    if model.playback.events.contains(where: { $0.agentId != nil }) {
                        Picker("Stream", selection: Binding(get: { model.stream }, set: { stream in
                            if let sessionId { menu.selection = .pinned(sessionId) }
                            model.selectStream(stream)
                        })) {
                            Text("All streams").tag("all")
                            Text("Main thread").tag("main")
                            ForEach(agentIds, id: \.self) { agent in
                                Text("Agent \(agent.prefix(12))").tag(agent)
                            }
                        }.pickerStyle(.menu).fixedSize()
                    }
                    PlaybackWorkspace(model: model) { event in
                        if let sessionId { menu.selection = .pinned(sessionId) }
                        model.inspect(event.id)
                    }
                    notices
                }
                recordingControls
            }
        }
        .background(PlaybackWindowVisibility { isVisible = $0 })
        .onDisappear { isVisible = false }
        .task(id: readKey) {
            guard isVisible else { return }
            model.activate(sessionId: sessionId, reload: true)
            guard let sessionId else { return }
            while !Task.isCancelled {
                await model.refresh {
                    try await worker.read(databasePath: menu.databasePath, sessionId: sessionId,
                                          recordingDirectory: recordingDirectory)
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .task(id: "\(readKey)|\(model.selection.eventId ?? "")|\(model.revision)") {
            guard isVisible, let event = model.selectedEvent,
                  event.snapshot != nil, let recordingDirectory else {
                model.clearSnapshot()
                return
            }
            await model.loadSnapshot { await worker.snapshot(for: event, directory: recordingDirectory) }
        }
    }

    private var agentIds: [String] { Array(Set(model.playback.events.compactMap(\.agentId))).sorted() }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Playback").font(.headline)
                Text("Select a step to inspect what was recorded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.selection.followsLive {
                Label("Following live", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Follow live", systemImage: "forward.end") { model.follow() }
                    .help("Return to the newest recorded step in this session")
            }
        }
    }

    private var notices: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.playback.notices, id: \.self) { notice in
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
            if model.playback.pendingLineCount > 0 {
                Text("Waiting for an incomplete transcript line to finish writing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var recordingControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            if menu.state.vendor == Vendor.claudeCode || recordingDirectory != nil {
                HStack {
                    Button(recordingDirectory == nil ? "Choose Claude recording folder…" : "Change recording folder…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        panel.prompt = "Read recordings"
                        panel.message = "Choose an existing Claude request-recording folder containing index.jsonl. "
                            + "Ullage only reads it."
                        panel.begin { response in
                            if response == .OK { recordingDirectory = panel.url }
                        }
                    }
                    if let recordingDirectory {
                        Text(recordingDirectory.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).help(recordingDirectory.path)
                        Button("Disconnect") { self.recordingDirectory = nil }
                    }
                }
            }
            Text("Reads local originals without archiving a copy. Deleted recordings become unavailable.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Kept separate from loading so the native layout can be reviewed with synthetic events.
struct PlaybackWorkspace: View {
    @ObservedObject var model: PlaybackModel
    let onInspect: (PlaybackEvent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.playback.events.isEmpty {
                Text("No replayable activity is available for this session. Usage charts may still be available below.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                track
                Divider()
                if let event = model.selectedEvent {
                    PlaybackInspector(event: event, snapshot: model.snapshot,
                                      isLoadingSnapshot: model.isLoadingSnapshot)
                        .id(event.id)
                } else {
                    Text("This step is no longer in the source. Choose another step or Follow live.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var track: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 6) {
                    ForEach(Array(model.visibleEvents.enumerated()), id: \.element.id) { index, event in
                        Button { onInspect(event) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text("\(index + 1)").monospacedDigit()
                                    Spacer()
                                    Image(systemName: event.snapshot == nil ? "circle" : "square.stack")
                                }
                                .font(.caption2).foregroundStyle(.secondary)
                                Text(event.title).font(.caption.weight(.medium)).lineLimit(1)
                                Text(event.agentId.map { "Agent \($0.prefix(8))" } ?? "Main thread")
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(8).frame(width: 108, alignment: .leading)
                            .background(model.selection.eventId == event.id
                                        ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .stroke(model.selection.eventId == event.id ? Color.accentColor : Color.clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Step \(index + 1), \(event.title), "
                                            + (event.agentId == nil ? "main thread" : "agent"))
                        .accessibilityAddTraits(model.selection.eventId == event.id ? .isSelected : [])
                        .id(event.id)
                    }
                }.padding(2)
            }
            .frame(height: 88)
            .onChange(of: model.selection.eventId, initial: true) { _, eventId in
                if model.selection.followsLive, let eventId { proxy.scrollTo(eventId, anchor: .trailing) }
            }
        }
    }
}
#endif

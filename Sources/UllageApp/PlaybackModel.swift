#if os(macOS)
import Foundation
import SwiftUI
import UllageCore

struct PlaybackSelection {
    private(set) var sessionId: String?
    private(set) var eventId: String?
    private(set) var followsLive = true

    mutating func update(sessionId: String?, eventIds: [String]) {
        if self.sessionId != sessionId {
            self.sessionId = sessionId
            followsLive = true
            eventId = nil
        }
        if followsLive { eventId = eventIds.last }
    }

    mutating func inspect(_ eventId: String) {
        followsLive = false
        self.eventId = eventId
    }

    mutating func follow(eventIds: [String]) {
        followsLive = true
        eventId = eventIds.last
    }
}

/// A single worker owns the incremental reader; no transcript or database IO runs on the UI actor.
actor PlaybackWorker {
    private let reader = SessionPlaybackReader()

    func read(databasePath: String, sessionId: String, recordingDirectory: URL?) throws -> SessionPlayback {
        let sources = try Store(path: databasePath).playbackSources(sessionId: sessionId)
        return reader.read(sessionId: sessionId, sources: sources, recordingDirectory: recordingDirectory)
    }

    func snapshot(for event: PlaybackEvent, directory: URL) -> PlaybackRequestSnapshot? {
        reader.requestSnapshot(for: event, recordingDirectory: directory)
    }
}

@MainActor
final class PlaybackModel: ObservableObject {
    @Published private(set) var selection = PlaybackSelection()
    @Published private(set) var playback = SessionPlayback()
    @Published private(set) var snapshot: PlaybackRequestSnapshot?
    @Published private(set) var revision = 0
    @Published private(set) var isLoading = true
    @Published private(set) var isLoadingSnapshot = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var stream = "all"
    private var generation = UUID()
    private var snapshotGeneration = UUID()

    var selectedEvent: PlaybackEvent? {
        playback.events.first { $0.id == selection.eventId }
    }

    var visibleEvents: [PlaybackEvent] {
        playback.events.filter { stream == "all" || ($0.agentId ?? "main") == stream }
    }

    func selectStream(_ stream: String) {
        self.stream = stream
        selection.follow(eventIds: visibleEvents.map(\.id))
        clearSnapshot()
    }

    func activate(sessionId: String?, reload: Bool = false) {
        guard reload || selection.sessionId != sessionId else { return }
        if selection.sessionId != sessionId { stream = "all" }
        generation = UUID()
        snapshotGeneration = UUID()
        selection.update(sessionId: sessionId, eventIds: [])
        playback = SessionPlayback()
        snapshot = nil
        errorMessage = nil
        isLoading = sessionId != nil
        isLoadingSnapshot = false
    }

    func refresh(load: () async throws -> SessionPlayback) async {
        let request = generation
        do {
            let result = try await load()
            guard request == generation, !Task.isCancelled else { return }
            let oldEventId = selection.eventId
            let oldReference = selectedEvent?.snapshot?.sourcePath
            let visibleIds = result.events.filter { stream == "all" || ($0.agentId ?? "main") == stream }.map(\.id)
            selection.update(sessionId: selection.sessionId, eventIds: visibleIds)
            let newReference = result.events.first { $0.id == selection.eventId }?.snapshot?.sourcePath
            if oldEventId != selection.eventId || oldReference != newReference { clearSnapshot() }
            playback = result
            revision += 1
            errorMessage = nil
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            playback = SessionPlayback()
            clearSnapshot()
            errorMessage = "Couldn't read playback: \(error.localizedDescription)"
        }
        isLoading = false
    }

    func inspect(_ eventId: String) {
        selection.inspect(eventId)
        clearSnapshot()
    }

    func follow() {
        selection.follow(eventIds: visibleEvents.map(\.id))
        clearSnapshot()
    }

    func clearSnapshot() {
        snapshotGeneration = UUID()
        snapshot = nil
        isLoadingSnapshot = false
    }

    func loadSnapshot(load: () async -> PlaybackRequestSnapshot?) async {
        snapshotGeneration = UUID()
        let request = snapshotGeneration
        let eventId = selection.eventId
        isLoadingSnapshot = snapshot == nil
        let result = await load()
        guard request == snapshotGeneration, eventId == selection.eventId, !Task.isCancelled else { return }
        snapshot = result
        isLoadingSnapshot = false
    }
}
#endif

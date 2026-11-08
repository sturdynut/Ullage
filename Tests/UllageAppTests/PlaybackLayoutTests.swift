import AppKit
import SwiftUI
import XCTest
import UllageCore
@testable import UllageApp

@MainActor
final class PlaybackLayoutTests: XCTestCase {
    func testNativeWorkspaceRendersSyntheticHistoricalAndLiveSelection() async throws {
        _ = NSApplication.shared
        let model = PlaybackModel()
        model.activate(sessionId: "synthetic-session")
        await model.refresh { SessionPlayback(events: events) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ullage-playback-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for mode in ["historical", "live"] {
            if mode == "historical" { model.inspect("read") } else { model.follow() }
            let view = VStack(alignment: .leading, spacing: 14) {
                Text("Session").font(.title2.bold())
                PageCard {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("Playback").font(.headline)
                            Spacer()
                            if model.selection.followsLive {
                                Label("Following live", systemImage: "dot.radiowaves.left.and.right")
                            } else {
                                Button("Follow live") { model.follow() }
                            }
                        }
                        Text("Select a step to inspect what was recorded.").foregroundStyle(.secondary)
                        PlaybackWorkspace(model: model) { model.inspect($0.id) }
                    }
                }
                Spacer()
            }.padding(24).frame(width: 880, height: 580).background(Color(nsColor: .windowBackgroundColor))
            let hosting = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 580),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.orderFront(nil)
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 5_000, "The native workspace must render its contents")
            let output = directory.appendingPathComponent("\(mode).png")
            try png.write(to: output)
            print("PLAYBACK_PREVIEW: \(output.path)")
            window.close()
        }
    }

    private var events: [PlaybackEvent] {
        [
            PlaybackEvent(id: "prompt", timestamp: "2026-10-15T10:00:00Z", kind: .message,
                          title: "User", text: "Find why the request retries after a successful response."),
            PlaybackEvent(id: "read", timestamp: "2026-10-15T10:00:01Z", kind: .toolCall,
                          title: "Read",
                          text: "{\n  \"file_path\": \"Sources/RetryPolicy.swift\",\n  \"limit\": 120\n}"),
            PlaybackEvent(id: "result", timestamp: "2026-10-15T10:00:02Z", kind: .toolResult,
                          title: "Tool result", text: "func shouldRetry(status: Int) -> Bool {\n    status >= 500\n}"),
            PlaybackEvent(id: "agent", timestamp: "2026-10-15T10:00:03Z", agentId: "reviewer",
                          kind: .message, title: "Assistant",
                          text: "The retry condition excludes successful responses."),
            PlaybackEvent(id: "usage", timestamp: "2026-10-15T10:00:04Z", kind: .usage,
                          title: "Request usage",
                          text: "{\n  \"input_tokens\": 1420,\n  \"cache_read_input_tokens\": 32000\n}",
                          usage: PlaybackUsage(input: 1_420, output: 224, cacheRead: 32_000,
                                               cacheWrite: 0, contextTokens: 33_420, windowLimit: 200_000))
        ]
    }
}

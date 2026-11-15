import AppKit
import SwiftUI
import XCTest
import UllageCore
@testable import UllageApp

@MainActor
final class DashboardLayoutTests: XCTestCase {
    func testDashboardControlsStayInsideResizedWindow() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("telemetry.db").path
        let store = try Store(path: path)
        for turn in 0..<4 {
            let timestamp = Timestamps.string(from: Date().addingTimeInterval(Double(turn - 4) * 600))
            try store.upsert(call: CallRow(dedupeKey: "layout-\(turn)",
                                          ts: timestamp,
                                          sessionId: "layout", project: "Layout fixture", input: 100,
                                          output: 200, contextTokens: 32_000, windowLimit: 200_000,
                                          sourceFile: "fixture"))
        }
        let hosting = NSHostingController(rootView: DashboardWindow(model: DashboardModel(databasePath: path)))
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.orderFront(nil)
        for width: CGFloat in [860, 1_000, 1_440, 860] {
            window.setContentSize(NSSize(width: width, height: 760))
            try await Task.sleep(for: .milliseconds(100))
            hosting.view.layoutSubtreeIfNeeded()
            // What the dashboard needs at this width, asked of SwiftUI itself:
            // wider than the window means a control is pushed off an edge.
            let needed = hosting.sizeThatFits(in: NSSize(width: width, height: 760))
            XCTAssertLessThanOrEqual(needed.width, width + 1, "the dashboard needs \(needed.width)pt at \(width)")
            // Whichever pickers are native AppKit controls must sit inside too.
            // How many are depends on the macOS version: through macOS 15 each
            // menu picker is an NSPopUpButton; on later versions SwiftUI draws
            // them itself and none is found here.
            let pickers = descendants(of: hosting.view).compactMap { $0 as? NSControl }
                .filter { $0 is NSSegmentedControl || $0 is NSPopUpButton }
            if ProcessInfo.processInfo.operatingSystemVersion.majorVersion <= 15 {
                XCTAssertGreaterThanOrEqual(pickers.count, 4)
            }
            for control in pickers {
                let frame = control.convert(control.bounds, to: hosting.view)
                XCTAssertGreaterThanOrEqual(frame.minX, 0, "\(control) overflows left at \(width)")
                XCTAssertLessThanOrEqual(frame.maxX, width + 1, "\(control) overflows right at \(width)")
            }
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}

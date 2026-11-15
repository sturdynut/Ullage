import AppKit
import XCTest
@testable import UllageApp

@MainActor
extension XCTestCase {
    /// Polls the condition on the main actor, giving AppKit run-loop turns in
    /// between, until it holds or the timeout passes. AppKit's timing varies
    /// by macOS version and load, so tests wait for a state, never a fixed time.
    func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Whether the menu bar placed the controller's status button. The popover
    /// opens from that button, and a menu bar with no room left (other status
    /// items, the camera notch) never places it: its window stays zero height
    /// and a click has nothing to open from.
    func waitForStatusButton(_ controller: MenuBarController) async throws -> Bool {
        func placed() -> Bool { (controller.statusItem.button?.window?.frame.height ?? 0) > 0 }
        try await waitUntil(placed)
        return placed()
    }
}

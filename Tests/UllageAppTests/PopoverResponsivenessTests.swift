import AppKit
import XCTest
import UllageCore
@testable import UllageApp

@MainActor
final class PopoverResponsivenessTests: XCTestCase {
    func testPopoverOpensWhenContextToolLedgerIsLocked() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ledgerURL = directory.appendingPathComponent("rtk.db")
        let ledger = try SQLiteDatabase(path: ledgerURL.path)
        try ledger.execute("CREATE TABLE commands (timestamp TEXT, saved_tokens INTEGER);")
        try ledger.execute("BEGIN EXCLUSIVE;")
        defer { try? ledger.execute("ROLLBACK;") }
        let databaseURL = directory.appendingPathComponent("telemetry.db")
        let model = MenuBarModel(databaseURL: databaseURL, transcriptRoots: [], checksClaudeLimits: false,
                                 environment: [
            "CLAUDE_CONFIG_DIR": directory.path, "RTK_DB_PATH": ledgerURL.path,
            "TOKENADE_HOME": directory.path, "HEADROOM_WORKSPACE_DIR": directory.path
        ])
        addTeardownBlock {
            await model.stop()
            try FileManager.default.removeItem(at: directory)
        }
        model.readStore = try Store(path: databaseURL.path)
        let controller = MenuBarController(model: model)
        defer { controller.stop() }
        try await Task.sleep(for: .milliseconds(100))

        let start = Date()
        controller.statusItem.button?.performClick(nil)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "A locked tool ledger must not delay opening the popover")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(controller.popover.isShown)
        controller.statusItem.button?.performClick(nil)
        XCTAssertFalse(controller.popover.isShown, "The popover must remain interactive while the ledger is busy")
        try ledger.execute("ROLLBACK;")
    }
}

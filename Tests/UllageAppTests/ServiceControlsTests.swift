import AppKit
import XCTest
import UllageCore
@testable import UllageApp

@MainActor
final class ServiceControlsTests: XCTestCase {
    func testNativeAppMenuPreservesEditingWithoutAnEmptySettingsCommand() {
        let menu = UllageApp.mainMenu()
        let items = menu.items.flatMap { $0.submenu?.items ?? [] }
        XCTAssertFalse(items.contains { $0.title.contains("Settings") })
        XCTAssertTrue(items.contains { $0.action == #selector(NSText.copy(_:)) && $0.keyEquivalent == "c" })
        XCTAssertTrue(items.contains { $0.action == #selector(NSText.paste(_:)) && $0.keyEquivalent == "v" })
        XCTAssertTrue(items.contains { $0.action == #selector(NSWindow.performClose(_:)) && $0.keyEquivalent == "w" })
        XCTAssertTrue(items.contains { $0.action == #selector(NSApplication.terminate(_:)) && $0.keyEquivalent == "q" })
    }

    func testCachedDisplayLoadsBeforeWatcherStartupFinishes() async throws {
        let watcher = ControlledWatcher()
        let entered = expectation(description: "watcher startup pending")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        watcher.startHook = {
            entered.fulfill()
            _ = gate.wait(timeout: .now() + 5)
        }
        let (model, _) = try makeModel { watcher }
        let store = try Store(path: model.databasePath)
        try store.upsert(call: CallRow(dedupeKey: "cached", ts: "2026-10-15T10:00:00Z",
                                      sessionId: "cached", contextTokens: 100,
                                      windowLimit: 200_000, sourceFile: "test"))
        let restarting = model.restart()
        await fulfillment(of: [entered], timeout: 5)
        await model.displayRefreshTask?.value
        XCTAssertTrue(model.isRestarting)
        XCTAssertEqual(model.state.sessionId, "cached")
        gate.signal()
        await restarting?.value
    }

    func testAsyncDisplayRejectsOldSelectionAndHoldsTheOpenSession() async throws {
        let (model, _) = try makeModel()
        await model.restart()?.value
        let store = try Store(path: model.databasePath)
        for (id, timestamp) in [("older", "2026-10-15T10:00:00Z"), ("newer", "2026-10-15T11:00:00Z")] {
            try store.upsert(call: CallRow(dedupeKey: id, ts: timestamp,
                                          sessionId: id, contextTokens: 100, windowLimit: 200_000, sourceFile: "test"))
        }
        model.selection = .pinned("older")
        model.selection = .pinned("newer")
        while let task = model.displayRefreshTask { await task.value }
        XCTAssertEqual(model.state.sessionId, "newer")
        model.selection = .automatic
        model.popoverDidOpen()
        while let task = model.displayRefreshTask { await task.value }
        try store.upsert(call: CallRow(dedupeKey: "latest", ts: "2026-10-15T12:00:00Z",
                                      sessionId: "latest", contextTokens: 200,
                                      windowLimit: 200_000, sourceFile: "test"))
        model.refresh()
        while let task = model.displayRefreshTask { await task.value }
        XCTAssertEqual(model.state.sessionId, "newer", "An open popover holds its session")
        XCTAssertEqual(model.menuBarState.sessionId, "latest", "The icon keeps following live activity")
        model.popoverDidClose()
        model.refresh()
        while let task = model.displayRefreshTask { await task.value }
        XCTAssertEqual(model.state.sessionId, "latest")
    }

    func testRestartCatchesUpWithoutDeletingOrDuplicatingHistory() async throws {
        let (model, directory) = try makeModel()
        await model.restart()?.value
        XCTAssertTrue(model.isWatching)

        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/basic-session.jsonl")
        try FileManager.default.copyItem(at: fixture, to: directory.appendingPathComponent("session.jsonl"))
        await model.restart()?.value
        XCTAssertTrue(model.isWatching)
        XCTAssertFalse(model.isRestarting)
        XCTAssertNil(model.errorMessage)
        let store = try Store(path: model.databasePath)
        XCTAssertEqual(try store.callCount(), 4)

        await model.restart()?.value
        XCTAssertEqual(try store.callCount(), 4)
        await model.stop()
        XCTAssertFalse(model.isWatching)
        XCTAssertNil(model.restart(), "Quit must prevent monitoring from being started again")
    }

    func testFailedRestartStopsPartialWatcherAndCanBeRetried() async throws {
        let failedWatcher = ControlledWatcher()
        failedWatcher.startHook = { throw WatcherError.couldNotStart("test failure") }
        var attempts = 0
        let (model, _) = try makeModel {
            attempts += 1
            return attempts == 2 ? failedWatcher : ControlledWatcher()
        }
        await model.restart()?.value
        XCTAssertTrue(model.isWatching)
        await model.restart()?.value
        XCTAssertFalse(model.isWatching)
        XCTAssertFalse(model.isRestarting)
        XCTAssertTrue(model.errorMessage?.contains("Monitoring stopped") == true)
        XCTAssertTrue(failedWatcher.didStop)
        model.refresh()
        XCTAssertNotNil(model.errorMessage, "A stopped monitor must not look healthy after a UI refresh")

        await model.restart()?.value
        XCTAssertTrue(model.isWatching)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(attempts, 3)
    }

    func testQuitDuringRestartWaitsAndPreventsOverlappingStarts() async throws {
        let watcher = ControlledWatcher()
        let entered = expectation(description: "watcher start entered")
        let gate = DispatchSemaphore(value: 0)
        watcher.startHook = {
            entered.fulfill()
            _ = gate.wait(timeout: .now() + 5)
        }
        var starts = 0
        let (model, _) = try makeModel {
            starts += 1
            return watcher
        }
        let restarting = model.restart()
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertTrue(model.isRestarting)
        model.restart()
        XCTAssertEqual(starts, 1)

        let stopping = Task { await model.stop() }
        await Task.yield()
        gate.signal()
        await stopping.value
        await restarting?.value
        XCTAssertTrue(watcher.didStop)
        XCTAssertFalse(model.isWatching)
        XCTAssertFalse(model.isRestarting)
        XCTAssertNil(model.restart())
        XCTAssertNil(model.tailer)
        XCTAssertNil(model.readStore)
        XCTAssertNil(model.refreshTimer)
        XCTAssertNil(model.claudeLimitsTimer)
    }

    func testRestartDrainsManualSweepAndRejectsOldCallbacks() async throws {
        let (model, directory) = try makeModel()
        await model.restart()?.value
        let oldTailer = try XCTUnwrap(model.tailer)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/basic-session.jsonl")
        try FileManager.default.copyItem(at: fixture, to: directory.appendingPathComponent("session.jsonl"))
        let blocker = try Store(path: model.databasePath)
        try blocker.database.execute("BEGIN IMMEDIATE;")
        defer { try? blocker.database.execute("ROLLBACK;") }
        model.refreshNow()
        XCTAssertNotNil(model.refreshTask)
        let restarting = model.restart()
        await Task.yield()
        XCTAssertTrue(model.isRestarting)
        XCTAssertTrue(model.tailer === oldTailer, "The old writer remains owned until its sweep finishes")
        try blocker.database.execute("ROLLBACK;")
        await restarting?.value
        XCTAssertFalse(model.tailer === oldTailer)
        XCTAssertEqual(try Store(path: model.databasePath).callCount(), 4)

        oldTailer.onError?(WatcherError.couldNotStart("stale error"))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.isWatching)
    }

    func testStatusButtonRoutesOnlyItsRightAndControlClicks() async throws {
        _ = NSApplication.shared
        let (model, _) = try makeModel()
        var quitRequested = false
        let controller = MenuBarController(model: model) { quitRequested = true }
        defer { controller.stop() }
        let button = try XCTUnwrap(controller.statusItem.button)
        let window = try XCTUnwrap(button.window)
        let location = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        func event(
            _ type: NSEvent.EventType, flags: NSEvent.ModifierFlags = [], windowNumber: Int? = nil
        ) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: flags, timestamp: 0,
                windowNumber: windowNumber ?? window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1
            ))
        }
        XCTAssertTrue(controller.contextMenu(for: try event(.rightMouseDown)) === controller.actionMenu)
        XCTAssertTrue(controller.contextMenu(for: try event(.leftMouseDown, flags: .control)) === controller.actionMenu)
        XCTAssertNil(controller.contextMenu(for: try event(.leftMouseDown)))
        XCTAssertNil(controller.contextMenu(for: try event(.rightMouseDown, windowNumber: 0)))
        XCTAssertEqual(controller.actionMenu.items.map(\.title), ["Restart Service", "", "Quit Ullage"])
        controller.actionMenu.performActionForItem(at: 2)
        XCTAssertTrue(quitRequested)

        controller.actionMenu.performActionForItem(at: 0)
        XCTAssertEqual(controller.actionMenu.items[0].title, "Restarting…")
        XCTAssertFalse(controller.actionMenu.items[0].isEnabled)
        await model.restart()?.value
        XCTAssertEqual(controller.actionMenu.items[0].title, "Restart Service")
        XCTAssertTrue(controller.actionMenu.items[0].isEnabled)
    }

    func testLeftClickPopoverAndFullWindowsStillOpen() async throws {
        _ = NSApplication.shared
        let (model, _) = try makeModel()
        let controller = MenuBarController(model: model)
        defer { controller.stop() }
        // Give AppKit a run-loop turn to insert the status button before clicking.
        try await Task.sleep(for: .milliseconds(100))
        controller.statusItem.button?.performClick(nil)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(controller.popover.isShown)
        XCTAssertGreaterThan(controller.popover.contentSize.height, 0)
        XCTAssertEqual(controller.popover.contentSize.width, 360, accuracy: 1)
        controller.statusItem.button?.performClick(nil)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(controller.popover.isShown)

        controller.openWindow(id: MainWindow.id)
        let mainWindow = try XCTUnwrap(NSApp.windows.first { $0.title == "Ullage" && $0.isVisible })
        XCTAssertNotNil(mainWindow.toolbar)
        XCTAssertTrue(mainWindow.styleMask.contains(.resizable))
        controller.openWindow(id: MainWindow.id)
        XCTAssertEqual(NSApp.windows.filter { $0.title == "Ullage" && $0.isVisible }.count, 1)
        controller.openWindow(id: DashboardWindow.id)
        XCTAssertTrue(NSApp.windows.contains { $0.title == "Ullage Dashboard" && $0.isVisible })
    }

    private func makeModel(
        makeWatcher: @escaping () -> DirectoryWatching = { ControlledWatcher() }
    ) throws -> (MenuBarModel, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ullage-app-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = MenuBarModel(
            databaseURL: directory.appendingPathComponent("telemetry.db"),
            transcriptRoots: [directory], checksClaudeLimits: false,
            environment: [
                "CLAUDE_CONFIG_DIR": directory.path,
                "ULLAGE_DB": directory.appendingPathComponent("telemetry.db").path,
                "RTK_DB_PATH": directory.appendingPathComponent("rtk.db").path,
                "TOKENADE_HOME": directory.path,
                "HEADROOM_WORKSPACE_DIR": directory.path
            ],
            makeWatcher: makeWatcher
        )
        addTeardownBlock {
            await model.stop()
            try FileManager.default.removeItem(at: directory)
        }
        return (model, directory)
    }
}

private final class ControlledWatcher: DirectoryWatching {
    var startHook: (() throws -> Void)?
    private let lock = NSLock()
    private var stopped = false
    var didStop: Bool { lock.withLock { stopped } }

    func start(paths: [URL], onChange: @escaping ([String]) -> Void) throws {
        try startHook?()
    }

    func stop() { lock.withLock { stopped = true } }
}

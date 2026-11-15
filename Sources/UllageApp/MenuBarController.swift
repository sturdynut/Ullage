#if os(macOS)
import AppKit
import Combine
import SwiftUI

/// Own the status button so both click paths use public AppKit APIs.
@MainActor
final class MenuBarController: NSObject {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let actionMenu = NSMenu()
    let popover = NSPopover()
    private let model: MenuBarModel
    private let quit: @MainActor () -> Void
    private var eventMonitor: Any?
    private var observations = Set<AnyCancellable>()
    private var windows: [String: NSWindowController] = [:]
    private let restartItem = NSMenuItem(title: "Restart Service", action: #selector(restartService), keyEquivalent: "")

    init(model: MenuBarModel, quit: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }) {
        self.model = model
        self.quit = quit
        super.init()
        restartItem.target = self
        actionMenu.autoenablesItems = false
        actionMenu.addItem(restartItem)
        actionMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Ullage", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        actionMenu.addItem(quitItem)

        let content = PopoverContent(model: model) { [weak self] id in self?.openWindow(id: id) }
        let host = NSHostingController(rootView: content)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = false
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.setAccessibilityLabel("Ullage")

        model.$menuBarState.sink { [weak self] state in
            self?.statusItem.button?.image = MenuBarLabel.image(for: state)
        }.store(in: &observations)
        model.$isRestarting.combineLatest(model.$isWatching).sink { [weak self] restarting, watching in
            self?.restartItem.title = restarting ? "Restarting…" : "Restart Service"
            self?.restartItem.isEnabled = !restarting
            let status = restarting ? "Restarting…" : (watching ? "Monitoring" : "Monitoring stopped")
            self?.statusItem.button?.toolTip = "Ullage — \(status)"
        }.store(in: &observations)

        // A local monitor sees only this app's events; no accessibility permission.
        // https://developer.apple.com/documentation/appkit/nsevent/addlocalmonitorforevents(matching:handler:)
        let clicks: NSEvent.EventTypeMask = [.rightMouseDown, .leftMouseDown]
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            guard let self, let menu = self.contextMenu(for: event),
                  let button = self.statusItem.button else { return event }
            self.popover.performClose(nil)
            NSMenu.popUpContextMenu(menu, with: event, for: button)
            return nil
        }
    }

    func contextMenu(for event: NSEvent) -> NSMenu? {
        guard event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)),
              let button = statusItem.button, event.window === button.window,
              button.bounds.contains(button.convert(event.locationInWindow, from: nil)) else { return nil }
        return actionMenu
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc private func restartService() { model.restart() }
    @objc private func quitApp() { quit() }

    func openWindow(id: String) {
        popover.performClose(nil)
        if windows[id] == nil {
            let window: NSWindow
            if id == MainWindow.id {
                window = NSWindow(contentViewController: NSHostingController(rootView: MainWindow(model: model)))
                window.setContentSize(NSSize(width: 1180, height: 760))
                window.title = "Ullage"
            } else {
                let dashboard = DashboardWindow(model: DashboardModel(databasePath: self.model.databasePath))
                window = NSWindow(contentViewController: NSHostingController(rootView: dashboard))
                window.setContentSize(NSSize(width: 1000, height: 760))
                window.title = "Ullage Dashboard"
            }
            window.center()
            windows[id] = NSWindowController(window: window)
        }
        windows[id]?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func stop() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        observations.removeAll()
        popover.performClose(nil)
        for controller in windows.values { controller.close() }
        windows.removeAll()
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}
#endif

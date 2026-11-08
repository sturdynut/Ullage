#if os(macOS)
import AppKit
import SwiftUI
import UllageCore

/// Runs unsandboxed: reading ~/.claude from a sandboxed app needs entitlements,
/// which is a packaging task and not this milestone's problem.
@main
@MainActor
struct UllageApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.mainMenu = mainMenu()
        // All windows belong to MenuBarController; a placeholder Settings scene
        // otherwise gives SwiftUI an empty window to open on launch/reopen.
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    static func mainMenu() -> NSMenu {
        let menu = NSMenu()
        let appMenu = NSMenu(title: "Ullage")
        appMenu.addItem(withTitle: "Quit Ullage", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")
        for submenu in [appMenu, editMenu, windowMenu] {
            menu.addItem(withTitle: submenu.title, action: nil, keyEquivalent: "").submenu = submenu
        }
        return menu
    }
}

/// Draws the menu bar item as a template NSImage: a gauge whose needle climbs
/// with occupancy, followed by the percentage. Template so the menu bar tints
/// it for light/dark automatically. Idle keeps the last percentage, faded.
enum MenuBarLabel {
    static func gaugeSymbol(_ occupancy: Double?) -> String {
        switch occupancy ?? 0 {
        case ..<0.34: return "gauge.with.dots.needle.33percent"
        case ..<0.67: return "gauge.with.dots.needle.67percent"
        default: return "gauge.with.dots.needle.100percent"
        }
    }

    static func image(for state: MenuBarState) -> NSImage {
        let font = NSFont.menuBarFont(ofSize: 0)
        // Idle keeps the last number, drawn faded: gone entirely, it read as
        // broken; at full strength, it would pass for live.
        let text = state.isIdle ? state.idleReading : state.title
        let textAlpha: CGFloat = state.isIdle ? 0.4 : 1
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
        let gauge = NSImage(systemSymbolName: gaugeSymbol(state.occupancy), accessibilityDescription: "context window")?
            .withSymbolConfiguration(symbolConfig)
        let symbolSize = gauge?.size ?? NSSize(width: font.pointSize, height: font.pointSize)

        // A template image is tinted by its alpha, so a fainter black draws a
        // fainter number in both light and dark menu bars.
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black.withAlphaComponent(textAlpha)]
        let textSize = text.map { ($0 as NSString).size(withAttributes: attributes) } ?? .zero
        let spacing: CGFloat = text == nil ? 0 : 3
        let height = ceil(max(symbolSize.height, textSize.height))
        let width = ceil(symbolSize.width + spacing + textSize.width)

        let image = NSImage(size: NSSize(width: max(width, 1), height: max(height, 1)))
        image.lockFocus()
        gauge?.draw(in: NSRect(x: 0, y: (height - symbolSize.height) / 2, width: symbolSize.width, height: symbolSize.height))
        if let text {
            (text as NSString).draw(
                at: NSPoint(x: symbolSize.width + spacing, y: (height - textSize.height) / 2),
                withAttributes: attributes
            )
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One copy only. A reinstall that relaunches the app while a login
        // item or launcher starts it too left two copies running, each
        // tailing the same transcripts into the same database.
        if let bundleId = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
               .contains(where: { $0 != NSRunningApplication.current && !$0.isTerminated }) {
            NSApp.terminate(nil)
            return
        }
        // Menu bar only: no Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)
        menuBar = MenuBarController(model: MenuBarModel.shared)
        MenuBarModel.shared.start()
    }

    // AppKit's terminateLater keeps the run loop alive while writers drain.
    // https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldterminate(_:)
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard menuBar != nil else { return .terminateNow }
        if !isTerminating {
            isTerminating = true
            Task { @MainActor in
                await MenuBarModel.shared.stop()
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuBar?.stop()
    }
}
#else
import Foundation

@main
struct UllageApp {
    static func main() {
        FileHandle.standardError.write(Data("The Ullage menu bar app requires macOS 14 or later.\n".utf8))
        FileHandle.standardError.write(Data("The collector and its CLI (`ullage`) build and run here.\n".utf8))
        exit(1)
    }
}
#endif

#if os(macOS)
import AppKit
import SwiftUI
import UllageCore

/// M4 put the number in the menu bar; M5 put a popover behind it.
///
/// Runs unsandboxed: reading ~/.claude from a sandboxed app needs entitlements,
/// which is a packaging task and not this milestone's problem.
@main
struct UllageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = MenuBarModel.shared

    var body: some Scene {
        MenuBarExtra {
            PopoverContent(model: model)
        } label: {
            if model.state.isIdle {
                // A glyph, not a stale percentage.
                Image(systemName: "circle.dotted")
            } else {
                Text(model.state.title)
            }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)
        MenuBarModel.shared.start()
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

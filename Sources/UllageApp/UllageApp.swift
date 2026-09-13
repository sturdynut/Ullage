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
            // A gauge icon so the number reads as "context window", not just
            // another percentage next to CPU, RAM and battery. Idle shows the
            // same icon dimmed with no stale number behind it.
            if model.state.isIdle {
                Image(systemName: "gauge.with.dots.needle.33percent")
            } else {
                Text("\(Image(systemName: gaugeSymbol(model.state.occupancy))) \(model.state.title)")
            }
        }
        .menuBarExtraStyle(.window)

        // M6/M7 — history across days and what the window is made of. A real
        // window, because the popover is the wrong size for a table.
        Window("Ullage History", id: HistoryWindow.id) {
            HistoryWindow()
        }
        .defaultSize(width: 980, height: 680)
    }
}

/// Fill metaphor: the needle climbs with occupancy, so the icon alone hints at
/// how full the window is before the number is read.
func gaugeSymbol(_ occupancy: Double?) -> String {
    switch occupancy ?? 0 {
    case ..<0.34: return "gauge.with.dots.needle.33percent"
    case ..<0.67: return "gauge.with.dots.needle.67percent"
    default: return "gauge.with.dots.needle.100percent"
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

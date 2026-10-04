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
            // Rendered as one NSImage: a MenuBarExtra label built from a SwiftUI
            // Text with an inline SF Symbol drops the symbol in the menu bar, so
            // the gauge and the number are drawn together into a template image
            // instead. The gauge makes the number read as "context window"
            // rather than yet another percentage next to CPU, RAM and battery.
            Image(nsImage: MenuBarLabel.image(for: model.menuBarState))
        }
        .menuBarExtraStyle(.window)

        // One main window: the popover is the glance, this is everything at
        // full size. Composition, History and Token savers are its pages.
        Window("Ullage", id: MainWindow.id) {
            MainWindow(model: model)
        }
        .defaultSize(width: 1180, height: 760)
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

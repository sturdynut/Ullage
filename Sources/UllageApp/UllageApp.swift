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

        // M6/M7 — history across days and what the window is made of. A real
        // window, because the popover is the wrong size for a table.
        Window("Ullage History", id: HistoryWindow.id) {
            HistoryWindow()
        }
        .defaultSize(width: 980, height: 680)
    }
}

/// Draws the menu bar item as a template NSImage: a gauge whose needle climbs
/// with occupancy, followed by the percentage. Template so the menu bar tints
/// it for light/dark automatically. Idle shows the gauge alone, no stale number.
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
        let text = state.isIdle ? nil : state.title
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
        let gauge = NSImage(systemSymbolName: gaugeSymbol(state.occupancy), accessibilityDescription: "context window")?
            .withSymbolConfiguration(symbolConfig)
        let symbolSize = gauge?.size ?? NSSize(width: font.pointSize, height: font.pointSize)

        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
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

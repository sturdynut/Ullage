#if os(macOS)
import AppKit
import SwiftUI

/// Shrinks the menu bar window to its content.
///
/// A `MenuBarExtra` window grows when its content does but does not reliably
/// shrink: collapse a section and the smaller content sits centred in the old
/// frame, with blank bands above and below. This finds the hosting window and
/// sets its height to the content's whenever that changes, keeping the top
/// edge where it is — under the menu bar.
struct WindowFitter: NSViewRepresentable {
    let height: CGFloat

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let height = height
        DispatchQueue.main.async {
            guard let window = view.window, height > 0 else { return }
            var frame = window.frame
            let target = window.frameRect(forContentRect: NSRect(origin: .zero, size: CGSize(width: frame.width, height: height))).height
            guard abs(frame.height - target) > 0.5 else { return }
            frame.origin.y += frame.height - target
            frame.size.height = target
            window.setFrame(frame, display: true, animate: false)
        }
    }
}
#endif

#if os(macOS)
import AppKit
import SwiftUI

/// Closing or minimizing a retained window must stop the playback reader as well as hiding it.
struct PlaybackWindowVisibility: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: VisibilityView, context: Context) { view.onChange = onChange }

    final class VisibilityView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            if let window {
                let notifications: [Notification.Name] = [
                    NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                    NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification
                ]
                observers = notifications.map { name in
                    NotificationCenter.default.addObserver(forName: name, object: window,
                                                           queue: .main) { [weak self] note in
                        let isClosing = note.name == NSWindow.willCloseNotification
                        Task { @MainActor in self?.report(isClosing: isClosing) }
                    }
                }
            }
            Task { @MainActor [weak self] in self?.report() }
        }

        private func report(isClosing: Bool = false) {
            onChange?(!isClosing && window?.isVisible == true && window?.isMiniaturized == false
                      && window?.occlusionState.contains(.visible) == true)
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
#endif

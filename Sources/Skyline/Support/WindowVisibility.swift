import AppKit
import SwiftUI

/// Reports whether the hosting window is actually visible on screen (not occluded, minimised or closed).
/// Used to pause refreshes and radar animation when nobody can see them.
///
/// `onOpenChange` reports the window being closed (false) and shown again (true), separately from
/// occlusion, so the app can tear down the heavy window content (map, radar layers, background) while
/// only the menu bar is in use and rebuild it when the window comes back.
struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void
    var onOpenChange: ((Bool) -> Void)? = nil

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.onChange = onChange
        view.onOpenChange = onOpenChange
        return view
    }

    func updateNSView(_ view: VisibilityView, context: Context) {
        view.onChange = onChange
        view.onOpenChange = onOpenChange
    }

    final class VisibilityView: NSView {
        var onChange: ((Bool) -> Void)?
        var onOpenChange: ((Bool) -> Void)?
        private var lastOpen: Bool?
        private var observers: [NSObjectProtocol] = []
        private var lastReported: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            observers.forEach { center.removeObserver($0) }
            observers.removeAll()
            guard let window else {
                report(false)
                return
            }
            let names: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
            ]
            for name in names {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reportCurrent() }
                })
            }
            observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.report(false)
                    self?.reportOpen(false)
                }
            })
            // SwiftUI keeps a closed `Window` (and this view) alive and re-shows the same NSWindow.
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reportCurrent() }
                })
            }
            reportCurrent()
        }

        private func reportCurrent() {
            guard let window else { return report(false) }
            if window.isVisible { reportOpen(true) }
            report(window.occlusionState.contains(.visible) && !window.isMiniaturized)
        }

        /// Deferred like `report`, and delivered even if this view is gone by the next turn.
        private func reportOpen(_ open: Bool) {
            guard open != lastOpen else { return }
            lastOpen = open
            let callback = onOpenChange
            DispatchQueue.main.async { callback?(open) }
        }

        /// Deferred to the next main-queue turn: this can run inside a view-hierarchy/layout pass
        /// (viewDidMoveToWindow), where writing observed SwiftUI state is not allowed.
        /// The callback is captured strongly: on window close this view is often deallocated before the
        /// next turn, and a `[weak self]` bail-out used to drop the "hidden" signal, leaving the store
        /// believing the window (and radar) were still visible (Code Reviewer F5).
        private func report(_ visible: Bool) {
            guard visible != lastReported else { return }
            lastReported = visible
            let callback = onChange
            DispatchQueue.main.async { [weak self] in
                if let self, self.lastReported != visible { return } // superseded by a newer report
                callback?(visible)
            }
        }
    }
}

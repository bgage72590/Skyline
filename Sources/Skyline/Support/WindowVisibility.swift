import AppKit
import SwiftUI
import SkylineCore

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

/// Releases the main window when it closes, instead of leaving the NSWindow, its hosting view, and
/// the backing store alive behind an empty root. Reopen goes through `openWindow` and builds a new
/// one. The menu-bar item, the dropdown panel, and Settings are not this window.
struct MainWindowRelease: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.arm() }

    static func isMain(_ window: NSWindow) -> Bool {
        MainWindowMatch.isMain(MainWindowAttributes(window: window))
    }

    /// `-SkylineReleaseWhenClosed YES` (default off). Mac QA turns it on only if the closed-window
    /// measurement misses by more than 3 MB without it. `strip` still swaps in an empty content view.
    static var releaseWhenClosed: Bool { LaunchArguments.bool("SkylineReleaseWhenClosed") }

    /// Drops radar shells (including ones AppKit's key-view table is holding), the hosting view's
    /// layer tree, and the content view. `isReleasedWhenClosed` lets AppKit free the NSWindow when
    /// the launch argument is on.
    static func strip(_ window: NSWindow) {
        guard isMain(window), !window.isVisible else { return }
        if releaseWhenClosed { window.isReleasedWhenClosed = true }
        var containers: [RadarMapContainer] = []
        func collect(_ view: NSView?) {
            guard let view else { return }
            if let container = view as? RadarMapContainer { containers.append(container) }
            view.subviews.forEach { collect($0) }
        }
        collect(window.contentView)
        containers.forEach { $0.teardown() }
        window.initialFirstResponder = nil
        if let content = window.contentView {
            func releaseLayers(_ view: NSView) {
                view.breakKeyViewLink()
                view.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
                view.wantsLayer = false
                view.subviews.forEach { releaseLayers($0) }
            }
            releaseLayers(content)
            content.subviews.forEach { $0.removeFromSuperview() }
        }
        window.recalculateKeyViewLoop()
        window.contentViewController = nil
        window.contentView = NSView(frame: .zero)
    }

    final class Probe: NSView {
        private var observer: NSObjectProtocol?

        func arm() {
            guard let window, MainWindowRelease.isMain(window) else { return }
            if MainWindowRelease.releaseWhenClosed { window.isReleasedWhenClosed = true }
            guard observer == nil else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak window] _ in
                MainActor.assumeIsolated {
                    if let window { MainWindowFrameHold.capture(window) }
                    if MainWindowRelease.releaseWhenClosed { window?.isReleasedWhenClosed = true }
                    // After the close notification and the empty-root swap, drop whatever is left.
                    DispatchQueue.main.async {
                        DispatchQueue.main.async { [weak window] in
                            guard let window else { return }
                            MainWindowRelease.strip(window)
                        }
                    }
                }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

extension NSView {
    /// Public path: drop `nextKeyView` and rebuild the loop. The private `previousKeyView` selector
    /// runs only with `-SkylinePrivateKeyViewBreak YES` (default off). Mac QA removes that branch if
    /// `maps=0` after close without it.
    func breakKeyViewLink() {
        if LaunchArguments.bool("SkylinePrivateKeyViewBreak") {
            let sel = Selector(("previousKeyView"))
            if responds(to: sel), let previous = perform(sel)?.takeUnretainedValue() as? NSView, previous.nextKeyView === self {
                previous.nextKeyView = nil
                print("[keyview] private previousKeyView break")
                fflush(stdout)
            }
        }
        nextKeyView = nil
        window?.recalculateKeyViewLoop()
    }
}

extension MainWindowAttributes {
    init(window: NSWindow) {
        self.init(
            identifier: window.identifier?.rawValue,
            title: window.title,
            isPanel: window is NSPanel,
            className: window.className,
            frameAutosaveName: window.frameAutosaveName,
            hasSheetParent: window.sheetParent != nil || window.isSheet,
            isTitled: window.styleMask.contains(.titled)
        )
    }
}

/// Last closed main-window frame, in memory only (no new preferences key). Reopen puts it back when
/// SwiftUI has handed the window a different frame.
@MainActor
enum MainWindowFrameHold {
    private static var closed: NSRect?

    static func capture(_ window: NSWindow) {
        guard MainWindowRelease.isMain(window) else { return }
        closed = window.frame
    }

    static func applyToVisible() {
        guard let closed else { return }
        for window in NSApp.windows where window.isVisible && MainWindowRelease.isMain(window) {
            guard !matches(window.frame, closed) else { continue }
            window.setFrame(closed, display: true)
            print("[frame] restored \(describe(closed))")
            fflush(stdout)
        }
    }

    /// One pass on the next turn and another shortly after, covering a frame SwiftUI applies late.
    static func scheduleRestore() {
        DispatchQueue.main.async {
            applyToVisible()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { applyToVisible() }
        }
    }

    static func describeCurrent() -> String {
        let frames = NSApp.windows.filter { $0.isVisible && MainWindowRelease.isMain($0) }.map { describe($0.frame) }
        return frames.isEmpty ? "none" : frames.joined(separator: ";")
    }

    static func describe(_ rect: NSRect) -> String {
        let x = Int(rect.origin.x.rounded()), y = Int(rect.origin.y.rounded())
        let w = Int(rect.size.width.rounded()), h = Int(rect.size.height.rounded())
        return "\(x),\(y) \(w)x\(h)"
    }

    private static func matches(_ a: NSRect, _ b: NSRect) -> Bool {
        abs(a.origin.x - b.origin.x) < 1 && abs(a.origin.y - b.origin.y) < 1
            && abs(a.size.width - b.size.width) < 1 && abs(a.size.height - b.size.height) < 1
    }
}

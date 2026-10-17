import AppKit
import SwiftUI

/// Reaches the window hosting the dropdown (the MenuBarExtra panel or HotkeyPanel) with public AppKit
/// only, to make it transparent and give it the dropdown's rounded shape (build 57, glass spec path B).
struct DropdownWindowConfigurator: NSViewRepresentable {
    let cornerRadius: CGFloat
    /// Called each time the dropdown's window becomes key, i.e. every time it opens. The MenuBarExtra
    /// keeps its view alive between openings, so `.task` alone ran only on the first open (QA item 5).
    var onBecomeKey: (() -> Void)? = nil

    func makeNSView(context: Context) -> ProbeView { ProbeView(cornerRadius: cornerRadius, onBecomeKey: onBecomeKey) }
    func updateNSView(_ view: ProbeView, context: Context) { view.onBecomeKey = onBecomeKey }

    final class ProbeView: NSView {
        let cornerRadius: CGFloat
        var onBecomeKey: (() -> Void)?
        private var keyObserver: NSObjectProtocol?
        init(cornerRadius: CGFloat, onBecomeKey: (() -> Void)?) {
            self.cornerRadius = cornerRadius; self.onBecomeKey = onBecomeKey; super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        deinit { if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) } }

        override func layout() {
            super.layout()
            window?.invalidateShadow() // the dropdown's height changes with its content
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let keyObserver { NotificationCenter.default.removeObserver(keyObserver); self.keyObserver = nil }
            guard let window else { return }
            keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window,
                                                                 queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onBecomeKey?() }
            }
            // Root cause of the square-ish corners: the panel is transparent already, but the dropdown
            // painted an opaque rectangle edge to edge, so the only rounding was the window server's small
            // default corner mask (about 5 pt). The content is now clipped to 22 pt; make sure the window
            // stays clear and recompute its shadow from the rounded alpha shape.
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = !UserDefaults.standard.bool(forKey: "SkylineNoShadowTest")
            // The panel also draws SwiftUI's own backdrop (blur + opaque dark fill) edge to edge, which
            // showed as grey wedges outside the dropdown's corners. Round the window's frame view (its
            // layer already masks to bounds), so everything in the window, backdrop included, is clipped
            // to the same 22 pt continuous corners. Public AppKit/Core Animation on our own window.
            if let frameView = window.contentView?.superview {
                frameView.wantsLayer = true
                frameView.layer?.cornerRadius = cornerRadius
                frameView.layer?.cornerCurve = .continuous
                frameView.layer?.masksToBounds = true
            }
            DispatchQueue.main.async { window.invalidateShadow() }
            if UserDefaults.standard.bool(forKey: "SkylineDumpDropdownWindow") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Self.dump(window) }
            }
        }

        static func dump(_ w: NSWindow) {
            print("[dropdown-window] \(w.className) style=\(w.styleMask.rawValue) opaque=\(w.isOpaque) bg=\(String(describing: w.backgroundColor)) shadow=\(w.hasShadow) frame=\(w.frame)")
            func walk(_ v: NSView, _ depth: Int) {
                let layer = v.layer.map { "layer \(type(of: $0)) r=\($0.cornerRadius) mask=\($0.masksToBounds) bg=\(String(describing: $0.backgroundColor)) sub=\($0.sublayers?.map { String(describing: type(of: $0)) } ?? []) filters=\(String(describing: $0.backgroundFilters))" } ?? "no layer"
                print("[dropdown-window] " + String(repeating: "  ", count: depth) + "\(v.className) \(v.frame.size) \(layer)")
                if depth < 4 { v.subviews.forEach { walk($0, depth + 1) } }
            }
            if let frameView = w.contentView?.superview { walk(frameView, 0) }
            fflush(stdout)
        }
    }
}

import AppKit
import Carbon.HIToolbox
import SwiftUI
import SkylineCore

/// "Exiting leaves Skyline in the menu bar" (batch 6): ⌘Q and the close button only close windows, so
/// the batch 2 teardown (WindowVisibility) frees the map/radar and the menu-bar extra keeps running.
/// Full quits: the dropdown's "Quit Skyline", Skyline › Quit Skyline Completely (⌥⌘Q), the Dock menu,
/// logout/restart. Policy lives in SkylineCore.QuitPolicy (tested).
@MainActor
enum AppExit {
    static func perform(_ source: QuitPolicy.Source) {
        switch QuitPolicy.action(for: source) {
        case .terminate: NSApp.terminate(nil)
        case .closeWindow: closeWindows()
        }
    }

    /// Closes Skyline's ordinary windows (main, Settings); the menu-bar extra's panel isn't one of them.
    static func closeWindows() {
        GlobalHotkey.closePanel() // the hotkey panel is an NSPanel, so close it explicitly (QA batch 6 Q1)
        for w in NSApp.windows where w.isVisible && isAppWindow(w) { w.performClose(nil) }
    }

    static func isAppWindow(_ w: NSWindow) -> Bool {
        w.styleMask.contains(.titled) && !(w is NSPanel) && w.className != "NSStatusBarWindow"
    }

    static var mainWindowVisible: Bool {
        NSApp.windows.contains { $0.isVisible && MainWindowMatch.isMain(MainWindowAttributes(window: $0)) }
    }

    /// Brings the main window back (dropdown, Dock click, relaunch, hotkey fallback, Shortcuts).
    /// Opens Settings from any context (main window, menu-bar dropdown, or ⌃⌥W panel). SettingsLink
    /// only works inside an app Scene; the hotkey panel hosts the dropdown outside one (QA #3).
    static func openSettings() {
        DockIcon.apply(openMainWindow: true) // Settings needs the app menu bar too
        NSApp.activate()
        // Private but stable selector used by System Settings / SwiftUI SettingsLink on macOS.
        let sel = Selector(("showSettingsWindow:"))
        if NSApp.sendAction(sel, to: nil, from: nil) { return }
        // Older fallback.
        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
    }

    static func showMainWindow() {
        AppActions.performOpenMainWindow()
        NSApp.activate()
    }

    /// Hidden QA hook: `-SkylineQuitKeyTest YES` sends ⌘Q through the app's own main menu (in-process,
    /// no events to other apps), checks Skyline is still running with the window closed and the
    /// menu-bar item present, then closes and reopens five times. Logs one PASS/FAIL line and quits.
    /// Show in Dock off is `-showInDock NO` in the argument domain; this hook never writes that default.
    /// Not swift-testable: reopen goes through SwiftUI's `openWindow` environment.
    static func runQuitKeyTestIfRequested() {
        guard UserDefaults.standard.bool(forKey: "SkylineQuitKeyTest") else { return }
        Task {
            try? await Task.sleep(for: .seconds(3))
            var failures: [String] = []
            if !mainWindowVisible { failures.append("window not open at start") }
            let q = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                     windowNumber: NSApp.keyWindow?.windowNumber ?? 0, context: nil,
                                     characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12)!
            let handled = NSApp.mainMenu?.performKeyEquivalent(with: q) ?? false
            if !handled { failures.append("⌘Q not handled by the menu") }
            try? await Task.sleep(for: .seconds(2))
            if mainWindowVisible { failures.append("window still open after ⌘Q") }
            let statusItem = NSApp.windows.contains { $0.className == "NSStatusBarWindow" }
            if !statusItem { failures.append("menu-bar item missing") }
            print("[quit-test] after ⌘Q: alive=yes window=\(mainWindowVisible ? "open" : "closed") statusItem=\(statusItem)")
            for cycle in 1...5 {
                print("[quit-test] frame before close \(MainWindowFrameHold.describeCurrent())")
                MemoryTest.closeMainWindow()
                let mapsDeadline = Date().addingTimeInterval(8)
                while RadarMapContainer.live != 0 && Date() < mapsDeadline {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if RadarMapContainer.live != 0 { failures.append("cycle \(cycle) maps=\(RadarMapContainer.live)") }
                _ = AppDelegateReopen.simulateReopen()
                let visibleDeadline = Date().addingTimeInterval(8)
                while !mainWindowVisible && Date() < visibleDeadline {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if !mainWindowVisible { failures.append("cycle \(cycle) window not visible") }
                try? await Task.sleep(for: .milliseconds(400))
                print("[quit-test] frame after reopen \(MainWindowFrameHold.describeCurrent())")
                MainWindowFrameHold.applyToVisible()
                print("[quit-test] frame settled \(MainWindowFrameHold.describeCurrent())")
            }
            print(failures.isEmpty ? "[quit-test] PASS" : "[quit-test] FAIL: \(failures.joined(separator: "; "))")
            fflush(stdout)
            perform(.quitCompletely)
        }
    }
}

/// Same path as a Dock click / relaunch (`applicationShouldHandleReopen` with no visible windows).
@MainActor
enum AppDelegateReopen {
    static func simulateReopen() -> Bool {
        NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false) ?? false
    }
}

/// Optional global hotkey (L22): ⌃⌥W opens the menu-bar dropdown from any app. Off by default
/// (Settings). Carbon `RegisterEventHotKey` needs no Accessibility permission and only sees this one
/// key combination.
@MainActor
enum GlobalHotkey {
    static let key = "globalHotkey"
    static let label = "⌃⌥W"
    private static var ref: EventHotKeyRef?
    private static var handlerInstalled = false

    /// Set when ⌃⌥W couldn't be registered (another app holds it); Settings shows it (QA batch 6 H1).
    static var lastError: String?

    /// Returns false (and turns the setting back off) when the key couldn't be registered.
    @discardableResult
    static func apply() -> Bool {
        let on = UserDefaults.standard.bool(forKey: key)
        if on, ref == nil {
            if register() != noErr || ref == nil {
                ref = nil
                lastError = "\(label) is in use by another app, so Skyline couldn't take it."
                UserDefaults.standard.set(false, forKey: key)
                return false
            }
        } else if !on, let r = ref { UnregisterEventHotKey(r); ref = nil }
        lastError = nil
        return true
    }

    @discardableResult
    private static func register() -> OSStatus {
        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotkey.fire() } }
                return noErr
            }, 1, &spec, nil, nil)
            handlerInstalled = true
        }
        let id = EventHotKeyID(signature: OSType(0x534B_594C), id: 1) // 'SKYL'
        // Exclusive: fails (eventHotKeyExistsErr) instead of sharing when another app already has it.
        return RegisterEventHotKey(UInt32(kVK_ANSI_W), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(),
                                   OptionBits(kEventHotKeyExclusive), &ref)
    }

    static var isRegistered: Bool { ref != nil }

    /// Shows the menu-bar forecast (the same view as the dropdown) in a panel under Skyline's
    /// status item. SwiftUI's MenuBarExtra can't be opened programmatically (its button ignores
    /// performClick and synthetic clicks), so the hotkey hosts the dropdown content itself. The panel
    /// closes when it loses focus, like the dropdown; pressing the hotkey again closes it.
    private static var panel: HotkeyPanel?

    static func fire() {
        if let panel, panel.isVisible { panel.close(); return }
        guard let store = IntentStore.shared else { return AppExit.showMainWindow() }
        let p = panel ?? HotkeyPanel(store: store)
        panel = p
        p.show(under: statusButton()?.window?.frame)
    }

    static func closePanel() { panel?.close() }

    static var isPanelOpen: Bool { panel?.isVisible == true }

    /// Skyline's own status item button (the one wired to an action; other status-bar windows in the
    /// process have none).
    static func statusButton() -> NSStatusBarButton? {
        var fallback: NSStatusBarButton?
        for w in NSApp.windows where w.className == "NSStatusBarWindow" {
            if let b = find(in: w.contentView) {
                if b.action != nil { return b }
                fallback = fallback ?? b
            }
        }
        return fallback
    }

    private static func find(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let b = view as? NSStatusBarButton { return b }
        for s in view.subviews { if let b = find(in: s) { return b } }
        return nil
    }

    /// Hidden QA hook: `-SkylineShowDropdown <seconds>` opens the dropdown panel once the forecast has
    /// loaded and prints its window number (`[dropdown] window=N height=H`) for `screencapture -l N`.
    static func showDropdownIfRequested() {
        let delay = UserDefaults.standard.double(forKey: "SkylineShowDropdown")
        guard delay > 0 else { return }
        Task {
            try? await Task.sleep(for: .seconds(delay))
            fire()
            try? await Task.sleep(for: .seconds(1))
            if let panel {
                print("[dropdown] window=\(panel.windowNumber) height=\(Int(panel.frame.height)) width=\(Int(panel.frame.width))")
                fflush(stdout)
            }
        }
    }

    /// Hidden QA hook: `-SkylineHotkeyTest YES` turns the hotkey on for this run, calls its handler
    /// in-process, checks the dropdown opened, logs PASS/FAIL and quits. No keystrokes are sent.
    static func runTestIfRequested() {
        guard UserDefaults.standard.bool(forKey: "SkylineHotkeyTest") else { return }
        Task {
            try? await Task.sleep(for: .seconds(3))
            if ref == nil { _ = register() }
            // A second exclusive registration of the same key must fail: this is the conflict path (H1).
            var dup: EventHotKeyRef?
            let conflict = RegisterEventHotKey(UInt32(kVK_ANSI_W), UInt32(controlKey | optionKey),
                                               EventHotKeyID(signature: OSType(0x534B_594C), id: 2), GetEventDispatcherTarget(),
                                               OptionBits(kEventHotKeyExclusive), &dup)
            if let dup { UnregisterEventHotKey(dup) }
            print("[hotkey-test] duplicateRegistration=\(conflict) (non-zero means a conflict is detected)")
            let registered = isRegistered
            let found = statusButton() != nil
            fire()
            try? await Task.sleep(for: .seconds(1.5))
            // The MenuBarExtra's window: visible, untitled, not the status-bar strip itself.
            let open = isPanelOpen
            let classes = NSApp.windows.filter(\.isVisible).map { "\($0.className)\(Int($0.frame.height))" }.joined(separator: ",")
            fire()
            try? await Task.sleep(for: .milliseconds(500))
            let closedAgain = !isPanelOpen
            print("[hotkey-test] registered=\(registered) statusButton=\(found) panelOpen=\(open) secondPressCloses=\(closedAgain) windows=\(classes)")
            print(registered && found && open && closedAgain ? "[hotkey-test] PASS" : "[hotkey-test] FAIL")
            fflush(stdout)
            NSApp.terminate(nil)
        }
    }
}

/// Borderless key panel hosting the dropdown content for the global hotkey.
@MainActor
final class HotkeyPanel: NSPanel {
    init(store: WeatherStore) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 400), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        // Stays open while a screenshot is taken (QA hook only).
        if UserDefaults.standard.double(forKey: "SkylineShowDropdown") > 0 { keepOpenForScreenshot = true }
        let host = NSHostingController(rootView: MenuBarContentView().environment(store))
        host.sizingOptions = [.preferredContentSize]
        contentViewController = host
        contentView?.wantsLayer = true
        contentView?.layer?.cornerRadius = DropdownShape.radius
        contentView?.layer?.masksToBounds = true
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.keepOpenForScreenshot != true { self?.close() } }
        }
    }

    var keepOpenForScreenshot = false

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { close() } // Esc

    func show(under statusFrame: NSRect?) {
        layoutIfNeeded()
        let size = contentViewController?.view.fittingSize ?? frame.size
        let screen = NSScreen.screens.first { $0.frame.intersects(statusFrame ?? .zero) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        var x = (statusFrame?.midX ?? visible.maxX - 200) - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let top = statusFrame?.minY ?? visible.maxY
        setFrame(NSRect(x: x, y: top - size.height - 4, width: size.width, height: size.height), display: true)
        // Nonactivating panel: show without NSApp.activate(), which would also raise the main window
        // in front of whatever the user was looking at (QA #9).
        orderFrontRegardless()
        makeKey()
    }
}

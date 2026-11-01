import AppKit
import MapKit
import SwiftUI
import SkylineCore

@main
struct SkylineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = WeatherStore.forApp()
    @State private var updates = UpdateActivity.shared

    init() {
        // L23: start the request-rate clock at launch, not at the first request.
        _ = RequestStats.shared
    }

    var body: some Scene {
        Window("Skyline", id: SceneID.main) {
            ContentView()
                .environment(store)
                .frame(minWidth: 860, minHeight: 600)
        }
        // T18: wide enough on a fresh install for the three-column layout (sidebar 290 + detail ≥ 1000);
        // macOS clamps it to smaller screens, where the narrow layout takes over as before.
        .defaultSize(width: 1360, height: 860)
        // Static, and evaluated before the launch event can be read. didFinish opens the window
        // for a manual launch; a login launch leaves it uncreated.
        .defaultLaunchBehavior(.suppressed)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button(updates.downloadingTitle ?? "Update Skyline…") { Updater.checkForUpdates() }
                    .disabled(updates.isPending)
            }
            // ⌘Q closes the window and leaves Skyline in the menu bar (batch 6); ⌥⌘Q really quits.
            CommandGroup(replacing: .appTermination) {
                Button("Close Skyline Window") { AppExit.perform(.commandQ) }
                    .keyboardShortcut("q", modifiers: .command)
                Button("Quit Skyline Completely") { AppExit.perform(.quitCompletely) }
                    .keyboardShortcut("q", modifiers: [.command, .option])
            }
            CommandMenu("Weather") {
                Button("Refresh") {
                    Task { await store.refreshAll(force: true) }
                }
                .keyboardShortcut("r", modifiers: .command)
                Button(store.radarExpanded ? "Hide Radar Map" : "Show Radar Map") {
                    if store.radarExpanded { store.radar.isPlaying = false }
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) {
                        store.activeModule = nil
                        store.radarExpanded.toggle()
                    }
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(store.selectedLocation == nil)
                Button(store.radar.isPlaying ? "Pause Radar" : "Play Radar") { store.radar.togglePlay() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Divider()
                Button("Previous Location") { store.selectLocation(offset: -1) }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Button("Next Location") { store.selectLocation(offset: 1) }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                ForEach(Array(store.allLocations.prefix(9).enumerated()), id: \.element.id) { i, location in
                    Button(location.isCurrentLocation ? "My Location" : location.name) { store.selectLocation(number: i + 1) }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
                Button("Forecast Accuracy") {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
                        store.radarExpanded = false
                        store.activeModule = ModuleSelection(module: .accuracy, day: nil)
                    }
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(store.selectedLocation == nil)
                Divider()
                Button("Focus Forecast") { store.focusContentRequest += 1 }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarContentView()
                .environment(store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}

enum SceneID {
    static let main = "main"
}

/// Bridges AppKit lifecycle events that SwiftUI scenes don't expose.
@MainActor
enum AppActions {
    /// Set by views that have access to `openWindow`, used when the Dock icon is clicked with no window open.
    static var openMainWindow: (() -> Void)?

    private static var spaceMonitor: Any?

    /// Space plays/pauses the radar from anywhere in the main window, except where Space already means
    /// something: a text field being edited, or a focused button, checkbox, slider, pop-up or segmented
    /// control (keyboard navigation), which get the key as usual (L10). In-app event monitor only;
    /// nothing is sent to other apps.
    static func installSpaceShortcut(store: WeatherStore) {
        guard spaceMonitor == nil else { return }
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak store] event in
            guard event.keyCode == 49,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  let window = event.window, window.identifier?.rawValue.hasPrefix(SceneID.main) == true
                    || window.title == "Skyline",
                  !spaceBelongsTo(window.firstResponder), !event.isARepeat,
                  let store, store.selectedLocation != nil else { return event }
            store.radar.togglePlay()
            return nil
        }
    }

    /// True when the focused view handles Space itself (text editing, or pressing a focused control).
    /// Lists (the sidebar) have no Space action, so Space still plays the radar there.
    static func spaceBelongsTo(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        if responder is NSText { return true }
        if let control = responder as? NSControl, !(control is NSTableView) {
            return control.isEnabled && control.acceptsFirstResponder
        }
        // SwiftUI plain buttons aren't NSControls. They only take focus with keyboard navigation on
        // (System Settings › Keyboard), and then the first responder is a hosted view other than the
        // window's root view; leave Space to it (Code Reviewer batch 3). Decided with public API only (no
        // private SwiftUI type names, Code Reviewer batch 4): any focused NSView that isn't the root,
        // a table, or part of the map.
        if NSApp.isFullKeyboardAccessEnabled, let view = responder as? NSView, !(view is NSTableView),
           view !== view.window?.contentView, Bundle(for: type(of: view)) != Bundle(for: MKMapView.self) {
            return true
        }
        return false
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var didFinishStarted = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Evidence only: the launch event is usually not delivered yet. didFinish classifies.
            let seen = LaunchEventSnapshot.read()
            print("[launch] willFinish event=\(seen.eventCode)")
            fflush(stdout)
            // Always dark, like the dropdown: in system Light Mode the sidebar material, sheets, alerts and
            // Settings otherwise turn light gray against the dark sky panel (UI/UX #3). App-wide, because
            // `.preferredColorScheme` on the window kept its content (map, radar) alive after closing,
            // and SwiftUI resets a window's own `appearance`. The menu-bar icon is a template image, so the
            // menu bar still tints it for its own light/dark look.
            NSApp.appearance = NSAppearance(named: .darkAqua)
            // "Show in Dock" off → menu-bar-only app from launch (T10).
            DockIcon.apply()
        }
    }

    /// Keep running in the menu bar after the main window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Pumping the run loop while waiting for the window handler can re-enter this method.
            guard !didFinishStarted else { return }
            didFinishStarted = true
            SlimLaunchRuntime.didFinishAt = Date()
            let event = LaunchEventSnapshot.read()
            let decision = SlimLaunch.decide(
                eventClass: event.eventClass,
                eventID: event.eventID,
                propData: event.propData,
                launchKindArgument: LaunchArguments.string("SkylineLaunchKind"),
                slimModeNo: LaunchArguments.slimModeNo,
                showInDock: DockIcon.prefersDockIcon)
            SlimLaunchRuntime.decision = decision
            print("[launch] kind=\(decision.kind.rawValue) event=\(event.eventCode) prop=\(event.propCode)")
            fflush(stdout)
            if decision.opensWindow { SlimLaunchRuntime.openMainWindowForLaunch() }
            GlobalHotkey.apply()
            AppExit.runQuitKeyTestIfRequested()
            GlobalHotkey.runTestIfRequested()
            GlobalHotkey.showDropdownIfRequested()
            SearchTypeTest.runIfRequested()
            Updater.showUpdateResultIfNeeded()
            DockMenuTest.runIfRequested()
            GlobalHotkey.runDropdownCyclesIfRequested()
            SlimOpen.runIfRequested()
            SlimHooks.runIfRequested()
            // Keep activation policy in sync when Settings becomes key or any window closes.
            let center = NotificationCenter.default
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { DockIcon.apply() }
            }
            center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
                MainActor.assumeIsolated {
                    // After this window closes, recompute (main window may still be open).
                    DispatchQueue.main.async { DockIcon.apply() }
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            MainActor.assumeIsolated { AppActions.openMainWindow?() }
        }
        return true
    }
}

/// The launch Apple event, read at will-finish (evidence) and at the start of did-finish (the decision).
@MainActor
struct LaunchEventSnapshot {
    var eventClass: UInt32?
    var eventID: UInt32?
    var propData: UInt32?
    var eventCode: String { SlimLaunch.codeString(eventID) }
    var propCode: String { SlimLaunch.codeString(propData) }

    static func read() -> LaunchEventSnapshot {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else {
            return LaunchEventSnapshot(eventClass: nil, eventID: nil, propData: nil)
        }
        return LaunchEventSnapshot(eventClass: UInt32(event.eventClass), eventID: UInt32(event.eventID),
                                   propData: propData(of: event))
    }

    /// keyAEPropData ('prdt'), as a typeType or typeEnumerated four-character code.
    private static func propData(of event: NSAppleEventDescriptor) -> UInt32? {
        guard let desc = event.paramDescriptor(forKeyword: AEKeyword(0x7072_6474)) else { return nil }
        let kind = desc.descriptorType
        let code: OSType
        if kind == DescType(0x656E_756D) { // 'enum'
            code = desc.enumCodeValue
        } else if kind == DescType(0x7479_7065) { // 'type'
            code = desc.typeCodeValue
        } else {
            return nil
        }
        return code == 0 ? nil : UInt32(code)
    }
}

/// Clock and decision from did-finish, shared with the QA hooks. The window opens through
/// `AppActions.openMainWindow`, which MenuBarLabel registers; that registration stays where it is.
@MainActor
enum SlimLaunchRuntime {
    static var didFinishAt = Date()
    static var decision: SlimLaunchDecision?
    static var handlerMissing = false

    static func waitForHandler(seconds: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while AppActions.openMainWindow == nil && Date() < deadline {
            _ = RunLoop.current.run(mode: .common, before: Date().addingTimeInterval(0.05))
        }
        return AppActions.openMainWindow != nil
    }

    static func openMainWindowForLaunch() {
        guard waitForHandler() else {
            handlerMissing = true
            print("[open] handler missing at launch")
            fflush(stdout)
            return
        }
        AppActions.openMainWindow?()
    }
}

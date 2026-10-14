import AppKit
import MapKit
import SwiftUI
import SkylineCore

@main
struct SkylineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = WeatherStore()

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
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Update Skyline…") { Updater.checkForUpdates() }
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
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
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
            GlobalHotkey.apply()
            AppExit.runQuitKeyTestIfRequested()
            GlobalHotkey.runTestIfRequested()
            GlobalHotkey.showDropdownIfRequested()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            MainActor.assumeIsolated { AppActions.openMainWindow?() }
        }
        return true
    }
}

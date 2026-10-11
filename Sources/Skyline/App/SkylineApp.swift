import AppKit
import SwiftUI
import SkylineCore

@main
struct SkylineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = WeatherStore()

    var body: some Scene {
        Window("Skyline", id: SceneID.main) {
            ContentView()
                .environment(store)
                .frame(minWidth: 860, minHeight: 600)
        }
        .defaultSize(width: 1180, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
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

    /// Space plays/pauses the radar from anywhere in the main window, except while a text field
    /// (e.g. the search field) is being edited. In-app event monitor only; nothing is sent to other apps.
    static func installSpaceShortcut(store: WeatherStore) {
        guard spaceMonitor == nil else { return }
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak store] event in
            guard event.keyCode == 49,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  let window = event.window, window.identifier?.rawValue.hasPrefix(SceneID.main) == true
                    || window.title == "Skyline",
                  !(window.firstResponder is NSText), !event.isARepeat,
                  let store, store.selectedLocation != nil else { return event }
            store.radar.togglePlay()
            return nil
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Keep running in the menu bar after the main window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            MainActor.assumeIsolated { AppActions.openMainWindow?() }
        }
        return true
    }
}

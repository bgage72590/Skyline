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
            }
        }

        Window("Radar", id: SceneID.radar) {
            RadarWindowView()
                .environment(store)
                .frame(minWidth: 640, minHeight: 480)
        }
        .defaultSize(width: 1000, height: 760)

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
    static let radar = "radar"
}

/// Bridges AppKit lifecycle events that SwiftUI scenes don't expose.
@MainActor
enum AppActions {
    /// Set by views that have access to `openWindow`, used when the Dock icon is clicked with no window open.
    static var openMainWindow: (() -> Void)?
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

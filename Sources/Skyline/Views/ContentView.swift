import AppKit
import SwiftUI
import SkylineCore

struct ContentView: View {
    @Environment(WeatherStore.self) private var store

    var body: some View {
        Group {
            if store.isMainWindowOpen {
                windowContent
            } else {
                // Fallback while the closed window is released. Reopen builds this view again.
                Color.black
            }
        }
        .background(WindowVisibilityReader(onChange: { visible in store.setMainWindowVisible(visible) },
                                           onOpenChange: { open in store.setMainWindowOpen(open) }))
        .background(MainWindowRelease())
        .onAppear {
            // MenuBarLabel owns openMainWindow for the life of the app. This window's openWindow
            // goes stale once the window is released.
            AppActions.installSpaceShortcut(store: store)
        }
    }

    @ViewBuilder private var windowContent: some View {
        @Bindable var store = store
        NavigationSplitView {
            SidebarView()
                .id(store.clockStyle) // times re-format when the 12/24-hour setting changes
                .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 380)
        } detail: {
            if let location = store.selectedLocation {
                LocationDetailView(location: location)
                    .id(location.id + "|" + store.clockStyle.rawValue)
            } else {
                EmptyStateView()
            }
        }
        .searchable(text: $store.searchText, placement: .sidebar, prompt: "Search for a city or airport")
        .onChange(of: store.searchText) { _, _ in store.searchTextChanged() }
        .onSubmit(of: .search) { store.submitSearch() } // Return adds the first result (T19)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if store.selectedLocation != nil {
                    Button {
                        if store.radarExpanded { store.radar.isPlaying = false }
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) {
                            store.activeModule = nil
                            store.radarExpanded.toggle()
                        }
                    } label: {
                        // Says what it does now: back to the forecast when the map is expanded (L15).
                        Label(store.radarExpanded ? "Forecast" : "Map", systemImage: store.radarExpanded ? "list.bullet" : "map")
                    }
                    .help(store.radarExpanded ? "Back to the forecast" : "Give the radar map the whole window")
                }
                Button {
                    Task { await store.refreshAll(force: true) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh all locations (⌘R)")
                .disabled(!store.loadingIDs.isEmpty)
            }
        }
        .modifier(HiddenWindowTitle())
        .onAppear {
            // Launch arguments for screenshots/QA: `-SkylineOpenRadar YES`, `-SkylineOpenModule uv`.
            let defaults = UserDefaults.standard
            guard !QAHooksRan.done else { return } // once per launch, not again when the window reopens
            QAHooksRan.done = true
            if defaults.bool(forKey: "SkylineOpenRadar") { store.radarExpanded = true }
            StressTest.runIfRequested(store: store)
            OverscanHitProbe.runIfRequested(store: store)
            MenuSnapshot.runIfRequested(store: store)
            MeasureHooks.runIfRequested(store: store)
            MemoryTest.runIfRequested(store: store)
            if let raw = defaults.string(forKey: "SkylineOpenModule"), let module = DetailModule(rawValue: raw) {
                store.activeModule = ModuleSelection(module: module, day: nil)
            }
            // `-SkylineWindowSize 980x760`: QA/screenshot hook to test the narrow layout.
            if let raw = defaults.string(forKey: "SkylineWindowSize") {
                let parts = raw.lowercased().split(separator: "x").compactMap { Double($0) }
                if parts.count == 2 {
                    DispatchQueue.main.async {
                        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) && $0.frame.height > 300 }) else { return }
                        var frame = window.frame
                        frame.origin.y += frame.height - parts[1]
                        frame.size = CGSize(width: parts[0], height: parts[1])
                        window.setFrame(frame, display: true)
                    }
                }
            }
        }
    }
}

struct EmptyStateView: View {
    var body: some View {
        ZStack {
            SkyPalette.gradient(.partlyCloudy, isDay: true).ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "cloud.sun.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 64))
                Text("Search for a city to get started").font(.title2)
                Text("Use the search field in the sidebar, or allow Location Services for weather where you are.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .foregroundStyle(.white)
            .padding()
        }
    }
}

/// Apple Weather shows no window title; the gradient runs under a transparent toolbar.
private struct HiddenWindowTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .title).toolbarBackground(.hidden, for: .windowToolbar)
        } else {
            content.toolbarBackground(.hidden, for: .windowToolbar)
        }
    }
}

@MainActor
private enum QAHooksRan { static var done = false }

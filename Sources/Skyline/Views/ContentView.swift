import SwiftUI
import SkylineCore

struct ContentView: View {
    @Environment(WeatherStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 380)
        } detail: {
            if let location = store.selectedLocation {
                LocationDetailView(location: location)
                    .id(location.id)
            } else {
                EmptyStateView()
            }
        }
        .searchable(text: $store.searchText, placement: .sidebar, prompt: "Search for a city or airport")
        .onChange(of: store.searchText) { _, _ in store.searchTextChanged() }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let location = store.selectedLocation {
                    Button {
                        store.radarLocation = location
                        openWindow(id: SceneID.radar)
                    } label: {
                        Label("Radar", systemImage: "map")
                    }
                    .help("Open the animated radar map")
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
        .background(WindowVisibilityReader { visible in store.setMainWindowVisible(visible) })
        .onAppear {
            let open = openWindow
            AppActions.openMainWindow = { open(id: SceneID.main) }
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

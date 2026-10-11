import SwiftUI
import SkylineCore

struct SidebarView: View {
    @Environment(WeatherStore.self) private var store

    var body: some View {
        @Bindable var store = store
        List(selection: $store.selectedID) {
            if !store.searchText.isEmpty {
                Section("Search Results") {
                    if store.isSearching && store.searchResults.isEmpty {
                        Text("Searching…").foregroundStyle(.secondary)
                    } else if store.searchResults.isEmpty {
                        Text("No matches").foregroundStyle(.secondary)
                    }
                    ForEach(store.searchResults) { result in
                        Button {
                            store.add(result)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.name).font(.headline)
                                Text([result.admin1, result.country].compactMap { $0 }.joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section {
                ForEach(store.allLocations) { location in
                    SidebarRow(location: location,
                               report: store.reports[location.id],
                               units: store.units,
                               isSelected: store.selectedLocation?.id == location.id)
                        .tag(location.id)
                        .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                        .contextMenu {
                            if !location.isCurrentLocation {
                                Button("Move Up") { store.move(location, by: -1) }
                                Button("Move Down") { store.move(location, by: 1) }
                                Divider()
                                Button("Remove", role: .destructive) { store.remove(location) }
                            }
                        }
                }
            } footer: {
                if store.locationDenied {
                    Text("Location Services is off for Skyline. Enable it in System Settings › Privacy & Security to see weather where you are.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand {
            if let location = store.selectedLocation { store.remove(location) }
        }
        .task {
            // Fill in sidebar temperatures (cheap: served from cache when fresh).
            await store.refreshDue()
        }
    }
}

struct SidebarRow: View {
    let location: WeatherLocation
    let report: WeatherReport?
    let units: UnitPreference
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if location.isCurrentLocation {
                        Image(systemName: "location.fill").font(.caption2)
                    }
                    Text(location.isCurrentLocation ? "My Location" : location.name)
                        .font(.headline)
                        .lineLimit(1)
                }
                Text(location.isCurrentLocation ? location.name : Fmt.time(Date(), location.timeZone))
                    .font(.caption)
                    .opacity(0.85)
                Spacer(minLength: 8)
                Text(report?.current.condition.description ?? " ")
                    .font(.caption)
                    .opacity(0.9)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(units.temperatureString(report?.current.temperature))
                    .font(.system(size: 30, weight: .light))
                Spacer(minLength: 0)
                if let today = report?.today {
                    Text("H:\(units.temperatureString(today.high))  L:\(units.temperatureString(today.low))")
                        .font(.caption)
                }
                if let alert = report?.alerts.first {
                    Label(alert.event, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(10)
        .frame(height: 84)
        .background(SkyPalette.gradient(for: report), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(isSelected ? 0.9 : 0), lineWidth: 2)
        )
        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
    }
}

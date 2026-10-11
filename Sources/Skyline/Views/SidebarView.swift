import SwiftUI
import SkylineCore

/// Sidebar: translucent (the system sidebar vibrancy shows through) and tinted with the selected
/// location's sky, so it reads as one surface with the detail view instead of a flat black column.
/// Location cards carry their own condition gradient, toned down so neighbours harmonise; selection is
/// a thin light edge with a soft glow rather than the system's bright blue highlight.
struct SidebarView: View {
    @Environment(WeatherStore.self) private var store
    @FocusState private var focused: Bool

    var body: some View {
        // A plain List (no selection binding, so no system highlight) keeps the sidebar search field and
        // native scrolling; rows are custom cards on a clear background.
        List {
            Group {
                if !store.searchText.isEmpty { searchResults }
                if store.currentLocation == nil && store.isLocating && !store.locationDenied {
                    LocatingRow()
                }
                ForEach(Array(store.allLocations.enumerated()), id: \.element.id) { index, location in
                    let selected = store.selectedLocation?.id == location.id
                    Button {
                        if store.selectedID != location.id { store.selectedID = location.id }
                        focused = true
                    } label: {
                        SidebarRow(location: location, report: store.reports[location.id],
                                   units: store.units, isSelected: selected)
                    }
                    .buttonStyle(.plain)
                    .help(index < 9 ? "⌘\(index + 1)" : "")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .contextMenu {
                        if !location.isCurrentLocation {
                            Button("Move Up") { store.move(location, by: -1) }
                            Button("Move Down") { store.move(location, by: 1) }
                            Divider()
                            Button("Remove", role: .destructive) { store.remove(location) }
                        }
                    }
                }
                if store.locationDenied {
                    Text("Location Services is off for Skyline. Enable it in System Settings › Privacy & Security to see weather where you are.")
                        .font(.caption)
                        .foregroundStyle(Glass.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.top, 4)
                }
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
        .background { SidebarBackdrop(report: store.selectedLocation.flatMap { store.reports[$0.id] }) }
        .environment(\.colorScheme, .dark)
        // ↑/↓ move between locations while the sidebar has focus (⌘↑/⌘↓ and ⌘1–9 work everywhere).
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { store.selectLocation(offset: -1); return .handled }
        .onKeyPress(.downArrow) { store.selectLocation(offset: 1); return .handled }
        .onDeleteCommand {
            if let location = store.selectedLocation, !location.isCurrentLocation { store.remove(location) }
        }
        .task {
            // Fill in sidebar temperatures (cheap: served from cache when fresh).
            await store.refreshDue()
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        SidebarSectionHeader(title: "Search Results")
        if store.isSearching && store.searchResults.isEmpty {
            Text("Searching…").font(.callout).foregroundStyle(Glass.secondaryText).padding(.horizontal, 6)
        } else if store.searchResults.isEmpty {
            Text("No matches").font(.callout).foregroundStyle(Glass.secondaryText).padding(.horizontal, 6)
        }
        ForEach(store.searchResults) { result in
            Button { store.add(result) } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.name).font(.headline)
                        Text([result.admin1, result.country].compactMap { $0 }.joined(separator: ", "))
                            .font(.caption).foregroundStyle(Glass.secondaryText)
                    }
                    Spacer()
                    Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(.white.opacity(0.7))
                }
                .foregroundStyle(.white)
                .padding(10)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        SidebarSectionHeader(title: "Locations").padding(.top, 6)
    }
}

private struct SidebarSectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(Glass.secondaryText)
            .padding(.horizontal, 6)
    }
}

/// Translucent sky tint behind the sidebar: the selected location's gradient at partial opacity over the
/// system sidebar material, darkened a touch so the cards on top stand out.
struct SidebarBackdrop: View {
    let report: WeatherReport?

    var body: some View {
        ZStack {
            SkyPalette.gradient(for: report).opacity(0.55)
            LinearGradient(colors: [.black.opacity(0.30), .black.opacity(0.12)], startPoint: .top, endPoint: .bottom)
        }
        .overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.06)).frame(width: 0.5) }
        .animation(.easeInOut(duration: 0.6), value: report?.current.condition.category)
        .ignoresSafeArea()
    }
}

/// Placeholder shown until the first location fix arrives (instead of the row silently missing).
struct LocatingRow: View {
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Label("My Location", systemImage: "location.fill").font(.headline)
                Text("Finding your location…").font(.caption).foregroundStyle(Glass.secondaryText)
            }
            Spacer()
            ProgressView().controlSize(.small)
        }
        .foregroundStyle(.white)
        .padding(12)
        .frame(height: 78)
        .background(SidebarRow.cardFill(SkyPalette.gradient(.partlyCloudy, isDay: true), selected: false))
        .accessibilityLabel("My Location, finding your location")
    }
}

struct SidebarRow: View {
    let location: WeatherLocation
    let report: WeatherReport?
    let units: UnitPreference
    let isSelected: Bool
    @State private var hovering = false

    static let radius: CGFloat = 14

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if location.isCurrentLocation {
                        Image(systemName: "location.fill").font(.system(size: 10, weight: .semibold))
                    }
                    Text(location.isCurrentLocation ? "My Location" : location.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                }
                Text(location.isCurrentLocation ? location.name : Fmt.time(Date(), location.timeZone))
                    .font(.caption)
                    .foregroundStyle(Glass.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 2)
                if let alert = report?.activeAlerts().first {
                    Label(alert.event, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AlertsCard.color(alert.severity))
                        .lineLimit(1)
                } else {
                    Text(report?.current.condition.description ?? " ")
                        .font(.caption)
                        .foregroundStyle(Glass.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 2)
            VStack(alignment: .trailing, spacing: 1) {
                HStack(alignment: .center, spacing: 6) {
                    if let report {
                        WeatherSymbol(condition: report.current.condition, isDay: report.current.isDay, size: 18)
                    }
                    Text(units.temperatureString(report?.current.temperature))
                        .font(.system(size: 28, weight: .light))
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
                if let today = report?.today {
                    Text("H:\(units.temperatureString(today.high))  L:\(units.temperatureString(today.low))")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Glass.secondaryText)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(height: 78)
        .background(Self.cardFill(SkyPalette.gradient(for: report), selected: isSelected, hovering: hovering))
        .overlay {
            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .strokeBorder(.white.opacity(isSelected ? 0.55 : (hovering ? 0.16 : 0.07)), lineWidth: isSelected ? 1 : 0.5)
        }
        .shadow(color: .white.opacity(isSelected ? 0.16 : 0), radius: 8)
        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .onHover { h in if h != hovering { hovering = h } }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.2), value: isSelected)
    }

    /// The card's condition gradient, slightly darkened (more when not selected) with a soft top sheen,
    /// so different skies sit together without the brightest card shouting.
    static func cardFill(_ gradient: LinearGradient, selected: Bool, hovering: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return ZStack {
            shape.fill(gradient)
            shape.fill(Color.black.opacity(selected ? 0.08 : (hovering ? 0.18 : 0.26)))
            shape.fill(LinearGradient(colors: [.white.opacity(0.10), .clear], startPoint: .top, endPoint: .center))
        }
    }
}

import AppKit
import SwiftUI
import SkylineCore

/// Sidebar: translucent (the system sidebar vibrancy shows through) and tinted with the selected
/// location's sky, so it reads as one surface with the detail view instead of a flat black column.
/// Location cards carry their own condition gradient, toned down so neighbours harmonise; selection is
/// a thin light edge with a soft glow rather than the system's bright blue highlight.
struct SidebarView: View {
    @Environment(WeatherStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    @FocusState private var focused: Bool
    @State private var typed = ""
    @State private var typedAt = Date.distantPast

    var body: some View {
        // A plain List (no selection binding, so no system highlight) keeps the sidebar search field and
        // native scrolling; rows are custom cards on a clear background.
        List {
            Group {
                if !store.searchText.isEmpty { searchResults }
                if store.currentLocation == nil && store.isLocating && !store.locationDenied {
                    LocatingRow()
                } else if store.currentLocation == nil && store.locationUnavailable && !store.locationDenied {
                    Text("Couldn’t find your location yet. Skyline keeps trying; check Location Services in System Settings › Privacy & Security if this stays.")
                        .font(.caption)
                        .foregroundStyle(Glass.secondaryText)
                        .padding(.horizontal, 6)
                }
                if let current = store.currentLocation {
                    row(current, index: 0)
                }
                // Saved cities: drag to reorder (T19). My Location stays pinned on top.
                let offset = store.currentLocation == nil ? 0 : 1
                ForEach(Array(store.savedLocations.enumerated()), id: \.element.id) { index, location in
                    row(location, index: index + offset)
                }
                .onMove { source, destination in store.moveSaved(fromOffsets: source, toOffset: destination) }
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
        // The sidebar search field lives inside this view, so these handlers see its keystrokes first.
        // While any text field is being edited they must pass keys through, or typing a city name does
        // nothing (bug in build 24: L17 returned .handled for every letter).
        .onKeyPress(.upArrow) {
            guard !Self.isEditingText else { return .ignored }
            store.selectLocation(offset: -1); return .handled
        }
        .onKeyPress(.downArrow) {
            guard !Self.isEditingText else { return .ignored }
            store.selectLocation(offset: 1); return .handled
        }
        // Type a city's first letters to jump to it, like a standard Mac list (L17).
        .onKeyPress(characters: .alphanumerics, phases: .down) { press in
            guard !Self.isEditingText, press.modifiers.intersection([.command, .control, .option]).isEmpty else { return .ignored }
            let now = Date()
            typed = now.timeIntervalSince(typedAt) < 1.0 ? typed + press.characters : press.characters
            typedAt = now
            let list = store.allLocations
            guard let i = LocationList.typeSelect(typed, in: list.map { $0.isCurrentLocation ? "My Location" : $0.name }) else {
                return .ignored // no match: let the key through (system beep), don't eat it (QA #4)
            }
            store.selectedID = list[i].id
            return .handled
        }
        .onDeleteCommand {
            // Undoable with ⌘Z (T19).
            if let location = store.selectedLocation, !location.isCurrentLocation {
                store.remove(location, undoManager: undoManager)
            }
        }
        .task {
            // Fill in sidebar temperatures (cheap: served from cache when fresh).
            await store.refreshDue()
        }
    }

    /// True while a text field (the city search) has the keyboard: AppKit's field editor is first responder.
    static var isEditingText: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSText || responder is NSTextField
    }

    private func row(_ location: WeatherLocation, index: Int) -> some View {
        let selected = store.selectedLocation?.id == location.id
        return Button {
            if store.selectedID != location.id { store.selectedID = location.id }
            focused = true
        } label: {
            SidebarRow(location: location, report: store.reports[location.id],
                       units: store.units, isSelected: selected,
                       inMenuBar: store.menuBarLocation?.id == location.id,
                       status: store.reports[location.id] != nil ? nil
                           : (store.errors[location.id] != nil ? "Couldn’t update · retrying"
                              : (store.isLoading(location) ? "Updating…" : nil)))
        }
        .buttonStyle(.plain)
        .help(index < 9 ? "⌘\(index + 1)" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            if store.menuBarPinID == location.id {
                Button("Stop Pinning to Menu Bar") { store.menuBarPinID = nil }
            } else {
                Button("Show in Menu Bar") { store.menuBarPinID = location.id }
            }
            if !location.isCurrentLocation {
                Divider()
                Button("Move Up") { store.move(location, by: -1) }
                Button("Move Down") { store.move(location, by: 1) }
                Divider()
                Button("Remove", role: .destructive) { store.remove(location, undoManager: undoManager) }
            }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        SidebarSectionHeader(title: "Search Results")
        // Every outcome says something (Brian, Oct 17: adding a city failed silently).
        if let status = store.searchStatus {
            VStack(alignment: .leading, spacing: 6) {
                switch status.kind {
                case .failed:
                    Label(status.message, systemImage: "wifi.exclamationmark").font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                case .noResults:
                    Label(status.message, systemImage: "magnifyingglass").font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                case .searching:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(status.message).font(.callout).foregroundStyle(Glass.secondaryText)
                    }
                case .hint, .chooseOne:
                    Text(status.message).font(.callout).foregroundStyle(Glass.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let detail = status.detail {
                    Text(detail).font(.caption).foregroundStyle(Glass.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if status.canRetry { Button("Try Again") { store.retrySearch() } }
            }
            .padding(.horizontal, 6)
        }
        ForEach(store.searchResults) { result in
            Button { store.add(result) } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.name).font(.headline)
                        Text(result.subtitle)
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
    let units: DisplayUnits
    let isSelected: Bool
    var inMenuBar = false
    /// Shown instead of the condition while there's no data yet ("Updating…", "Couldn’t update").
    var status: String? = nil
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
                    if inMenuBar {
                        Image(systemName: "menubar.rectangle").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Glass.secondaryText)
                            .help("Shown in the menu bar")
                    }
                }
                if location.isCurrentLocation {
                    Text(location.name).font(.caption).foregroundStyle(Glass.secondaryText).lineLimit(1)
                } else {
                    // Ticks with the clock instead of waiting for the next data refresh (L14).
                    TimelineView(.everyMinute) { context in
                        Text(Fmt.time(context.date, location.timeZone))
                            .font(.caption).foregroundStyle(Glass.secondaryText).lineLimit(1)
                    }
                }
                Spacer(minLength: 2)
                if let alert = report?.activeAlerts().first {
                    Label(alert.event, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AlertsCard.color(alert.severity))
                        .lineLimit(1)
                } else {
                    Text(report?.current.condition.description ?? status ?? " ")
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
                    Text(units.temperatureString(report?.current.temperature, withUnit: true))
                        .font(.system(size: 28, weight: .light))
                        .monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                Spacer(minLength: 0)
                if let today = report?.today {
                    Text("H:\(units.temperatureString(today.high, withUnit: true))  L:\(units.temperatureString(today.low, withUnit: true))")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Glass.secondaryText)
                        .lineLimit(1).minimumScaleFactor(0.7)
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

    /// The card's condition gradient, darkened at least `SkyColors.cardScrim` (selected cards too: the
    /// selection shows as the light edge and glow, not a brighter, less readable card), a bottom scrim
    /// under the H/L line, and a soft top sheen. Keeps white text ≥ 4.5:1 on every sky (T6, tested).
    static func cardFill(_ gradient: LinearGradient, selected: Bool, hovering: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let wash = selected || hovering ? SkyColors.cardScrim : SkyColors.cardScrim + 0.06
        return ZStack {
            shape.fill(gradient)
            shape.fill(Color.black.opacity(wash))
            shape.fill(LinearGradient(colors: [.clear, .black.opacity(SkyColors.cardBottomScrim)],
                                      startPoint: .center, endPoint: .bottom))
            shape.fill(LinearGradient(colors: [.white.opacity(0.06), .clear], startPoint: .top, endPoint: .center))
        }
    }
}

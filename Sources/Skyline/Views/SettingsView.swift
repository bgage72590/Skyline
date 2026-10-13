import AppKit
import ServiceManagement
import SwiftUI
import SkylineCore

/// Settings (⌘, or the gear in the dropdown): menu-bar basics (T10), units and clock (T20), refresh.
struct SettingsView: View {
    @Environment(WeatherStore.self) private var store
    @AppStorage(DockIcon.key) private var showInDock = true
    @AppStorage(GlobalHotkey.key) private var globalHotkey = false
    @State private var loginItem = LoginItem.status()
    @State private var loginError: String?

    var body: some View {
        @Bindable var store = store
        Form {
            Section("General") {
                Toggle("Open Skyline at login", isOn: Binding(
                    get: { loginItem == .enabled || loginItem == .requiresApproval },
                    set: { on in
                        loginError = LoginItem.set(on)
                        loginItem = LoginItem.status()
                    }))
                if loginItem == .requiresApproval {
                    HStack {
                        Text("Allow Skyline in System Settings › General › Login Items.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Open") { SMAppService.openSystemSettingsLoginItems() }
                            .controlSize(.small)
                    }
                }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.orange)
                }
                Toggle("Show Skyline in the Dock", isOn: $showInDock)
                    .onChange(of: showInDock) { _, _ in DockIcon.apply() }
                if !showInDock {
                    Text("Skyline stays in the menu bar; open the window from there. Closing the window or ⌘Q always leaves it there; use Quit Skyline in the dropdown to exit.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Open the menu-bar forecast with \(GlobalHotkey.label) from any app", isOn: $globalHotkey)
                    .onChange(of: globalHotkey) { _, _ in GlobalHotkey.apply() }
                Picker("Menu bar shows", selection: $store.menuBarPinID) {
                    Text(store.currentLocation == nil ? "Automatic (first city)" : "Automatic (My Location)")
                        .tag(String?.none)
                    Divider()
                    if store.currentLocation != nil {
                        Text("My Location").tag(Optional(WeatherLocation.currentLocationID))
                    }
                    ForEach(store.savedLocations) { location in
                        Text(location.name).tag(Optional(location.id))
                    }
                }
            }

            NotificationSettings()

            Section("Units") {
                Picker("Preset", selection: $store.unitPreset) {
                    ForEach(UnitPreference.allCases) { Text($0.label).tag($0) }
                }
                unitPicker("Temperature", $store.temperatureUnit, preset: store.unitPreset.units.temperature)
                unitPicker("Wind", $store.speedUnit, preset: store.unitPreset.units.speed)
                unitPicker("Rain", $store.precipitationUnit, preset: store.unitPreset.units.precipitation)
                unitPicker("Pressure", $store.pressureUnit, preset: store.unitPreset.units.pressure)
                unitPicker("Visibility", $store.distanceUnit, preset: store.unitPreset.units.distance)
                Picker("Time", selection: $store.clockStyle) {
                    ForEach(ClockStyle.allCases) { Text($0.label).tag($0) }
                }
            }

            Section("Updates") {
                Picker("Refresh every", selection: $store.refreshMinutes) {
                    Text("10 minutes").tag(10)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("60 minutes").tag(60)
                }
                Text("With only the menu bar open, Skyline refreshes the menu-bar city about half as often.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Data sources") {
                Text("Forecasts blend Open-Meteo models (best match, NOAA HRRR, ECMWF IFS, NOAA GFS, DWD ICON) with the official National Weather Service forecast in the US. Alerts from NWS. Radar from NOAA NEXRAD via Iowa Environmental Mesonet (US) and RainViewer (global). All free, no API keys.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 640)
        .padding()
        .onAppear { loginItem = LoginItem.status() }
        // Approving Skyline in System Settings happens in another app: re-check when Skyline is active again.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem = LoginItem.status()
        }
    }

    /// "Automatic (°F)" follows the preset; any other choice overrides just this dimension.
    private func unitPicker<U: Hashable & Identifiable & CaseIterable>(
        _ title: String, _ selection: Binding<U?>, preset: U
    ) -> some View where U.AllCases: RandomAccessCollection, U: UnitLabelled {
        Picker(title, selection: selection) {
            Text("Automatic (\(preset.label))").tag(U?.none)
            ForEach(Array(U.allCases)) { unit in Text(unit.label).tag(Optional(unit)) }
        }
    }
}

/// Settings → Notifications (T8, L19). Everything starts off; the first switch turned on asks macOS for
/// permission. Severe warnings cover the point (storm polygons are checked), rain notices come from the
/// 15-minute nowcast, and quiet hours hold back everything except extreme warnings.
struct NotificationSettings: View {
    @Environment(WeatherStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Section {
            Toggle("Weather warnings", isOn: on(\.alerts))
            if store.notificationPrefs.alerts {
                Picker("Notify for", selection: $store.notificationPrefs.minimumSeverity) {
                    Text("Extreme only (e.g. tornado warnings)").tag(AlertSeverity.extreme)
                    Text("Severe and extreme").tag(AlertSeverity.severe)
                    Text("Moderate and up (wind, winter advisories)").tag(AlertSeverity.moderate)
                    Text("All alerts (incl. frost, flood advisories)").tag(AlertSeverity.minor)
                }
            }
            Toggle("Rain starting or stopping", isOn: on(\.rain))
            Toggle("Morning briefing", isOn: on(\.morningBriefing))
            if store.notificationPrefs.morningBriefing {
                DatePicker("Briefing time", selection: minutes(\.briefingMinutes), displayedComponents: .hourAndMinute)
            }
            Toggle("Quiet hours", isOn: $store.notificationPrefs.quietHours)
            if store.notificationPrefs.quietHours {
                DatePicker("From", selection: minutes(\.quietStartMinutes), displayedComponents: .hourAndMinute)
                DatePicker("Until", selection: minutes(\.quietEndMinutes), displayedComponents: .hourAndMinute)
            }
            if store.notificationPrefs.alerts || store.notificationPrefs.rain {
                ForEach(store.allLocations) { location in
                    Toggle(isOn: Binding(get: { store.notifies(location) }, set: { store.setNotifies(location, $0) })) {
                        Text("Notify for \(location.name)")
                    }
                }
            }
            if store.notificationPermission == false {
                HStack {
                    Text("Notifications for Skyline are turned off in System Settings.")
                        .font(.caption).foregroundStyle(.orange)
                    Button("Open") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Rain notices use the 15-minute nowcast, so timing is approximate. Quiet hours hold back everything except extreme warnings, and the morning briefing comes for the menu-bar city.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// A switch that asks for permission when it's turned on.
    private func on(_ key: WritableKeyPath<NotificationPrefs, Bool>) -> Binding<Bool> {
        Binding(get: { store.notificationPrefs[keyPath: key] }, set: { value in
            store.notificationPrefs[keyPath: key] = value
            if value { Task { await store.ensureNotificationPermission() } }
        })
    }

    /// Minutes after midnight shown as a time of day.
    private func minutes(_ key: WritableKeyPath<NotificationPrefs, Int>) -> Binding<Date> {
        Binding(get: {
            // Wall-clock hour and minute (not "midnight + N minutes"), so 10 PM still reads 10 PM on the
            // DST change days (Code Reviewer / QA batch 4).
            let m = store.notificationPrefs[keyPath: key]
            return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            store.notificationPrefs[keyPath: key] = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        })
    }
}

protocol UnitLabelled { var label: String { get } }
extension TemperatureUnit: UnitLabelled {}
extension SpeedUnit: UnitLabelled {}
extension PrecipitationUnit: UnitLabelled {}
extension PressureUnit: UnitLabelled {}
extension DistanceUnit: UnitLabelled {}

/// "Show in Dock" (T10): `.accessory` hides the Dock icon and app menu; the menu-bar extra stays, so
/// Skyline is always reachable. Applied at launch and whenever the setting changes.
@MainActor
enum DockIcon {
    static let key = "showInDock"

    static func apply() {
        let show = UserDefaults.standard.object(forKey: key) as? Bool ?? true
        let policy: NSApplication.ActivationPolicy = show ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // Switching policy can drop the window behind other apps; bring Skyline back.
        DispatchQueue.main.async { NSApp.activate() }
    }
}

/// Open at login via SMAppService (T10). Off unless Brian turns it on in Settings.
enum LoginItem {
    static func status() -> SMAppService.Status { SMAppService.mainApp.status }

    /// Returns a readable error, or nil on success.
    static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return "Couldn’t change the login item: \(error.localizedDescription)"
        }
    }
}

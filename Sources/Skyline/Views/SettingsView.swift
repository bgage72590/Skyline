import AppKit
import ServiceManagement
import SwiftUI
import SkylineCore

/// Settings (⌘, or the gear in the dropdown): menu-bar basics (T10), units and clock (T20), refresh.
struct SettingsView: View {
    @Environment(WeatherStore.self) private var store
    @AppStorage(DockIcon.key) private var showInDock = true
    @AppStorage(GlobalHotkey.key) private var globalHotkey = false
    @State private var hotkeyError: String? = GlobalHotkey.lastError
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
                    Text("Skyline stays in the menu bar (no Dock icon). While the main window or Settings is open, Skyline’s menus appear in the system menu bar; Update Skyline… is also in the menu-bar dropdown. Closing the window or ⌘Q hides the Dock icon again; use Quit Skyline in the dropdown to exit.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Open the menu-bar forecast with \(GlobalHotkey.label) from any app", isOn: $globalHotkey)
                    .onChange(of: globalHotkey) { _, on in
                        if on {
                            // Taken by another app: show why and flip the toggle back off (QA batch 6 H1).
                            if GlobalHotkey.apply() { hotkeyError = nil } else { hotkeyError = GlobalHotkey.lastError; globalHotkey = false }
                        } else {
                            GlobalHotkey.apply() // keeps a failure message visible after the flip back
                        }
                    }
                if let hotkeyError {
                    Text(hotkeyError).font(.caption).foregroundStyle(.orange)
                }
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

            SyncSection()

            PrivacyEnergySection()

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

/// "Show in Dock" (T10): `.accessory` hides the Dock icon when Skyline is menu-bar-only. While the
/// main window or Settings is up we switch to `.regular` so the system menu bar shows Skyline's menus
/// (Update Skyline…, Weather, …) even with the Dock icon preference off; closing the window goes
/// back to `.accessory` (Brian, Oct 14).
@MainActor
enum DockIcon {
    static let key = "showInDock"

    /// True when Show-in-Dock is on (default).
    static var prefersDockIcon: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    /// Windows that need the app menu bar (main Skyline window or Settings).
    static func needsMenuBar(openMainWindow: Bool? = nil) -> Bool {
        if let openMainWindow, openMainWindow { return true }
        for w in NSApp.windows where w.isVisible {
            if AppExit.isAppWindow(w) { return true }
            // SwiftUI Settings window titles vary; the Settings scene uses this bundle's settings.
            if w.frameAutosaveName.contains("com_apple_SwiftUI_Settings") || w.title == "Settings"
                || w.title.hasPrefix("Settings") { return true }
        }
        return false
    }

    static func apply(openMainWindow: Bool? = nil) {
        let wantRegular = prefersDockIcon || needsMenuBar(openMainWindow: openMainWindow)
        let policy: NSApplication.ActivationPolicy = wantRegular ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // Switching policy can drop the window behind other apps; bring Skyline back when we just
        // became regular for a window. Going accessory: don't activate (nothing to show).
        if wantRegular {
            DispatchQueue.main.async { NSApp.activate() }
        }
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

/// Settings › Privacy & energy (L23): what Skyline keeps, a reset, and how much it's doing.
/// Polish 1 and 2: where cities and settings sync, and updating from the build Mac's iCloud zip.
struct SyncSection: View {
    @Environment(WeatherStore.self) private var store

    var body: some View {
        // Pass the singleton into a child so @Observable tracks lastSynced / lastError (QA #7).
        if let sync = SyncCoordinator.shared {
            SyncSectionBody(store: store, sync: sync)
        } else {
            Section("Sync & updates") {
                Text("iCloud Drive is off on this Mac; cities stay on this Mac.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

struct SyncSectionBody: View {
    var store: WeatherStore
    var sync: SyncCoordinator
    private let updates = UpdateActivity.shared

    var body: some View {
        Section("Sync & updates") {
            Text("Your cities, units, clock, refresh interval, menu-bar city and notification choices sync through iCloud Drive (Skyline/sync.json) to every Mac signed in to your Apple Account. Nothing is lost when two Macs change things: cities are merged. Status updates when another Mac writes (or on Sync Now); relative time refreshes below.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    Group {
                        if let error = sync.lastError {
                            Text(error).font(.caption).foregroundStyle(.orange)
                        } else if let date = sync.lastSynced {
                            Text("Synced \(date.formatted(.relative(presentation: .named))) · \(store.savedLocations.count) cities")
                                .font(.caption).foregroundStyle(.secondary)
                                .id(context.date) // refresh the relative phrase
                        }
                    }
                }
                Spacer()
                Button("Sync Now") { sync.pushNow() }
                    .disabled(sync.fileURL == nil)
            }
            HStack {
                Text("Build \(Updater.installedBuild)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(updates.downloadingTitle ?? "Update Skyline…") { Updater.checkForUpdates() }
                    .disabled(updates.isPending)
            }
        }
    }
}

struct PrivacyEnergySection: View {
    @Environment(WeatherStore.self) private var store
    @State private var confirmReset = false
    @State private var didReset = false

    var body: some View {
        Section("Privacy & energy") {
            Text("Skyline keeps up to 90 days of forecast-accuracy history for your cities (city-level, about 1 km) and a 14-day download cache, in your user Library. Time Machine backs them up. Nothing is sent anywhere except the weather services listed below; there is no tracking.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(didReset ? "Accuracy data reset" : "Reset Accuracy Data…") { confirmReset = true }
                    .disabled(didReset)
                Spacer()
            }
            .confirmationDialog("Reset accuracy data?", isPresented: $confirmReset) {
                Button("Reset", role: .destructive) {
                    Task { await store.resetAccuracyData(); didReset = true }
                }
            } message: {
                Text("Skyline forgets what it has learned about which forecast is most accurate for each city and starts again. Forecasts use equal weights until about 3 days are collected.")
            }
            if let error = store.widgetError {
                Text("Widgets can’t get new data: \(error)").font(.caption).foregroundStyle(.orange)
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(EnergyLine.text(now: context.date)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

/// "142 requests since launch (about 18 an hour) · CPU 0.1% on average" from this process's own counters.
enum EnergyLine {
    static func text(now: Date) -> String {
        let stats = RequestStats.shared
        var line = "\(stats.total) requests since launch"
        if let h = stats.perHour(now: now) { line += " (about \(Int(h.rounded())) an hour)" }
        if let cpu = averageCPU() { line += String(format: " · CPU %.1f%% on average", cpu) }
        return line
    }

    /// CPU time used / time since launch, in % of one core.
    static func averageCPU() -> Double? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        let wall = Date().timeIntervalSince(RequestStats.shared.since)
        return wall > 60 ? cpu / wall * 100 : nil
    }
}

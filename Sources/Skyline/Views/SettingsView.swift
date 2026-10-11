import AppKit
import ServiceManagement
import SwiftUI
import SkylineCore

/// Settings (⌘, or the gear in the dropdown): menu-bar basics (T10), units and clock (T20), refresh.
struct SettingsView: View {
    @Environment(WeatherStore.self) private var store
    @AppStorage(DockIcon.key) private var showInDock = true
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
                    Text("Skyline stays in the menu bar; open the window from there.")
                        .font(.caption).foregroundStyle(.secondary)
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
        .frame(width: 480)
        .padding()
        .onAppear { loginItem = LoginItem.status() }
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

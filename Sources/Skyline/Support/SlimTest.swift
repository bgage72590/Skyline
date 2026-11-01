import AppKit
import Foundation
import SkylineCore

/// Launch arguments from the argument domain only. A persisted default with the same name does not count.
enum LaunchArguments {
    static func value(_ key: String) -> Any? {
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[key]
    }

    static func string(_ key: String) -> String? {
        switch value(key) {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    /// `-SkylineSlimMode NO` (argument domain). YES and a missing argument do not force the window.
    static var slimModeNo: Bool {
        guard let raw = value("SkylineSlimMode") else { return false }
        if let n = raw as? NSNumber {
            let boolean = CFGetTypeID(n) == CFBooleanGetTypeID() || String(cString: n.objCType) == "c"
            if boolean { return n.boolValue == false }
            let text = n.stringValue.lowercased()
            return text == "no" || text == "false" || text == "0"
        }
        if let s = raw as? String {
            let text = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return text == "no" || text == "false" || text == "0"
        }
        return false
    }

    static func int(_ key: String) -> Int? {
        switch value(key) {
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
        default: return nil
        }
    }

    static func double(_ key: String) -> Double? {
        switch value(key) {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s.trimmingCharacters(in: .whitespacesAndNewlines))
        default: return nil
        }
    }

    /// Present, and not an explicit NO. Bare YES and a boolean true both count.
    static func enabled(_ key: String) -> Bool {
        guard value(key) != nil else { return false }
        let text = string(key)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return text != "no" && text != "false" && text != "0"
    }
}

@MainActor
enum SlimLog {
    static func line(_ text: String) {
        print(text)
        fflush(stdout)
    }

    static func waitFromLaunch(_ seconds: Double) async {
        let remain = seconds - Date().timeIntervalSince(SlimLaunchRuntime.didFinishAt)
        if remain > 0 { try? await Task.sleep(for: .seconds(remain)) }
    }
}

@MainActor
enum SlimWindows {
    /// Identifier only (`main` or `main-…`). The updater's progress window is also titled Skyline.
    static var count: Int {
        NSApp.windows.filter { window in
            let id = window.identifier?.rawValue ?? ""
            return id == SceneID.main || id.hasPrefix("main-")
        }.count
    }

    static func policyLabel(_ policy: NSApplication.ActivationPolicy) -> String {
        switch policy {
        case .regular: return "regular"
        case .accessory: return "accessory"
        case .prohibited: return "prohibited"
        @unknown default: return "other(\(policy.rawValue))"
        }
    }

    /// Closed: regular when Show in Dock is on (absent counts as on), otherwise accessory.
    /// Open: regular either way, because the window needs the menu bar.
    static func expectedPolicy(windows: Int) -> NSApplication.ActivationPolicy {
        if windows > 0 || DockIcon.prefersDockIcon { return .regular }
        return .accessory
    }

    static func fields(expected: Int) -> String {
        let open = IntentStore.shared?.isMainWindowOpen == true ? 1 : 0
        return "n=\(count) expected=\(expected) appear=\(ContentAppear.count) open=\(open) policy=\(policyLabel(NSApp.activationPolicy()))"
    }
}

/// `-SkylineSlimCheck`, `-SkylineSlimSettingsTest`, and `-SkylineSlimMenuTest`.
@MainActor
enum SlimHooks {
    static func runIfRequested() {
        if let seconds = LaunchArguments.double("SkylineSlimCheck") {
            let expect = LaunchArguments.int("SkylineExpectWindows")
            Task { @MainActor in await SlimCheck.run(seconds: seconds, expectOverride: expect) }
        }
        if LaunchArguments.enabled("SkylineSlimSettingsTest") {
            Task { @MainActor in await SlimSettings.run() }
        }
        if LaunchArguments.enabled("SkylineSlimMenuTest") {
            Task { @MainActor in await SlimMenu.run() }
        }
    }
}

@MainActor
enum SlimCheck {
    static func run(seconds: Double, expectOverride: Int?) async {
        let expected = expectOverride ?? (SlimLaunchRuntime.decision?.opensWindow == false ? 0 : 1)
        var times = [3.0]
        if seconds != 3 { times.append(seconds) }
        times.sort()
        var reasons: [String] = []
        for t in times {
            await SlimLog.waitFromLaunch(t)
            for reason in sample(expected: expected, at: t) where !reasons.contains(reason) {
                reasons.append(reason)
            }
        }
        let unique = reasons
        let fields = SlimWindows.fields(expected: expected) + " t=\(times.map { String(format: "%g", $0) }.joined(separator: ","))"
        if unique.isEmpty {
            SlimLog.line("[slim] PASS \(fields)")
        } else {
            SlimLog.line("[slim] FAIL reason=\(unique.joined(separator: ";")) \(fields)")
        }
    }

    private static func sample(expected: Int, at t: Double) -> [String] {
        var reasons: [String] = []
        let n = SlimWindows.count
        let mark = "t=\(String(format: "%g", t))"
        if n != expected { reasons.append("windows \(mark)") }
        if ContentAppear.count != n { reasons.append("appear \(mark)") }
        if expected > 0 && SlimLaunchRuntime.handlerMissing { reasons.append("handler missing") }
        guard let store = IntentStore.shared else { return reasons + ["store"] }
        if store.isMainWindowOpen != (expected > 0) { reasons.append("open \(mark)") }
        let policy = NSApp.activationPolicy()
        if policy != SlimWindows.expectedPolicy(windows: expected) { reasons.append("policy \(mark)") }
        return reasons
    }
}

/// Open Settings from the dropdown path and check the activation policy before, during, and after.
@MainActor
enum SlimSettings {
    static func run() async {
        await SlimLog.waitFromLaunch(0.5)
        var reasons: [String] = []
        let before = SlimWindows.expectedPolicy(windows: 0)
        if NSApp.activationPolicy() != before {
            reasons.append("before policy=\(SlimWindows.policyLabel(NSApp.activationPolicy())) expected=\(SlimWindows.policyLabel(before))")
        }
        AppExit.openSettings()
        let opened = await waitForSettings(seconds: 2)
        if !opened { reasons.append("settings not open") }
        if NSApp.activationPolicy() != .regular {
            reasons.append("during policy=\(SlimWindows.policyLabel(NSApp.activationPolicy()))")
        }
        AppExit.closeWindows()
        let afterOK = await waitForPolicy(before, seconds: 1)
        if !afterOK {
            reasons.append("after policy=\(SlimWindows.policyLabel(NSApp.activationPolicy())) expected=\(SlimWindows.policyLabel(before))")
        }
        let fields = SlimWindows.fields(expected: SlimWindows.count)
        if reasons.isEmpty {
            SlimLog.line("[slim] settings PASS \(fields)")
        } else {
            SlimLog.line("[slim] settings FAIL reason=\(reasons.joined(separator: ";")) \(fields)")
        }
    }

    private static func settingsVisible() -> Bool {
        NSApp.windows.contains { window in
            guard window.isVisible else { return false }
            if window.frameAutosaveName.contains("com_apple_SwiftUI_Settings") { return true }
            return window.title == "Settings" || window.title.hasPrefix("Settings")
        }
    }

    private static func waitForSettings(seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if settingsVisible() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return settingsVisible()
    }

    private static func waitForPolicy(_ expected: NSApplication.ActivationPolicy, seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if NSApp.activationPolicy() == expected { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return NSApp.activationPolicy() == expected
    }
}

/// App-menu commands with no window. Fails if a main window appears or the synced snapshot changes.
@MainActor
enum SlimMenu {
    static func run() async {
        await SlimLog.waitFromLaunch(1)
        guard let store = IntentStore.shared else {
            SlimLog.line("[slim] menu FAIL reason=store n=0")
            return
        }
        let before = snapshot(store)
        var reasons: [String] = []
        if SlimWindows.count != 0 { reasons.append("window at start n=\(SlimWindows.count)") }
        let commands: [(String, () -> NSMenuItem?)] = [
            ("Show Radar Map", { item(titled: "Show Radar Map") }),
            ("Next Location", { item(titled: "Next Location") }),
            ("Previous Location", { item(titled: "Previous Location") }),
            ("⌘1", { commandDigit(1) }),
            ("Play Radar", { item(titled: "Play Radar") }),
            ("Close Skyline Window", { item(titled: "Close Skyline Window") })
        ]
        for (name, find) in commands {
            guard let item = await waitItem(find, seconds: 2) else {
                reasons.append("missing \(name)")
                continue
            }
            if !item.isEnabled { reasons.append("disabled \(name)") }
            if !fire(item) { reasons.append("unfired \(name)") }
            try? await Task.sleep(for: .milliseconds(200))
            if SlimWindows.count != 0 { reasons.append("window after \(name) n=\(SlimWindows.count)") }
        }
        let after = snapshot(store)
        if before.units != after.units { reasons.append("units") }
        if before.cities != after.cities { reasons.append("cities") }
        // Next / Previous / ⌘1 change the selected city in memory. The snapshot includes that id,
        // so a command list that does not end on the starting city fails here.
        if before.selection != after.selection { reasons.append("selection") }
        if before.sync != after.sync { reasons.append("sync") }
        let fields = "n=\(SlimWindows.count) appear=\(ContentAppear.count) selection=\(after.selection ?? "nil")"
        if reasons.isEmpty {
            SlimLog.line("[slim] menu PASS \(fields)")
        } else {
            SlimLog.line("[slim] menu FAIL reason=\(reasons.joined(separator: ";")) \(fields)")
        }
    }

    private struct Snap: Equatable {
        var units: String
        var cities: [WeatherLocation]
        var selection: String?
        var sync: [String: String]
    }

    private static func snapshot(_ store: WeatherStore) -> Snap {
        let units = [
            store.unitPreset.rawValue,
            store.temperatureUnit?.rawValue ?? "",
            store.speedUnit?.rawValue ?? "",
            store.precipitationUnit?.rawValue ?? "",
            store.pressureUnit?.rawValue ?? "",
            store.distanceUnit?.rawValue ?? "",
            store.clockStyle.rawValue,
            String(store.refreshMinutes)
        ].joined(separator: "|")
        let sync = SyncCoordinator.shared?.currentSettings() ?? [:]
        return Snap(units: units, cities: store.savedLocations, selection: store.selectedID, sync: sync)
    }

    private static func item(titled title: String) -> NSMenuItem? {
        find { $0.title == title }
    }

    private static func commandDigit(_ n: Int) -> NSMenuItem? {
        find { $0.keyEquivalent == "\(n)" && $0.keyEquivalentModifierMask.contains(.command) }
    }

    private static func find(_ match: (NSMenuItem) -> Bool) -> NSMenuItem? {
        func walk(_ menu: NSMenu?) -> NSMenuItem? {
            guard let menu else { return nil }
            for item in menu.items {
                if match(item) { return item }
                if let found = walk(item.submenu) { return found }
            }
            return nil
        }
        return walk(NSApp.mainMenu)
    }

    private static func waitItem(_ find: () -> NSMenuItem?, seconds: Double) async -> NSMenuItem? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let item = find() { return item }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return find()
    }

    private static func fire(_ item: NSMenuItem) -> Bool {
        guard let menu = item.menu else { return false }
        let index = menu.index(of: item)
        guard index >= 0 else { return false }
        menu.performAction(forItemAt: index)
        return true
    }
}

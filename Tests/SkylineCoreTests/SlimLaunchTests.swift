import XCTest
@testable import SkylineCore

/// Launch classification and the "open the window?" decision. No AppKit: four-character codes only.
final class SlimLaunchTests: XCTestCase {
    private func decide(
        eventClass: UInt32? = SlimLaunch.coreEventClass,
        eventID: UInt32? = SlimLaunch.openApplication,
        propData: UInt32? = nil,
        launchKindArgument: String? = nil,
        slimModeNo: Bool = false,
        showInDock: Bool? = nil
    ) -> SlimLaunchDecision {
        SlimLaunch.decide(eventClass: eventClass, eventID: eventID, propData: propData,
                          launchKindArgument: launchKindArgument, slimModeNo: slimModeNo, showInDock: showInDock)
    }

    func testLoginItemEventIsLogin() {
        let d = decide(propData: SlimLaunch.launchedAsLoginItem)
        XCTAssertEqual(d.kind, .login)
        XCTAssertFalse(d.opensWindow)
        XCTAssertEqual(SlimLaunch.codeString(SlimLaunch.launchedAsLoginItem), "lgit")
        XCTAssertEqual(SlimLaunch.codeString(SlimLaunch.openApplication), "oapp")
    }

    func testServiceItemEventIsLogin() {
        let d = decide(propData: SlimLaunch.launchedAsServiceItem)
        XCTAssertEqual(d.kind, .login)
        XCTAssertFalse(d.opensWindow)
        XCTAssertEqual(SlimLaunch.codeString(SlimLaunch.launchedAsServiceItem), "svit")
    }

    func testPlainOpenEventIsManual() {
        // An open-application event whose property data is not a login marker.
        let d = decide(propData: 0x7072_6474) // 'prdt', not lgit/svit
        XCTAssertEqual(d.kind, .manual)
        XCTAssertTrue(d.opensWindow)
    }

    func testMissingEventIsManual() {
        let d = decide(eventClass: nil, eventID: nil, propData: nil)
        XCTAssertEqual(d.kind, .manual)
        XCTAssertTrue(d.opensWindow)
        XCTAssertEqual(SlimLaunch.codeString(nil), "none")
    }

    func testMissingPropDataIsManual() {
        let d = decide(propData: nil)
        XCTAssertEqual(d.kind, .manual)
        XCTAssertTrue(d.opensWindow)
    }

    func testReopenOrOpenDocumentsEventIsManual() {
        let reopen = decide(eventID: SlimLaunch.reopenApplication, propData: SlimLaunch.launchedAsLoginItem)
        XCTAssertEqual(reopen.kind, .manual)
        XCTAssertTrue(reopen.opensWindow)
        let documents = decide(eventID: SlimLaunch.openDocuments, propData: SlimLaunch.launchedAsServiceItem)
        XCTAssertEqual(documents.kind, .manual)
        XCTAssertTrue(documents.opensWindow)
        // Right id and marker, wrong event class: not an open-application event.
        let otherClass = decide(eventClass: SlimLaunch.openDocuments, propData: SlimLaunch.launchedAsLoginItem)
        XCTAssertEqual(otherClass.kind, .manual)
    }

    func testLaunchKindArgumentOverrides() {
        let forcedManual = decide(propData: SlimLaunch.launchedAsLoginItem, launchKindArgument: "manual")
        XCTAssertEqual(forcedManual.kind, .manual)
        XCTAssertTrue(forcedManual.opensWindow)
        let forcedLogin = decide(propData: nil, launchKindArgument: "LOGIN")
        XCTAssertEqual(forcedLogin.kind, .login)
        XCTAssertFalse(forcedLogin.opensWindow)
        let unknown = decide(propData: SlimLaunch.launchedAsLoginItem, launchKindArgument: "nope")
        XCTAssertEqual(unknown.kind, .login, "an unrecognised argument leaves the classifier in charge")
        let blank = decide(eventClass: nil, eventID: nil, launchKindArgument: "  ")
        XCTAssertEqual(blank.kind, .manual)
    }

    func testSlimModeNoAlwaysShowsWindow() {
        let login = decide(propData: SlimLaunch.launchedAsLoginItem, slimModeNo: true)
        XCTAssertEqual(login.kind, .login)
        XCTAssertTrue(login.opensWindow)
        let overridden = decide(propData: nil, launchKindArgument: "login", slimModeNo: true, showInDock: false)
        XCTAssertEqual(overridden.kind, .login)
        XCTAssertTrue(overridden.opensWindow)
        let without = decide(propData: SlimLaunch.launchedAsServiceItem, slimModeNo: false)
        XCTAssertFalse(without.opensWindow)
    }

    func testDockPreferenceIsIgnored() {
        let login = SlimLaunch.launchedAsLoginItem
        let on = decide(propData: login, showInDock: true)
        let off = decide(propData: login, showInDock: false)
        let unknown = decide(propData: login, showInDock: nil)
        XCTAssertEqual(on, off)
        XCTAssertEqual(off, unknown)
        XCTAssertEqual(on.kind, .login)
        XCTAssertFalse(on.opensWindow)

        let manualOn = decide(propData: nil, showInDock: true)
        let manualOff = decide(propData: nil, showInDock: false)
        let manualUnknown = decide(propData: nil, showInDock: nil)
        XCTAssertEqual(manualOn, manualOff)
        XCTAssertEqual(manualOff, manualUnknown)
        XCTAssertTrue(manualOn.opensWindow)
    }
}

/// Slim launch must not add a synced setting. The list is the one bef7a00 encoded.
final class SyncDocumentTests: XCTestCase {
    func testSlimAddsNoSyncedKey() throws {
        let bef7a00: Set<String> = [
            "unitPreference", "unit.temperature", "unit.speed", "unit.precipitation", "unit.pressure",
            "unit.distance", "clockStyle", "refreshMinutes", "menuBarLocationID",
            "notifications.prefs.v1", "notifications.locations.v1"
        ]
        XCTAssertEqual(Set(SyncDocument.syncedSettingKeys), bef7a00)

        var doc = SyncDocument()
        doc.settings = Dictionary(uniqueKeysWithValues: SyncDocument.syncedSettingKeys.map { ($0, "s:x") })
        let data = try doc.encoded()
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let settings = json?["settings"] as? [String: String] ?? [:]
        XCTAssertEqual(Set(settings.keys), bef7a00)

        // Top-level keys of an empty document, so a new stored sync field fails this too.
        let empty = try JSONSerialization.jsonObject(with: try SyncDocument().encoded()) as? [String: Any] ?? [:]
        XCTAssertEqual(Set(empty.keys), [
            "deletedByUser", "format", "locationStamps", "locations", "removed", "settingStamps",
            "settings", "versions", "writtenAt", "writtenBy"
        ])
    }
}

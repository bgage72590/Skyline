import Foundation
import Testing
@testable import SkylineCore

struct MainWindowMatchTests {
    private func window(identifier: String? = nil, title: String = "", isPanel: Bool = false,
                        className: String = "NSWindow", autosave: String = "", sheet: Bool = false,
                        titled: Bool = true) -> MainWindowAttributes {
        MainWindowAttributes(identifier: identifier, title: title, isPanel: isPanel, className: className,
                             frameAutosaveName: autosave, hasSheetParent: sheet, isTitled: titled)
    }

    @Test func mainIdentifierMatches() {
        #expect(MainWindowMatch.isMain(window(identifier: "main")))
    }

    @Test func swiftUIMainIdentifierMatches() {
        #expect(MainWindowMatch.isMain(window(identifier: "main-AppWindow-2", title: "Skyline")))
    }

    @Test func mainXIsRejected() {
        #expect(!MainWindowMatch.isMain(window(identifier: "mainX", title: "Skyline")))
    }

    @Test func settingsIsRejected() {
        #expect(!MainWindowMatch.isMain(window(title: "Settings")))
        #expect(!MainWindowMatch.isMain(window(title: "Settings — General")))
        #expect(!MainWindowMatch.isMain(window(title: "Skyline", autosave: "com_apple_SwiftUI_Settings_Window")))
    }

    @Test func statusBarWindowIsRejected() {
        #expect(!MainWindowMatch.isMain(window(title: "Skyline", className: "NSStatusBarWindow", titled: false)))
        #expect(!MainWindowMatch.isMain(window(title: "Skyline", className: "NSStatusBarWindow")))
    }

    @Test func menuBarHotkeyPanelIsRejected() {
        #expect(!MainWindowMatch.isMain(window(title: "Skyline", isPanel: true, className: "HotkeyPanel", titled: false)))
    }

    @Test func popoverPanelIsRejected() {
        #expect(!MainWindowMatch.isMain(window(title: "Skyline", isPanel: true, className: "NSPanel", titled: false)))
    }

    @Test func sheetTitledSkylineIsRejected() {
        #expect(!MainWindowMatch.isMain(window(title: "Skyline", sheet: true)))
    }

    @Test func alertIsRejected() {
        #expect(!MainWindowMatch.isMain(window(title: "Skyline", isPanel: true, className: "NSAlertPanel")))
        #expect(!MainWindowMatch.isMain(window(title: "Skyline", className: "NSAlert")))
    }

    @Test func titledSkylineFallbackIsAccepted() {
        #expect(MainWindowMatch.isMain(window(title: "Skyline")))
        #expect(!MainWindowMatch.isMain(window(title: "Skyline", titled: false)))
    }
}

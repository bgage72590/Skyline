import Foundation

/// Plain facts about a window. The app fills this from NSWindow; the match itself has no AppKit.
public struct MainWindowAttributes: Equatable, Sendable {
    public var identifier: String?
    public var title: String
    public var isPanel: Bool
    public var className: String
    public var frameAutosaveName: String
    public var hasSheetParent: Bool
    public var isTitled: Bool

    public init(identifier: String?, title: String, isPanel: Bool, className: String,
                frameAutosaveName: String, hasSheetParent: Bool, isTitled: Bool) {
        self.identifier = identifier
        self.title = title
        self.isPanel = isPanel
        self.className = className
        self.frameAutosaveName = frameAutosaveName
        self.hasSheetParent = hasSheetParent
        self.isTitled = isTitled
    }
}

/// Which window is Skyline's main scene.
///
/// An identifier of `main`, or one with the prefix `main-` (`main-AppWindow-1`), is the main window.
/// `mainX` is not. With no identifier, the title `Skyline` matches only a titled window that is not a
/// panel, not the status-bar window, not a sheet, and not Settings.
public enum MainWindowMatch {
    public static func isMain(_ window: MainWindowAttributes) -> Bool {
        if let identifier = window.identifier, !identifier.isEmpty {
            return identifier == "main" || identifier.hasPrefix("main-")
        }
        if window.frameAutosaveName.contains("com_apple_SwiftUI_Settings") || window.title.hasPrefix("Settings") {
            return false
        }
        if window.className.contains("Alert") { return false }
        guard window.isTitled, !window.isPanel, window.className != "NSStatusBarWindow", !window.hasSheetParent else {
            return false
        }
        return window.title == "Skyline"
    }
}

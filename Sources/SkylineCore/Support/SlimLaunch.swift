import Foundation

/// How Skyline was started, from the launch Apple event. Plain four-character codes, no AppKit,
/// so the decision can be tested on Linux. A missed login signal is manual: the window shows.
public enum SlimLaunchKind: String, Equatable, Sendable {
    case login
    case manual
}

/// Whether did-finish should open the main window. `showInDock` is an input and does not affect
/// the result: Dock on, off, and unknown all decide the same way.
public struct SlimLaunchDecision: Equatable, Sendable {
    public var kind: SlimLaunchKind
    public var opensWindow: Bool

    public init(kind: SlimLaunchKind, opensWindow: Bool) {
        self.kind = kind
        self.opensWindow = opensWindow
    }
}

public enum SlimLaunch {
    /// kCoreEventClass 'aevt'.
    public static let coreEventClass: UInt32 = 0x6165_7674
    /// kAEOpenApplication 'oapp'.
    public static let openApplication: UInt32 = 0x6F61_7070
    /// kAEReopenApplication 'rapp'.
    public static let reopenApplication: UInt32 = 0x7261_7070
    /// kAEOpenDocuments 'odoc'.
    public static let openDocuments: UInt32 = 0x6F64_6F63
    /// keyAELaunchedAsLogInItem 'lgit'.
    public static let launchedAsLoginItem: UInt32 = 0x6C67_6974
    /// keyAELaunchedAsServiceItem 'svit'.
    public static let launchedAsServiceItem: UInt32 = 0x7376_6974

    /// Log form of a four-character code: `oapp`, `lgit`, or `none` when the code is missing.
    public static func codeString(_ code: UInt32?) -> String {
        guard let code else { return "none" }
        let bytes = [
            UInt8(truncatingIfNeeded: code >> 24),
            UInt8(truncatingIfNeeded: code >> 16),
            UInt8(truncatingIfNeeded: code >> 8),
            UInt8(truncatingIfNeeded: code)
        ]
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }), let text = String(bytes: bytes, encoding: .ascii) {
            return text
        }
        let hex = String(code, radix: 16)
        return String(repeating: "0", count: max(0, 8 - hex.count)) + hex
    }

    /// Login only for an open-application event whose property data is the login-item or
    /// service-item marker. Anything else, including a missing event or a missing parameter, is manual.
    /// `-SkylineLaunchKind login|manual` replaces that result. `-SkylineSlimMode NO` (`slimModeNo`)
    /// opens the window either way. `showInDock` is ignored.
    public static func decide(
        eventClass: UInt32?,
        eventID: UInt32?,
        propData: UInt32?,
        launchKindArgument: String?,
        slimModeNo: Bool,
        showInDock: Bool?
    ) -> SlimLaunchDecision {
        let kind = resolvedKind(eventClass: eventClass, eventID: eventID, propData: propData,
                                launchKindArgument: launchKindArgument)
        let opensWindow = slimModeNo || kind == .manual
        // Dock preference is accepted so callers pass it, and so tests can show it does not decide.
        _ = showInDock
        return SlimLaunchDecision(kind: kind, opensWindow: opensWindow)
    }

    private static func resolvedKind(
        eventClass: UInt32?,
        eventID: UInt32?,
        propData: UInt32?,
        launchKindArgument: String?
    ) -> SlimLaunchKind {
        switch launchKindArgument?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "login": return .login
        case "manual": return .manual
        default: return classified(eventClass: eventClass, eventID: eventID, propData: propData)
        }
    }

    private static func classified(eventClass: UInt32?, eventID: UInt32?, propData: UInt32?) -> SlimLaunchKind {
        guard eventClass == coreEventClass, eventID == openApplication, let propData else { return .manual }
        if propData == launchedAsLoginItem || propData == launchedAsServiceItem { return .login }
        return .manual
    }
}

import AppKit
import SwiftUI

/// Hidden QA hook: `-SkylineSearchTypeTest YES` types "bos" into the city search field of Skyline's own
/// main window (key events sent in-process to that window, nothing to other apps) and checks the text
/// arrives. Runs three times: at launch, after ⌘Q-to-menu-bar + reopen, and after the hotkey dropdown
/// was shown. Logs `[search-test] PASS/FAIL` and quits.
@MainActor
enum SearchTypeTest {
    static func runIfRequested() {
        guard UserDefaults.standard.bool(forKey: "SkylineSearchTypeTest") else { return }
        Task {
            try? await Task.sleep(for: .seconds(4))
            var results: [String] = []
            results.append("launch=" + (await attempt() ? "ok" : "FAIL"))
            AppExit.perform(.commandQ)
            try? await Task.sleep(for: .seconds(1.5))
            AppExit.showMainWindow()
            NSApp.activate()
            try? await Task.sleep(for: .seconds(2.5))
            results.append("reopen=" + (await attempt() ? "ok" : "FAIL"))
            GlobalHotkey.fire()
            try? await Task.sleep(for: .seconds(1))
            GlobalHotkey.closePanel()
            AppExit.showMainWindow()
            NSApp.activate()
            try? await Task.sleep(for: .seconds(1.5))
            results.append("afterDropdown=" + (await attempt() ? "ok" : "FAIL"))
            print("[search-test] " + results.joined(separator: " "))
            let verdict = results.allSatisfy { $0.hasSuffix("ok") } ? "[search-test] PASS" : "[search-test] FAIL"
            print(verdict)
            // Also to a file, for runs started with `open` (LaunchServices activates the app; stdout is lost).
            let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/skyline-search-test.txt")
            try? ("[search-test] " + results.joined(separator: " ") + "\n" + verdict + "\n").write(to: log, atomically: true, encoding: .utf8)
            fflush(stdout)
            NSApp.terminate(nil)
        }
    }

    private static func attempt() async -> Bool {
        guard let store = IntentStore.shared,
              let window = NSApp.windows.first(where: { AppExit.isAppWindow($0) && $0.isVisible }) else {
            print("[search-test] no main window"); return false
        }
        store.searchText = ""
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<20 where !window.isKeyWindow { try? await Task.sleep(for: .milliseconds(100)) }
        guard let field = findSearchField(window.contentView) ?? findSearchField(window.contentView?.superview) else {
            print("[search-test] no search field"); return false
        }
        let tookFocus = window.makeFirstResponder(field)
        try? await Task.sleep(for: .milliseconds(300))
        for ch in "bos" {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: String(ch),
                                            charactersIgnoringModifiers: String(ch), isARepeat: false, keyCode: 0) {
                    window.sendEvent(e)
                }
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
        try? await Task.sleep(for: .milliseconds(400))
        let text = field.stringValue
        print("[search-test] key=\(window.isKeyWindow) firstResponder=\(tookFocus) field=\"\(text)\" store=\"\(store.searchText)\" policy=\(NSApp.activationPolicy().rawValue)")
        let ok = text == "bos" && store.searchText == "bos"
        field.stringValue = ""
        store.searchText = ""
        return ok
    }

    private static func findSearchField(_ view: NSView?) -> NSSearchField? {
        guard let view else { return nil }
        if let f = view as? NSSearchField { return f }
        for s in view.subviews { if let f = findSearchField(s) { return f } }
        return nil
    }
}

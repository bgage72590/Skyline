import Foundation

/// Process arguments only. A value stored with `defaults write` is invisible here.
public enum LaunchArguments {
    public static func int(_ name: String, arguments: [String] = CommandLine.arguments) -> Int? {
        guard let raw = value(name, arguments: arguments) else { return nil }
        return Int(raw)
    }

    /// `-Name YES` is true. Missing, `NO`, and anything else are false.
    public static func bool(_ name: String, arguments: [String] = CommandLine.arguments) -> Bool {
        guard let raw = value(name, arguments: arguments) else { return false }
        switch raw.lowercased() {
        case "yes", "true", "1": return true
        default: return false
        }
    }

    private static func value(_ name: String, arguments: [String]) -> String? {
        let flag = name.hasPrefix("-") ? name : "-" + name
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let next = index + 1
        guard arguments.indices.contains(next), !arguments[next].hasPrefix("-") else { return "YES" }
        return arguments[next]
    }
}

// Prints the CGWindowID of the largest on-screen window owned by a process name (default "Skyline"),
// for `screencapture -l <id>` (window-only screenshots, no input sent to any app).
import CoreGraphics
import Foundation
let owner = CommandLine.arguments.dropFirst().first ?? "Skyline"
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let best = list.filter { ($0[kCGWindowOwnerName as String] as? String) == owner && ($0[kCGWindowLayer as String] as? Int) == 0 }
    .max { a, b in
        func area(_ w: [String: Any]) -> Double { let r = w[kCGWindowBounds as String] as? [String: Double] ?? [:]; return (r["Width"] ?? 0) * (r["Height"] ?? 0) }
        return area(a) < area(b)
    }
if let id = best?[kCGWindowNumber as String] as? Int { print(id) } else { exit(1) }

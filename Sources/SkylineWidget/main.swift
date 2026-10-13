import Foundation
import SkylineCore

// Entry point of the widget extension. `--selftest` (run by build-app.sh and the QA hook, never by
// WidgetKit) reads the snapshot through the sandbox exactly as the widget does and prints one line.
if CommandLine.arguments.contains("--selftest") {
    let s = SnapshotStore.load()
    print("[widget] snapshot=\(s != nil) city=\(s?.locationName ?? "-") age=\(s.map { Int(Date().timeIntervalSince($0.dataTime) / 60) } ?? -1)min "
          + "sandboxed=\(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil)")
    exit(0)
}
SkylineWidgets.main()

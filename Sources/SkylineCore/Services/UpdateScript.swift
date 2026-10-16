import Foundation

/// The detached shell command "Update Skyline…" runs (QA L3, from build 29). The installer's output
/// goes to a temporary file that becomes the result log **only on failure** (an atomic `mv`). Before,
/// the success log sat at the result path until `rm` ran after the installer had already reopened the
/// new app, which could read it first and show a false "Couldn't update Skyline".
public enum UpdateScript {
    public static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    public static func command(installer: String, newerThan build: Int, zip: String, resultLog: String) -> String {
        let log = quote(resultLog), tmp = quote(resultLog + ".partial")
        return """
            sleep 1
            rm -f \(tmp)
            if /bin/bash \(quote(installer)) --newer-than \(build) \(quote(zip)) > \(tmp) 2>&1; then
              rm -f \(tmp)
            else
              mv -f \(tmp) \(log)
              open -a Skyline
            fi
            """
    }
}

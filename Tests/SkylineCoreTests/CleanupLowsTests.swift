import Foundation
import Testing
@testable import SkylineCore

/// L1–L7 / QA cleanup (MASTER-LIST).
struct CleanupLowsTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// QA L2: a real distance instead of grid rounding.
    @Test func duplicateCheckUsesDistance() {
        let a = WeatherLocation(id: "a", name: "A", coordinate: Coordinate(latitude: 41.24995, longitude: -73.0))
        let across = WeatherLocation(id: "b", name: "B", coordinate: Coordinate(latitude: 41.25020, longitude: -73.0)) // ~28 m
        let sameCellFar = WeatherLocation(id: "c", name: "C", coordinate: Coordinate(latitude: 41.2, longitude: -73.0))
        let far = WeatherLocation(id: "d", name: "D", coordinate: Coordinate(latitude: 41.2126, longitude: -73.0)) // ~4 km
        #expect(LocationList.isDuplicate(across, of: a))
        #expect(!LocationList.isDuplicate(far, of: a))
        _ = sameCellFar
    }

    /// QA L3: the success log never sits at the result path; only a failure moves it there.
    @Test func updaterWritesTheResultLogOnlyOnFailure() {
        let cmd = UpdateScript.command(installer: "/A/install-verified.sh", newerThan: 79, zip: "/I/Skyline.zip",
                                       resultLog: "/L/skyline-update-result.txt")
        let lines = cmd.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let ifLine = lines.first { $0.hasPrefix("if ") } ?? ""
        #expect(ifLine.contains("> '/L/skyline-update-result.txt.partial' 2>&1"))
        #expect(!ifLine.contains("> '/L/skyline-update-result.txt' "))
        let elseIdx = lines.firstIndex(of: "else")!, thenIdx = lines.firstIndex { $0.hasSuffix("then") }!
        #expect(lines[(thenIdx + 1)..<elseIdx].allSatisfy { !$0.contains("skyline-update-result.txt'") || $0.contains(".partial") })
        #expect(lines[elseIdx + 1].hasPrefix("mv -f '/L/skyline-update-result.txt.partial' '/L/skyline-update-result.txt'"))
        #expect(lines.firstIndex { $0.hasPrefix("mv -f") }! < lines.firstIndex { $0.hasPrefix("open -a") }!)
        #expect(UpdateScript.quote("it's") == "'it'\\''s'")
    }
}

import Foundation
import Testing
@testable import SkylineCore

/// L1–L7 / QA cleanup (MASTER-LIST).
struct CleanupLowsTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let nyc = WeatherLocation(id: "40.7128,-74.0060", name: "NYC", coordinate: Coordinate(latitude: 40.7128, longitude: -74.006))
    let boston = WeatherLocation(id: "42.3601,-71.0589", name: "Boston", coordinate: Coordinate(latitude: 42.3601, longitude: -71.0589))

    /// QA L1 (build 29): another Mac 1 h fast renames NYC; NYC is removed here during the merge flight.
    /// The removal used to lose (`["NYC (remote)", "Boston"]`).
    @Test func removalDuringFlightBeatsASkewedRemoteClock() {
        var snapshot = SyncDocument()
        snapshot.locations = [nyc, boston]
        snapshot.locationStamps = [nyc.id: t0, boston.id: t0]
        var renamed = nyc; renamed.name = "NYC (remote)"
        var merged = snapshot
        merged.locations = [renamed, boston]
        merged.locationStamps[nyc.id] = t0.addingTimeInterval(3600) // remote clock +1 h
        let out = SyncDocument.rebasing(locations: [boston], settings: [:], snapshot: snapshot, onto: merged,
                                        now: t0.addingTimeInterval(10), deletions: [nyc.id: t0.addingTimeInterval(9)])
        #expect(out.locations.map(\.name) == ["Boston"])
        #expect(out.deletedByUser[nyc.id] != nil)
    }

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

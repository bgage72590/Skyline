import Foundation
import Testing
@testable import SkylineCore

/// Deferred polish after PRs #5–#7.
struct DeferredPolishTests {
    let tz = TimeZone(secondsFromGMT: 0)!
    let t = Date(timeIntervalSince1970: 1_800_000_000 - 8 * 3600 + 15 * 3600 + 5 * 60) // 15:05:00 UTC

    @Test func clockFollowsLocaleTwelveOrTwentyFourHour() {
        let us = UserFacingError.clockTime(t, timeZone: tz, locale: Locale(identifier: "en_US"))
        let gb = UserFacingError.clockTime(t, timeZone: tz, locale: Locale(identifier: "en_GB"))
        let de = UserFacingError.clockTime(t, timeZone: tz, locale: Locale(identifier: "de_DE"))
        #expect(us.hasPrefix("3:05") && us.uppercased().contains("PM"))
        #expect(gb == "15:05")
        #expect(de == "15:05")
    }

    @Test func retryTimeIsNeverEarlierThanTheRetry() {
        let us = Locale(identifier: "en_US")
        // The retry fires up to 12 s after `until` (2 s margin + 10 s tolerance), so 15:05:00 shows 15:06.
        #expect(UserFacingError.busyLine(host: "api.open-meteo.com", until: t, timeZone: tz, locale: us)
            .hasSuffix("3:06 PM"))
        // A partial minute always rounds up, never down.
        let mid = t.addingTimeInterval(20)
        #expect(UserFacingError.busyLine(host: "api.open-meteo.com", until: mid, timeZone: tz, locale: us)
            .hasSuffix("3:06 PM"))
        #expect(UserFacingError.clockTime(t, timeZone: tz, locale: us, roundUp: true).hasPrefix("3:05"))
        for s in Swift.stride(from: 0.0, to: 600, by: 7) {
            let until = t.addingTimeInterval(s)
            let line = UserFacingError.clockTime(until.addingTimeInterval(UserFacingError.retrySlack),
                                                 timeZone: tz, locale: Locale(identifier: "en_GB"), roundUp: true)
            let parts = line.split(separator: ":").compactMap { Int($0) }
            var c = Calendar(identifier: .gregorian); c.timeZone = tz
            let d = c.dateComponents([.year, .month, .day], from: until)
            let shown = c.date(from: DateComponents(year: d.year, month: d.month, day: d.day, hour: parts[0], minute: parts[1]))!
            #expect(shown >= until.addingTimeInterval(UserFacingError.retrySlack))
        }
    }

    @Test func provisionalRetriesStopAfterTheCap() {
        #expect(RadarProvisionalRetry.shouldRetry(attempts: 1))
        #expect(RadarProvisionalRetry.shouldRetry(attempts: RadarProvisionalRetry.maxAttempts - 1))
        #expect(!RadarProvisionalRetry.shouldRetry(attempts: RadarProvisionalRetry.maxAttempts))
    }

    @Test func rangeRingsAdaptToZoomAndNeverCrowd() {
        // Zoomed in (20 pt/mi on a 600 pt map): small set, all labelled.
        let near = RangeRings.visible(pointsPerMile: 20, minDimension: 600)
        #expect(near.map(\.miles) == [2, 5, 10])
        // Zoomed out (1 pt/mi): wide set; the rings too small to read are dropped.
        let far = RangeRings.visible(pointsPerMile: 1, minDimension: 600)
        #expect(far.map(\.miles) == [50, 100, 250])
        #expect(RangeRings.visible(pointsPerMile: 0.15, minDimension: 600).map(\.miles) == [250])
        for ppm in Swift.stride(from: 0.2, through: 60, by: 0.37) {
            for dim in [180.0, 320, 600, 1200] {
                let rings = RangeRings.visible(pointsPerMile: ppm, minDimension: dim)
                for r in rings { #expect(r.miles * ppm >= RangeRings.minRingPoints) }
                let labelled = rings.filter(\.showLabel).map { $0.miles * ppm }
                // NE labels: neighbours ≥ 20 pt apart per axis (label height 14 pt), so no overlap.
                for (a, b) in zip(labelled, labelled.dropFirst()) { #expect((b - a) / 2.squareRoot() >= 14) }
                for r in labelled { #expect(r >= RangeRings.minLabelPoints) }
            }
        }
    }

    @Test func neighbourMasksFetchConcurrentlyAndShareRawTiles() async {
        final class Probe: @unchecked Sendable {
            let lock = NSLock(); var live = 0, peak = 0
            func enter() { lock.lock(); live += 1; peak = max(peak, live); lock.unlock() }
            func leave() { lock.lock(); live -= 1; lock.unlock() }
        }
        let probe = Probe()
        let store = RadarQCMaskStore { _ in
            probe.enter()
            try? await Task.sleep(for: .milliseconds(30))
            probe.leave()
            return [UInt8](repeating: 255, count: 256 * 256)
        }
        let template = "https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/mrms::lcref/{z}/{x}/{y}.png"
        async let a = store.mask(template: template, tile: .init(z: 6, x: 18, y: 24))
        async let b = store.mask(template: template, tile: .init(z: 6, x: 19, y: 24))
        let (ma, mb) = await (a, b)
        #expect(ma != nil && mb != nil)
        #expect(probe.peak > 1) // neighbours in parallel, not one at a time
        #expect(await store.fetches == 12) // 3×4 distinct raw tiles; shared ones fetched once
    }
}

/// Sint Maarten: deleted on the iMac at 12:38 PM ET (in `deletedByUser`), back at 1:15 PM ET with a
/// fresh stamp written by this MacBook. A Mac whose local list still had the city (its last-synced state
/// already had the tombstone) noted it as a brand-new add, and the newer stamp beat the delete.
struct StaleCopyResurrectionTests {
    let sm = WeatherLocation(id: "52.7725,4.7458", name: "Sint Maarten", coordinate: Coordinate(latitude: 52.7725, longitude: 4.7458))
    let ny = WeatherLocation(id: "40.7128,-74.0060", name: "New York", coordinate: Coordinate(latitude: 40.7128, longitude: -74.006))
    let deletedAt = Date(timeIntervalSince1970: 1_800_000_000)

    /// Last-synced state after the other Mac's delete was merged in.
    func lastSynced() -> SyncDocument {
        var d = SyncDocument()
        d.locations = [ny]
        d.locationStamps = [ny.id: deletedAt.addingTimeInterval(-3600)]
        d.removed = [sm.id: deletedAt]
        d.deletedByUser = [sm.id: deletedAt]
        return d
    }

    @Test func staleLocalCopyIsNotResurrected() {
        let now = deletedAt.addingTimeInterval(37 * 60)
        let local = SyncDocument.noting(locations: [ny, sm], settings: [:], previous: lastSynced(), now: now, deletions: [:])
        #expect(!local.locations.contains { $0.id == sm.id })
        #expect(local.locationStamps[sm.id] == nil)
        #expect(local.removed[sm.id] == deletedAt && local.deletedByUser[sm.id] == deletedAt)
        // And merging with the file keeps it deleted.
        let merged = SyncDocument.merge(local: local, remote: lastSynced(), now: now)
        #expect(!merged.locations.contains { $0.id == sm.id })
    }

    @Test func reAddAfterTheDeleteIsKept() {
        let now = deletedAt.addingTimeInterval(600)
        let local = SyncDocument.noting(locations: [ny, sm], settings: [:], previous: lastSynced(), now: now, deletions: [:],
                                        additions: [sm.id: deletedAt.addingTimeInterval(300)])
        #expect(local.locations.contains { $0.id == sm.id })
        let merged = SyncDocument.merge(local: local, remote: lastSynced(), now: now)
        #expect(merged.locations.contains { $0.id == sm.id })
        // An add from before the delete doesn't count.
        let old = SyncDocument.noting(locations: [ny, sm], settings: [:], previous: lastSynced(), now: now, deletions: [:],
                                      additions: [sm.id: deletedAt.addingTimeInterval(-60)])
        #expect(!old.locations.contains { $0.id == sm.id })
    }

    @Test func launchDropsAStaleCopyButKeepsNewCities() {
        let paris = WeatherLocation(id: "48.8566,2.3522", name: "Paris", coordinate: Coordinate(latitude: 48.8566, longitude: 2.3522))
        let out = LocationPersistence.launchLocations(local: [ny, sm, paris], lastSynced: [ny], removed: lastSynced().removed)
        #expect(out.map(\.id) == [ny.id, paris.id])
        let kept = LocationPersistence.launchLocations(local: [ny, sm], lastSynced: [ny], removed: lastSynced().removed,
                                                       added: [sm.id: deletedAt.addingTimeInterval(1)])
        #expect(kept.map(\.id) == [ny.id, sm.id])
    }

    @Test func nearestLabelNamesTheCurrentSite() {
        #expect(RadarSiteChoice.nearestLabel(nil) == "Nearest")
        let fairfield = Coordinate(latitude: 41.1408, longitude: -73.2613)
        let spokane = Coordinate(latitude: 47.6597, longitude: -117.4291)
        let a = NexradStation.nearest(to: fairfield), b = NexradStation.nearest(to: spokane)
        #expect(a?.icao == "KOKX" && b?.icao == "KOTX")
        #expect(RadarSiteChoice.nearestLabel(a) == "Nearest (KOKX)")
    }
}

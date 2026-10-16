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
        // Every second across an hour boundary and midnight: the minute shown is the first whole minute at
        // or after the latest retry moment (until + slack), compared as minutes of the day (mod 1440).
        let gb = Locale(identifier: "en_GB")
        let midnight = Date(timeIntervalSince1970: 1_800_000_000 - 8 * 3600 + 24 * 3600)
        for base in [t.addingTimeInterval(54 * 60), midnight.addingTimeInterval(-5 * 60)] {
            for s in Swift.stride(from: 0.0, to: 600, by: 1) {
                let until = base.addingTimeInterval(s)
                let line = UserFacingError.clockTime(until.addingTimeInterval(UserFacingError.retrySlack),
                                                     timeZone: tz, locale: gb, roundUp: true)
                let p = line.split(separator: ":").compactMap { Int($0) }
                let shown = p[0] * 60 + p[1]
                let secOfDay = (until.timeIntervalSince1970 + UserFacingError.retrySlack).truncatingRemainder(dividingBy: 86400)
                let expected = Int((secOfDay / 60).rounded(.up)) % 1440
                #expect(shown == expected, "\(until) → \(line)")
            }
        }
    }

    @Test func roundUpRollsOverAtFiftyNineAndMidnight() {
        let gb = Locale(identifier: "en_GB"), us = Locale(identifier: "en_US")
        let midnight = Date(timeIntervalSince1970: 1_800_000_000 - 8 * 3600 + 24 * 3600)
        #expect(UserFacingError.clockTime(t.addingTimeInterval(54 * 60 + 40), timeZone: tz, locale: gb, roundUp: true) == "16:00") // 15:59:40
        #expect(UserFacingError.clockTime(midnight.addingTimeInterval(-30), timeZone: tz, locale: gb, roundUp: true) == "00:00")
        #expect(UserFacingError.clockTime(midnight, timeZone: tz, locale: gb, roundUp: true) == "00:00") // exact minute stays
        #expect(UserFacingError.clockTime(midnight.addingTimeInterval(-30), timeZone: tz, locale: us, roundUp: true) == "12:00 AM")
        // 23:59:50 + 12 s slack = 00:00:02 → 00:01.
        #expect(UserFacingError.busyLine(host: "api.open-meteo.com", until: midnight.addingTimeInterval(-10), timeZone: tz, locale: gb)
            .hasSuffix("00:01"))
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

/// "Nearest (K…)" radar site label.
struct NearestSiteLabelTests {
    @Test func nearestLabelNamesTheCurrentSite() {
        #expect(RadarSiteChoice.nearestLabel(nil) == "Nearest")
        let fairfield = Coordinate(latitude: 41.1408, longitude: -73.2613)
        let spokane = Coordinate(latitude: 47.6597, longitude: -117.4291)
        let a = NexradStation.nearest(to: fairfield), b = NexradStation.nearest(to: spokane)
        #expect(a?.icao == "KOKX" && b?.icao == "KOTX")
        #expect(RadarSiteChoice.nearestLabel(a) == "Nearest (KOKX)")
    }
}

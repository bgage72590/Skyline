import Foundation
import XCTest
@testable import SkylineCore

/// Plan §6 items 9–10 + Fix 1 / Decision 2 planner tests.
final class RefreshPlannerTests: XCTestCase {
    private func city(_ id: String, lat: Double = 40.7, lon: Double = -74.0) -> WeatherLocation {
        WeatherLocation(id: id, name: id, country: "United States",
                        coordinate: Coordinate(latitude: lat, longitude: lon))
    }

    // MARK: Roles

    func testRolesFreshVersusBackground() {
        let cities = [city("viewed"), city("menu"), city("notify"), city("other"), city("also")]
        let roles = RefreshPlanner.roles(cities: cities, viewedID: "viewed", menuBarID: "menu",
                                         notifyIDs: ["notify"])
        XCTAssertEqual(roles["viewed"], .freshCadence)
        XCTAssertEqual(roles["menu"], .freshCadence)
        XCTAssertEqual(roles["notify"], .freshCadence)
        XCTAssertEqual(roles["other"], .background)
        XCTAssertEqual(roles["also"], .background)

        XCTAssertEqual(RefreshPlanner.role(for: "x", viewedID: "x", menuBarID: nil, notifyIDs: []), .freshCadence)
        XCTAssertEqual(RefreshPlanner.role(for: "y", viewedID: "x", menuBarID: "y", notifyIDs: []), .freshCadence)
        XCTAssertEqual(RefreshPlanner.role(for: "z", viewedID: "x", menuBarID: "y", notifyIDs: ["z"]), .freshCadence)
        XCTAssertEqual(RefreshPlanner.role(for: "bg", viewedID: "x", menuBarID: "y", notifyIDs: []), .background)
    }

    // MARK: Due (M6) + Decision 2 TTL

    func testDecision2TTLConstants() {
        XCTAssertEqual(WeatherService.TTL.background, 10_800)
        XCTAssertEqual(WeatherService.TTL.blendMaxAge, 43_200)
        XCTAssertEqual(WeatherService.TTL.notifyReuseHidden, 1_800)
    }

    func testDueFreshByForecastTTLBackgroundByBackgroundTTL() {
        let cities = [city("fresh"), city("bg")]
        let roles: [String: RefreshPlanner.Role] = ["fresh": .freshCadence, "bg": .background]
        let forecastTTL = WeatherService.TTL.forecast
        let backgroundTTL = WeatherService.TTL.background

        let young = RefreshPlanner.due(cities: cities,
                                       pairAges: ["fresh": forecastTTL - 1, "bg": backgroundTTL - 1],
                                       roles: roles)
        XCTAssertTrue(young.fresh.isEmpty)
        XCTAssertTrue(young.background.isEmpty)

        let freshDue = RefreshPlanner.due(cities: cities,
                                          pairAges: ["fresh": forecastTTL, "bg": 0],
                                          roles: roles)
        XCTAssertEqual(freshDue.fresh, ["fresh"])
        XCTAssertTrue(freshDue.background.isEmpty)

        let bgDue = RefreshPlanner.due(cities: cities,
                                       pairAges: ["fresh": 0, "bg": backgroundTTL],
                                       roles: roles)
        XCTAssertTrue(bgDue.fresh.isEmpty)
        XCTAssertEqual(bgDue.background, ["bg"])

        let missing = RefreshPlanner.due(cities: cities, pairAges: [:], roles: roles)
        XCTAssertEqual(missing.fresh, ["fresh"])
        XCTAssertEqual(missing.background, ["bg"])
    }

    func testDueWantsIssuanceEvenIfYoung() {
        let cities = [city("bg")]
        let roles: [String: RefreshPlanner.Role] = ["bg": .background]
        let due = RefreshPlanner.due(cities: cities,
                                     pairAges: ["bg": 60],
                                     roles: roles,
                                     wantsIssuance: ["bg": true],
                                     windowVisible: true)
        XCTAssertEqual(due.background, ["bg"])

        let notWanted = RefreshPlanner.due(cities: cities,
                                           pairAges: ["bg": 60],
                                           roles: roles,
                                           wantsIssuance: ["bg": false])
        XCTAssertTrue(notWanted.background.isEmpty)
    }

    /// Decision 2: TTL-due background cities while hidden; issuance-only while hidden → not due.
    func testHiddenWindowBackgroundTTLDue() {
        let cities = [city("menu"), city("old"), city("empty"), city("young")]
        let roles: [String: RefreshPlanner.Role] = [
            "menu": .freshCadence, "old": .background, "empty": .background, "young": .background
        ]
        let ages: [String: TimeInterval] = [
            "menu": WeatherService.TTL.forecast,
            "old": WeatherService.TTL.background,
            "young": WeatherService.TTL.background - 1
        ]
        let hidden = RefreshPlanner.due(cities: cities, pairAges: ages, roles: roles,
                                        wantsIssuance: ["young": true, "old": true],
                                        windowVisible: false)
        XCTAssertEqual(hidden.fresh, ["menu"])
        XCTAssertEqual(Set(hidden.background), Set(["old", "empty"]))
        XCTAssertFalse(hidden.background.contains("young"), "issuance-only while hidden is not due")

        let atBoundary = RefreshPlanner.due(cities: [city("bg")],
                                            pairAges: ["bg": 10_800],
                                            roles: ["bg": .background],
                                            windowVisible: false)
        XCTAssertEqual(atBoundary.background, ["bg"])
        let justUnder = RefreshPlanner.due(cities: [city("bg")],
                                           pairAges: ["bg": 10_799],
                                           roles: ["bg": .background],
                                           windowVisible: false)
        XCTAssertTrue(justUnder.background.isEmpty)

        let visible = RefreshPlanner.due(cities: cities, pairAges: ages, roles: roles,
                                         wantsIssuance: ["young": true], windowVisible: true)
        XCTAssertEqual(Set(visible.background), Set(["old", "empty", "young"]))
    }

    func testNotifyReuseWhileHidden() {
        let cities = [city("notify"), city("other")]
        let roles: [String: RefreshPlanner.Role] = ["notify": .freshCadence, "other": .freshCadence]
        // At 20 min: notify reuses (not due); other uses 10-min forecast TTL (due).
        let mid = RefreshPlanner.due(cities: cities, pairAges: ["notify": 1_200, "other": 1_200],
                                     roles: roles, windowVisible: false, notifyIDs: ["notify"])
        XCTAssertEqual(mid.fresh, ["other"])
        // At 30 min: notify becomes due under notifyReuseHidden.
        let due = RefreshPlanner.due(cities: [city("notify")], pairAges: ["notify": 1_800],
                                     roles: ["notify": .freshCadence],
                                     windowVisible: false, notifyIDs: ["notify"])
        XCTAssertEqual(due.fresh, ["notify"])
        let justUnder = RefreshPlanner.due(cities: [city("notify")], pairAges: ["notify": 1_799],
                                           roles: ["notify": .freshCadence],
                                           windowVisible: false, notifyIDs: ["notify"])
        XCTAssertTrue(justUnder.fresh.isEmpty)
    }

    // MARK: Stagger / retain / dropdown / stillDue

    func testStaggerDelayAtLeast15() {
        for id in ["a", "b", "city-3", "nyc"] {
            XCTAssertGreaterThanOrEqual(RefreshPlanner.staggerDelay(for: id), RefreshPlanner.staggerBase)
            XCTAssertGreaterThanOrEqual(RefreshPlanner.staggerDelay(for: id), 15)
            XCTAssertEqual(RefreshPlanner.staggerDelay(for: id),
                           RefreshPlanner.staggerBase + FetchRetryPolicy.jitter(for: id))
        }
    }

    func testNextDequeueDelayAndShouldEnqueue() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(RefreshPlanner.nextDequeueDelay(lastDequeueAt: nil, now: now, id: "a"), 0)
        let last = now.addingTimeInterval(-5)
        let delay = RefreshPlanner.nextDequeueDelay(lastDequeueAt: last, now: now, id: "a")
        XCTAssertGreaterThanOrEqual(delay, 10)
        XCTAssertLessThanOrEqual(delay, RefreshPlanner.staggerDelay(for: "a"))

        XCTAssertTrue(RefreshPlanner.shouldEnqueue(id: "x", queued: [], loading: []))
        XCTAssertFalse(RefreshPlanner.shouldEnqueue(id: "x", queued: ["x"], loading: []))
        XCTAssertFalse(RefreshPlanner.shouldEnqueue(id: "x", queued: [], loading: ["x"]))
    }

    func testRetainOnHide() {
        let kept = RefreshPlanner.retainOnHide(ids: ["empty", "old", "young"],
                                               pairAges: ["old": 10_800, "young": 60])
        XCTAssertEqual(Set(kept), Set(["empty", "old"]))
    }

    func testDropdownStaleOldestFirstCap5() {
        let order = (0..<15).map { "c\($0)" }
        var ages: [String: TimeInterval] = [:]
        var thresholds: [String: TimeInterval] = [:]
        for (i, id) in order.enumerated() where id != "c1" {
            ages[id] = TimeInterval(i * 100) // c0 youngest, c14 oldest
            thresholds[id] = 500
        }
        thresholds["c1"] = 500
        let picked = RefreshPlanner.dropdownStale(ages: ages, missing: ["c1"], thresholds: thresholds,
                                                  order: order, cap: 5)
        XCTAssertEqual(picked.count, 5)
        XCTAssertEqual(picked.first, "c1")
        XCTAssertEqual(picked[1], "c14")
        XCTAssertFalse(picked.contains("c0"))
        XCTAssertFalse(picked.contains("c2")) // under threshold
    }

    func testStillDue() {
        XCTAssertTrue(RefreshPlanner.stillDue(id: "a", pairAge: 10_800, role: .background,
                                              wantsIssuance: false, windowVisible: false, dailyLimited: false))
        XCTAssertFalse(RefreshPlanner.stillDue(id: "a", pairAge: 10_799, role: .background,
                                               wantsIssuance: true, windowVisible: false, dailyLimited: false))
        XCTAssertFalse(RefreshPlanner.stillDue(id: "a", pairAge: 10_800, role: .background,
                                               wantsIssuance: false, windowVisible: false, dailyLimited: true))
        XCTAssertTrue(RefreshPlanner.stillDue(id: "a", pairAge: 60, role: .background,
                                              wantsIssuance: true, windowVisible: true, dailyLimited: false))
    }

    // MARK: manualRefreshTargets (M8)

    func testManualRefreshTargetsSelectedMenuBarCases() {
        let selected = city("sel", lat: 40.71)
        let menuBar = city("mb", lat: 40.80)
        let same = city("same")

        let two = RefreshPlanner.manualRefreshTargets(selected: selected, menuBar: menuBar)
        XCTAssertEqual(two.map(\.id), ["sel", "mb"])

        let one = RefreshPlanner.manualRefreshTargets(selected: same, menuBar: same)
        XCTAssertEqual(one.map(\.id), ["same"])

        let viewedOnly = RefreshPlanner.manualRefreshTargets(selected: selected, menuBar: nil)
        XCTAssertEqual(viewedOnly.map(\.id), ["sel"])

        let fallback = city("fallback-first-saved")
        let resolved = RefreshPlanner.manualRefreshTargets(selected: selected, menuBar: fallback,
                                                           saved: [fallback, city("other")])
        XCTAssertEqual(resolved.map(\.id), ["sel", "fallback-first-saved"])
        XCTAssertFalse(resolved.map(\.id).contains("stale-deleted-pin"))
    }

    // MARK: appliesStoreGuard

    func testAppliesStoreGuard() {
        XCTAssertTrue(RefreshPlanner.appliesStoreGuard(role: .freshCadence, allowNetwork: nil))
        XCTAssertTrue(RefreshPlanner.appliesStoreGuard(role: nil, allowNetwork: nil))
        XCTAssertFalse(RefreshPlanner.appliesStoreGuard(role: .background, allowNetwork: nil))
        XCTAssertFalse(RefreshPlanner.appliesStoreGuard(role: .freshCadence, allowNetwork: true))
        XCTAssertFalse(RefreshPlanner.appliesStoreGuard(role: .freshCadence, allowNetwork: false))
        XCTAssertFalse(RefreshPlanner.appliesStoreGuard(role: .background, allowNetwork: true))
    }

    // MARK: retryOwner

    func testRetryOwnerPrefersViewed() {
        let v = city("v")
        let m = city("m")
        XCTAssertEqual(RefreshPlanner.retryOwner(viewed: v, menuBar: m)?.id, "v")
        XCTAssertEqual(RefreshPlanner.retryOwner(viewed: nil, menuBar: m)?.id, "m")
        XCTAssertNil(RefreshPlanner.retryOwner(viewed: nil, menuBar: nil))
    }
}

import Foundation
import XCTest
@testable import SkylineCore

/// Plan §6 items 9–10: RefreshPlanner roles, due, stagger, manualRefreshTargets, store guard.
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

    // MARK: Due (M6)

    func testDueFreshByForecastTTLBackgroundByBackgroundTTL() {
        let cities = [city("fresh"), city("bg")]
        let roles: [String: RefreshPlanner.Role] = ["fresh": .freshCadence, "bg": .background]
        let forecastTTL = WeatherService.TTL.forecast
        let backgroundTTL = WeatherService.TTL.background

        // Young pairs — nothing due.
        let young = RefreshPlanner.due(cities: cities,
                                       pairAges: ["fresh": forecastTTL - 1, "bg": backgroundTTL - 1],
                                       roles: roles)
        XCTAssertTrue(young.fresh.isEmpty)
        XCTAssertTrue(young.background.isEmpty)

        // Fresh past 10 min TTL.
        let freshDue = RefreshPlanner.due(cities: cities,
                                          pairAges: ["fresh": forecastTTL, "bg": 0],
                                          roles: roles)
        XCTAssertEqual(freshDue.fresh, ["fresh"])
        XCTAssertTrue(freshDue.background.isEmpty)

        // Background past background TTL.
        let bgDue = RefreshPlanner.due(cities: cities,
                                       pairAges: ["fresh": 0, "bg": backgroundTTL],
                                       roles: roles)
        XCTAssertTrue(bgDue.fresh.isEmpty)
        XCTAssertEqual(bgDue.background, ["bg"])

        // Missing pair age → due.
        let missing = RefreshPlanner.due(cities: cities, pairAges: [:], roles: roles)
        XCTAssertEqual(missing.fresh, ["fresh"])
        XCTAssertEqual(missing.background, ["bg"])
    }

    func testDueWantsIssuanceEvenIfYoung() {
        let cities = [city("bg")]
        let roles: [String: RefreshPlanner.Role] = ["bg": .background]
        let due = RefreshPlanner.due(cities: cities,
                                     pairAges: ["bg": 60], // young vs background TTL
                                     roles: roles,
                                     wantsIssuance: ["bg": true])
        XCTAssertEqual(due.background, ["bg"])

        let notWanted = RefreshPlanner.due(cities: cities,
                                           pairAges: ["bg": 60],
                                           roles: roles,
                                           wantsIssuance: ["bg": false])
        XCTAssertTrue(notWanted.background.isEmpty)
    }

    // MARK: Stagger

    func testStaggerDelayAtLeast15() {
        for id in ["a", "b", "city-3", "nyc"] {
            XCTAssertGreaterThanOrEqual(RefreshPlanner.staggerDelay(for: id), RefreshPlanner.staggerBase)
            XCTAssertGreaterThanOrEqual(RefreshPlanner.staggerDelay(for: id), 15)
            XCTAssertEqual(RefreshPlanner.staggerDelay(for: id),
                           RefreshPlanner.staggerBase + FetchRetryPolicy.jitter(for: id))
        }
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

        // Deleted pin: caller already resolved LocationList fallback into menuBar.
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

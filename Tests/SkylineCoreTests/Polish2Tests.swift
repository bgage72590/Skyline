import XCTest
@testable import SkylineCore

/// Open items after polish review (#5 duplicates, #6 radar preference). N1 is in ReviewPolish2Tests.
final class Polish2Tests: XCTestCase {
    func city(_ name: String, region: String? = "MA", country: String? = "United States",
              lat: Double, lon: Double, code: String? = "US") -> WeatherLocation {
        WeatherLocation(name: name, region: region, country: country,
                        coordinate: Coordinate(latitude: lat, longitude: lon), countryCode: code)
    }

    func testDuplicateByNameRegionCountryAndByProximity() {
        let a = city("Boston", lat: 42.3601, lon: -71.0589)
        let near = city("Boston", lat: 42.361, lon: -71.059)
        XCTAssertTrue(LocationList.isDuplicate(near, of: a), "within ~1 km (coarse)")
        let named = city("Boston", region: "MA", country: "United States", lat: 48.0, lon: -122.0)
        XCTAssertTrue(LocationList.isDuplicate(named, of: a), "same name+region+country")
        let other = city("Cambridge", lat: 42.373, lon: -71.110)
        XCTAssertFalse(LocationList.isDuplicate(other, of: a))
        let springfieldIL = city("Springfield", region: "IL", country: "United States", lat: 39.78, lon: -89.65)
        let springfieldMA = city("Springfield", region: "MA", country: "United States", lat: 42.10, lon: -72.59)
        XCTAssertFalse(LocationList.isDuplicate(springfieldIL, of: springfieldMA), "different region")
        XCTAssertEqual(LocationList.existingDuplicate(of: near, in: [a, other])?.name, "Boston")
    }

    func testRadarPreferenceSurvivesLeavingCONUS() {
        XCTAssertEqual(RadarProvider.resolved(saved: .nexrad, inCONUS: true), .nexrad)
        XCTAssertEqual(RadarProvider.resolved(saved: .rainViewer, inCONUS: true), .rainViewer)
        XCTAssertEqual(RadarProvider.resolved(saved: .nexrad, inCONUS: false), .rainViewer)
        XCTAssertEqual(RadarProvider.resolved(saved: .rainViewer, inCONUS: false), .rainViewer)
        XCTAssertEqual(RadarProvider.resolved(saved: .nexrad, inCONUS: true), .nexrad)
    }
}

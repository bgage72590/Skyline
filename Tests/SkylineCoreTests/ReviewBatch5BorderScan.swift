import XCTest
@testable import SkylineCore

/// Saved US places (country known) near the border/coast must keep NWS + warnings. Scan of US border / coastal towns: any that the outline puts outside the US lose NWS forecasts AND warnings.
final class ReviewBatch5BorderScan: XCTestCase {
    func testUSTownsAreInside() {
        let conus: [(String, Double, Double)] = [
            ("Eastport ME",44.91,-66.99),("Lubec ME",44.86,-66.98),("Cutler ME",44.66,-67.20),("Machias ME",44.72,-67.46),("Calais ME",45.18,-67.27),
            ("Houlton ME",46.13,-67.84),("Van Buren ME",47.16,-67.94),("Madawaska ME",47.36,-68.33),("Fort Kent ME",47.26,-68.59),("Presque Isle ME",46.68,-68.02),
            ("Jackman ME",45.62,-70.25),("Bar Harbor ME",44.39,-68.20),("Pittsburg NH",45.05,-71.39),("Derby Line VT",45.005,-72.10),("Newport VT",44.94,-72.21),
            ("Rouses Point NY",44.99,-73.36),("Champlain NY",44.99,-73.45),("Malone NY",44.85,-74.29),("Ogdensburg NY",44.69,-75.49),("Alexandria Bay NY",44.34,-75.92),
            ("Cape Vincent NY",44.13,-76.33),("Watertown NY",43.97,-75.91),("Oswego NY",43.46,-76.51),("Rochester NY",43.16,-77.61),("Lewiston NY",43.17,-79.04),
            ("Dunkirk NY",42.48,-79.33),("Erie PA",42.13,-80.09),("Put-in-Bay OH",41.65,-82.82),("Toledo OH",41.65,-83.54),("Algonac MI",42.62,-82.53),
            ("Port Huron MI",42.98,-82.42),("Drummond Is MI",46.0,-83.7),("Mackinac Is MI",45.85,-84.62),("Copper Harbor MI",47.47,-87.89),("Isle Royale MI",48.0,-88.9),
            ("Grand Portage MN",47.96,-89.68),("International Falls MN",48.60,-93.41),("Baudette MN",48.71,-94.60),("Warroad MN",48.91,-95.31),("Pembina ND",48.97,-97.24),
            ("Sweetgrass MT",48.99,-111.96),("Sumas WA",48.999,-122.26),("Blaine WA",48.99,-122.75),("Port Angeles WA",48.12,-123.43),("Neah Bay WA",48.37,-124.62),
            ("Forks WA",47.95,-124.39),("Astoria OR",46.19,-123.83),("Crescent City CA",41.76,-124.20),("Eureka CA",40.80,-124.16),("Monterey CA",36.60,-121.89),
            ("San Ysidro CA",32.55,-117.04),("Calexico CA",32.68,-115.50),("Yuma AZ",32.69,-114.62),("Douglas AZ",31.34,-109.55),("Columbus NM",31.83,-107.64),
            ("Presidio TX",29.56,-104.37),("Del Rio TX",29.36,-100.90),("Eagle Pass TX",28.71,-100.50),("Laredo TX",27.51,-99.51),("Zapata TX",26.91,-99.27),
            ("Roma TX",26.41,-99.02),("Rio Grande City TX",26.38,-98.82),("Hidalgo TX",26.10,-98.26),("McAllen TX",26.20,-98.23),("South Padre TX",26.10,-97.17),
            ("Corpus Christi TX",27.80,-97.40),("Galveston TX",29.30,-94.80),("Grand Isle LA",29.24,-90.0),("Venice LA",29.28,-89.35),("Dauphin Is AL",30.25,-88.11),
            ("Apalachicola FL",29.73,-84.98),("Cedar Key FL",29.14,-83.03),("Naples FL",26.14,-81.79),("Marathon FL",24.71,-81.09),("Dry Tortugas FL",24.63,-82.87),
            ("Miami FL",25.76,-80.19),("Cape Canaveral FL",28.39,-80.60),("Charleston SC",32.78,-79.93),("Ocracoke NC",35.11,-75.98),("Cape May NJ",38.94,-74.91),
            ("Montauk NY",41.07,-71.86),("Block Island RI",41.17,-71.58),("Provincetown MA",42.05,-70.19),("Chatham MA",41.68,-69.96),("Portland ME",43.66,-70.26),
        ]
        let alaska: [(String, Double, Double)] = [("Hyder AK",55.92,-130.02),("Skagway AK",59.46,-135.31),("Haines AK",59.24,-135.44),("Yakutat AK",59.55,-139.73),
            ("Metlakatla AK",55.13,-131.57),("Wrangell AK",56.47,-132.38),("Petersburg AK",56.81,-132.96),("Craig AK",55.48,-133.15),("Unalaska AK",53.87,-166.54)]
        var bad: [String] = []
        func us(_ a: Double, _ b: Double) -> WeatherLocation { WeatherLocation(name: "x", country: "United States", coordinate: Coordinate(latitude: a, longitude: b)) }
        for (n, a, b) in conus where !us(a, b).isInCONUS || !us(a, b).isLikelyInNWSCoverage { bad.append(n) }
        for (n, a, b) in alaska where !us(a, b).isLikelyInNWSCoverage || us(a, b).isInCONUS { bad.append(n) }
        // Canadian/Mexican twins with their saved country stay out.
        for (a, b, c) in [(46.53, -84.33, "Canada"), (45.19, -67.28, "Canada"), (26.09, -98.27, "Mexico"), (42.30, -83.02, "Canada")] {
            let l = WeatherLocation(name: "y", country: c, coordinate: Coordinate(latitude: a, longitude: b))
            if l.isInCONUS || l.isLikelyInNWSCoverage { bad.append("twin \(a),\(b)") }
        }
        print("[review] US towns classified outside: \(bad)")
        XCTAssertEqual(bad, [])
    }
}

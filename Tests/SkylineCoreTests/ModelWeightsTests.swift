import XCTest
@testable import SkylineCore

/// Locked model-weight changes: B1 daily wind de-dup, B2 nearest ASOS, P1 HRRR temperature curve,
/// P2 US ICON temperature, P4 narrow Sint Maarten ICON wind.
final class ModelWeightsTests: XCTestCase {
    let nyc = Coordinate(latitude: 40.71, longitude: -73.99)
    let london = Coordinate(latitude: 51.5, longitude: -0.12)
    let tncm = Coordinate(latitude: 18.04, longitude: -63.11)

    // MARK: P1 — HRRR temperature curve only

    func testHRRRTemperatureCurveFadesBy30h() {
        for variable in ["temperature_2m", "apparent_temperature", "dew_point_2m", "temperature_2m_max", "temperature_2m_min"] {
            XCTAssertEqual(ForecastBlender.weight(.model(.hrrr), variable: variable, leadHours: 12, coordinate: nyc), 3.0, variable)
            XCTAssertEqual(ForecastBlender.weight(.model(.hrrr), variable: variable, leadHours: 0, coordinate: nyc), 3.0, variable)
            XCTAssertEqual(ForecastBlender.weight(.model(.hrrr), variable: variable, leadHours: 30, coordinate: nyc), 0.5, variable)
            XCTAssertEqual(ForecastBlender.weight(.model(.hrrr), variable: variable, leadHours: 48, coordinate: nyc), 0.5, variable)
        }
        // Mid-fade: 12 h → 30 h is the same 2.5 drop the old curve used over 18 h.
        let mid = ForecastBlender.weight(.model(.hrrr), variable: "temperature_2m", leadHours: 21, coordinate: nyc)
        XCTAssertEqual(mid, 1.75, accuracy: 1e-9)
    }

    func testHRRRWindAndPrecipCurvesUnchanged() {
        XCTAssertEqual(ForecastBlender.weight(.model(.hrrr), leadHours: 0), 3.0)
        XCTAssertEqual(ForecastBlender.weight(.model(.hrrr), leadHours: 18), 3.0)
        XCTAssertEqual(ForecastBlender.weight(.model(.hrrr), leadHours: 27), 1.75, accuracy: 1e-9)
        XCTAssertEqual(ForecastBlender.weight(.model(.hrrr), leadHours: 36), 0.5)
        XCTAssertEqual(ForecastBlender.weight(.model(.hrrr), variable: "wind_speed_10m", leadHours: 27, coordinate: nyc),
                       ForecastBlender.weight(.model(.hrrr), leadHours: 27), accuracy: 1e-9)
        XCTAssertEqual(ForecastBlender.weight(.model(.hrrr), variable: "wind_gusts_10m", leadHours: 18, coordinate: nyc), 3.0)
        XCTAssertEqual(ForecastBlender.precipitationWeight(.model(.hrrr), leadHours: 1), 5.0)
        XCTAssertEqual(ForecastBlender.weight(.model(.hrrr), variable: "precipitation", leadHours: 1, coordinate: nyc), 5.0)
        XCTAssertEqual(ForecastBlender.weight(.model(.hrrr), variable: "precipitation", leadHours: 30, coordinate: nyc),
                       ForecastBlender.precipitationWeight(.model(.hrrr), leadHours: 30), accuracy: 1e-9)
        XCTAssertNotEqual(ForecastBlender.weight(.model(.hrrr), variable: "temperature_2m", leadHours: 30),
                          ForecastBlender.weight(.model(.hrrr), variable: "wind_speed_10m", leadHours: 30))
    }

    func testDailyHighUsesHRRRTemperatureLead() throws {
        // Day 1's representative lead is 36 h, where the temperature curve is already 0.5 (wind's daily step is still 1).
        let day0 = 1_790_000_000.0
        let days = [day0, day0 + 86400]
        let json = """
        {"latitude":40.71,"longitude":-73.99,"timezone":"UTC","utc_offset_seconds":0,
         "daily":{"time":\(days),
                  "temperature_2m_max_gfs_hrrr":[20,20],"temperature_2m_min_gfs_hrrr":[0,0],
                  "temperature_2m_max_ecmwf_ifs025":[10,10],"temperature_2m_min_ecmwf_ifs025":[0,0]},
         "hourly":{"time":[\(day0)],"temperature_2m_gfs_hrrr":[15],"temperature_2m_ecmwf_ifs025":[15]}}
        """
        let om = try OpenMeteoResponse.decode(Data(json.utf8))
        let daily = ForecastBlender.blendDaily(openMeteo: om, nwsPeriods: [], timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(daily[0].high, wmean([(20, 3.0), (10, 1.5)]), accuracy: 1e-9)
        XCTAssertEqual(daily[1].high, wmean([(20, 0.5), (10, 1.5)]), accuracy: 1e-9)
    }

    // MARK: P2 — ICON temperature in the US

    func testUSICONTemperatureIsRaisedAndWindIsNot() {
        for variable in ["temperature_2m", "apparent_temperature", "dew_point_2m"] {
            XCTAssertEqual(ForecastBlender.weight(.model(.icon), variable: variable, leadHours: 6, coordinate: nyc), 1.5, variable)
            XCTAssertEqual(ForecastBlender.weight(.model(.icon), variable: variable, leadHours: 48, coordinate: london), 1.0, variable)
        }
        XCTAssertEqual(ForecastBlender.weight(.model(.icon), variable: "wind_speed_10m", leadHours: 6, coordinate: nyc), 1.0)
        XCTAssertEqual(ForecastBlender.weight(.model(.icon), variable: "wind_gusts_10m", leadHours: 12, coordinate: nyc), 1.0)
        XCTAssertEqual(ForecastBlender.weight(.model(.icon), variable: "precipitation", leadHours: 12, coordinate: nyc),
                       ForecastBlender.precipitationWeight(.model(.icon), leadHours: 12))
        XCTAssertEqual(ForecastBlender.weight(.model(.ecmwf), variable: "temperature_2m", leadHours: 12, coordinate: nyc), 1.5)
    }

    func testDailyICONTemperatureFollowsUS() throws {
        let t = 1_790_000_000.0
        func json(lat: Double, lon: Double) -> String {
            """
            {"latitude":\(lat),"longitude":\(lon),"timezone":"UTC","utc_offset_seconds":0,
             "daily":{"time":[\(t)],"temperature_2m_max_icon_seamless":[20],"temperature_2m_min_icon_seamless":[0],
                      "temperature_2m_max_ecmwf_ifs025":[10],"temperature_2m_min_ecmwf_ifs025":[0]},
             "hourly":{"time":[\(t)],"temperature_2m_icon_seamless":[20],"temperature_2m_ecmwf_ifs025":[10]}}
            """
        }
        let us = try OpenMeteoResponse.decode(Data(json(lat: nyc.latitude, lon: nyc.longitude).utf8))
        let abroad = try OpenMeteoResponse.decode(Data(json(lat: london.latitude, lon: london.longitude).utf8))
        let tz = TimeZone(identifier: "UTC")!
        let usHigh = try XCTUnwrap(ForecastBlender.blendDaily(openMeteo: us, nwsPeriods: [], timeZone: tz).first).high
        let abroadHigh = try XCTUnwrap(ForecastBlender.blendDaily(openMeteo: abroad, nwsPeriods: [], timeZone: tz).first).high
        XCTAssertEqual(usHigh, wmean([(20, 1.5), (10, 1.5)]), accuracy: 1e-9)
        XCTAssertEqual(abroadHigh, wmean([(20, 1.0), (10, 1.5)]), accuracy: 1e-9)
    }

    // MARK: P4 — narrow Sint Maarten ICON wind

    func testSmallIslandGateIsNarrow() {
        XCTAssertTrue(ForecastBlender.isSmallIslandWindGate(tncm))
        XCTAssertTrue(ForecastBlender.isSmallIslandWindGate(Coordinate(latitude: 17.0, longitude: -63.5)))
        XCTAssertTrue(ForecastBlender.isSmallIslandWindGate(Coordinate(latitude: 18.6, longitude: -62.5)))
        XCTAssertFalse(ForecastBlender.isSmallIslandWindGate(Coordinate(latitude: 18.04, longitude: -63.51)))
        XCTAssertFalse(ForecastBlender.isSmallIslandWindGate(Coordinate(latitude: 18.61, longitude: -63.1)))
        XCTAssertFalse(ForecastBlender.isSmallIslandWindGate(nyc))
        XCTAssertFalse(ForecastBlender.isSmallIslandWindGate(Coordinate(latitude: 25.76, longitude: -80.19))) // Miami
    }

    func testICONWindOnlyInsideTheGate() {
        XCTAssertEqual(ForecastBlender.weight(.model(.icon), variable: "wind_speed_10m", leadHours: 12, coordinate: tncm), 6.0)
        XCTAssertEqual(ForecastBlender.weight(.model(.icon), variable: "wind_gusts_10m", leadHours: 36, coordinate: tncm), 6.0)
        XCTAssertEqual(ForecastBlender.weight(.model(.ecmwf), variable: "wind_speed_10m", leadHours: 12, coordinate: tncm), 1.5)
        XCTAssertEqual(ForecastBlender.weight(.model(.gfs), variable: "wind_speed_10m", leadHours: 12, coordinate: tncm), 1.0)
        XCTAssertEqual(ForecastBlender.weight(.model(.icon), variable: "temperature_2m", leadHours: 12, coordinate: tncm), 1.0)
        XCTAssertEqual(ForecastBlender.weight(.model(.icon), variable: "precipitation", leadHours: 12, coordinate: tncm),
                       ForecastBlender.weight(.model(.icon), variable: "precipitation", leadHours: 12, coordinate: london))
        let justWest = Coordinate(latitude: 18.04, longitude: -64.0)
        XCTAssertEqual(ForecastBlender.weight(.model(.icon), variable: "wind_speed_10m", leadHours: 12, coordinate: justWest), 1.0)
        XCTAssertEqual(ForecastBlender.weight(.model(.icon), variable: "wind_speed_10m", leadHours: 12, coordinate: nyc), 1.0)
    }

    func testHourlyWindBlendInsideAndOutsideTheGate() throws {
        func json(lat: Double, lon: Double) -> String {
            let t = 1_790_000_000.0
            return """
            {"latitude":\(lat),"longitude":\(lon),"timezone":"UTC","utc_offset_seconds":0,
             "hourly":{"time":[\(t)],"temperature_2m_icon_seamless":[28],"temperature_2m_gfs_seamless":[28],
                       "wind_speed_10m_icon_seamless":[10],"wind_speed_10m_gfs_seamless":[20],
                       "wind_gusts_10m_icon_seamless":[12],"wind_gusts_10m_gfs_seamless":[24]}}
            """
        }
        let now = Date(timeIntervalSince1970: 1_790_000_000 - 3600)
        let inside = try OpenMeteoResponse.decode(Data(json(lat: tncm.latitude, lon: tncm.longitude).utf8))
        let outside = try OpenMeteoResponse.decode(Data(json(lat: 18.04, lon: -64.0).utf8))
        let a = try XCTUnwrap(ForecastBlender.blendHourly(openMeteo: inside, nwsHourly: [], now: now).first)
        let b = try XCTUnwrap(ForecastBlender.blendHourly(openMeteo: outside, nwsHourly: [], now: now).first)
        XCTAssertEqual(a.windSpeed ?? -1, wmean([(10, 6), (20, 1)]), accuracy: 1e-9)
        XCTAssertEqual(a.windGust ?? -1, wmean([(12, 6), (24, 1)]), accuracy: 1e-9)
        XCTAssertEqual(b.windSpeed ?? -1, wmean([(10, 1), (20, 1)]), accuracy: 1e-9)
        XCTAssertEqual(a.temperature, b.temperature, accuracy: 1e-9, "temperature weights are not part of the wind gate")
    }

    // MARK: B1 — daily wind / gust NOAA de-dup, HRRR day excluded

    func testDailyWindDedupesNOAAAndDropsHRRR() throws {
        let day0 = 1_790_000_000.0
        let days = [day0, day0 + 86400, day0 + 2 * 86400]
        let hours = [day0, day0 + 3600, day0 + 7200]
        // Identical NOAA winds: without de-dup, best_match 2 + HRRR 3 + GFS 1 would all count.
        // HRRR's 50 km/h (including the later, truncated days) must not enter. NWS wind must not either.
        // Three matching days so best_match is detected as a GFS/HRRR copy (the US rule).
        let json = """
        {"latitude":40.71,"longitude":-73.99,"timezone":"UTC","utc_offset_seconds":0,
         "daily":{"time":\(days),
                  "temperature_2m_max_best_match":[20,20,20],"temperature_2m_min_best_match":[10,10,10],
                  "temperature_2m_max_gfs_seamless":[20,20,20],"temperature_2m_min_gfs_seamless":[10,10,10],
                  "temperature_2m_max_gfs_hrrr":[20,20,20],"temperature_2m_min_gfs_hrrr":[10,10,10],
                  "temperature_2m_max_ecmwf_ifs025":[18,18,18],"temperature_2m_min_ecmwf_ifs025":[8,8,8],
                  "temperature_2m_max_icon_seamless":[17,17,17],"temperature_2m_min_icon_seamless":[7,7,7],
                  "wind_speed_10m_max_best_match":[20,20,20],"wind_speed_10m_max_gfs_seamless":[20,20,20],
                  "wind_speed_10m_max_gfs_hrrr":[50,50,50],"wind_speed_10m_max_ecmwf_ifs025":[10,10,10],
                  "wind_speed_10m_max_icon_seamless":[30,30,30],
                  "wind_gusts_10m_max_best_match":[40,40,40],"wind_gusts_10m_max_gfs_seamless":[40,40,40],
                  "wind_gusts_10m_max_gfs_hrrr":[90,90,90],"wind_gusts_10m_max_ecmwf_ifs025":[16,16,16],
                  "wind_gusts_10m_max_icon_seamless":[24,24,24]},
         "hourly":{"time":\(hours),
                   "temperature_2m_best_match":[15,15,15],"temperature_2m_gfs_seamless":[15,15,15],
                   "temperature_2m_gfs_hrrr":[15,15,15],"temperature_2m_ecmwf_ifs025":[14,14,14],
                   "temperature_2m_icon_seamless":[13,13,13]}}
        """
        let om = try OpenMeteoResponse.decode(Data(json.utf8))
        let day = Date(timeIntervalSince1970: day0)
        let nws = NWSPeriod(name: "Friday", startTime: day, endTime: day.addingTimeInterval(12 * 3600),
                            isDaytime: true, temperatureC: 21, probabilityOfPrecipitation: nil, relativeHumidity: nil,
                            windSpeedKmh: 100, windDirection: nil, shortForecast: "Sunny", detailedForecast: "")
        let daily = ForecastBlender.blendDaily(openMeteo: om, nwsPeriods: [nws], timeZone: TimeZone(identifier: "UTC")!)
        // Highs still count HRRR (one NOAA vote at 3). Wind does not, and best_match folds into GFS at 1.0.
        XCTAssertEqual(daily[0].high, wmean([(20, 3), (18, 1.5), (17, 1.5), (21, 2.5)]), accuracy: 1e-6)
        let wind = wmean([(20, 1), (10, 1.5), (30, 1)])
        let gust = wmean([(40, 1), (16, 1.5), (24, 1)])
        XCTAssertEqual(daily[0].windSpeedMax ?? -1, wind, accuracy: 1e-6)
        XCTAssertEqual(daily[1].windSpeedMax ?? -1, wind, accuracy: 1e-6, "truncated HRRR day excluded like precip")
        XCTAssertEqual(daily[0].windGustMax ?? -1, gust, accuracy: 1e-6)
        XCTAssertEqual(daily[1].windGustMax ?? -1, gust, accuracy: 1e-6)
    }

    // MARK: B2 — nearest ASOS airport, else the first station

    func testNearestASOSAirportBeatsFirstListEntry() throws {
        let point = Coordinate(latitude: 37.78, longitude: -122.42) // downtown SF
        let json = """
        {"type":"FeatureCollection","features":[
          {"type":"Feature","geometry":{"type":"Point","coordinates":[-122.42,37.78]},
           "properties":{"stationIdentifier":"SFOC1","name":"SAN FRANCISCO DOWNTOWN","provider":"HADS"}},
          {"type":"Feature","geometry":{"type":"Point","coordinates":[-122.22,37.72]},
           "properties":{"stationIdentifier":"KOAK","name":"San Francisco Bay Oakland International Airport","provider":"ASOS-HFM"}},
          {"type":"Feature","geometry":{"type":"Point","coordinates":[-122.37,37.62]},
           "properties":{"stationIdentifier":"KSFO","name":"San Francisco, San Francisco International Airport","provider":"ASOS"}}
        ]}
        """
        let chosen = try XCTUnwrap(NWSObservationParser.verificationStation(Data(json.utf8), near: point))
        XCTAssertEqual(chosen.id, "KSFO")
        XCTAssertEqual(try NWSObservationParser.firstStation(Data(json.utf8))?.id, "SFOC1")
    }

    func testCentralParkASOSIsNotAnAirport() throws {
        let point = Coordinate(latitude: 40.75, longitude: -73.99)
        let json = """
        {"type":"FeatureCollection","features":[
          {"type":"Feature","geometry":{"type":"Point","coordinates":[-73.97,40.78]},
           "properties":{"stationIdentifier":"KNYC","name":"New York City, Central Park","provider":"ASOS"}},
          {"type":"Feature","geometry":{"type":"Point","coordinates":[-73.88,40.78]},
           "properties":{"stationIdentifier":"KLGA","name":"New York, La Guardia Airport","provider":"ASOS"}}
        ]}
        """
        XCTAssertFalse(NWSObservationParser.isASOSAirport(id: "KNYC", provider: "ASOS", name: "New York City, Central Park"))
        XCTAssertFalse(NWSObservationParser.isASOSAirport(id: "SFOC1", provider: "HADS", name: "SAN FRANCISCO DOWNTOWN"))
        XCTAssertTrue(NWSObservationParser.isASOSAirport(id: "KLGA", provider: "ASOS", name: "New York, La Guardia Airport"))
        let chosen = try XCTUnwrap(NWSObservationParser.verificationStation(Data(json.utf8), near: point))
        XCTAssertEqual(chosen.id, "KLGA")
    }

    func testNoASOSFallsBackToFirstStation() throws {
        let point = Coordinate(latitude: 34.05, longitude: -118.25)
        let json = """
        {"type":"FeatureCollection","features":[
          {"type":"Feature","geometry":{"type":"Point","coordinates":[-118.24,34.05]},
           "properties":{"stationIdentifier":"FHMC1","name":"LOS ANGELES DOWNTOWN","provider":"HADS"}},
          {"type":"Feature","geometry":{"type":"Point","coordinates":[-118.40,34.02]},
           "properties":{"stationIdentifier":"KSDB","name":"Sandberg","provider":"ASOS"}}
        ]}
        """
        let chosen = try XCTUnwrap(NWSObservationParser.verificationStation(Data(json.utf8), near: point))
        XCTAssertEqual(chosen.id, "FHMC1")
    }

    func testVerifierStoresNearestASOS() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skyline-asos-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let stations = """
        {"type":"FeatureCollection","features":[
          {"type":"Feature","geometry":{"type":"Point","coordinates":[-73.97,40.78]},
           "properties":{"stationIdentifier":"KNYC","name":"New York City, Central Park","provider":"ASOS"}},
          {"type":"Feature","geometry":{"type":"Point","coordinates":[-73.88,40.78]},
           "properties":{"stationIdentifier":"KLGA","name":"New York, La Guardia Airport","provider":"ASOS"}}
        ]}
        """.data(using: .utf8)!
        let client = ScriptedHTTPClient { url in
            if url.absoluteString.contains("/stations") && !url.absoluteString.contains("/observations") { return stations }
            return Data("{\"features\":[]}".utf8)
        }
        let v = ForecastVerifier(directory: dir, client: client, now: { t0 })
        let rec = ForecastRecord(loc: "nyc", issued: t0.addingTimeInterval(-6 * 3600), valid: t0.addingTimeInterval(-3600),
                                 f: [VerificationSource.blend.rawValue: SourceValues(t: 15)])
        await v.record([rec], key: "nyc")
        let url = URL(string: "https://api.weather.gov/gridpoints/OKX/33,42/stations")!
        await v.verifyIfDue(key: "nyc", stationsURL: url, near: Coordinate(latitude: 40.75, longitude: -73.99))
        let report = await v.report("nyc")
        XCTAssertEqual(report.stationID, "KLGA")
        XCTAssertEqual(report.stationName, "New York, La Guardia Airport")
    }
}

/// Returns scripted bodies. Used so station selection can run through `ForecastVerifier` without fixtures.
private final class ScriptedHTTPClient: HTTPClient, @unchecked Sendable {
    let body: @Sendable (URL) -> Data
    init(_ body: @escaping @Sendable (URL) -> Data) { self.body = body }
    func get(_ url: URL, headers: [String: String]) async throws -> Data { body(url) }
}

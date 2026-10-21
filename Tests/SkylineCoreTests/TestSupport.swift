import Foundation
import XCTest
@testable import SkylineCore

enum Fixture {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing fixture \(name)"])
        }
        return try Data(contentsOf: url)
    }
}

/// Serves fixture JSON based on URL, records requests, can be switched offline.
final class MockHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URL] = []
    private var _offline = false

    var requests: [URL] { lock.lock(); defer { lock.unlock() }; return _requests }
    var offline: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _offline }
        set { lock.lock(); _offline = newValue; lock.unlock() }
    }

    /// Appends the request and returns whether we're offline (sync so the lock isn't held across awaits).
    private func record(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        _requests.append(url)
        return _offline
    }

    func get(_ url: URL, headers: [String: String]) async throws -> Data {
        if record(url) { throw URLError(.notConnectedToInternet) }
        let s = url.absoluteString
        let name: String
        if s.contains("air-quality-api.open-meteo.com") { name = "om_aqi" }
        else if s.contains("geocoding-api.open-meteo.com") { name = "om_geo" }
        else if s.contains("api.open-meteo.com") {
            // A/B pair: serve the matching half of the multi-model fixture (CR M1).
            let fixture = s.contains("latitude=48.") ? "om_paris" : "om_nyc"
            let full = try OpenMeteoResponse.decode(Fixture.data(fixture))
            let halves = full.splitPairHalves()
            let isB = s.contains("minutely_15") || s.contains("current=")
                || (s.contains("models=best_match") && !s.contains("models=best_match,"))
            return try OpenMeteoResponse.encode(isB ? halves.b : halves.a)
        }
        else if s.contains("api.weather.gov/points") { name = "nws_points" }
        else if s.contains("forecast/hourly") { name = "nws_hourly" }
        else if s.contains("api.weather.gov/gridpoints") { name = "nws_forecast" }
        else if s.contains("api.weather.gov/alerts") { name = "nws_alerts" }
        else if s.contains("api.weather.gov/products/types/AFD") { name = "nws_afd_list" }
        else if s.contains("api.weather.gov/products/") { name = "nws_afd_okx" }
        else if s.contains("spc.noaa.gov") { name = "spc_day1_test" }
        else if s.contains("rainviewer") { name = "rainviewer" }
        else if s.contains("mesonet.agron.iastate.edu") { name = "iem_n0q" }
        else { throw HTTPError.status(404, url) }
        return try Fixture.data(name)
    }
}

/// Mutable clock for cache TTL tests.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ now: Date) { _now = now }
    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return _now }
        set { lock.lock(); _now = newValue; lock.unlock() }
    }
}

func fToC(_ f: Double) -> Double { (f - 32) * 5 / 9 }

/// Plain weighted mean for expected values in tests.
func wmean(_ pairs: [(Double, Double)]) -> Double {
    var sum = 0.0, total = 0.0
    for (v, w) in pairs { sum += v * w; total += w }
    return sum / total
}

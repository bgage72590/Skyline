import Foundation
import SkylineCore

/// QA hook client (`-SkylineSimulateOffline`): every request fails as if the Mac had no network.
struct OfflineHTTPClient: HTTPClient {
    func get(_ url: URL, headers: [String: String]) async throws -> Data {
        throw URLError(.notConnectedToInternet)
    }
}

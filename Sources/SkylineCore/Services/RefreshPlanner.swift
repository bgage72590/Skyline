import Foundation

/// Pure refresh planning: city roles, due lists, stagger spacing, ⌘R targets, and the daily-limit
/// retry owner. Roles are computed per call and never stored on `WeatherLocation`.
public enum RefreshPlanner {
    public enum Role: Equatable, Sendable {
        /// Viewed ∪ menu-bar ∪ notify cities: 10-min OM TTL.
        case freshCadence
        /// Everyone else: `WeatherService.TTL.background`.
        case background
    }

    public struct Due: Equatable, Sendable {
        /// Fresh-cadence cities due now (loaded directly).
        public var fresh: [String]
        /// Background cities due by TTL or issuance (append to the store's stagger queue).
        public var background: [String]

        public init(fresh: [String] = [], background: [String] = []) {
            self.fresh = fresh; self.background = background
        }
    }

    /// Minimum gap between background network refreshes (≥15 s + per-city jitter).
    public static let staggerBase: TimeInterval = 15

    public static func staggerDelay(for id: String) -> TimeInterval {
        staggerBase + FetchRetryPolicy.jitter(for: id)
    }

    /// Fresh-cadence = viewed ∪ menu-bar ∪ notify (when notifications are on). Everyone else is background.
    public static func role(for id: String, viewedID: String?, menuBarID: String?,
                            notifyIDs: Set<String>) -> Role {
        if id == viewedID || id == menuBarID || notifyIDs.contains(id) { return .freshCadence }
        return .background
    }

    public static func roles(cities: [WeatherLocation], viewedID: String?, menuBarID: String?,
                             notifyIDs: Set<String>) -> [String: Role] {
        Dictionary(uniqueKeysWithValues: cities.map {
            ($0.id, role(for: $0.id, viewedID: viewedID, menuBarID: menuBarID, notifyIDs: notifyIDs))
        })
    }

    /// Cities whose OM pair is due. `pairAges[id]` = age of the pair (older half); nil = no pair.
    /// `wantsIssuance[id]` = M6: due for a background refresh even inside the background TTL.
    public static func due(now: Date = Date(),
                           cities: [WeatherLocation],
                           pairAges: [String: TimeInterval],
                           roles: [String: Role],
                           wantsIssuance: [String: Bool] = [:],
                           forecastTTL: TimeInterval = WeatherService.TTL.forecast,
                           backgroundTTL: TimeInterval = WeatherService.TTL.background) -> Due {
        var fresh: [String] = []
        var background: [String] = []
        var seen = Set<String>()
        for city in cities {
            let id = city.id
            guard seen.insert(id).inserted else { continue }
            let role = roles[id] ?? .background
            let age = pairAges[id]
            switch role {
            case .freshCadence:
                if age == nil || age! >= forecastTTL { fresh.append(id) }
            case .background:
                let ttlDue = age == nil || age! >= backgroundTTL
                let issueDue = wantsIssuance[id] == true
                if ttlDue || issueDue { background.append(id) }
            }
        }
        return Due(fresh: fresh, background: background)
    }

    /// ⌘R / toolbar force targets: distinct ids of {selected, menuBar}. Nil menu-bar → viewed only.
    /// Deleted pin uses the LocationList fallback the caller already resolved into `menuBar`.
    public static func manualRefreshTargets(selected: WeatherLocation?,
                                            menuBar: WeatherLocation?,
                                            saved: [WeatherLocation] = []) -> [WeatherLocation] {
        var out: [WeatherLocation] = []
        var seen = Set<String>()
        for loc in [selected, menuBar].compactMap({ $0 }) {
            if seen.insert(loc.id).inserted { out.append(loc) }
        }
        // `saved` is unused for targeting (M8: never assign savedLocations); kept so call sites can
        // pass the list for pin-deleted fallback resolution done before this call.
        _ = saved
        return out
    }

    /// Only the viewed city (else the menu-bar city) schedules a daily-limit probe/retry.
    public static func retryOwner(viewed: WeatherLocation?, menuBar: WeatherLocation?) -> WeatherLocation? {
        viewed ?? menuBar
    }

    /// Whether the 10-min store guard applies: only fresh-cadence with no explicit allowNetwork.
    public static func appliesStoreGuard(role: Role?, allowNetwork: Bool?) -> Bool {
        allowNetwork == nil && (role == nil || role == .freshCadence)
    }
}

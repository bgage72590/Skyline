import Foundation

/// Pure refresh planning: city roles, due lists, stagger spacing, ⌘R targets, and the daily-limit
/// retry owner. Roles are computed per call and never stored on `WeatherLocation`.
public enum RefreshPlanner {
    public enum Role: Equatable, Sendable {
        /// Viewed ∪ menu-bar ∪ notify cities: 10-min OM TTL (or notify-reuse while hidden).
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

    /// Spacing across hide / wake / restart: never fire sooner than `staggerDelay` after the last dequeue.
    public static func nextDequeueDelay(lastDequeueAt: Date?, now: Date, id: String) -> TimeInterval {
        guard let last = lastDequeueAt else { return 0 }
        return max(0, last.addingTimeInterval(staggerDelay(for: id)).timeIntervalSince(now))
    }

    /// Skip ids already queued or currently loading (in-flight dedupe).
    public static func shouldEnqueue(id: String, queued: Set<String>, loading: Set<String>) -> Bool {
        !queued.contains(id) && !loading.contains(id)
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

    /// Cities whose OM pair is due. `pairAges[id]` = age of the pair; nil = no pair.
    /// Background TTL-due applies whether the window is visible or hidden (Decision 2).
    /// Issuance-only due only when `windowVisible` (store only sets wantsIssuance then).
    /// While hidden, notify cities use `notifyReuseTTL` for OM due-ness (Decision 2 N).
    public static func due(now: Date = Date(),
                           cities: [WeatherLocation],
                           pairAges: [String: TimeInterval],
                           roles: [String: Role],
                           wantsIssuance: [String: Bool] = [:],
                           forecastTTL: TimeInterval = WeatherService.TTL.forecast,
                           backgroundTTL: TimeInterval = WeatherService.TTL.background,
                           windowVisible: Bool = true,
                           notifyReuseTTL: TimeInterval = WeatherService.TTL.notifyReuseHidden,
                           notifyIDs: Set<String> = []) -> Due {
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
                let ttl: TimeInterval
                if !windowVisible, notifyIDs.contains(id) {
                    ttl = notifyReuseTTL
                } else {
                    ttl = forecastTTL
                }
                if age == nil || age! >= ttl { fresh.append(id) }
            case .background:
                let ttlDue = age == nil || age! >= backgroundTTL
                let issueDue = windowVisible && wantsIssuance[id] == true
                if ttlDue || issueDue { background.append(id) }
            }
        }
        return Due(fresh: fresh, background: background)
    }

    /// Re-check at dequeue: still due under current ages / role / window / daily-limit.
    public static func stillDue(id: String,
                                pairAge: TimeInterval?,
                                role: Role,
                                wantsIssuance: Bool,
                                windowVisible: Bool,
                                dailyLimited: Bool,
                                forecastTTL: TimeInterval = WeatherService.TTL.forecast,
                                backgroundTTL: TimeInterval = WeatherService.TTL.background,
                                notifyReuseTTL: TimeInterval = WeatherService.TTL.notifyReuseHidden,
                                isNotify: Bool = false) -> Bool {
        _ = id
        if dailyLimited, role == .background { return false }
        switch role {
        case .freshCadence:
            let ttl = (!windowVisible && isNotify) ? notifyReuseTTL : forecastTTL
            return pairAge == nil || pairAge! >= ttl
        case .background:
            let ttlDue = pairAge == nil || pairAge! >= backgroundTTL
            let issueDue = windowVisible && wantsIssuance
            return ttlDue || issueDue
        }
    }

    /// On hide: keep queue entries still due under hidden rules (no report or TTL-due).
    /// Drop issuance-only extras.
    public static func retainOnHide(ids: [String],
                                    pairAges: [String: TimeInterval],
                                    backgroundTTL: TimeInterval = WeatherService.TTL.background) -> [String] {
        ids.filter { id in
            guard let age = pairAges[id] else { return true }
            return age >= backgroundTTL
        }
    }

    /// Dropdown backstop: filter stale → oldest first (no report first) → cap.
    /// Pass age only for cities with a report; `missing` = no-report ids. `order` is saved-list order.
    public static func dropdownStale(ages: [String: TimeInterval],
                                     missing: Set<String> = [],
                                     thresholds: [String: TimeInterval],
                                     order: [String],
                                     cap: Int = 5) -> [String] {
        let stale = order.filter { id in
            if missing.contains(id) { return true }
            guard let age = ages[id] else { return false }
            let threshold = thresholds[id] ?? WeatherService.TTL.background
            return age >= threshold
        }
        let sorted = stale.sorted { a, b in
            let missingA = missing.contains(a)
            let missingB = missing.contains(b)
            if missingA != missingB { return missingA && !missingB }
            let ageA = ages[a] ?? 0
            let ageB = ages[b] ?? 0
            if ageA != ageB { return ageA > ageB }
            return (order.firstIndex(of: a) ?? 0) < (order.firstIndex(of: b) ?? 0)
        }
        return Array(sorted.prefix(max(0, cap)))
    }

    /// ⌘R / toolbar force targets: distinct ids of {selected, menuBar}. Nil menu-bar → viewed only.
    public static func manualRefreshTargets(selected: WeatherLocation?,
                                            menuBar: WeatherLocation?,
                                            saved: [WeatherLocation] = []) -> [WeatherLocation] {
        var out: [WeatherLocation] = []
        var seen = Set<String>()
        for loc in [selected, menuBar].compactMap({ $0 }) {
            if seen.insert(loc.id).inserted { out.append(loc) }
        }
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

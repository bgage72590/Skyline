import Foundation

/// Role of each city's last network load. The age banner keeps the background threshold until a
/// fresh-cadence attempt is recorded for that city. The next attempt replaces the stored role;
/// nothing clears the book.
public struct FreshAttemptBook: Equatable, Sendable {
    public var lastAttemptRole: [String: RefreshPlanner.Role]

    public init(lastAttemptRole: [String: RefreshPlanner.Role] = [:]) {
        self.lastAttemptRole = lastAttemptRole
    }

    public mutating func recordAttempt(id: String, role: RefreshPlanner.Role) {
        lastAttemptRole[id] = role
    }

    /// Background threshold when the city is fresh-cadence but its last attempt was background
    /// (or it has not been attempted). Otherwise the threshold for `currentRole`.
    public func displayStaleAfter(id: String, currentRole: RefreshPlanner.Role, refreshMinutes: Int) -> TimeInterval {
        if currentRole == .freshCadence {
            switch lastAttemptRole[id] {
            case .background, nil:
                return DataAge.staleAfter(refreshMinutes: refreshMinutes, role: .background)
            case .freshCadence:
                break
            }
        }
        return DataAge.staleAfter(refreshMinutes: refreshMinutes, role: currentRole)
    }
}

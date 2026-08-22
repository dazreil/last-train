import Foundation

/**
 Whether a departure is close enough to earn a live countdown.

 Kept in the domain package so every surface uses the same boundary and the rule can be
 tested without ActivityKit. Four hours is deliberately inclusive: a train exactly four
 hours away is inside the window; one second beyond it is not.
 */
public enum CountdownWindow {
    public static let duration: TimeInterval = 4 * 60 * 60

    public enum Eligibility: Equatable, Sendable {
        case eligible
        case departed
        case tooFar
    }

    public static func eligibility(
        departure: Date,
        now: Date = .now
    ) -> Eligibility {
        let wait = departure.timeIntervalSince(now)
        guard wait > 0 else { return .departed }
        return wait <= duration ? .eligible : .tooFar
    }
}

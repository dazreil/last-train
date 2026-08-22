import Foundation
import Testing

import LastTrainCore

@Suite("Live countdown window")
struct CountdownWindowTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("a future departure within four hours is eligible")
    func inside() {
        #expect(
            CountdownWindow.eligibility(
                departure: now.addingTimeInterval(3 * 60 * 60),
                now: now
            ) == .eligible
        )
    }

    @Test("the four-hour boundary is inclusive")
    func boundary() {
        #expect(
            CountdownWindow.eligibility(
                departure: now.addingTimeInterval(CountdownWindow.duration),
                now: now
            ) == .eligible
        )
    }

    @Test("a departure beyond four hours is too far away")
    func outside() {
        #expect(
            CountdownWindow.eligibility(
                departure: now.addingTimeInterval(CountdownWindow.duration + 1),
                now: now
            ) == .tooFar
        )
    }

    @Test("now and the past have already departed")
    func departed() {
        #expect(CountdownWindow.eligibility(departure: now, now: now) == .departed)
        #expect(
            CountdownWindow.eligibility(
                departure: now.addingTimeInterval(-1),
                now: now
            ) == .departed
        )
    }
}

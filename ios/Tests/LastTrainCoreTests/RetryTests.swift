import Foundation
import Testing

import LastTrainCore

/**
 The backoff behind the widget's reload policy.

 The bug this exists to prevent was not subtle once seen: a failed lookup produced an
 entry dated *now*, and the policy asked to reload after that entry — so the widget
 requested again immediately, for as long as the failure lasted.
 */
@Suite("WidgetRetry")
struct RetryTests {

    @Test("the first failure waits, rather than retrying at once")
    func firstFailureWaits() {
        #expect(WidgetRetry.delay(afterConsecutiveFailures: 1) == WidgetRetry.base)
        #expect(WidgetRetry.delay(afterConsecutiveFailures: 1) > 0)
    }

    @Test("each further failure doubles the wait")
    func doublesEachTime() {
        #expect(WidgetRetry.delay(afterConsecutiveFailures: 2) == WidgetRetry.base * 2)
        #expect(WidgetRetry.delay(afterConsecutiveFailures: 3) == WidgetRetry.base * 4)
        #expect(WidgetRetry.delay(afterConsecutiveFailures: 4) == WidgetRetry.base * 8)
    }

    /**
     The ceiling is the point of the whole thing.

     A long outage is most likely our own deployment being down, and a widget doubling
     without limit would either overflow or wait a fortnight. Two hours keeps it polite
     and still recovers the same day.
     */
    @Test("the wait is capped however long the outage runs")
    func capped() {
        for failures in [8, 20, 500, Int.max / 2] {
            let delay = WidgetRetry.delay(afterConsecutiveFailures: failures)
            #expect(delay == WidgetRetry.ceiling, "\(failures) failures should sit at the ceiling")
            #expect(delay.isFinite)
        }
    }

    /// A caller that has lost count must still wait, not retry immediately.
    @Test("zero and nonsense counts still wait")
    func nonsenseStillWaits() {
        #expect(WidgetRetry.delay(afterConsecutiveFailures: 0) == WidgetRetry.base)
        #expect(WidgetRetry.delay(afterConsecutiveFailures: -3) == WidgetRetry.base)
    }

    @Test("the next attempt is always in the future")
    func nextAttemptIsAhead() {
        let now = Date()
        for failures in [0, 1, 5, 99] {
            #expect(WidgetRetry.nextAttempt(afterConsecutiveFailures: failures, from: now) > now)
        }
    }
}

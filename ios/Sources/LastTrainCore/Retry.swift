import Foundation

/**
 How long to wait before a widget asks again, having failed.

 A timeline's reload policy is the only thing standing between a broken lookup and a
 request loop. The provider used to hand WidgetKit `.after(last.date)` where the entry
 was dated *now* — which is a request as fast as the system will allow one, for as long
 as the failure lasts. WidgetKit throttles a badly-behaved widget rather than obeying it,
 so the symptom is not a flood; it is a widget that stops updating and a budget spent on
 nothing.

 Three states did it, not only the obvious one:

 - a failed lookup,
 - a widget with no station chosen yet, which cannot succeed until somebody acts,
 - a board with no departure still ahead of it, which `Glance.reloadDate` already had a
   fallback for that the provider was not using.

 Doubling from ten minutes to a two-hour ceiling. Ten is short enough that a blip
 recovers while you are still walking to the station; the ceiling matters because the
 realistic cause of a long outage is our own deployment being down, and a widget hammering
 a server that is already unwell is the wrong thing to do with the last of its budget.
 */
public enum WidgetRetry {

    /// The first wait, and the unit everything doubles from.
    public static let base: TimeInterval = 10 * 60

    /// Never longer than this, however long the outage.
    public static let ceiling: TimeInterval = 2 * 60 * 60

    /**
     The wait after `failures` consecutive failures.

     `failures` is the count *including* the one that just happened, so the first failure
     asks for `base`. Zero and negatives return `base` rather than nothing: a caller that
     has lost count should still wait.
     */
    public static func delay(afterConsecutiveFailures failures: Int) -> TimeInterval {
        guard failures > 1 else { return base }

        // Capped before the shift so a long outage cannot overflow the exponent.
        let doublings = min(failures - 1, 8)
        return min(base * pow(2, Double(doublings)), ceiling)
    }

    /// The same, as a date to hand a timeline policy.
    public static func nextAttempt(
        afterConsecutiveFailures failures: Int,
        from now: Date = Date()
    ) -> Date {
        now.addingTimeInterval(delay(afterConsecutiveFailures: failures))
    }
}

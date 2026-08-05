import Foundation

/**
 A whole board reduced to the one line a widget has room for.

 IOS.md §7 names the widget as the thing that justifies going native at all — "last
 train home on the lock screen, updating through the evening". A lock screen accessory
 is about the size of a sentence, so the board has to become a single answer, and
 choosing *which* departure that is turns out to be the entire design.

 **The answer is the last train, not the next one.** A next-train widget is a different
 product; this app exists because the interesting departure is the one after which you
 are walking. So through the whole evening the widget shows the same time — the last
 train — and it is only after that train has gone that the answer changes, to the first
 one back. That stillness is the feature. A number that does not move is a number you
 can trust at a glance.

 The exception is the pre-service window. Between 03:00 and the day's first departure
 nothing has run yet, so the board is in its `preService` arrangement and the day's last
 train is twenty hours away. At 03:30 the honest answer is the first train out, and
 that is what this returns.

 ### One fetch is enough

 Both answers are already on the board. A `normal` board carries the last trains *and*
 the first one back, which is precisely the pair this switches between — so the widget
 never needs a second request to cross that boundary, and the reload can wait until
 every departure it is holding has gone. The board is timetabled rather than live, so
 that is usually one fetch per station-day. IOS.md §10 worried that widget refreshes
 would drive upstream volume; they do not, because the timeline is computed from data
 already in hand.

 No SwiftUI here, and no WidgetKit — this is the part worth testing.
 */
public struct Glance: Sendable, Equatable {

    /// What to call the departure being shown. The widget turns these into words.
    public enum Label: String, Sendable, Equatable {
        /// The last train of the service day on the board. The red one.
        case lastTrain
        /// The first train of the *next* service day, because tonight's have all gone.
        case firstBack
        /// The first train out of a service day that has not started running yet.
        case firstOut
    }

    public let label: Label
    /// The departure the widget leads with.
    public let departure: BoardDeparture
    /// Everything still to come, in departure order, `departure` included.
    public let remaining: [BoardDeparture]

    /// Whether the headline departure is the service day's last train, and so is red.
    public var isLastTrain: Bool { label == .lastTrain }

    /**
     Reduce a board to what the widget shows, or nil when there is nothing left on it.

     Nil is a real outcome rather than a failure: a direction with no service at all
     produces an empty board, and after the last departure of a `preService` board there
     is genuinely nothing further in hand. The widget says so plainly, the same way the
     app does — `PRODUCT.md` is explicit that a blank result has to be trustworthy.
     */
    public static func of(board: DepartureBoard, now: Date = Date()) -> Glance? {
        let remaining = board.services.filter { service in
            guard let instant = ServiceDay.instant(from: service.depInstant) else {
                // Unparseable is treated as gone rather than as still to come. A time
                // that cannot be read cannot be relied on to tell you to run.
                return false
            }
            return instant > now
        }

        guard let leader = remaining.first else { return nil }

        // Nothing has run yet today, so the day's last train is most of a day away and
        // the first one out is the answer. The board still carries that last train, and
        // this deliberately does not lead with it.
        if board.mode == .preService {
            let firstOut = remaining.first { $0.role == .first } ?? leader
            return Glance(label: .firstOut, departure: firstOut, remaining: remaining)
        }

        // The evening case, and the common one: the last train while it can still be
        // caught. It stays the answer no matter how many departures pass in front of it.
        if let last = board.lastTrain, remaining.contains(where: { $0.id == last.id }) {
            return Glance(label: .lastTrain, departure: last, remaining: remaining)
        }

        // It has gone. What is left on a normal board is the first train back, which was
        // fetched with everything else -- so crossing this boundary costs no request.
        return Glance(label: .firstBack, departure: leader, remaining: remaining)
    }

    // MARK: - Timeline

    /**
     The moments at which this board starts saying something different.

     Every departure that passes shortens `remaining`, and one of them — the last train
     — also changes the headline. Handing WidgetKit an entry for each means the widget
     stays correct through the evening on data it already holds, rather than by waking up
     to ask again.

     A second past each departure rather than on it. WidgetKit treats an entry date as
     the moment it *may* render, not a guarantee it renders no earlier, and a render that
     lands a few hundred milliseconds short would evaluate on the wrong side of the
     boundary and redraw the departure that is leaving as though it were still to come.
     A second of slack costs nothing and removes the wobble.
     */
    public static func changePoints(board: DepartureBoard, now: Date = Date()) -> [Date] {
        board.services
            .compactMap { ServiceDay.instant(from: $0.depInstant) }
            .filter { $0 > now }
            .sorted()
            .map { $0.addingTimeInterval(1) }
    }

    /**
     When the widget has to go back to the network, having run out of board.

     After the final departure on it there is nothing left to compute from, so this is
     the one point a request is genuinely required. `fallback` covers the boards that
     never had a future departure in them at all, which would otherwise ask again
     immediately and keep asking.
     */
    public static func reloadDate(
        board: DepartureBoard,
        now: Date = Date(),
        fallback: TimeInterval = 60 * 60
    ) -> Date {
        let exhausted = changePoints(board: board, now: now).last
        return exhausted ?? now.addingTimeInterval(fallback)
    }
}

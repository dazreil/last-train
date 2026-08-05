import Foundation

/**
 Which shape the board takes, decided by the clock.

 A port of `lib/board.ts`. The app answers "what is the last train home, and if I miss
 it, what is the first one back" — two different questions at two different times of
 night, and a fixed arrangement gets one of them wrong:

 - At 22:00 the last trains are the answer, and the first train that is any use is
   tomorrow morning's. Today's first train left before breakfast; printing it under
   "first train" fills space with a departure that has already gone.
 - Between the last train of a service day and the first of the next, there is no last
   train left to catch. What you need is the next few departures, with the day's last
   one still visible because that is the thing this app is for.

 So there are two arrangements, and one rule chooses between them: has the first train
 of the service day on the board departed yet?

 | | |
 |---|---|
 | `normal` | last three of the day, then the first train of the next day |
 | `preService` | first three of the day, then that same day's last train |

 Both read top to bottom in departure order, and in both the red block is the last
 train of the service day on the board. Red never means anything else.

 Times are read through `ServiceDay.instant(from:)`, so this is correct for the API's
 timezone-less London wall-clock strings. Comparing them any other way reintroduces
 the bug `ServiceDay` exists to prevent.
 */
public enum BoardMode: String, Sendable, Codable {
    case normal
    /// Hyphenated to match what `lib/board.ts` puts on the wire. Swift's default
    /// raw value would be `preService`, which decodes to nothing.
    case preService = "pre-service"
}

/// Which part of the answer a service is: a first train, or a last one.
public enum ServiceRole: String, Sendable, Codable {
    case first
    case last
}

/// Which service day a block is drawn from, relative to the one on the board.
public enum BoardDay: Sendable {
    case current
    case next
}

/// The minimum a service has to look like for the board rules to read it.
public protocol BoardService {
    var role: ServiceRole { get }
    /// The departure, in whatever form the API gave it.
    var departure: String { get }
}

public enum Board {

    // MARK: - Which arrangement

    /**
     Pre-service when the service day on the board has not started running.

     That window opens at 03:00, when the service day rolls over, and closes at the
     day's first departure — a real time read from the timetable, never a guessed
     hour. It differs by station and by day: a Sunday first train is well after a
     Monday one, and a rural branch later than either.

     Within one service day this can only ever go `preService → normal`, never back,
     because the first departure does not move and the clock only advances. That
     one-way property is what makes a cached answer safe to keep — see `hasExpired`.

     A past or future service day is never pre-service: nothing on it has "not started
     yet" with respect to a clock it does not contain.
     */
    public static func mode(
        isLiveServiceDay: Bool,
        firstDeparture: String?,
        now: Date = Date()
    ) -> BoardMode {
        guard isLiveServiceDay,
              let firstDeparture,
              let first = ServiceDay.instant(from: firstDeparture)
        else { return .normal }

        return now < first ? .preService : .normal
    }

    /**
     True once every train of the service day on the board has gone.

     Only reachable between the last departure and 03:00 — at 00:40 on Sunday morning,
     Saturday's service day is still the current one but has nothing left in it. A
     board of departures that have all been and gone answers nothing, so the useful day
     is the next one and the caller moves to it.

     A day with nothing running is *not* spent: nothing ran, so nothing was missed, and
     an empty board is its own answer rather than a reason to skip ahead.
     */
    public static func isServiceDaySpent(lastDeparture: String?, now: Date = Date()) -> Bool {
        guard let lastDeparture, let last = ServiceDay.instant(from: lastDeparture) else {
            return false
        }
        return now > last
    }

    /**
     Whether a stored answer has outlived the arrangement it was built for.

     Answers are cached by station, direction and date, deliberately *without* the mode
     in the key: the mode is only known after the line-up has been read, and keying on
     it would mean a cache miss forcing a fresh API call at exactly the moment the
     line-up cache has aged out.

     So the boundary is checked on read instead. A pre-service answer holds the day's
     first departures, and therefore carries the very time that decides its own
     validity; once that train has gone the answer is the wrong shape and is rebuilt. A
     normal answer cannot go stale this way, because the transition only runs one
     direction within a service day.
     */
    public static func hasExpired(
        mode: BoardMode,
        services: [some BoardService],
        now: Date = Date()
    ) -> Bool {
        guard mode == .preService else { return false }
        guard let firstOut = services.first(where: { $0.role == .first }),
              let departure = ServiceDay.instant(from: firstOut.departure)
        else { return false }
        return departure <= now
    }

    // MARK: - Which departures

    public struct Selection<T>: Sendable where T: Sendable {
        public let item: T
        public let role: ServiceRole

        public init(item: T, role: ServiceRole) {
            self.item = item
            self.role = role
        }
    }

    /**
     Which departures the board is made of.

     Kept apart from the fetching so the arrangement can be tested without an API: the
     caller passes a `take`, which yields the first or last few qualifying departures of
     a service day, and this decides what to ask it for. The result comes back in
     departure order, which is also the order it is shown in.

     **The one thing to preserve if this is ever edited: pre-service must never ask for
     the next day.** Each service day costs a station line-up, the free tier allows ten
     requests a minute, and a pre-service board is answerable entirely out of the day it
     is already holding. There is a test that says so.
     */
    public static func select<T: Identifiable & Sendable>(
        mode: BoardMode,
        take: (_ day: BoardDay, _ fromEnd: Bool, _ wanted: Int) async throws -> [T]
    ) async rethrows -> [Selection<T>] {
        if mode == .preService {
            let lastTrain = try await take(.current, true, 1)
            let firstThree = try await take(.current, false, 3).filter { candidate in
                // On a quiet enough day the last train is also one of the first three.
                // It belongs to the last-train block, which is where the red goes --
                // listing it twice would be the same train contradicting itself.
                !lastTrain.contains { $0.id == candidate.id }
            }

            return firstThree.map { Selection(item: $0, role: .first) }
                + lastTrain.map { Selection(item: $0, role: .last) }
        }

        let lastThree = try await take(.current, true, 3)

        // Skipped when nothing runs this way today. An empty board is answered by
        // saying so, not by offering tomorrow morning instead -- and it saves a
        // line-up at every station where the direction is a dead end.
        let firstBack = lastThree.isEmpty ? [] : try await take(.next, false, 1)

        return lastThree.map { Selection(item: $0, role: .last) }
            + firstBack.map { Selection(item: $0, role: .first) }
    }
}

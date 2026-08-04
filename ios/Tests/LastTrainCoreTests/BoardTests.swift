import Foundation
import Testing

import LastTrainCore

/**
 A port of `lib/board.test.ts`.

 Departure times use the shape the API actually sends: a London wall-clock time with no
 timezone at all. `now` is written as a true instant, with the London time it
 corresponds to in a comment, because those two differing by an hour through BST is why
 this runs under `TZ=UTC`.
 */
@Suite("Board")
struct BoardTests {

    // MARK: - Which arrangement

    @Test("a service day that has not started yet leads with its first trains")
    func dayNotStartedLeadsWithFirstTrains() {
        #expect(
            Board.mode(
                isLiveServiceDay: true,
                firstDeparture: "2026-08-02T06:04:00",
                now: utcInstant("2026-08-02T02:00:00Z") // 03:00 London, the day just rolled over
            ) == .preService
        )
    }

    @Test("once the day is running the board is the normal way round")
    func runningDayIsNormal() {
        #expect(
            Board.mode(
                isLiveServiceDay: true,
                firstDeparture: "2026-08-02T06:04:00",
                now: utcInstant("2026-08-02T21:00:00Z") // 22:00 London, what the app is for
            ) == .normal
        )
    }

    /**
     06:04 London in August is 05:04Z. Read the API string as UTC instead — which is
     what any timezone-less parse does — and this same clock reads as an hour before the
     first train rather than half an hour after it, flipping the board into the wrong
     shape for the whole of the early morning.
     */
    @Test("the boundary is the first departure itself, resolved as London")
    func boundaryIsResolvedAsLondon() {
        let first = "2026-08-02T06:04:00"

        // 06:30 London: it has gone.
        #expect(Board.mode(isLiveServiceDay: true, firstDeparture: first,
                           now: utcInstant("2026-08-02T05:30:00Z")) == .normal)
        // 05:30 London: it has not.
        #expect(Board.mode(isLiveServiceDay: true, firstDeparture: first,
                           now: utcInstant("2026-08-02T04:30:00Z")) == .preService)
        // Exactly 06:04 London: it is leaving, not waiting.
        #expect(Board.mode(isLiveServiceDay: true, firstDeparture: first,
                           now: utcInstant("2026-08-02T05:04:00Z")) == .normal)
    }

    @Test("the same rule holds under GMT")
    func ruleHoldsUnderGmt() {
        #expect(Board.mode(isLiveServiceDay: true, firstDeparture: "2026-12-13T07:12:00",
                           now: utcInstant("2026-12-13T03:00:00Z")) == .preService)
        #expect(Board.mode(isLiveServiceDay: true, firstDeparture: "2026-12-13T07:12:00",
                           now: utcInstant("2026-12-13T09:00:00Z")) == .normal)
    }

    @Test("a day other than the live one is never pre-service")
    func otherDaysAreNeverPreService() {
        // Tomorrow's board is a timetable, not a countdown. Nothing on it has "not
        // started yet" with respect to a clock it does not contain.
        #expect(Board.mode(isLiveServiceDay: false, firstDeparture: "2026-08-03T06:04:00",
                           now: utcInstant("2026-08-02T02:00:00Z")) == .normal)
    }

    @Test("a day with nothing running is never pre-service")
    func emptyDayIsNeverPreService() {
        #expect(Board.mode(isLiveServiceDay: true, firstDeparture: nil,
                           now: utcInstant("2026-08-02T02:00:00Z")) == .normal)
    }

    // MARK: - Spent days

    @Test("a service day is spent once its last train has gone")
    func dayIsSpentAfterLastTrain() {
        // Saturday's last train leaves at 00:22 on Sunday morning and is still
        // Saturday's. 00:22 London in August is 23:22Z.
        let last = "2026-08-02T00:22:00"

        #expect(Board.isServiceDaySpent(lastDeparture: last, now: utcInstant("2026-08-01T23:40:00Z")))   // 00:40
        #expect(!Board.isServiceDaySpent(lastDeparture: last, now: utcInstant("2026-08-01T23:00:00Z")))  // 00:00
    }

    @Test("a day with nothing running is not spent")
    func emptyDayIsNotSpent() {
        // Nothing ran, so nothing has been missed. An empty board is its own answer and
        // must not push the app on to the next day looking for one.
        #expect(!Board.isServiceDaySpent(lastDeparture: nil, now: utcInstant("2026-08-01T23:40:00Z")))
    }

    // MARK: - Cached answers

    private struct StoredService: BoardService {
        let role: ServiceRole
        let departure: String
    }

    @Test("a pre-service answer expires when the first train it leads with departs")
    func preServiceAnswerExpires() {
        let services = [
            StoredService(role: .first, departure: "2026-08-02T05:04:00Z"), // 06:04 London
            StoredService(role: .first, departure: "2026-08-02T05:34:00Z"),
            StoredService(role: .last, departure: "2026-08-02T22:47:00Z"),
        ]

        #expect(!Board.hasExpired(mode: .preService, services: services,
                                  now: utcInstant("2026-08-02T04:00:00Z")))
        #expect(Board.hasExpired(mode: .preService, services: services,
                                 now: utcInstant("2026-08-02T05:30:00Z")))
    }

    @Test("a normal answer does not expire this way")
    func normalAnswerDoesNotExpire() {
        // Within one service day the shape only ever goes pre-service -> normal, so a
        // normal answer stays the right shape until its TTL runs out.
        let services = [
            StoredService(role: .last, departure: "2026-08-02T22:47:00Z"),
            StoredService(role: .first, departure: "2026-08-03T05:04:00Z"),
        ]
        #expect(!Board.hasExpired(mode: .normal, services: services,
                                  now: utcInstant("2026-08-03T12:00:00Z")))
    }

    @Test("a pre-service answer with no first train left is not treated as expired")
    func preServiceWithNoFirstTrainIsNotExpired() {
        // One train all day: it is the last train, so it is shown as one, and there is
        // no first-train entry whose departure could decide anything.
        let services = [StoredService(role: .last, departure: "2026-08-02T22:47:00Z")]
        #expect(!Board.hasExpired(mode: .preService, services: services,
                                  now: utcInstant("2026-08-02T04:00:00Z")))
    }

    // MARK: - Selection

    private struct Train: Identifiable, Sendable, Equatable {
        let id: String
    }

    /**
     Stands in for the route's lazy walk along a day's departures.

     Records what it was asked for, which is how the tests below check that a
     pre-service board never reaches for the next service day — a rate-limit guarantee
     rather than a detail, because each day costs a station line-up.
     */
    private final class Taker: @unchecked Sendable {
        private let current: [Train]
        private let next: [Train]
        private(set) var asked: [String] = []

        init(current: [String], next: [String] = []) {
            self.current = current.map(Train.init(id:))
            self.next = next.map(Train.init(id:))
        }

        func take(_ day: BoardDay, _ fromEnd: Bool, _ wanted: Int) async -> [Train] {
            asked.append(day == .current ? "current" : "next")
            let all = day == .current ? current : next
            return fromEnd ? Array(all.suffix(wanted)) : Array(all.prefix(wanted))
        }
    }

    private func shape(_ board: [Board.Selection<Train>]) -> [String] {
        board.map { "\($0.role.rawValue):\($0.item.id)" }
    }

    @Test("a normal board is the last three, then the first train of the next day")
    func normalBoardIsLastThreeThenFirstBack() async {
        let taker = Taker(current: ["a", "b", "c", "d", "e"], next: ["n1", "n2", "n3"])
        let board = await Board.select(mode: .normal, take: taker.take)

        // Departure order, and the first train back is the next morning's, not this
        // morning's -- which is the whole point of the block moving to the bottom.
        #expect(shape(board) == ["last:c", "last:d", "last:e", "first:n1"])
        #expect(taker.asked == ["current", "next"])
    }

    @Test("an empty day never reaches for the next one")
    func emptyDayNeverFetchesNextDay() async {
        // The rate limit is ten requests a minute and each day costs a line-up. Nothing
        // runs this way, so there is nothing to miss and nothing to look up.
        let taker = Taker(current: [], next: ["n1"])
        let board = await Board.select(mode: .normal, take: taker.take)

        #expect(shape(board).isEmpty)
        #expect(taker.asked == ["current"])
    }

    @Test("a pre-service board is the first three, then that same day's last train")
    func preServiceBoardIsFirstThreeThenLast() async {
        let taker = Taker(current: ["a", "b", "c", "d", "e"], next: ["n1"])
        let board = await Board.select(mode: .preService, take: taker.take)

        #expect(shape(board) == ["first:a", "first:b", "first:c", "last:e"])
        // Answered entirely out of the day already in hand: no second line-up.
        #expect(taker.asked == ["current", "current"])
    }

    @Test("a train that is both first and last is only shown as the last one")
    func trainThatIsBothIsShownOnceAsLast() async {
        // Three trains all day: the third is both the last of the first three and the
        // last of the day. Red goes on the genuine last train, nothing listed twice.
        let three = Taker(current: ["a", "b", "c"])
        #expect(await shape(Board.select(mode: .preService, take: three.take))
                == ["first:a", "first:b", "last:c"])

        let two = Taker(current: ["a", "b"])
        #expect(await shape(Board.select(mode: .preService, take: two.take))
                == ["first:a", "last:b"])

        // One train all day: it is the last train, and that is all it is.
        let one = Taker(current: ["a"])
        #expect(await shape(Board.select(mode: .preService, take: one.take)) == ["last:a"])
    }
}

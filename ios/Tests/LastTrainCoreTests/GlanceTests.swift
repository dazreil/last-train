import Foundation
import Testing

import LastTrainCore

/**
 What the widget shows, and when it changes.

 Boards come from `Fixtures.swift`, decoded from JSON copied out of live
 `/api/v2/trains` responses. `now` is always written as a true UTC instant with the
 London time beside it, because the whole suite runs under `TZ=UTC` and 5 August is BST.
 */
@Suite("Glance")
struct GlanceTests {

    // MARK: - Which departure

    /**
     The point of the whole thing. At 19:00, at 22:00 and at 23:52 the widget says the
     same thing — 00:42 — even though a departure passed in between. A next-train widget
     would have shown three different times across those three readings and answered a
     question this app is not for.
     */
    @Test("the last train is the answer all evening, however many trains pass")
    func lastTrainHoldsThroughTheEvening() throws {
        let evening = upminsterEastEvening()

        for (clock, london) in [
            ("2026-08-05T18:00:00Z", "19:00"),
            ("2026-08-05T21:00:00Z", "22:00"),
            ("2026-08-05T22:52:00Z", "23:52, one train already gone"),
        ] {
            let glance = try #require(Glance.of(board: evening, now: utcInstant(clock)))
            #expect(glance.label == .lastTrain, "at \(london)")
            #expect(glance.departure.dep == "00:42", "at \(london)")
            #expect(glance.isLastTrain, "at \(london)")
        }
    }

    @Test("once the last train has gone the answer is the first one back")
    func afterTheLastTrainComesTheFirstBack() throws {
        let glance = try #require(
            Glance.of(
                board: upminsterEastEvening(),
                now: utcInstant("2026-08-05T23:45:00Z") // 00:45 London, three minutes late
            )
        )

        #expect(glance.label == .firstBack)
        #expect(glance.departure.dep == "05:00")
        #expect(!glance.isLastTrain)
    }

    /**
     At its own departure time a train is leaving, not waiting.

     Not an arbitrary tie-break: it is the rule `Board.mode` already applies to the
     first departure of a service day — "exactly 06:04 London: it is leaving, not
     waiting" — and the two would contradict each other for one minute a night
     otherwise, which is precisely the minute this app is about.
     */
    @Test("a train at its own departure time has gone, not arrived")
    func departureMinuteCountsAsGone() throws {
        let evening = upminsterEastEvening()

        let aMinuteBefore = try #require(
            Glance.of(board: evening, now: utcInstant("2026-08-05T23:41:00Z"))
        )
        #expect(aMinuteBefore.label == .lastTrain)

        let onTheMinute = try #require(
            Glance.of(board: evening, now: utcInstant("2026-08-05T23:42:00Z"))
        )
        #expect(onTheMinute.label == .firstBack)
    }

    /**
     At 03:30 the day's last train is twenty hours away and naming it would be a
     technically true answer to nobody's question. The board carries it — this
     deliberately leads with the first one out instead.
     */
    @Test("before the day has started, the first train out leads")
    func beforeServiceTheFirstTrainLeads() throws {
        let glance = try #require(
            Glance.of(
                board: upminsterEastBeforeService(),
                now: utcInstant("2026-08-06T02:30:00Z") // 03:30 London
            )
        )

        #expect(glance.label == .firstOut)
        #expect(glance.departure.dep == "05:00")
        #expect(!glance.isLastTrain)
        // The day's last train is still on the board, just not leading.
        #expect(glance.remaining.contains { $0.dep == "00:57" })
    }

    @Test("nothing left on the board is nil, not an empty answer dressed up")
    func nothingLeftIsNil() {
        #expect(
            Glance.of(
                board: upminsterEastEvening(),
                now: utcInstant("2026-08-06T05:00:00Z") // 06:00 London, all four gone
            ) == nil
        )
    }

    @Test("a direction with no service at all produces nothing to show")
    func emptyBoardProducesNothing() {
        let empty = board(mode: "normal", date: "2026-08-05", firstDate: "2026-08-06", services: [])
        #expect(Glance.of(board: empty, now: utcInstant("2026-08-05T18:00:00Z")) == nil)
    }

    @Test("departures that have gone are not offered as still to come")
    func remainingExcludesDepartedTrains() throws {
        let glance = try #require(
            Glance.of(
                board: upminsterEastEvening(),
                now: utcInstant("2026-08-05T23:00:00Z") // 00:00 London, 23:51 has gone
            )
        )

        #expect(glance.remaining.map(\.dep) == ["00:18", "00:42", "05:00"])
    }

    // MARK: - Timeline

    /**
     The reason the widget is nearly free. Four departures produce four entries from one
     response, so it counts down through the evening and crosses the last-train boundary
     without asking the server anything — which is what IOS.md §10 wanted to be true of
     widget refreshes.
     */
    @Test("one board yields an entry for every departure still to come")
    func everyDepartureBecomesAnEntry() {
        let points = Glance.changePoints(
            board: upminsterEastEvening(),
            now: utcInstant("2026-08-05T18:00:00Z") // 19:00 London
        )

        #expect(points.count == 4)
        #expect(utcString(points.first) == "2026-08-05T22:51:01Z")
        #expect(utcString(points.last) == "2026-08-06T04:00:01Z")
    }

    @Test("entries land a second past each departure, not on it")
    func entriesLandAfterTheDeparture() throws {
        let evening = upminsterEastEvening()
        let points = Glance.changePoints(board: evening, now: utcInstant("2026-08-05T18:00:00Z"))

        // Whatever an entry is timed for, evaluating the glance at that moment must
        // agree the train is gone. Timed on the minute it would not.
        let atLastTrainBoundary = try #require(points.first { utcString($0) == "2026-08-05T23:42:01Z" })
        let glance = try #require(Glance.of(board: evening, now: atLastTrainBoundary))
        #expect(glance.label == .firstBack)
    }

    @Test("passed departures do not get entries")
    func passedDeparturesGetNoEntries() {
        let points = Glance.changePoints(
            board: upminsterEastEvening(),
            now: utcInstant("2026-08-05T23:00:00Z") // 00:00 London
        )
        #expect(points.count == 3)
    }

    @Test("the reload waits until the board has nothing left in it")
    func reloadWaitsForTheLastDeparture() {
        let reload = Glance.reloadDate(
            board: upminsterEastEvening(),
            now: utcInstant("2026-08-05T18:00:00Z")
        )
        #expect(utcString(reload) == "2026-08-06T04:00:01Z")
    }

    /**
     Without this a board with no future departure asks again the instant it is drawn,
     and keeps asking. WidgetKit would throttle it, but the request budget is spent
     either way.
     */
    @Test("a board with nothing ahead of it still waits before asking again")
    func exhaustedBoardStillWaits() {
        let now = utcInstant("2026-08-06T05:00:00Z")
        let reload = Glance.reloadDate(board: upminsterEastEvening(), now: now, fallback: 1800)
        #expect(reload == now.addingTimeInterval(1800))
    }
}

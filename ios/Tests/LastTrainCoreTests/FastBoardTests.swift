import Foundation
import Testing

import LastTrainCore

/**
 The Fast Train ranking rule.

 Times are written as timezone-less London strings, which is the shape the API sends, and
 `now` is written as a true UTC instant. The suite runs under `TZ=UTC`, so a rule that
 reads a London string as UTC fails here rather than on a platform in August.
 */
@Suite("FastBoard")
struct FastBoardTests {

    private func service(
        _ id: String,
        _ stops: [(String, String)],
        from: String = "UPM",
        to: String = "SOC"
    ) -> FastService? {
        FastBoard.service(
            from: from,
            to: to,
            serviceId: id,
            headcode: id,
            toc: "CC",
            finalDestination: "Shoeburyness",
            calls: serviceCalls(stops.map { (crs: $0.0, time: $0.1) })
        )
    }

    // MARK: - The point of the mode

    /**
     The case §11 was written around, and the whole reason the mode exists.

     The Tilbury train leaves first and arrives last. A departure board cannot show you
     that; ordering by arrival is the only thing that can.
     */
    @Test("the train that leaves first is not always the one that arrives first")
    func arrivalBeatsDeparture() throws {
        let viaTilbury = try #require(
            service("tilbury", [
                ("UPM", "2026-08-10T17:12:00"),
                ("GRY", "2026-08-10T17:30:00"),
                ("SOC", "2026-08-10T18:05:00"),
            ])
        )
        let viaBasildon = try #require(
            service("basildon", [
                ("UPM", "2026-08-10T17:27:00"),
                ("LAI", "2026-08-10T17:40:00"),
                ("SOC", "2026-08-10T17:52:00"),
            ])
        )

        let ranked = FastBoard.rank([viaTilbury, viaBasildon])

        #expect(ranked.map(\.serviceId) == ["basildon", "tilbury"])
        // The later departure wins, which is the answer a departure board cannot give.
        #expect(ranked[0].departure == "17:27")
        #expect(ranked[0].journeyMinutes == 25)
        #expect(ranked[1].journeyMinutes == 53)
    }

    // MARK: - What is not a candidate

    @Test("a train that never calls at your destination is dropped")
    func mustCallAtTheDestination() {
        #expect(
            service("nope", [
                ("UPM", "2026-08-10T17:12:00"),
                ("LAI", "2026-08-10T17:30:00"),
            ]) == nil
        )
    }

    /**
     The same pair appears in both directions.

     A Southend train through Upminster calls at both, and so does the train coming back.
     Only the order in the pattern tells them apart — so the destination is searched for
     from the boarding point on, never from the start.
     */
    @Test("a train going the other way is dropped, though it calls at both")
    func directionComesFromTheOrder() {
        #expect(
            service("wrongway", [
                ("SOC", "2026-08-10T17:00:00"),
                ("GRY", "2026-08-10T17:25:00"),
                ("UPM", "2026-08-10T17:45:00"),
            ]) == nil
        )
    }

    @Test("a stop with no time cannot be ranked, so the train is dropped")
    func timesAreRequired() {
        let missing = serviceCalls([
            (crs: "UPM", time: "2026-08-10T17:12:00"),
            (crs: "SOC", time: nil),
        ])

        #expect(
            FastBoard.service(
                from: "UPM", to: "SOC", serviceId: "x", headcode: nil, toc: "CC",
                finalDestination: "Shoeburyness", calls: missing
            ) == nil
        )
    }

    // MARK: - The service day

    /**
     23:50 to 00:15 is twenty-five minutes, not a journey that ends before it starts.
     Resolving these as London through `ServiceDay` is what makes that true in August,
     and comparing the clock strings would make it false.
     */
    @Test("a journey across midnight is still going forwards")
    func acrossMidnight() throws {
        let overnight = try #require(
            service("late", [
                ("UPM", "2026-08-10T23:50:00"),
                ("SOC", "2026-08-11T00:15:00"),
            ])
        )

        #expect(overnight.journeyMinutes == 25)
        #expect(overnight.arrivesAt > overnight.departsAt)
    }

    // MARK: - Ordering and limits

    @Test("trains that arrive together are listed with the earlier departure first")
    func tiesBreakOnDeparture() throws {
        let early = try #require(
            service("early", [("UPM", "2026-08-10T17:00:00"), ("SOC", "2026-08-10T18:00:00")])
        )
        let late = try #require(
            service("late", [("UPM", "2026-08-10T17:20:00"), ("SOC", "2026-08-10T18:00:00")])
        )

        #expect(FastBoard.rank([late, early]).map(\.serviceId) == ["early", "late"])
    }

    @Test("four are shown, however many are found")
    func showsFour() throws {
        let many = try (0..<9).map { index in
            try #require(
                service("s\(index)", [
                    ("UPM", "2026-08-10T17:0\(index):00"),
                    ("SOC", "2026-08-10T18:0\(index):00"),
                ])
            )
        }

        #expect(FastBoard.rank(many).count == FastBoard.shown)
        #expect(FastBoard.rank(many, limit: 0).isEmpty)
    }

    @Test("a train that has left is not a candidate")
    func onlyUpcoming() throws {
        let gone = try #require(
            service("gone", [("UPM", "2026-08-10T17:00:00"), ("SOC", "2026-08-10T18:00:00")])
        )
        let ahead = try #require(
            service("ahead", [("UPM", "2026-08-10T19:00:00"), ("SOC", "2026-08-10T20:00:00")])
        )

        // 18:00 London on 10 August is 17:00Z.
        let upcoming = FastBoard.upcoming([gone, ahead], now: utcInstant("2026-08-10T17:00:00Z"))
        #expect(upcoming.map(\.serviceId) == ["ahead"])
    }
}

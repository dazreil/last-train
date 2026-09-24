import Foundation
import Testing

import LastTrainCore

/// Live expected times from Darwin: what shows, what ranks, and which train is red.
@Suite("Live times")
struct LiveTimesTests {

    /// A board whose rows can carry live fields, built from the wire shape.
    private func liveBoard(_ rows: [String]) -> DepartureBoard {
        let json = """
        {
          "from": { "crs": "UPM", "name": "Upminster", "locality": null },
          "direction": "east", "date": "2026-08-05", "mode": "normal", "firstDate": "2026-08-06",
          "services": [\(rows.joined(separator: ","))],
          "directions": { "north": 0, "east": 3, "south": 0, "west": 0 },
          "available": ["east"], "unclassified": 0, "totalServices": 3,
          "towards": ["Shoeburyness"], "towardsByDirection": { "east": ["Shoeburyness"] }
        }
        """
        return try! JSONDecoder().decode(DepartureBoard.self, from: Data(json.utf8))
    }

    private func row(_ dep: String, _ instant: String, role: String = "last", extra: String = "") -> String {
        """
        { "dep": "\(dep)", "depInstant": "\(instant)", "toc": "CC", "tocName": "c2c",
          "destination": "Shoeburyness", "platform": "2", "isReplacementBus": false,
          "headcode": "2S\(dep.prefix(2))", "serviceId": "gb-nr:\(dep)", "role": "\(role)"\(extra) }
        """
    }

    @Test("a late train shows its expected time and how late it is")
    func lateTrain() {
        let board = liveBoard([
            row("00:27", "2026-08-05T23:27:00.000Z",
                extra: #", "expectedDep": "00:34", "expectedDepInstant": "2026-08-05T23:34:00.000Z""#),
        ])
        let train = board.services[0]
        #expect(train.liveDep == "00:34")
        #expect(train.dep == "00:27")
        #expect(train.minutesLate == 7)
        #expect(train.instant == utcInstant("2026-08-05T23:34:00Z"))
    }

    @Test("an older deployment's row, with no live fields, reads as on time")
    func noLiveFields() {
        let train = liveBoard([row("00:27", "2026-08-05T23:27:00.000Z")]).services[0]
        #expect(train.liveDep == "00:27")
        #expect(train.minutesLate == nil)
        #expect(!train.delayed)
        #expect(!train.cancelled)
    }

    /// The owner's rule: a cancelled last train hands the red to the one before.
    @Test("a cancelled last train is not the last train")
    func cancelledLastTrain() {
        let board = liveBoard([
            row("23:51", "2026-08-05T22:51:00.000Z"),
            row("00:27", "2026-08-05T23:27:00.000Z", extra: #", "isCancelled": true"#),
            row("05:00", "2026-08-06T04:00:00.000Z", role: "first"),
        ])
        #expect(board.lastTrain?.dep == "23:51")
        #expect(board.services.count == 3)
    }

    @Test("if every last-train row is cancelled, the latest keeps the name")
    func allCancelled() {
        let board = liveBoard([
            row("00:27", "2026-08-05T23:27:00.000Z", extra: #", "isCancelled": true"#),
        ])
        #expect(board.lastTrain?.dep == "00:27")
    }

    private func fast(_ dep: String, _ arr: String, expectedDep: String? = nil, expectedArr: String? = nil) -> FastService {
        func at(_ hhmm: String) -> Date { utcInstant("2026-08-05T\(hhmm):00Z") }
        return FastService(
            serviceId: dep, headcode: nil, toc: "CC", destination: "Southend Central",
            departure: dep, arrival: arr, departsAt: at(dep), arrivesAt: at(arr),
            expectedDeparture: expectedDep, expectedArrival: expectedArr,
            expectedDepartsAt: expectedDep.map(at), expectedArrivesAt: expectedArr.map(at)
        )
    }

    /// The owner's rule: Fast Train ranks by when a train will really arrive.
    @Test("a late fast train drops behind a slower one that will arrive first")
    func ranksByExpectedArrival() {
        let fastButLate = fast("19:00", "19:30", expectedDep: "19:15", expectedArr: "19:45")
        let slowOnTime = fast("19:05", "19:40")
        #expect(FastBoard.rank([fastButLate, slowOnTime]).map(\.serviceId) == ["19:05", "19:00"])
    }

    @Test("a train past its timetabled time but running late can still be caught")
    func lateTrainIsStillUpcoming() {
        let late = fast("19:00", "19:30", expectedDep: "19:10", expectedArr: "19:40")
        let now = utcInstant("2026-08-05T19:05:00Z")
        #expect(FastBoard.upcoming([late], now: now).count == 1)
        #expect(late.minutesLate == 10)
        #expect(late.journeyMinutes == 30)
    }
}

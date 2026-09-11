import Foundation
import Testing

@testable import LastTrainCore

/**
 The wire contract for the two-to-four-hour window.

 `DARWIN-INGEST.md` §3 stage 4. These three fields are how the window stopped failing
 silently, and all three are optional on purpose: an older deployment sends none of them
 and must still decode. A test that only checked the happy shape would let that
 compatibility rot without noticing.
 */
@Suite("Timetable window")
struct TimetableWindowTests {

    private func decodeBoard(_ json: String) throws -> FastBoardResponse {
        try JSONDecoder().decode(FastBoardResponse.self, from: Data(json.utf8))
    }

    private let service = """
    {"serviceId":"r1","headcode":null,"toc":"CC","tocName":"c2c","destination":"Shoeburyness",
     "departure":"20:05","departureInstant":"2026-09-10T20:05:00",
     "arrival":"21:12","arrivalInstant":"2026-09-10T21:12:00","platform":"1"}
    """

    private func board(extra: String) -> String {
        """
        {"from":{"crs":"FST","name":"London Fenchurch Street","locality":null},
         "to":{"crs":"SRY","name":"Shoeburyness","locality":null},
         "date":"2026-09-10","services":[\(service)],"candidates":1,"truncated":false\(extra)}
        """
    }

    @Test("a board with no notice means there is nothing wrong")
    func noNotice() throws {
        let decoded = try decodeBoard(board(extra: ""))
        #expect(decoded.notice == nil)
        #expect(decoded.source == nil)
        #expect(decoded.services.count == 1)
    }

    @Test("a notice survives, because it is the whole point")
    func notice() throws {
        let decoded = try decodeBoard(
            board(extra: #","notice":"No timetable has been published for today yet.","source":"timetable""#)
        )
        #expect(decoded.notice == "No timetable has been published for today yet.")
        #expect(decoded.source == "timetable")
    }

    @Test("an empty board with a notice is not the same as an empty board without one")
    func emptyMeansTwoThings() throws {
        let empty = """
        {"from":{"crs":"FST","name":"London Fenchurch Street","locality":null},
         "to":{"crs":"SRY","name":"Shoeburyness","locality":null},
         "date":"2026-09-10","services":[],"candidates":0,"truncated":false
        """
        // Could not find out.
        let unknown = try decodeBoard(empty + #","notice":"The timetable could not be read just now."}"#)
        // There are none.
        let none = try decodeBoard(empty + "}")

        #expect(unknown.services.isEmpty)
        #expect(none.services.isEmpty)
        // Identical train lists, opposite meanings. Only the notice tells them apart, and
        // the board must never claim the window is exhausted on the first.
        #expect(unknown.notice != nil)
        #expect(none.notice == nil)
    }

    @Test("a train is live unless it says otherwise")
    func scheduledDefaultsToFalse() throws {
        let decoded = try decodeBoard(board(extra: ""))
        // Every deployment before the timetable sent no such field, and everything it sent
        // was live. Absent must therefore mean live, never scheduled.
        #expect(decoded.services[0].isScheduled == false)
    }

    @Test("a scheduled train says so")
    func scheduledDecodes() throws {
        let scheduled = service.replacingOccurrences(
            of: #""platform":"1""#,
            with: #""platform":"1","isScheduled":true"#
        )
        let decoded = try JSONDecoder().decode(FastService.self, from: Data(scheduled.utf8))
        #expect(decoded.isScheduled)
    }

    @Test("an older deployment's board still decodes")
    func backwardCompatible() throws {
        // Exactly what the API sent before stage 4: no notice, no source, no isScheduled.
        let decoded = try decodeBoard(board(extra: ""))
        #expect(decoded.services[0].serviceId == "r1")
        #expect(decoded.services[0].isScheduled == false)
        #expect(decoded.notice == nil)
    }
}

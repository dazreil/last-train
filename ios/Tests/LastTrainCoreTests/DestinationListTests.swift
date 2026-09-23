import Foundation
import Testing

@testable import LastTrainCore

/**
 The destination list as the picker reads it.

 With no direction chosen, the server sends every direction at once and each station
 carries its own. The picker groups on that, and the row a passenger taps is the direction
 they are heading — so the decoding and the grouping are what "which way" rests on.
 */
@Suite("Destination list")
struct DestinationListTests {

    private func decode(_ json: String) throws -> DestinationList {
        try JSONDecoder().decode(DestinationList.self, from: Data(json.utf8))
    }

    private let everyWay = """
    {"from":{"crs":"UPM","name":"Upminster"},"direction":null,"date":"2026-09-23",
     "destinations":[
       {"crs":"WHR","name":"West Horndon","minutes":6,"direction":"east","trains":60},
       {"crs":"OCK","name":"Ockendon","minutes":5,"direction":"south","trains":40},
       {"crs":"EMP","name":"Emerson Park","minutes":4,"direction":"west","trains":30},
       {"crs":"BKG","name":"Barking","minutes":8,"direction":"west","trains":117}
     ],"truncated":false,"comparedWith":["north","east","south","west"],"source":"timetable"}
    """

    @Test("a list with no direction decodes, and says it has none")
    func noDirection() throws {
        let list = try decode(everyWay)
        #expect(list.direction == nil)
        #expect(list.destinations.count == 4)
        #expect(list.destinations.first { $0.crs == "BKG" }?.direction == .west)
    }

    @Test("grouped in compass order, each group in the order it came")
    func grouped() throws {
        let groups = try decode(everyWay).byDirection
        #expect(groups.map(\.direction) == [.east, .south, .west])
        #expect(groups.last?.destinations.map(\.crs) == ["EMP", "BKG"])
    }

    @Test("a station two directions reach equally is two rows, not one")
    func tieIsTwoRows() throws {
        let tied = try decode("""
        {"from":{"crs":"CLJ","name":"Clapham Junction"},"direction":null,"date":"2026-09-23",
         "destinations":[
           {"crs":"WNT","name":"Wandsworth Town","minutes":2,"direction":"north"},
           {"crs":"WNT","name":"Wandsworth Town","minutes":2,"direction":"west"}
         ],"truncated":false,"comparedWith":[]}
        """)
        // One identity per row. With the station code alone, SwiftUI would see two rows with
        // one id, and the tap on either would be ambiguous about which way you meant.
        #expect(Set(tied.destinations.map(\.id)).count == 2)
        #expect(tied.byDirection.map(\.direction) == [.north, .west])
    }

    @Test("a list for one direction still decodes as it always has")
    func oneDirection() throws {
        let list = try decode("""
        {"from":{"crs":"UPM","name":"Upminster"},"direction":"west","date":"2026-09-23",
         "destinations":[{"crs":"BKG","name":"Barking","minutes":8}],
         "truncated":false,"comparedWith":["east"]}
        """)
        #expect(list.direction == .west)
        // An older server sends no per-station direction. That must still decode.
        #expect(list.destinations.first?.direction == nil)
    }
}

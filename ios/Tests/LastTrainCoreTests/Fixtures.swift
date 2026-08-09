import Foundation

import LastTrainCore

// MARK: - The national station list

/**
 The bundled station list, read exactly the way the app reads it.

 These tests used to reach up the directory tree for `data/national.json`, which worked
 for a test and would never have worked for an app — an app ships as a bundle and has
 no repo to climb. Now `npm run national:data` writes the same bytes to both places and
 `Stations` loads the bundled copy through `Bundle.module`, so the tests exercise the
 real path rather than a convenient one.
 */
enum National {
    static var stations: [Station] { Stations.all }
    static func find(_ crs: String) -> Station? { Stations.find(crs) }
}

/// Deterministic pseudo-random, so a failure is reproducible.
struct Lcg {
    private var state: UInt32

    init(seed: UInt32) { self.state = seed }

    mutating func next() -> Double {
        state = state &* 1_664_525 &+ 1_013_904_223
        return Double(state) / Double(UInt32.max)
    }
}

/**
 An absolute instant, written as UTC.

 Test inputs standing for "now" are always written this way, with the London time
 they correspond to in a comment, because those two differing by an hour through BST
 is the entire reason these tests exist.
 */
func utcInstant(_ iso: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: iso) else {
        preconditionFailure("bad fixture instant: \(iso)")
    }
    return date
}

// MARK: - Boards

/**
 A board, decoded from JSON rather than constructed.

 `DepartureBoard` has no memberwise initialiser on purpose, and building fixtures
 through the decoder is the right constraint rather than an inconvenience: it is the
 only way a test can be wrong in the same way production would be.

 That is not hypothetical here. `depInstant` is written by JavaScript's `toISOString()`,
 which always emits milliseconds, and a fixture that quietly dropped them let a
 formatter that could not parse the real thing pass every test while the feature it
 supported did nothing on device. These strings are copied from live
 `/api/v2/trains` responses, milliseconds and all.
 */
func board(
    mode: String,
    date: String,
    firstDate: String,
    services: [(role: String, dep: String, instant: String, destination: String)]
) -> DepartureBoard {
    let rows = services.map { service in
        """
        {
          "dep": "\(service.dep)",
          "depInstant": "\(service.instant)",
          "toc": "CC",
          "tocName": "c2c",
          "destination": "\(service.destination)",
          "platform": "2",
          "isReplacementBus": false,
          "headcode": "\(service.dep.replacingOccurrences(of: ":", with: ""))",
          "serviceId": "gb-nr:\(service.dep):\(date)",
          "role": "\(service.role)"
        }
        """
    }

    let json = """
    {
      "from": { "crs": "UPM", "name": "Upminster", "locality": null },
      "direction": "east",
      "date": "\(date)",
      "mode": "\(mode)",
      "firstDate": "\(firstDate)",
      "services": [\(rows.joined(separator: ","))],
      "directions": { "north": 0, "east": 108, "south": 16, "west": 138 },
      "available": ["east", "south", "west"],
      "unclassified": 0,
      "totalServices": 108,
      "towards": ["Shoeburyness"],
      "towardsByDirection": { "east": ["Shoeburyness"], "south": ["Grays"] }
    }
    """

    do {
        return try JSONDecoder().decode(DepartureBoard.self, from: Data(json.utf8))
    } catch {
        preconditionFailure("bad board fixture: \(error)")
    }
}

/**
 Upminster east on 5 August 2026, copied from the deployment.

 Three last trains and the first one back — the `normal` arrangement, and the shape the
 app is in whenever it is opened in the evening.
 */
func upminsterEastEvening() -> DepartureBoard {
    board(
        mode: "normal",
        date: "2026-08-05",
        firstDate: "2026-08-06",
        services: [
            ("last", "23:51", "2026-08-05T22:51:00.000Z", "Pitsea"),
            ("last", "00:18", "2026-08-05T23:18:00.000Z", "Southend Central"),
            ("last", "00:42", "2026-08-05T23:42:00.000Z", "Southend Central"),
            ("first", "05:00", "2026-08-06T04:00:00.000Z", "Southend Central"),
        ]
    )
}

/// The same station on the 6th, before anything has run: the `preService` arrangement.
func upminsterEastBeforeService() -> DepartureBoard {
    board(
        mode: "pre-service",
        date: "2026-08-06",
        firstDate: "2026-08-06",
        services: [
            ("first", "05:00", "2026-08-06T04:00:00.000Z", "Southend Central"),
            ("first", "05:22", "2026-08-06T04:22:00.000Z", "Shoeburyness"),
            ("first", "05:30", "2026-08-06T04:30:00.000Z", "Southend Central"),
            ("last", "00:57", "2026-08-06T23:57:00.000Z", "Shoeburyness"),
        ]
    )
}

/// Renders an instant back to UTC ISO, for asserting what a London string resolved to.
func utcString(_ date: Date?) -> String? {
    guard let date else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.string(from: date)
}

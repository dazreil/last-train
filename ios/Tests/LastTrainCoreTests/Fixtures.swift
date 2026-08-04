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

/// Renders an instant back to UTC ISO, for asserting what a London string resolved to.
func utcString(_ date: Date?) -> String? {
    guard let date else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.string(from: date)
}

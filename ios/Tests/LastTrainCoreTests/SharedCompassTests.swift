import Foundation
import Testing

import LastTrainCore

/**
 The compass cases in `data/compass-cases.json`, which `lib/compass.test.ts` also reads.

 The server and the app each classify a train's direction, and they must agree, or the
 counts on screen stop matching the list beneath them. One file of cases, checked by both
 suites, turns a drift between the two into a failing test. Add a case there, not here.
 */
private struct SharedCases: Decodable {
    struct Classify: Decodable { let from: String; let to: String?; let expect: String? }
    struct Bearing: Decodable { let from: String; let to: String; let degrees: Double }
    struct Sector: Decodable { let degrees: Double; let expect: String }

    let stations: [String: Coordinate]
    let classify: [Classify]
    let bearings: [Bearing]
    let sectors: [Sector]

    static func load() throws -> SharedCases {
        // ios/Tests/LastTrainCoreTests/ -> the repo root.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../data/compass-cases.json")
            .standardizedFileURL
        return try JSONDecoder().decode(SharedCases.self, from: Data(contentsOf: url))
    }
}

@Test func everySharedCompassCaseMatchesTheServer() throws {
    let shared = try SharedCases.load()
    func at(_ code: String) throws -> Coordinate { try #require(shared.stations[code]) }

    for c in shared.classify {
        let to = try c.to.map(at)
        #expect(Direction.classify(from: try at(c.from), to: to)?.rawValue == c.expect, "\(c.from) to \(c.to ?? "nil")")
    }
    for c in shared.bearings {
        let actual = Direction.bearingDegrees(from: try at(c.from), to: try at(c.to))
        #expect(abs(actual - c.degrees) < 0.1, "\(c.from) to \(c.to): \(actual)")
    }
    for c in shared.sectors {
        #expect(Direction.compass(forBearing: c.degrees).rawValue == c.expect, "\(c.degrees) degrees")
    }
}

import Foundation
import Testing

import LastTrainCore

/**
 The bundled station list.

 These tests exist because the failure they catch is silent. If the resource is not
 declared in `Package.swift`, or the generator stops writing the second copy, or the
 filename drifts, then `Bundle.module` simply finds nothing and every station lookup
 returns empty — an app with a picker that offers no stations and no error to explain
 why.

 `Stations.validate()` is the same check the app should make at launch.
 */
@Suite("Stations")
struct StationsTests {

    @Test("the station list is actually in the bundle")
    func listIsBundled() throws {
        // Throws rather than returning empty, so a bundling mistake names itself.
        try Stations.validate()
        #expect(!Stations.all.isEmpty, "Bundle.module found no stations")
    }

    @Test("it holds the whole network")
    func holdsTheWholeNetwork() {
        #expect(Stations.all.count > 2_500, "got \(Stations.all.count)")
        #expect(Stations.generatedAt != nil)
    }

    @Test("every station has a plausible position inside Great Britain")
    func positionsArePlausible() {
        // Filtered, then asserted once. A `#expect` per station is 5,238 of them, each
        // capturing its own source location and expression description -- it took this
        // file from four seconds to thirty-four without testing anything more.
        let outside = Stations.all.filter {
            $0.lat <= 49.5 || $0.lat >= 61.0 || $0.lon <= -8.8 || $0.lon >= 2.1
        }
        #expect(
            outside.isEmpty,
            "outside Great Britain: \(outside.prefix(5).map { "\($0.crs) \($0.lat),\($0.lon)" })"
        )
    }

    @Test("CRS lookup is case-insensitive and forgiving of whitespace")
    func lookupIsForgiving() throws {
        let upper = try #require(Stations.find("UPM"))
        #expect(upper.name == "Upminster")
        #expect(Stations.find("upm")?.crs == "UPM")
        #expect(Stations.find("  upm  ")?.crs == "UPM")
        #expect(Stations.find("ZZZ") == nil)
    }

    /**
     The three stops with no published position, carried deliberately.

     Two are rail-air interchanges rather than rail stations; the third is Winslow,
     which reopened on East West Rail before NaPTAN published it. They are exposed
     rather than dropped so that a service bound for one of them, which cannot be given
     a direction, is traceable rather than mysterious.
     */
    @Test("the unplaced stops are carried, not hidden")
    func unplacedStopsAreCarried() {
        let codes = Set(Stations.unplaced.map(\.crs))
        #expect(codes == ["XPB", "XMT", "WNO"], "got \(codes.sorted())")
        #expect(Stations.unplaced.allSatisfy { !$0.reason.isEmpty })

        // None of them is also in the placed list, which would be a contradiction.
        for stop in Stations.unplaced {
            #expect(Stations.find(stop.crs) == nil, "\(stop.crs) is both placed and unplaced")
        }
    }

    @Test("the bundled index answers nearest-station queries")
    func bundledIndexAnswers() throws {
        let upminster = try #require(Stations.find("UPM"))
        #expect(Stations.nearest(to: upminster.coordinate, limit: 1).first?.station.crs == "UPM")

        // The index is built from the same list, so it must not have lost anyone.
        #expect(Stations.index.size == Stations.all.count)
    }

    @Test("stations are identifiable by CRS, for SwiftUI lists")
    func stationsAreIdentifiable() throws {
        let station = try #require(Stations.find("INV"))
        #expect(station.id == "INV")
        #expect(Set(Stations.all.map(\.id)).count == Stations.all.count, "CRS codes are not unique")
    }
}

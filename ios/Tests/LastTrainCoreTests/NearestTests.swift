import Foundation
import Testing

import LastTrainCore

/**
 A port of `lib/nearest.test.ts`, over the same generated national list.

 The test that matters is `agreesWithAFullScan`. A grid that returns *an* answer
 quickly is worthless; it has to return *the* answer. The failure mode it catches is
 the obvious implementation — search the 3×3 block and stop — which is wrong exactly
 when the nearest station sits just across a cell boundary, and which looks perfectly
 fine in casual use.
 */
/// The synthetic cases need something with a position and nothing else.
private struct Marker: Located, Sendable {
    let coordinate: Coordinate
    init(_ lat: Double, _ lon: Double) { self.coordinate = Coordinate(lat: lat, lon: lon) }
}

@Suite("Nearest")
struct NearestTests {

    private static let stations = National.stations
    private static let index = SpatialIndex(National.stations)

    /**
     How hard to push the agreement tests.

     Each one compares the grid against a full scan of 2,619 stations at every sampled
     position, so the work is positions × 2,619 haversines. Sampling exhaustively —
     every station, plus thousands of random points — takes this file from under two
     seconds to the better part of a minute in a `-Onone` test build, and a suite slow
     enough to skip is worse than one that samples.

     The claim being tested is universal, so a few hundred positions test it about as
     well as a few thousand; what matters is that they land *near boundaries*, which is
     what the beside-every-station sample is for.

     `LASTTRAIN_EXHAUSTIVE=1 swift test` runs the thorough version. Worth doing after
     any change to the stopping rule.
     */
    private static let exhaustive = ProcessInfo.processInfo.environment["LASTTRAIN_EXHAUSTIVE"] == "1"

    // MARK: - The data

    @Test("the national list is present and plausible")
    func nationalListIsPlausible() {
        #expect(Self.stations.count > 2_500, "expected the whole network, got \(Self.stations.count)")
        #expect(Self.index.size == Self.stations.count)
        // If every station landed in one cell the grid is doing nothing.
        #expect(Self.index.cells > 500, "only \(Self.index.cells) occupied cells")
    }

    // MARK: - Known answers

    @Test("a position on a platform finds that platform")
    func positionOnPlatformFindsIt() throws {
        let upminster = try #require(National.find("UPM"))
        let nearest = Self.index.nearest(to: upminster.coordinate, limit: 1)
        #expect(nearest.first?.station.crs == "UPM")
    }

    @Test("the far ends of the country resolve to themselves", arguments: ["PNZ", "INV", "WCK", "PMH"])
    func farEndsResolveToThemselves(crs: String) throws {
        // The list is generated; a code that is not in it is skipped rather than
        // asserted into existence.
        guard let station = National.find(crs) else { return }
        let nearest = Self.index.nearest(to: station.coordinate, limit: 1)
        #expect(nearest.first?.station.crs == crs, "\(crs) did not find itself")
    }

    @Test("results come back closest first")
    func resultsAreOrdered() {
        // Roughly the Thames between Grays and Tilbury.
        let results = Self.index.nearest(to: Coordinate(lat: 51.47, lon: 0.35), limit: 4)
        #expect(results.count == 4)
        for i in 1..<results.count {
            #expect(results[i].distanceMetres >= results[i - 1].distanceMetres)
        }
    }

    // MARK: - Agreement with brute force

    /**
     Ground truth: every distance from here to every station, sorted.

     Deliberately `[Double]` rather than `SpatialIndex.scan`. Distances are what the
     comparison is about — several stations share a position to within millimetres, and
     either is a correct answer at that rank — and carrying the station structs along
     costs an enormous amount of reference counting on their strings. Materialising
     2,619 of them per position took this file to 21 seconds; primitives take it to
     under two, with the sample sizes untouched.

     It is also still trivially the right answer: measure everything, sort, take the
     front. No cleverness for the grid to accidentally agree with.
     */
    /**
     Positions only, pulled out once.

     `Station.coordinate` is a computed property in another module, so in a `-Onone`
     test build every access is a real call. The reference scan makes 2,619 of them per
     sampled position, and reading them through the struct rather than from a flat
     array took these three tests from two seconds each to twenty-five.
     */
    private static let coordinates: [Coordinate] = Stations.all.map(\.coordinate)

    /**
     The reference haversine, written out here rather than called from `Direction`.

     Two reasons, and the second is the better one. It is faster — in a `-Onone` test
     build every call into another module is a real call, and the reference makes 2,619
     of them per sampled position, which is most of this file's runtime. And it makes
     the oracle **independent**: a reference that calls the same function as the code
     under test cannot catch an error in that function, only in the grid around it.
     */
    private static func referenceMetres(_ a: Coordinate, _ b: Coordinate) -> Double {
        let toRadians = Double.pi / 180
        let dLat = (b.lat - a.lat) * toRadians
        let dLon = (b.lon - a.lon) * toRadians
        let h =
            sin(dLat / 2) * sin(dLat / 2)
            + cos(a.lat * toRadians) * cos(b.lat * toRadians) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * 6_371_000 * asin(min(1, sqrt(h)))
    }

    private func nearestDistances(to position: Coordinate, limit: Int) -> [Double] {
        Self.coordinates
            .map { Self.referenceMetres(position, $0) }
            .sorted()
            .prefix(limit)
            .map { $0 }
    }

    private func assertAgrees(_ positions: [Coordinate], limit: Int) {
        for position in positions {
            let fromIndex = Self.index.nearest(to: position, limit: limit).map(\.distanceMetres)
            let expected = nearestDistances(to: position, limit: limit)

            #expect(fromIndex.count == expected.count,
                    "length differs at \(position.lat),\(position.lon)")

            for i in 0..<min(fromIndex.count, expected.count) {
                #expect(
                    abs(fromIndex[i] - expected[i]) < 1e-6,
                    "rank \(i) at \(position.lat),\(position.lon): grid \(fromIndex[i])m, scan \(expected[i])m"
                )
            }
        }
    }

    @Test("the grid agrees with a full scan across Great Britain")
    func agreesWithAFullScan() {
        var random = Lcg(seed: 20_260_801)
        var positions: [Coordinate] = []
        for _ in 0..<(Self.exhaustive ? 1_500 : 220) {
            positions.append(
                Coordinate(lat: 49.9 + random.next() * (58.7 - 49.9),
                           lon: -7.6 + random.next() * (1.8 + 7.6))
            )
        }
        assertAgrees(positions, limit: 4)
    }

    @Test("the grid agrees right next to every station, where boundaries bite")
    func agreesBesideEveryStation() {
        // Offsets of a few hundred metres, which is where a station's own cell and the
        // answer's cell most often differ. This is the highest-value sample in the
        // file, so it strides the list rather than shrinking the range -- every part of
        // the country is still represented.
        var random = Lcg(seed: 981)
        let stride = Self.exhaustive ? 1 : 8
        let positions = Self.stations.enumerated()
            .filter { $0.offset % stride == 0 }
            .map { _, station in
                Coordinate(lat: station.lat + (random.next() - 0.5) * 0.02,
                           lon: station.lon + (random.next() - 0.5) * 0.02)
            }
        assertAgrees(positions, limit: 3)
    }

    @Test("the grid agrees at the extremes of latitude")
    func agreesAtLatitudeExtremes() {
        // A degree of longitude is 71km at Penzance and 57km at Wick. Anything assuming
        // a cell is a fixed number of kilometres is wrong at one end or the other.
        var random = Lcg(seed: 4_242)
        var positions: [Coordinate] = []
        for centre in [
            Coordinate(lat: 58.44, lon: -3.09), // Wick
            Coordinate(lat: 50.12, lon: -5.53), // Penzance
            Coordinate(lat: 60.15, lon: -1.15), // Shetland, well past any station
        ] {
            for _ in 0..<(Self.exhaustive ? 200 : 40) {
                positions.append(
                    Coordinate(lat: centre.lat + (random.next() - 0.5) * 1.5,
                               lon: centre.lon + (random.next() - 0.5) * 3)
                )
            }
        }
        assertAgrees(positions, limit: 4)
    }

    // MARK: - Edge cases

    @Test("a position far offshore still returns the nearest stations")
    func farOffshoreStillAnswers() {
        // Mid-North Sea. Every ring around the query cell is empty for a long way, so
        // this is the case that exercises the fallback to a scan.
        let position = Coordinate(lat: 56.0, lon: 3.0)
        let results = Self.index.nearest(to: position, limit: 3)
        #expect(results.count == 3)
        #expect(results.map(\.station.crs)
                == SpatialIndex.scan(Self.stations, to: position, limit: 3).map(\.station.crs))
    }

    @Test("asking for more stations than exist returns all of them")
    func moreThanExistReturnsAll() {
        let tiny = SpatialIndex([Marker(51.5, -0.1), Marker(55.0, -3.0)])
        #expect(tiny.nearest(to: Coordinate(lat: 51.5, lon: -0.1), limit: 10).count == 2)
    }

    @Test("an empty index answers with nothing rather than failing")
    func emptyIndexAnswersWithNothing() {
        let empty = SpatialIndex([Marker]())
        #expect(empty.nearest(to: Coordinate(lat: 51.5, lon: -0.1)).isEmpty)
        #expect(empty.size == 0)
    }

    @Test("a nonsense position answers with nothing rather than failing")
    func nonsensePositionAnswersWithNothing() {
        #expect(Self.index.nearest(to: Coordinate(lat: .nan, lon: 0)).isEmpty)
        #expect(Self.index.nearest(to: Coordinate(lat: 51.5, lon: -0.1), limit: 0).isEmpty)
    }

    @Test("stations without usable coordinates are left out of the index")
    func junkCoordinatesAreExcluded() {
        let withJunk = SpatialIndex([Marker(51.5, -0.1), Marker(.nan, 0)])
        #expect(withJunk.size == 1)
    }

    @Test("a cell size that puts everything in one bucket still gives right answers")
    func degenerateCellSizeStillCorrect() {
        // Degenerate on purpose: with 90° cells the grid stops helping, and the results
        // must not change. If they do, the answer depended on the bucketing.
        let coarse = SpatialIndex(Self.stations, cellDegrees: 90)
        let position = Coordinate(lat: 53.4, lon: -2.1)
        #expect(coarse.nearest(to: position, limit: 4).map(\.station.crs)
                == SpatialIndex.scan(Self.stations, to: position, limit: 4).map(\.station.crs))
    }
}

import Foundation
import Testing

import LastTrainCore

/**
 Real stations, real coordinates, real answers.

 Fixtures are copied from `data/national.json`, which is generated from RTT's stop
 list joined to NaPTAN — so these are the same numbers the app will use, not numbers
 invented to make a test pass. Each is named and commented with its CRS so a wrong one
 is visible rather than plausible.

 The cases are the ones the national probe (`npm run national`) actually exercised.
 Inverness is the reason the compass exists at all: it is the station that genuinely
 sends trains in all four directions.
 */
enum Station {
    static let inverness = Coordinate(lat: 57.47987, lon: -4.223361)            // INV
    static let wick = Coordinate(lat: 58.441568, lon: -3.096859)                // WCK
    static let aberdeen = Coordinate(lat: 57.143704, lon: -2.098685)            // ABD
    static let edinburgh = Coordinate(lat: 55.952393, lon: -3.188228)           // EDB
    static let kyleOfLochalsh = Coordinate(lat: 57.279772, lon: -5.713813)      // KYL

    static let upminster = Coordinate(lat: 51.559018, lon: 0.25088)             // UPM
    static let fenchurchStreet = Coordinate(lat: 51.511646, lon: -0.078897)     // FST
    static let shoeburyness = Coordinate(lat: 51.530973, lon: 0.795345)         // SRY
    static let romford = Coordinate(lat: 51.574829, lon: 0.183237)              // RMF
    static let barking = Coordinate(lat: 51.539495, lon: 0.080903)              // BKG

    // The Ockendon branch, which runs south out of Upminster to Grays.
    static let ockendon = Coordinate(lat: 51.521992, lon: 0.290469)             // OCK
    static let chaffordHundred = Coordinate(lat: 51.485557, lon: 0.287447)      // CFH
    static let grays = Coordinate(lat: 51.476248, lon: 0.321832)                // GRY

    static let penzance = Coordinate(lat: 50.121674, lon: -5.532565)            // PNZ
    static let stIves = Coordinate(lat: 50.209045, lon: -5.477912)              // SIV

    static let denton = Coordinate(lat: 53.456866, lon: -2.13166)               // DTN
    static let stalybridge = Coordinate(lat: 53.484579, lon: -2.062742)         // SYB
    static let stockport = Coordinate(lat: 53.405538, lon: -2.163013)           // SPT

    static let berneyArms = Coordinate(lat: 52.589787, lon: 1.630376)           // BYA
    static let norwich = Coordinate(lat: 52.627154, lon: 1.30682)               // NRW
    static let greatYarmouth = Coordinate(lat: 52.61216, lon: 1.720886)         // GYM
}

@Suite("Direction")
struct DirectionTests {

    // MARK: - The case the compass exists for

    @Test("Inverness sends trains in all four directions, and each reads right")
    func invernessUsesAllFourDirections() {
        let from = Station.inverness
        #expect(Direction.classify(from: from, to: Station.wick) == .north)
        #expect(Direction.classify(from: from, to: Station.aberdeen) == .east)
        #expect(Direction.classify(from: from, to: Station.edinburgh) == .south)
        #expect(Direction.classify(from: from, to: Station.kyleOfLochalsh) == .west)
    }

    @Test("a station offers only the directions that have services")
    func availabilityFallsOutOfTheTally() {
        // Upminster, using only the c2c main line and the Overground shuttle: west to
        // Fenchurch Street and Barking, east to Shoeburyness, north-west to Romford.
        let tally = Direction.tally(
            from: Station.upminster,
            destinations: [
                Station.fenchurchStreet,
                Station.barking,
                Station.shoeburyness,
                Station.romford,
            ]
        )

        #expect(tally.available == [.east, .west])
        #expect(tally.count(.east) == 1)
        #expect(tally.count(.west) == 3)
        #expect(tally.count(.north) == 0)
        #expect(tally.count(.south) == 0)
        #expect(tally.unclassified == 0)
        #expect(tally.total == 4)
    }

    @Test("the Ockendon branch is southbound, and used to be invisible")
    func ockendonBranchIsSouthbound() {
        // Both PRODUCT.md and IOS.md asserted that Upminster has no southbound service.
        // It has 16 on a weekday, down the Ockendon branch to Grays -- the 07:02 calls
        // at Ockendon, then Chafford Hundred, then Grays, each of them south and
        // slightly east. The claim survived only because the web app offered east and
        // west and nothing else, so a whole branch line was folded into one of the two.
        #expect(Direction.classify(from: Station.upminster, to: Station.ockendon) == .south)
        #expect(Direction.classify(from: Station.upminster, to: Station.chaffordHundred) == .south)
        #expect(Direction.classify(from: Station.upminster, to: Station.grays) == .south)

        // With the branch included, Upminster has three directions, not two.
        let tally = Direction.tally(
            from: Station.upminster,
            destinations: [
                Station.fenchurchStreet,
                Station.shoeburyness,
                Station.romford,
                Station.grays,
            ]
        )
        #expect(tally.available == [.east, .south, .west])
    }

    // MARK: - The guard that ate a branch line

    /**
     The regression that matters most in this file.

     Romford is 4.99km from Upminster. A minimum-separation guard set anywhere in the
     kilometres — 5km was the plausible-sounding choice — silently removes every
     London Overground departure on that branch, 32 of them on the day the probe ran.
     The guard exists to stop two coordinates for *the same place* producing a bearing
     out of rounding noise, and 140 metres is the size of that problem.
     */
    @Test("a branch line five kilometres away is still a direction")
    func shortBranchLineIsNotSwallowedByTheGuard() {
        let metres = Direction.distanceMetres(from: Station.upminster, to: Station.romford)
        #expect(metres > 4_900 && metres < 5_100, "Romford should be about 4.99km from Upminster")

        // The whole point: it classifies, and it classifies west.
        #expect(Direction.classify(from: Station.upminster, to: Station.romford) == .west)
    }

    @Test("the guard is 140 metres, not kilometres")
    func guardIsMetresNotKilometres() {
        #expect(Direction.minimumSeparationMetres == 140)

        // Roughly 100m north of Upminster: the same place, no meaningful bearing.
        let almostHere = Coordinate(lat: Station.upminster.lat + 0.0009, lon: Station.upminster.lon)
        #expect(Direction.distanceMetres(from: Station.upminster, to: almostHere) < 140)
        #expect(Direction.classify(from: Station.upminster, to: almostHere) == nil)

        // Roughly 300m north: far enough to mean something.
        let clearlyNorth = Coordinate(lat: Station.upminster.lat + 0.0027, lon: Station.upminster.lon)
        #expect(Direction.distanceMetres(from: Station.upminster, to: clearlyNorth) > 140)
        #expect(Direction.classify(from: Station.upminster, to: clearlyNorth) == .north)
    }

    @Test("a service terminating where you are standing has no direction")
    func terminatingHereHasNoDirection() {
        #expect(Direction.classify(from: Station.upminster, to: Station.upminster) == nil)
    }

    @Test("a destination with no coordinates is unclassified, never guessed")
    func missingCoordinatesAreUnclassified() {
        // A service whose direction cannot be established is left out rather than
        // guessed at -- guessing would put it under two buttons at once.
        #expect(Direction.classify(from: Station.upminster, to: nil) == nil)

        let tally = Direction.tally(
            from: Station.upminster,
            destinations: [Station.shoeburyness, nil, Station.fenchurchStreet]
        )
        #expect(tally.unclassified == 1)
        #expect(tally.total == 2)
        #expect(tally.available == [.east, .west])
    }

    // MARK: - The rest of the network the probe visited

    @Test("the far south-west reads north and east, never west into the Atlantic")
    func penzanceReadsNorthAndEast() {
        // Penzance is a terminus: everything leaves in one broad direction. St Ives is
        // 21.8 degrees, Edinburgh 12.7 -- both north, which is what a passenger would
        // say about the sleeper.
        #expect(Direction.classify(from: Station.penzance, to: Station.stIves) == .north)
        #expect(Direction.classify(from: Station.penzance, to: Station.edinburgh) == .north)

        let tally = Direction.tally(
            from: Station.penzance,
            destinations: [Station.stIves, Station.edinburgh]
        )
        #expect(tally.available == [.north])
    }

    @Test("a two-train rural station still classifies both of them")
    func ruralStationsClassify() {
        // Denton has two departures all day, one each way, 5.5km and 6.1km out. Under
        // a kilometres-scale guard this station would have no directions at all.
        #expect(Direction.classify(from: Station.denton, to: Station.stalybridge) == .east)
        #expect(Direction.classify(from: Station.denton, to: Station.stockport) == .south)

        // Berney Arms: a request stop with three trains, two east and one west.
        #expect(Direction.classify(from: Station.berneyArms, to: Station.greatYarmouth) == .east)
        #expect(Direction.classify(from: Station.berneyArms, to: Station.norwich) == .west)
    }

    // MARK: - Geometry

    @Test("bearings match the ones the national probe measured")
    func bearingsMatchTheProbe() {
        let cases: [(Coordinate, Coordinate, Double, String)] = [
            (Station.upminster, Station.romford, 290.6, "Upminster to Romford"),
            (Station.upminster, Station.fenchurchStreet, 257.1, "Upminster to Fenchurch Street"),
            (Station.upminster, Station.shoeburyness, 94.5, "Upminster to Shoeburyness"),
            (Station.penzance, Station.stIves, 21.8, "Penzance to St Ives"),
            (Station.inverness, Station.wick, 31.4, "Inverness to Wick"),
            (Station.inverness, Station.kyleOfLochalsh, 256.6, "Inverness to Kyle of Lochalsh"),
            (Station.denton, Station.stalybridge, 55.9, "Denton to Stalybridge"),
            (Station.denton, Station.stockport, 200.0, "Denton to Stockport"),
        ]

        for (from, to, expected, label) in cases {
            let actual = Direction.bearingDegrees(from: from, to: to)
            #expect(abs(actual - expected) < 0.1, "\(label): expected \(expected)°, got \(actual)°")
        }
    }

    @Test("every bearing is inside the sector it should be, with room to spare")
    func noBearingSitsOnASectorEdge() {
        // The narrowest margin the national probe measured was 10.9 degrees, at Denton
        // to Stalybridge. Nothing in real data sits on a boundary waiting to flip.
        let pairs: [(Coordinate, Coordinate)] = [
            (Station.upminster, Station.romford),
            (Station.upminster, Station.shoeburyness),
            (Station.inverness, Station.wick),
            (Station.denton, Station.stalybridge),
            (Station.penzance, Station.stIves),
        ]

        for (from, to) in pairs {
            let bearing = Direction.bearingDegrees(from: from, to: to)
            let margin = [45.0, 135.0, 225.0, 315.0]
                .map { min(abs(bearing - $0), 360 - abs(bearing - $0)) }
                .min()!
            #expect(margin > 10, "bearing \(bearing)° is only \(margin)° from a sector edge")
        }
    }

    @Test("sector boundaries belong to the clockwise sector")
    func sectorBoundariesAreStated() {
        #expect(Direction.compass(forBearing: 0) == .north)
        #expect(Direction.compass(forBearing: 44.9) == .north)
        #expect(Direction.compass(forBearing: 45) == .east)
        #expect(Direction.compass(forBearing: 134.9) == .east)
        #expect(Direction.compass(forBearing: 135) == .south)
        #expect(Direction.compass(forBearing: 224.9) == .south)
        #expect(Direction.compass(forBearing: 225) == .west)
        #expect(Direction.compass(forBearing: 314.9) == .west)
        #expect(Direction.compass(forBearing: 315) == .north)
        #expect(Direction.compass(forBearing: 359.9) == .north)
    }

    @Test("bearings out of range are normalised rather than misfiled")
    func outOfRangeBearingsNormalise() {
        #expect(Direction.compass(forBearing: 360) == .north)
        #expect(Direction.compass(forBearing: 450) == .east)
        #expect(Direction.compass(forBearing: -90) == .west)
    }

    @Test("distance is symmetric and zero against itself")
    func distanceIsWellBehaved() {
        #expect(Direction.distanceMetres(from: Station.upminster, to: Station.upminster) == 0)
        let there = Direction.distanceMetres(from: Station.inverness, to: Station.wick)
        let back = Direction.distanceMetres(from: Station.wick, to: Station.inverness)
        #expect(abs(there - back) < 0.001)
        #expect(there > 125_000 && there < 127_000, "Inverness to Wick is about 126km")
    }

    @Test("the reverse bearing is the opposite direction")
    func reverseBearingIsOpposite() {
        // Not exactly 180 degrees apart on a sphere, but the sectors must oppose.
        #expect(Direction.classify(from: Station.upminster, to: Station.shoeburyness) == .east)
        #expect(Direction.classify(from: Station.shoeburyness, to: Station.upminster) == .west)
        #expect(Direction.classify(from: Station.inverness, to: Station.edinburgh) == .south)
        #expect(Direction.classify(from: Station.edinburgh, to: Station.inverness) == .north)
    }

    @Test("an empty line-up offers no directions rather than all of them")
    func emptyTallyOffersNothing() {
        let tally = Direction.tally(from: Station.upminster, destinations: [Coordinate?]())
        #expect(tally.available.isEmpty)
        #expect(tally.total == 0)
        #expect(tally.unclassified == 0)
    }
}

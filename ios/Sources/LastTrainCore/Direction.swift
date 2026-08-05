import Foundation

/**
 Which way is that train going?

 The one piece of this app that is genuinely new rather than a port. The web app
 compares the *longitude* of a service's destination against the station's, which
 works on three corridors that all run broadly east–west and fails the moment the
 network does anything else. IOS.md §4 replaces it with a bearing, bucketed into four
 90° sectors centred on the cardinal points.

 The direction is taken to the **destination**, not to the next calling point. It
 matches how a passenger thinks about which way a train is going: the 23:52 from
 Inverness is "the Wick train", not "the train to Dingwall".

 ## Availability comes free

 There is no separate query for "which directions exist here". An unfiltered line-up
 already contains every service at the station, so bucketing it produces the available
 directions as a by-product — `tally` returns both. At Upminster that yields east and
 west and nothing else, which is the answer `PRODUCT.md` states for it.

 ## A direction merges unrelated railways, deliberately

 Measured at Upminster: "west" holds c2c to Fenchurch Street at 257° *and* the London
 Overground shuttle to Romford at 291°. Two different railways under one button. That
 is the honest answer to "what leaves here going that way", and separating them would
 mean reintroducing the corridor machinery §5 exists to delete. The destination is on
 every row, so the difference is visible where it matters.
 */
public enum Compass: String, CaseIterable, Sendable, Codable {
    case north
    case east
    case south
    case west
}

public struct Coordinate: Equatable, Sendable, Codable {
    public let lat: Double
    public let lon: Double

    public init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }
}

public enum Direction {

    /**
     Below this, two places are the same place and a bearing between them is noise.

     **This number has to stay small, and 140 metres is the size of the thing it
     guards against: rounding, not short journeys.** IOS.md §4 used to describe it as
     stopping "a train terminating one stop away" producing a meaningless bearing,
     which reads as licence for something in kilometres. It is not.

     A first pass at the national probe used 5km on exactly that reasoning and
     silently deleted every London Overground departure on the Romford branch at
     Upminster — 32 real, boardable trains — because Romford is 4.99km away. Any
     threshold big enough to catch "terminates one stop away" is big enough to delete
     a branch line, and it does it quietly, in the safe-looking direction.
     */
    public static let minimumSeparationMetres: Double = 140

    private static let earthRadiusMetres: Double = 6_371_000
    private static func toRadians(_ degrees: Double) -> Double { degrees * .pi / 180 }

    /// Great-circle distance between two points.
    public static func distanceMetres(from origin: Coordinate, to destination: Coordinate) -> Double {
        let dLat = toRadians(destination.lat - origin.lat)
        let dLon = toRadians(destination.lon - origin.lon)
        let h =
            pow(sin(dLat / 2), 2)
            + cos(toRadians(origin.lat)) * cos(toRadians(destination.lat)) * pow(sin(dLon / 2), 2)
        return 2 * earthRadiusMetres * asin(min(1, sqrt(h)))
    }

    /**
     Initial great-circle bearing, degrees clockwise from true north, in `0..<360`.

     Initial rather than average: over the length of Great Britain the two differ by a
     few degrees, and only the initial one answers "which way does it set off".
     */
    public static func bearingDegrees(from origin: Coordinate, to destination: Coordinate) -> Double {
        let lat1 = toRadians(origin.lat)
        let lat2 = toRadians(destination.lat)
        let dLon = toRadians(destination.lon - origin.lon)

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)

        let degrees = atan2(y, x) * 180 / .pi
        return degrees.truncatingRemainder(dividingBy: 360) + (degrees < 0 ? 360 : 0)
    }

    /**
     Four 90° sectors centred on the cardinal points, per IOS.md §4.

     | Sector | Direction |
     |---|---|
     | 315°–45° | North |
     | 45°–135° | East |
     | 135°–225° | South |
     | 225°–315° | West |

     Boundaries belong to the clockwise sector: exactly 45° is east, exactly 315° is
     north. Which side they fall on matters less than that it is stated and tested —
     a bearing landing exactly on a boundary is vanishingly rare in real data, and the
     narrowest margin measured across the national probe was 10.9°.
     */
    public static func compass(forBearing bearing: Double) -> Compass {
        let normalised = bearing.truncatingRemainder(dividingBy: 360) + (bearing < 0 ? 360 : 0)
        switch normalised {
        case 45..<135: return .east
        case 135..<225: return .south
        case 225..<315: return .west
        default: return .north
        }
    }

    /**
     Which way a service goes, or `nil` if the question does not have an answer.

     `nil` means one of two things, and both are honest: the destination is closer than
     `minimumSeparationMetres`, so there is no meaningful bearing; or the caller had no
     coordinate for the destination at all. A service whose direction cannot be
     established is left out rather than guessed at — guessing would put it under two
     buttons at once.
     */
    public static func classify(from origin: Coordinate, to destination: Coordinate?) -> Compass? {
        guard let destination else { return nil }
        guard distanceMetres(from: origin, to: destination) >= minimumSeparationMetres else {
            return nil
        }
        return compass(forBearing: bearingDegrees(from: origin, to: destination))
    }

    // MARK: - Availability

    /**
     How many services run each way from a station, and therefore which directions to
     offer at all.

     At Upminster north and south have no services and must not be offered. This falls
     out of the query that was being made anyway, so it costs nothing.
     */
    public struct Tally: Equatable, Sendable {
        public let counts: [Compass: Int]
        /// Services whose direction could not be established. Never silently folded in.
        public let unclassified: Int

        public init(counts: [Compass: Int], unclassified: Int = 0) {
            self.counts = counts
            self.unclassified = unclassified
        }

        /// Directions with at least one service, in compass order.
        public var available: [Compass] {
            Compass.allCases.filter { (counts[$0] ?? 0) > 0 }
        }

        public func count(_ direction: Compass) -> Int { counts[direction] ?? 0 }

        public var total: Int { counts.values.reduce(0, +) }
    }

    /// Bucket a station's departures by the direction of each one's destination.
    public static func tally(
        from origin: Coordinate,
        destinations: some Sequence<Coordinate?>
    ) -> Tally {
        var counts: [Compass: Int] = [:]
        var unclassified = 0

        for destination in destinations {
            if let direction = classify(from: origin, to: destination) {
                counts[direction, default: 0] += 1
            } else {
                unclassified += 1
            }
        }

        return Tally(counts: counts, unclassified: unclassified)
    }
}

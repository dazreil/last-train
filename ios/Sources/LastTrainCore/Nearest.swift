import Foundation

/**
 Nearest station, without scanning the whole country.

 A port of `lib/nearest.ts`. The web app scans 67 stations linearly, which is free.
 Nationally there are 2,619, and this runs on every location update on a phone —
 IOS.md §6 flags the linear scan as the thing that breaks at national scale.

 Stations are bucketed into a grid of latitude/longitude cells, and a query walks
 outward ring by ring from the cell it lands in. The part that has to be right is
 **when to stop**: it is tempting to search the 3×3 block around the query and call it
 done, and that is wrong whenever the true nearest station sits just over a cell
 boundary. So each ring is followed by a proof — the search only stops once the results
 in hand are closer than anything the unsearched cells could possibly hold.

 That bound is deliberately pessimistic. A degree of longitude is 71km at Penzance and
 57km at Wick, so anything assuming a fixed cell size in kilometres is wrong at one end
 of the country or the other. The bound uses the smallest kilometres-per-degree in
 play, which can only ever cause *more* searching, never a wrong answer.

 Distance comes from `Direction.distanceMetres`, so there is one haversine in this
 module rather than two that could drift apart.
 */

/// Anything that sits somewhere. Stations, but the index does not need to know that.
public protocol Located {
    var coordinate: Coordinate { get }
}

public struct Nearby<T>: Sendable where T: Sendable {
    public let station: T
    public let distanceMetres: Double

    public init(station: T, distanceMetres: Double) {
        self.station = station
        self.distanceMetres = distanceMetres
    }
}

public struct SpatialIndex<T: Located & Sendable>: Sendable {

    /**
     Cell size in degrees.

     0.1° is about 11km north-south and 6–7km east-west in Britain. Stations average
     roughly 9km apart, so a typical query finds its answer within one or two rings
     while the grid still skips almost all of the country.
     */
    public static var defaultCellDegrees: Double { 0.1 }

    /// Metres per degree of latitude, taken at its smallest so bounds stay safe.
    private static var metresPerDegree: Double { 110_570 }

    private struct Cell: Hashable {
        let lat: Int
        let lon: Int
    }

    private let cell: Double
    private let grid: [Cell: [T]]
    private let all: [T]
    private let bounds: (minLat: Int, maxLat: Int, minLon: Int, maxLon: Int)?

    public var size: Int { all.count }
    /// Occupied cells. Useful only for checking the cell size is sane.
    public var cells: Int { grid.count }

    /**
     Bucket stations by rounded position.

     Build once and keep it: rebuilding per query would cost far more than the linear
     scan this replaces.
     */
    public init(_ stations: [T], cellDegrees: Double = SpatialIndex.defaultCellDegrees) {
        self.cell = cellDegrees

        var grid: [Cell: [T]] = [:]
        var placed: [T] = []
        var minLat = Int.max, maxLat = Int.min, minLon = Int.max, maxLon = Int.min

        for station in stations {
            let point = station.coordinate
            guard point.lat.isFinite, point.lon.isFinite else { continue }

            let key = Cell(
                lat: Int(floor(point.lat / cellDegrees)),
                lon: Int(floor(point.lon / cellDegrees))
            )
            grid[key, default: []].append(station)
            placed.append(station)

            minLat = min(minLat, key.lat)
            maxLat = max(maxLat, key.lat)
            minLon = min(minLon, key.lon)
            maxLon = max(maxLon, key.lon)
        }

        self.grid = grid
        self.all = placed
        self.bounds = placed.isEmpty ? nil : (minLat, maxLat, minLon, maxLon)
    }

    /**
     The closest anything *outside* the searched block could possibly be.

     The block spans cells `centre ± ring`, so in degrees it runs from `(i-r)·cell` to
     `(i+r+1)·cell`. A point outside it must differ from the query by more than the gap
     to the nearest edge, in at least one of the two axes — so the smaller of the two
     gaps is a lower bound on the distance to anything not yet searched.

     Longitude is converted using the cosine of the *largest* latitude the block
     touches, which is the smallest that degree can be. Underestimating the bound costs
     an extra ring; overestimating it would return the wrong station.
     */
    private func unsearchedBound(from position: Coordinate, centre: Cell, ring: Int) -> Double {
        let latMin = Double(centre.lat - ring) * cell
        let latMax = Double(centre.lat + ring + 1) * cell
        let lonMin = Double(centre.lon - ring) * cell
        let lonMax = Double(centre.lon + ring + 1) * cell

        let latGap = min(position.lat - latMin, latMax - position.lat)
        let lonGap = min(position.lon - lonMin, lonMax - position.lon)

        let widestLatitude = min(max(abs(latMin), abs(latMax)), 89.9)
        let metresPerDegreeLon = Self.metresPerDegree * cos(widestLatitude * .pi / 180)

        return min(latGap * Self.metresPerDegree, lonGap * metresPerDegreeLon)
    }

    /// Nearest stations to a position, closest first.
    public func nearest(to position: Coordinate, limit: Int = 4) -> [Nearby<T>] {
        guard let bounds, limit > 0, position.lat.isFinite, position.lon.isFinite else { return [] }

        let centre = Cell(lat: Int(floor(position.lat / cell)), lon: Int(floor(position.lon / cell)))

        // Enough rings to reach every occupied cell from anywhere, so a query far
        // offshore still terminates with a real answer rather than an empty list.
        let maxRing = max(
            abs(centre.lat - bounds.minLat),
            abs(centre.lat - bounds.maxLat),
            abs(centre.lon - bounds.minLon),
            abs(centre.lon - bounds.maxLon)
        ) + 1

        var found: [Nearby<T>] = []
        var cellsProbed = 0

        func consider(_ key: Cell) {
            cellsProbed += 1
            guard let bucket = grid[key] else { return }
            for station in bucket {
                found.append(
                    Nearby(
                        station: station,
                        distanceMetres: Direction.distanceMetres(from: position, to: station.coordinate)
                    )
                )
            }
        }

        for ring in 0...maxRing {
            /**
             Give up on the grid once it has stopped paying for itself.

             Rings grow as the square of their radius, so a position with no station
             anywhere near it — the middle of the North Sea, most of the Atlantic —
             probes tens of thousands of empty cells and ends up slower than the scan it
             was meant to replace. Measured in the TypeScript: 80× faster than a scan
             near a station, but only 3× across a box that includes open sea.

             Once more cells have been probed than there are stations, scanning is the
             cheaper way to finish and it gives an identical answer.
             */
            if cellsProbed > all.count { return Self.scan(all, to: position, limit: limit) }

            if ring == 0 {
                consider(centre)
            } else {
                // The ring's edge only -- the interior was covered by earlier rings.
                for lat in (centre.lat - ring)...(centre.lat + ring) {
                    let onLatEdge = lat == centre.lat - ring || lat == centre.lat + ring
                    for lon in (centre.lon - ring)...(centre.lon + ring) {
                        let onLonEdge = lon == centre.lon - ring || lon == centre.lon + ring
                        if onLatEdge || onLonEdge { consider(Cell(lat: lat, lon: lon)) }
                    }
                }
            }

            if found.count >= limit {
                found.sort { $0.distanceMetres < $1.distanceMetres }
                found = Array(found.prefix(limit))
                if found[found.count - 1].distanceMetres
                    <= unsearchedBound(from: position, centre: centre, ring: ring) {
                    return found
                }
            }
        }

        found.sort { $0.distanceMetres < $1.distanceMetres }
        return Array(found.prefix(limit))
    }

    /**
     The linear scan the grid replaces.

     Kept because it is the definition of a correct answer: the tests assert that the
     index agrees with it exactly, over every station in the country, from thousands of
     positions. A spatial index that is merely fast is worthless.
     */
    public static func scan(_ stations: [T], to position: Coordinate, limit: Int = 4) -> [Nearby<T>] {
        stations
            .map { Nearby(station: $0, distanceMetres: Direction.distanceMetres(from: position, to: $0.coordinate)) }
            .sorted { $0.distanceMetres < $1.distanceMetres }
            .prefix(limit)
            .map { $0 }
    }
}

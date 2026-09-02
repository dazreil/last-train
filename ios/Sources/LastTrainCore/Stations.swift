import Foundation

/**
 Every station in Great Britain, bundled.

 IOS.md §5 has the app carrying its own station list rather than asking the API for
 one: the picker has to work the instant the app opens, on a platform with one bar of
 signal, and a list that changes a handful of times a year is not worth a round trip.

 The file is `Resources/national.json`, written by `npm run national:data`, which emits
 the same bytes here and to `data/national.json` for the API. **Neither copy is
 hand-maintained** — regenerating updates both, which is the only way a second copy of
 generated data stays honest.

 Loaded once, lazily. 2,619 stations decode in a few milliseconds and the result is
 held for the life of the process, so the picker and the nearest-station index share
 one copy.
 */
public struct Station: Decodable, Located, Sendable, Equatable, Identifiable {
    public let crs: String
    public let name: String
    public let lat: Double
    public let lon: Double
    /// NaPTAN locality, for telling two Newports apart. Frequently nil.
    public let locality: String?
    public let town: String?

    public var id: String { crs }
    public var coordinate: Coordinate { Coordinate(lat: lat, lon: lon) }
}

/// A stop the API can query that has no published position. See `Stations.unplaced`.
public struct UnplacedStop: Decodable, Sendable, Equatable {
    public let crs: String
    public let name: String
    public let reason: String
}

private struct StationFile: Decodable {
    let generatedAt: String
    let stationCount: Int
    let unplaced: [UnplacedStop]
    let stations: [Station]
}

public enum Stations {

    /// Thrown rather than silently returning nothing: an app with no stations is broken.
    public enum LoadError: Error, CustomStringConvertible {
        case resourceMissing
        case undecodable(String)

        public var description: String {
            switch self {
            case .resourceMissing:
                return "national.json is missing from the bundle. Run `npm run national:data`."
            case .undecodable(let detail):
                return "national.json could not be decoded: \(detail)"
            }
        }
    }

    private static let loaded: Result<StationFile, LoadError> = {
        guard let url = Bundle.module.url(forResource: "national", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return .failure(.resourceMissing) }

        do {
            return .success(try JSONDecoder().decode(StationFile.self, from: data))
        } catch {
            return .failure(.undecodable("\(error)"))
        }
    }()

    /// Every station with a known position, in the order the generator emitted them.
    public static var all: [Station] {
        (try? loaded.get())?.stations ?? []
    }

    /**
     Stops the API can query but that have no published position.

     Two rail-air interchanges that are not rail stations, and Winslow, which reopened
     on East West Rail before NaPTAN published it. Exposed rather than hidden: a
     service bound for one of these cannot be given a direction, and that should be
     traceable rather than mysterious.
     */
    public static var unplaced: [UnplacedStop] {
        (try? loaded.get())?.unplaced ?? []
    }

    /// When the bundled list was generated, for the diagnostics surface.
    public static var generatedAt: String? {
        (try? loaded.get())?.generatedAt
    }

    /// Surfaces a bundling failure instead of leaving an empty picker to explain itself.
    public static func validate() throws {
        _ = try loaded.get()
    }

    private static let byCrs: [String: Station] = {
        Dictionary(all.map { ($0.crs, $0) }, uniquingKeysWith: { first, _ in first })
    }()

    public static func find(_ crs: String) -> Station? {
        byCrs[crs.trimmingCharacters(in: .whitespaces).uppercased()]
    }

    /**
     Name to station, for the one direction the API does not answer.

     A board row carries its destination as a name — `London Fenchurch Street` — and no
     code, because the upstream line-up names the terminus rather than coding it. Showing
     `FST` on the row therefore needs this way round.

     **Checked against live boards before it was written**: every destination name six real
     boards produced resolved here. It is still a lookup that can miss, so every caller
     falls back to the name rather than to nothing — a row that says Fenchurch Street is
     merely wider than one that says FST, while a row that says nothing is a bug.

     Case- and whitespace-insensitive, since the two datasets agree on spelling but there
     is no reason to depend on their agreeing on either of those.
     */
    private static let byName: [String: Station] = {
        Dictionary(
            all.map { ($0.name.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }()

    public static func named(_ name: String) -> Station? {
        byName[name.trimmingCharacters(in: .whitespaces).lowercased()]
    }

    /// The three-letter code for a destination name, or `nil` when it cannot be resolved.
    public static func code(forName name: String) -> String? {
        named(name)?.crs
    }

    /// Built once. Rebuilding per location update would cost more than the scan it replaces.
    public static let index = SpatialIndex(all)

    /**
     How far away a station can be and still be an answer to "where am I?".

     There is always a nearest station. Without a bound, standing in San Francisco fills
     the field with **Thurso**, 7,907km away, because Thurso genuinely is the closest
     British station to California — the index is right and the answer is absurd. It is
     not a hypothetical: Xcode's default simulated location is San Francisco, which is
     how this was found.

     **It cannot be a test of which country you are in, and it does not try to be.**
     Measured against the station list: Cape Wrath is 70.7km from the nearest railhead
     (Forsinard) and Kinlochbervie 63.3km, while Belfast is 67.7km from Stranraer and
     Douglas 68.2km from Nethertown. Remote Great Britain is *further from a station*
     than Northern Ireland and the Isle of Man are. Any bound tight enough to exclude
     Belfast excludes Cape Wrath with it, so no threshold separates them and picking one
     that appeared to would just be fitting a number to one city.

     So the job here is narrower: rule out the absurd, not police a border. 100km clears
     the whole of Great Britain including its emptiest corners, and rules out Dublin
     (108km), Londonderry (146km) and the Channel Islands (128km). Belfast, the Isle of
     Man and Calais fall inside it and get a real railhead 40–70km away — which the
     `Near you` row shows the distance for, so it reads as what it is.
     */
    public static let plausibleRadiusMetres: Double = 100_000

    /**
     The stations around a position, nearest first.

     `within` defaults to unbounded, because "which is nearest" and "is anything near
     enough to matter" are different questions and only the caller knows it is being
     asked about a person standing somewhere.
     */
    public static func nearest(
        to position: Coordinate,
        limit: Int = 4,
        within maxMetres: Double = .infinity
    ) -> [Nearby<Station>] {
        index.nearest(to: position, limit: limit)
            .filter { $0.distanceMetres <= maxMetres }
    }
}

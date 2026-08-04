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

    /// Built once. Rebuilding per location update would cost more than the scan it replaces.
    public static let index = SpatialIndex(all)

    public static func nearest(to position: Coordinate, limit: Int = 4) -> [Nearby<Station>] {
        index.nearest(to: position, limit: limit)
    }
}

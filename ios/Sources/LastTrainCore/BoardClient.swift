import Foundation

/**
 The app's only network dependency: our own API.

 IOS.md §3 and §5 are both explicit — **the token never reaches the device.** RTT's
 terms require end-user apps to proxy through a server-side component, and a token
 found in a distributed app gets revoked. So this talks to `/api/v2/trains` on our
 Vercel deployment, which holds the credential, and never to `data.rtt.io`.

 The consequence, stated in §5 and worth remembering: the app needs our server up. The
 deployment is infrastructure rather than convenience.
 */

/// One departure, as the board shows it.
public struct BoardDeparture: Decodable, Sendable, Identifiable, Equatable {
    /// `23:52`, London local. Already formatted by the server, which owns the timezone.
    public let dep: String
    /// A true UTC instant, so nothing here re-derives a time from a naive string.
    public let depInstant: String
    public let toc: String
    public let tocName: String
    /// Where the train is going. Two names joined by `&` when it divides en route.
    public let destination: String
    public let platform: String?
    public let isReplacementBus: Bool
    public let headcode: String?
    public let serviceId: String
    public let role: ServiceRole

    public var id: String { serviceId }
}

public struct BoardStation: Decodable, Sendable, Equatable {
    public let crs: String
    public let name: String
    public let locality: String?
}

/**
 A whole board: which directions exist here, and what leaves the way you asked.

 `directions` carries the count for all four from the one query, so the control can
 show availability without a second request.
 */
public struct DepartureBoard: Decodable, Sendable, Equatable {
    public let from: BoardStation
    public let direction: Compass
    /// The service day on the board, `YYYY-MM-DD`.
    public let date: String
    public let mode: BoardMode
    /// The service day the `first`-role entries belong to.
    public let firstDate: String
    /// In departure order, which is also the order they are shown in.
    public let services: [BoardDeparture]
    public let directions: [Compass: Int]
    public let available: [Compass]
    public let unclassified: Int
    public let totalServices: Int
    public let towards: [String]
    /// Where each direction goes, so the control can name a destination on every block.
    public let towardsByDirection: [Compass: [String]]

    /// The last train of `date` — the one thing on the board that is red.
    public var lastTrain: BoardDeparture? {
        services.last { $0.role == .last }
    }

    public var lastTrains: [BoardDeparture] { services.filter { $0.role == .last } }
    public var firstTrains: [BoardDeparture] { services.filter { $0.role == .first } }

    private enum CodingKeys: String, CodingKey {
        case from, direction, date, mode, firstDate, services
        case directions, available, unclassified, totalServices, towards
        case towardsByDirection
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        from = try container.decode(BoardStation.self, forKey: .from)
        direction = try container.decode(Compass.self, forKey: .direction)
        date = try container.decode(String.self, forKey: .date)
        mode = try container.decode(BoardMode.self, forKey: .mode)
        firstDate = try container.decode(String.self, forKey: .firstDate)
        services = try container.decode([BoardDeparture].self, forKey: .services)
        available = try container.decode([Compass].self, forKey: .available)
        unclassified = try container.decode(Int.self, forKey: .unclassified)
        totalServices = try container.decode(Int.self, forKey: .totalServices)
        towards = try container.decode([String].self, forKey: .towards)

        // Decoded through `[String: Int]` on purpose. `JSONDecoder` writes a dictionary
        // with a non-String key type as a flat array of alternating keys and values, so
        // asking it for `[Compass: Int]` directly fails against an ordinary JSON object.
        let raw = try container.decode([String: Int].self, forKey: .directions)
        directions = raw.reduce(into: [:]) { result, pair in
            if let point = Compass(rawValue: pair.key) { result[point] = pair.value }
        }

        let rawTowards = try container.decodeIfPresent(
            [String: [String]].self, forKey: .towardsByDirection
        ) ?? [:]
        towardsByDirection = rawTowards.reduce(into: [:]) { result, pair in
            if let point = Compass(rawValue: pair.key) { result[point] = pair.value }
        }
    }

    /// The first-named destination each way, which is what a direction block shows.
    public var towardsLabels: [Compass: String] {
        towardsByDirection.compactMapValues(\.first)
    }

    /// Counts in the shape the direction control wants.
    public var tally: Direction.Tally {
        Direction.Tally(counts: directions, unclassified: unclassified)
    }
}

public enum BoardClientError: Error, LocalizedError, Equatable {
    /// The server answered, and said no.
    case api(String, retryAfterSeconds: Int?)
    case badStatus(Int)
    case unreachable
    case undecodable(String)

    public var errorDescription: String? {
        switch self {
        case .api(let message, _): message
        case .badStatus(let code): "The server returned an error (\(code))."
        // Never dressed as a fault in the app: no signal on a platform is ordinary.
        case .unreachable: "Could not reach the server. Are you online?"
        case .undecodable: "The server sent something this version cannot read."
        }
    }
}

public struct BoardClient: Sendable {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /**
     Fetch a board.

     `date` is optional; the server resolves the current *service* day when it is
     absent, which is the right default and keeps the 03:00 rule in one place rather
     than two.
     */
    public func board(
        from crs: String,
        direction: Compass,
        date: String? = nil,
        /// Set when this day was stepped on to because the previous one is spent.
        advanced: Bool = false,
        refresh: Bool = false
    ) async throws -> DepartureBoard {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("api/v2/trains"),
            resolvingAgainstBaseURL: false
        ) else { throw BoardClientError.unreachable }

        var query = [
            URLQueryItem(name: "from", value: crs),
            URLQueryItem(name: "direction", value: direction.rawValue),
        ]
        if let date { query.append(URLQueryItem(name: "date", value: date)) }
        if advanced { query.append(URLQueryItem(name: "advanced", value: "1")) }
        if refresh { query.append(URLQueryItem(name: "refresh", value: "1")) }
        components.queryItems = query

        guard let url = components.url else { throw BoardClientError.unreachable }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // The server sends `max-age`, and honouring it is what makes a repeat lookup
        // feel instant. But a refresh has to mean refresh: without this, pulling down
        // re-reads URLSession's copy and the board never changes — which also hides a
        // deploy that changed the response shape behind an hour of stale JSON.
        request.cachePolicy = refresh ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BoardClientError.unreachable
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status != 200 {
            // The route answers errors as JSON. Prefer its wording to a status code:
            // "Realtime Trains rate limit reached" is a better thing to show than 429.
            if let failure = try? JSONDecoder().decode(APIError.self, from: data) {
                throw BoardClientError.api(failure.error, retryAfterSeconds: failure.retryAfterSeconds)
            }
            throw BoardClientError.badStatus(status)
        }

        do {
            return try JSONDecoder().decode(DepartureBoard.self, from: data)
        } catch {
            throw BoardClientError.undecodable("\(error)")
        }
    }

    private struct APIError: Decodable {
        let error: String
        let retryAfterSeconds: Int?
    }
}

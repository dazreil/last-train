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

    /// The departure as an absolute instant, for counting down to.
    public var instant: Date? { ServiceDay.instant(from: depInstant) }
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
    /**
     Unreachable, but the address was this machine.

     Only a Debug build can be in this state: `project.yml` points Debug at a dev server
     on localhost and Release at the deployment. Reported separately because "are you
     online?" is a wrong and slow answer to "you have not run `npm run dev`" -- which is
     the actual cause every time, and one the message can simply name.
     */
    case devServerDown(String)
    case undecodable(String)

    public var errorDescription: String? {
        switch self {
        case .api(let message, _): message
        case .badStatus(let code): "The server returned an error (\(code))."
        // Never dressed as a fault in the app: no signal on a platform is ordinary.
        case .unreachable: "Could not reach the server. Are you online?"
        case .devServerDown(let host):
            "No dev server at \(host). Run `npm run dev`, or switch the scheme to "
                + "Release to use the deployment."
        case .undecodable: "The server sent something this version cannot read."
        }
    }
}

public struct BoardClient: Sendable {
    public let baseURL: URL
    /// Internal rather than private so the calling-points extension can reuse it.
    let session: URLSession

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
            throw isLoopback ? BoardClientError.devServerDown(hostLabel) : .unreachable
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

    /// Whether this client is pointed at the machine it is running on.
    var isLoopback: Bool {
        let host = baseURL.host()
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    var hostLabel: String {
        guard let host = baseURL.host() else { return "localhost" }
        return baseURL.port.map { "\(host):\($0)" } ?? host
    }

    private struct APIError: Decodable {
        let error: String
        let retryAfterSeconds: Int?
    }
}

// MARK: - Where one train goes

/// One stop on a train's route.
public struct ServiceCall: Decodable, Sendable, Equatable, Identifiable {
    /// Null for the few stops with no CRS, which are still worth naming.
    public let crs: String?
    public let name: String
    /// London wall-clock. The departure, or the arrival at the far end.
    public let time: String?
    /**
     The same moment, as something you can compare.

     `time` is for reading and cannot be ordered: 00:15 sorts before 23:50 as a string,
     and the two belong to one night. Fast Train ranks by arrival, so it needs the
     instant. Optional because a stop can have no time at all.
     */
    public let timeInstant: String?
    public let isCancelled: Bool

    /// Stable enough for a list: a train calls at a place once.
    public var id: String { crs ?? name }

    /// The call as an absolute moment, or nil if it has no usable time.
    public var instant: Date? {
        timeInstant.flatMap(ServiceDay.instant(from:))
    }
}

/// A train's whole route, as the sheet behind a tap shows it.
public struct ServiceCalls: Decodable, Sendable, Equatable {
    public let serviceId: String
    /// `2D88`. Stable day to day, unlike `serviceId`, which carries its date — so this
    /// is what a pin is keyed on.
    public let headcode: String?
    public let toc: String
    public let tocName: String
    public let origin: String
    public let destination: String
    public let calls: [ServiceCall]
}

extension BoardClient {
    /**
     Where one train goes.

     One request, made only when somebody taps, and cached by the server under the
     service id. Nothing calls this on behalf of a board.
     */
    public func calls(for serviceId: String) async throws -> ServiceCalls {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("api/v2/service"),
            resolvingAgainstBaseURL: false
        ) else { throw BoardClientError.unreachable }

        components.queryItems = [URLQueryItem(name: "id", value: serviceId)]
        guard let url = components.url else { throw BoardClientError.unreachable }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw isLoopback ? BoardClientError.devServerDown(hostLabel) : .unreachable
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            if let failure = try? JSONDecoder().decode(APIErrorBody.self, from: data) {
                throw BoardClientError.api(failure.error, retryAfterSeconds: nil)
            }
            throw BoardClientError.badStatus(status)
        }

        do {
            return try JSONDecoder().decode(ServiceCalls.self, from: data)
        } catch {
            throw BoardClientError.undecodable("\(error)")
        }
    }
}

/// The error shape every route uses. Mirrors the private one above, which cannot be
/// reached from an extension.
struct APIErrorBody: Decodable {
    let error: String
    let retryAfterSeconds: Int?
}

extension BoardClient {
    /**
     Every direct train from one station to another, with arrivals worked out.

     The server does the expensive half. Rank what comes back with `FastBoard.rank`.
     */
    public func fast(
        from origin: String,
        to destination: String,
        date: String? = nil,
        refresh: Bool = false
    ) async throws -> FastBoardResponse {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("api/v2/fast"),
            resolvingAgainstBaseURL: false
        ) else { throw BoardClientError.unreachable }

        var query = [
            URLQueryItem(name: "from", value: origin),
            URLQueryItem(name: "to", value: destination),
        ]
        if let date { query.append(URLQueryItem(name: "date", value: date)) }
        if refresh { query.append(URLQueryItem(name: "refresh", value: "1")) }
        components.queryItems = query

        guard let url = components.url else { throw BoardClientError.unreachable }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = refresh ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw isLoopback ? BoardClientError.devServerDown(hostLabel) : .unreachable
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            if let failure = try? JSONDecoder().decode(APIErrorBody.self, from: data) {
                throw BoardClientError.api(failure.error, retryAfterSeconds: failure.retryAfterSeconds)
            }
            throw BoardClientError.badStatus(status)
        }

        do {
            return try JSONDecoder().decode(FastBoardResponse.self, from: data)
        } catch {
            throw BoardClientError.undecodable("\(error)")
        }
    }
}

extension BoardClient {
    /// The places one direction goes, nearest first.
    public func destinations(
        from origin: String,
        direction: Compass,
        refresh: Bool = false
    ) async throws -> DestinationList {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("api/v2/destinations"),
            resolvingAgainstBaseURL: false
        ) else { throw BoardClientError.unreachable }

        var query = [
            URLQueryItem(name: "from", value: origin),
            URLQueryItem(name: "direction", value: direction.rawValue),
        ]
        if refresh { query.append(URLQueryItem(name: "refresh", value: "1")) }
        components.queryItems = query

        guard let url = components.url else { throw BoardClientError.unreachable }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw isLoopback ? BoardClientError.devServerDown(hostLabel) : .unreachable
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            if let failure = try? JSONDecoder().decode(APIErrorBody.self, from: data) {
                throw BoardClientError.api(failure.error, retryAfterSeconds: failure.retryAfterSeconds)
            }
            throw BoardClientError.badStatus(status)
        }

        do {
            return try JSONDecoder().decode(DestinationList.self, from: data)
        } catch {
            throw BoardClientError.undecodable("\(error)")
        }
    }
}

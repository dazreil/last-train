import Foundation

/**
 Fast Train: the trains from A to B, in the order they get you there.

 The one idea in the mode. A departure board can only sort by departure, and on any line
 with two routes that is the wrong order. Upminster to Southend Central is the case §11
 was written around: the train leaving now goes round by Tilbury, and the one leaving a
 quarter of an hour later goes up the main line through Basildon and arrives first.

 Sorting is therefore by **arrival**, and departure is only the tie-break.

 This file holds the rule and nothing else. No network, no formatting, no view. What it
 needs is a calling pattern per train, which is the expensive part and lives in the API.
 */
public struct FastService: Sendable, Equatable, Identifiable, Decodable {
    public let serviceId: String
    /// Stable day to day, unlike `serviceId`. What the pattern cache keys on.
    public let headcode: String?
    public let toc: String
    /// The operator as a person names it — `c2c`, not `CC`. The board rows read this;
    /// `toc` stays for the compact surfaces where two letters have to do.
    public let tocName: String
    /// Where the train finishes, which is often past where you get off.
    public let destination: String
    /// London clock at the origin, for reading.
    public let departure: String
    /// London clock at the chosen destination, for reading.
    public let arrival: String
    /// Both as moments, for ordering. Never re-derived from the strings above.
    public let departsAt: Date
    public let arrivesAt: Date

    public var id: String { serviceId }

    /// How long the journey takes, which is what makes one train beat another.
    public var journeyMinutes: Int {
        Int((arrivesAt.timeIntervalSince(departsAt) / 60).rounded())
    }

    public init(
        serviceId: String,
        headcode: String?,
        toc: String,
        tocName: String = "",
        destination: String,
        departure: String,
        arrival: String,
        departsAt: Date,
        arrivesAt: Date
    ) {
        self.serviceId = serviceId
        self.headcode = headcode
        self.toc = toc
        self.tocName = tocName
        self.destination = destination
        self.departure = departure
        self.arrival = arrival
        self.departsAt = departsAt
        self.arrivesAt = arrivesAt
    }

    private enum CodingKeys: String, CodingKey {
        case serviceId, headcode, toc, tocName, destination
        case departure, departureInstant, arrival, arrivalInstant
    }

    /**
     Decoded from the wire, with both instants resolved as London.

     Throws rather than falling back when an instant will not parse. A journey with no
     order cannot be ranked, and a silent default would put a train somewhere it has not
     earned — which is the failure mode this whole file exists to avoid.
     */
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serviceId = try container.decode(String.self, forKey: .serviceId)
        headcode = try container.decodeIfPresent(String.self, forKey: .headcode)
        toc = try container.decode(String.self, forKey: .toc)
        // Optional so an older deployment, which sent only the code, still decodes.
        tocName = try container.decodeIfPresent(String.self, forKey: .tocName) ?? ""
        destination = try container.decode(String.self, forKey: .destination)
        departure = try container.decode(String.self, forKey: .departure)
        arrival = try container.decode(String.self, forKey: .arrival)

        let departureInstant = try container.decode(String.self, forKey: .departureInstant)
        let arrivalInstant = try container.decode(String.self, forKey: .arrivalInstant)

        guard let departsAt = ServiceDay.instant(from: departureInstant),
              let arrivesAt = ServiceDay.instant(from: arrivalInstant)
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .departureInstant,
                in: container,
                debugDescription: "Unreadable departure or arrival instant."
            )
        }

        self.departsAt = departsAt
        self.arrivesAt = arrivesAt
    }
}

/// A whole Fast Train answer, as the API sends it.
public struct FastBoardResponse: Decodable, Sendable, Equatable {
    public let from: BoardStation
    public let to: BoardStation
    public let date: String
    /// In departure order. `FastBoard.rank` puts them in the order that matters.
    public let services: [FastService]
    /// How many direct trains the window holds, before the pattern budget.
    public let candidates: Int
    /**
     True when the budget stopped the server pricing every candidate.

     The four shown are still correct, but they are not provably the fastest four. A
     board that might be beaten has to admit it.
     */
    public let truncated: Bool
}

public enum FastBoard {

    /// How many trains the mode shows. §11 fixed this at four.
    public static let shown = 4

    /**
     Build one entry from a train's calling pattern.

     Returns nil when the train is no use, and each reason is a real case:

     - **It does not call at your destination.** `filterTo` should prevent this, but a
       pattern is the only proof and this is where the proof is.
     - **It calls there before it calls at you.** The same pair appears in both
       directions: a Southend train through Upminster has both stops, and so does the
       train coming back. Order in the pattern is what tells them apart.
     - **Either stop has no usable time.** A stop with no time cannot be ranked, and
       guessing one would put a train in an order it has not earned.
     */
    public static func service(
        from origin: String,
        to destination: String,
        serviceId: String,
        headcode: String?,
        toc: String,
        finalDestination: String,
        calls: [ServiceCall]
    ) -> FastService? {
        guard let boarding = calls.firstIndex(where: { $0.crs == origin }) else { return nil }

        // Searched from the boarding point on, so a train that passes your destination
        // on its way *to* you is not mistaken for one you can catch.
        guard let alighting = calls[boarding...].firstIndex(where: { $0.crs == destination })
        else { return nil }

        guard let departsAt = calls[boarding].instant,
              let arrivesAt = calls[alighting].instant,
              let departure = calls[boarding].time,
              let arrival = calls[alighting].time
        else { return nil }

        // A journey that ends before it starts is a parse failure wearing a disguise,
        // and the service-day rules exist because that is easy to produce.
        guard arrivesAt > departsAt else { return nil }

        return FastService(
            serviceId: serviceId,
            headcode: headcode,
            toc: toc,
            destination: finalDestination,
            departure: departure,
            arrival: arrival,
            departsAt: departsAt,
            arrivesAt: arrivesAt
        )
    }

    /**
     The four that get you there first.

     Ordered by arrival, then by departure. The second key matters more than it looks:
     two trains can arrive together, and the one you can still catch is the one that has
     not left yet — so the earlier departure is listed first and the later one is shown
     as the choice it is.
     */
    public static func rank(_ services: [FastService], limit: Int = shown) -> [FastService] {
        guard limit > 0 else { return [] }

        return services
            .sorted { left, right in
                if left.arrivesAt != right.arrivesAt { return left.arrivesAt < right.arrivesAt }
                return left.departsAt < right.departsAt
            }
            .prefix(limit)
            .map { $0 }
    }

    /**
     The trains you can still catch, and only those.

     A Fast Train board is read the same way a departure board is: standing somewhere,
     now. A train that has left cannot be ranked into first place.
     */
    public static func upcoming(_ services: [FastService], now: Date = Date()) -> [FastService] {
        services.filter { $0.departsAt > now }
    }
}

/// One place you can reach directly, and how long it takes.
public struct Destination: Decodable, Sendable, Equatable, Identifiable {
    public let crs: String
    public let name: String
    /// The shortest direct journey found. Also the list's order, which on a railway is
    /// the order you pass through the stations.
    public let minutes: Int

    public var id: String { crs }
}

/// Where one direction goes, as the API sends it.
public struct DestinationList: Decodable, Sendable, Equatable {
    public let direction: Compass
    public let date: String
    /// Nearest first.
    public let destinations: [Destination]
    /// True when the pattern budget stopped the server reading every route this way.
    public let truncated: Bool
    /**
     Which other directions this list was checked against.

     A destination belongs to the direction that reaches it fastest, and that check needs
     the other directions' times. The server reads those from cache only, so an empty
     array means the list may name places another direction reaches sooner.
     */
    public let comparedWith: [String]

    /// Whether the fastest-direction rule was applied at all.
    public var isSettled: Bool { !comparedWith.isEmpty }
}

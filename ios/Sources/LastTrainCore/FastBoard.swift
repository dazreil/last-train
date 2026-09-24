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
    /// The platform it leaves the origin from, when the line-up knows one.
    public let platform: String?
    /// Both as moments, for ordering. Never re-derived from the strings above.
    public let departsAt: Date
    public let arrivesAt: Date
    /**
     True when this train is a scheduled time rather than a live one.

     Everything past the two-hour live horizon comes from the ingested timetable, and the
     two sources are appended into one list on screen. Without a marker a schedule would sit
     beside a live departure looking equally sure of its platform and its punctuality.
     */
    public let isScheduled: Bool
    /**
     The live board's estimates, when they differ from the timetable.

     Nil when on time, not known, or from an older deployment. `departsAt` and
     `arrivesAt` stay the timetable; the `live` pair below is what ranks and shows.
     */
    public let expectedDeparture: String?
    public let expectedArrival: String?
    public let expectedDepartsAt: Date?
    public let expectedArrivesAt: Date?
    /// Running late with no estimate yet.
    public let isDelayed: Bool

    public var id: String { serviceId }

    /// When it will really leave and arrive, as far as anyone knows.
    public var liveDeparture: String { expectedDeparture ?? departure }
    public var liveArrival: String { expectedArrival ?? arrival }
    public var liveDepartsAt: Date { expectedDepartsAt ?? departsAt }
    public var liveArrivesAt: Date { expectedArrivesAt ?? arrivesAt }

    /// Minutes behind the timetable at departure, when the estimate is later.
    public var minutesLate: Int? {
        guard let expectedDepartsAt else { return nil }
        let minutes = Int((expectedDepartsAt.timeIntervalSince(departsAt) / 60).rounded())
        return minutes > 0 ? minutes : nil
    }

    /// How long the journey takes, which is what makes one train beat another.
    public var journeyMinutes: Int {
        Int((liveArrivesAt.timeIntervalSince(liveDepartsAt) / 60).rounded())
    }

    public init(
        serviceId: String,
        headcode: String?,
        toc: String,
        tocName: String = "",
        destination: String,
        departure: String,
        arrival: String,
        platform: String? = nil,
        departsAt: Date,
        arrivesAt: Date,
        isScheduled: Bool = false,
        expectedDeparture: String? = nil,
        expectedArrival: String? = nil,
        expectedDepartsAt: Date? = nil,
        expectedArrivesAt: Date? = nil,
        isDelayed: Bool = false
    ) {
        self.serviceId = serviceId
        self.headcode = headcode
        self.toc = toc
        self.tocName = tocName
        self.destination = destination
        self.departure = departure
        self.arrival = arrival
        self.platform = platform
        self.departsAt = departsAt
        self.arrivesAt = arrivesAt
        self.isScheduled = isScheduled
        self.expectedDeparture = expectedDeparture
        self.expectedArrival = expectedArrival
        self.expectedDepartsAt = expectedDepartsAt
        self.expectedArrivesAt = expectedArrivesAt
        self.isDelayed = isDelayed
    }

    private enum CodingKeys: String, CodingKey {
        case serviceId, headcode, toc, tocName, destination
        case departure, departureInstant, arrival, arrivalInstant, platform
        case isScheduled
        case expectedDeparture, expectedDepartureInstant, expectedArrival, expectedArrivalInstant
        case isDelayed
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
        // Optional: a deployment that predates it simply has no platform to give.
        platform = try container.decodeIfPresent(String.self, forKey: .platform)
        // Absent means live, which is what every deployment before the timetable sent.
        isScheduled = try container.decodeIfPresent(Bool.self, forKey: .isScheduled) ?? false
        // All optional: a deployment before live times sends none, and reads as on time.
        expectedDeparture = try container.decodeIfPresent(String.self, forKey: .expectedDeparture)
        expectedArrival = try container.decodeIfPresent(String.self, forKey: .expectedArrival)
        expectedDepartsAt = try container.decodeIfPresent(String.self, forKey: .expectedDepartureInstant)
            .flatMap(ServiceDay.instant(from:))
        expectedArrivesAt = try container.decodeIfPresent(String.self, forKey: .expectedArrivalInstant)
            .flatMap(ServiceDay.instant(from:))
        isDelayed = try container.decodeIfPresent(Bool.self, forKey: .isDelayed) ?? false

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
    /**
     Why this window is not the full answer, in a sentence to show as it is.

     Nil when nothing is wrong. **Empty `services` with a notice means "could not find
     out"; empty `services` without one means "there are none".** They are different
     answers and must not look the same.

     The fault this replaces was a silent one: a refused upstream burst left the board
     sitting on three pages with nothing said. A missing timetable must not repeat it.
     */
    public let notice: String?
    /// `live` for a Darwin or RTT board, `timetable` for scheduled times past two hours.
    public let source: String?

    public init(
        from: BoardStation,
        to: BoardStation,
        date: String,
        services: [FastService],
        candidates: Int,
        truncated: Bool,
        notice: String? = nil,
        source: String? = nil
    ) {
        self.from = from
        self.to = to
        self.date = date
        self.services = services
        self.candidates = candidates
        self.truncated = truncated
        self.notice = notice
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case from, to, date, services, candidates, truncated, notice, source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        from = try container.decode(BoardStation.self, forKey: .from)
        to = try container.decode(BoardStation.self, forKey: .to)
        date = try container.decode(String.self, forKey: .date)
        services = try container.decode([FastService].self, forKey: .services)
        candidates = try container.decode(Int.self, forKey: .candidates)
        truncated = try container.decode(Bool.self, forKey: .truncated)
        // Both optional, so a deployment that predates them still decodes.
        notice = try container.decodeIfPresent(String.self, forKey: .notice)
        source = try container.decodeIfPresent(String.self, forKey: .source)
    }
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

        // One train, one row. `serviceId` is what the board keys its rows on, so a
        // repeated id does not merely duplicate a line — it hands SwiftUI two rows
        // claiming to be the same object, which is how an identical pair appeared on a
        // page: same time, same operator, same platform, same journey. Two genuinely
        // different trains sharing a departure minute have different ids and both stay.
        var seen = Set<String>()
        let unique = services.filter { seen.insert($0.serviceId).inserted }

        return unique
            .sorted { left, right in
                // By when it will really arrive: a late fast train is placed where it will
                // get you there, not where the timetable said it would.
                if left.liveArrivesAt != right.liveArrivesAt { return left.liveArrivesAt < right.liveArrivesAt }
                return left.liveDepartsAt < right.liveDepartsAt
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
        // A train past its timetabled time but running late has not left yet.
        services.filter { $0.liveDepartsAt > now }
    }
}

/// One place you can reach directly, and how long it takes.
public struct Destination: Decodable, Sendable, Equatable, Identifiable {
    public let crs: String
    public let name: String
    /// The shortest direct journey found. Also the list's order, which on a railway is
    /// the order you pass through the stations.
    public let minutes: Int
    /**
     The way you head to get there: the direction whose train reaches it fastest.

     Present whenever the list came from the timetable. A station two directions reach in
     the same time is sent once under each, so the row a passenger taps already says which
     way — nothing on this side has to break a tie.
     */
    public let direction: Compass?

    public init(crs: String, name: String, minutes: Int, direction: Compass? = nil) {
        self.crs = crs
        self.name = name
        self.minutes = minutes
        self.direction = direction
    }

    /// The station *and* the way, because a tied station appears once per direction.
    public var id: String { "\(crs)-\(direction?.rawValue ?? "")" }
}

/// One of the busiest destinations, as the server names it: a station, and the way to it.
public struct PopularDestination: Decodable, Sendable, Equatable {
    public let crs: String
    public let direction: Compass?
}

/// Where one direction goes — or, with no direction, every way at once — as the API sends it.
public struct DestinationList: Decodable, Sendable, Equatable {
    /// Nil for the unfiltered list, where each destination carries its own direction.
    public let direction: Compass?
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

    /**
     The busiest few of these destinations, busiest first, as the server named them.

     From the Office of Rail and Road's count of journeys between every pair of stations.
     Drawn only from this list, so a direction's list gets that direction's busiest. Empty
     when the list is no longer than the section would be.
     */
    public let popular: [PopularDestination]?
    /// Where `popular` comes from, to show beside it — the data's licence asks for that.
    public let popularSource: String?

    /// Whether the fastest-direction rule was applied at all.
    public var isSettled: Bool { !comparedWith.isEmpty }

    /**
     `popular`, as the rows the picker draws.

     Matched on station *and* direction, because a station two directions reach equally is
     in the list twice, and the shortcut should open the same way its row below would.
     */
    public var popularDestinations: [Destination] {
        (popular ?? []).compactMap { ref in
            destinations.first { $0.crs == ref.crs && (ref.direction == nil || $0.direction == ref.direction) }
                ?? destinations.first { $0.crs == ref.crs }
        }
    }

    /**
     The destinations under each direction, in compass order, each nearest first.

     What the picker shows before you have said which way you are going: one section per
     direction, so the list teaches which way each station is while you choose it.
     */
    public var byDirection: [(direction: Compass, destinations: [Destination])] {
        Compass.allCases.compactMap { point in
            let these = destinations.filter { $0.direction == point }
            return these.isEmpty ? nil : (point, these)
        }
    }
}

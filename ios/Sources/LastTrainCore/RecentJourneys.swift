import Foundation

/**
 The journeys you have made — a start and a destination — most recent first.

 Shown as up to five rows on the blank board, and in the menu you get by holding either
 station code. Choosing one sets the whole board in one tap.

 **A followed journey ranks higher.** A journey you followed a train on counts as if it
 had been used a day later than it was: it rises above anything used in the last day,
 then settles back into order as newer journeys arrive. It is a nudge, not a pin — a
 journey followed once last month does not sit on top for ever.

 `UPM → BSO` and `BSO → UPM` are different journeys, because they are different trips.

 Pure, so the ranking can be tested without a device. The app stores it as JSON.
 */
public struct RecentJourneys: Codable, Equatable, Sendable {

    public struct Journey: Codable, Equatable, Sendable {
        public let from: String
        public let to: String
        /// The way the train goes, as the board had it, so a tap reopens the same board.
        public var direction: Compass
        public var lastUsed: Date
        public var lastFollowed: Date?

        public init(from: String, to: String, direction: Compass, lastUsed: Date, lastFollowed: Date? = nil) {
            self.from = from.uppercased()
            self.to = to.uppercased()
            self.direction = direction
            self.lastUsed = lastUsed
            self.lastFollowed = lastFollowed
        }

        /// The time it is ranked by: when it was used, or a day after it was last
        /// followed, whichever is later.
        public var rank: Date {
            guard let lastFollowed else { return lastUsed }
            return max(lastUsed, lastFollowed.addingTimeInterval(RecentJourneys.followBoost))
        }

        func isSame(from: String, to: String) -> Bool {
            self.from == from.uppercased() && self.to == to.uppercased()
        }
    }

    /// How much later a followed journey counts as having been used.
    public static let followBoost: TimeInterval = 24 * 60 * 60
    /// Kept, of which five are shown. Room for a few weeks of changing plans.
    public static let capacity = 20
    /// Shown on the blank board and in the menu.
    public static let shown = 5

    public private(set) var journeys: [Journey]

    public init(journeys: [Journey] = []) {
        self.journeys = journeys
    }

    /// Count a journey as used now, with the direction the board had for it.
    public mutating func record(from: String, to: String, direction: Compass, at date: Date = Date()) {
        guard from.uppercased() != to.uppercased() else { return }
        if let index = journeys.firstIndex(where: { $0.isSame(from: from, to: to) }) {
            journeys[index].direction = direction
            journeys[index].lastUsed = max(journeys[index].lastUsed, date)
        } else {
            journeys.append(Journey(from: from, to: to, direction: direction, lastUsed: date))
        }
        trim()
    }

    /// A train was followed on this journey. Also counts as a use.
    public mutating func markFollowed(from: String, to: String, direction: Compass, at date: Date = Date()) {
        record(from: from, to: to, direction: direction, at: date)
        if let index = journeys.firstIndex(where: { $0.isSame(from: from, to: to) }) {
            journeys[index].lastFollowed = date
        }
    }

    /**
     The journeys to offer, highest ranked first.

     `excluding` leaves out the journey already on screen, which is no use as a shortcut
     to itself.
     */
    public func list(limit: Int = RecentJourneys.shown, excluding current: (from: String, to: String)? = nil) -> [Journey] {
        journeys
            .filter { journey in
                guard let current else { return true }
                return !journey.isSame(from: current.from, to: current.to)
            }
            .sorted(by: Self.ranksAbove)
            .prefix(max(limit, 0))
            .map { $0 }
    }

    /// Past capacity, the lowest ranked goes.
    private mutating func trim() {
        guard journeys.count > Self.capacity else { return }
        journeys = Array(journeys.sorted(by: Self.ranksAbove).prefix(Self.capacity))
    }

    /// Higher rank first; the codes break a tie so the order is stable.
    private static func ranksAbove(_ a: Journey, _ b: Journey) -> Bool {
        if a.rank != b.rank { return a.rank > b.rank }
        if a.from != b.from { return a.from < b.from }
        return a.to < b.to
    }
}

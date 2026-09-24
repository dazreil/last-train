import Foundation
import Testing

import LastTrainCore

/// The ranking behind the recent journeys on the blank board and the station-code menu.
@Suite("RecentJourneys")
struct RecentJourneysTests {

    /// A clock the test drives, one hour a tick.
    private static func at(_ hour: Double) -> Date {
        Date(timeIntervalSince1970: 1_790_000_000 + hour * 3600)
    }

    private static func codes(_ list: [RecentJourneys.Journey]) -> [String] {
        list.map { "\($0.from)-\($0.to)" }
    }

    @Test("most recent first")
    func recency() {
        var recent = RecentJourneys()
        recent.record(from: "UPM", to: "BSO", direction: .east, at: Self.at(0))
        recent.record(from: "FST", to: "UPM", direction: .east, at: Self.at(1))
        recent.record(from: "EUS", to: "MKC", direction: .north, at: Self.at(2))
        #expect(Self.codes(recent.list()) == ["EUS-MKC", "FST-UPM", "UPM-BSO"])
    }

    @Test("a journey and its reverse are two journeys")
    func reverseIsDistinct() {
        var recent = RecentJourneys()
        recent.record(from: "UPM", to: "BSO", direction: .east, at: Self.at(0))
        recent.record(from: "BSO", to: "UPM", direction: .west, at: Self.at(1))
        #expect(recent.journeys.count == 2)
    }

    @Test("using a journey again moves it up and keeps one entry, with the newest direction")
    func reuse() {
        var recent = RecentJourneys()
        recent.record(from: "UPM", to: "BSO", direction: .east, at: Self.at(0))
        recent.record(from: "FST", to: "UPM", direction: .east, at: Self.at(1))
        recent.record(from: "upm", to: "bso", direction: .south, at: Self.at(2))
        #expect(recent.journeys.count == 2)
        #expect(Self.codes(recent.list()) == ["UPM-BSO", "FST-UPM"])
        #expect(recent.list().first?.direction == .south)
    }

    /// The owner's rule: a journey that has been followed appears nearer the top.
    @Test("a followed journey rises above ones used since, within a day")
    func followedRises() {
        var recent = RecentJourneys()
        recent.markFollowed(from: "UPM", to: "BSO", direction: .east, at: Self.at(0))
        recent.record(from: "FST", to: "UPM", direction: .east, at: Self.at(5))
        recent.record(from: "EUS", to: "MKC", direction: .north, at: Self.at(10))
        #expect(Self.codes(recent.list()).first == "UPM-BSO")
    }

    /// Nearer the top, not pinned there: a journey followed long ago settles back.
    @Test("a follow is a nudge, not a pin")
    func followFades() {
        var recent = RecentJourneys()
        recent.markFollowed(from: "UPM", to: "BSO", direction: .east, at: Self.at(0))
        recent.record(from: "EUS", to: "MKC", direction: .north, at: Self.at(30))
        #expect(Self.codes(recent.list()) == ["EUS-MKC", "UPM-BSO"])
    }

    @Test("five are shown, and the journey on screen is left out")
    func limitAndExclude() {
        var recent = RecentJourneys()
        for hour in 0..<8 {
            recent.record(from: String(format: "A%02d", hour), to: "ZZZ", direction: .west, at: Self.at(Double(hour)))
        }
        #expect(recent.list().count == 5)
        let without = recent.list(excluding: (from: "A07", to: "ZZZ"))
        #expect(without.count == 5)
        #expect(!Self.codes(without).contains("A07-ZZZ"))
    }

    @Test("a journey to where you already are is not recorded")
    func noSelfJourney() {
        var recent = RecentJourneys()
        recent.record(from: "UPM", to: "upm", direction: .east, at: Self.at(0))
        #expect(recent.journeys.isEmpty)
    }

    @Test("past capacity the lowest ranked goes, never a followed one first")
    func capacity() {
        var recent = RecentJourneys()
        recent.markFollowed(from: "OLD", to: "FOL", direction: .east, at: Self.at(0))
        for index in 1...RecentJourneys.capacity {
            recent.record(from: String(format: "S%02d", index), to: "ZZZ", direction: .west, at: Self.at(Double(index) / 10))
        }
        #expect(recent.journeys.count == RecentJourneys.capacity)
        #expect(recent.journeys.contains { $0.from == "OLD" })
        #expect(!recent.journeys.contains { $0.from == "S01" })
    }

    @Test("it survives a round trip through JSON, as the app stores it")
    func codable() throws {
        var recent = RecentJourneys()
        recent.markFollowed(from: "UPM", to: "BSO", direction: .east, at: Self.at(0))
        let data = try JSONEncoder().encode(recent)
        #expect(try JSONDecoder().decode(RecentJourneys.self, from: data) == recent)
    }
}

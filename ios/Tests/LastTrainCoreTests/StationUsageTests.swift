import Foundation
import Testing

import LastTrainCore

/// The ranking behind the "Most used" and "Recent" hold menus.
@Suite("StationUsage")
struct StationUsageTests {

    /// A clock the test drives, one minute a tick.
    private static func at(_ minute: Int) -> Date {
        Date(timeIntervalSince1970: 1_790_000_000 + Double(minute) * 60)
    }

    @Test("the station used most leads, whatever order the uses came in")
    func mostUsedLeads() {
        var usage = StationUsage()
        usage.record("UPM", at: Self.at(0))
        usage.record("FST", at: Self.at(1))
        usage.record("UPM", at: Self.at(2))
        usage.record("BKG", at: Self.at(3))
        usage.record("UPM", at: Self.at(4))
        usage.record("FST", at: Self.at(5))
        #expect(usage.mostUsed() == ["UPM", "FST", "BKG"])
    }

    @Test("a tie on count goes to the more recent")
    func tieGoesToRecent() {
        var usage = StationUsage()
        usage.record("UPM", at: Self.at(0))
        usage.record("FST", at: Self.at(1))
        #expect(usage.mostUsed() == ["FST", "UPM"])
    }

    @Test("recent leaves out what most used already shows, so no station is listed twice")
    func recentExcludesMostUsed() {
        var usage = StationUsage()
        for (minute, crs) in ["A01", "A02", "A03", "A04", "A05", "A06"].enumerated() {
            usage.record(crs, at: Self.at(minute))
        }
        usage.record("A01", at: Self.at(10))
        let most = usage.mostUsed()
        let recent = usage.recent(excluding: Set(most))
        #expect(most.count == 4)
        #expect(Set(most).isDisjoint(with: recent))
        #expect(most == ["A01", "A06", "A05", "A04"])
        #expect(recent == ["A03", "A02"])
    }

    @Test("both lists stop at the limit")
    func limits() {
        var usage = StationUsage()
        for minute in 0..<10 { usage.record(String(format: "S%02d", minute), at: Self.at(minute)) }
        #expect(usage.mostUsed().count == 4)
        #expect(usage.recent().count == 4)
        #expect(usage.recent() == ["S09", "S08", "S07", "S06"])
    }

    @Test("codes are counted without regard to case")
    func caseInsensitive() {
        var usage = StationUsage()
        usage.record("upm", at: Self.at(0))
        usage.record("UPM", at: Self.at(1))
        #expect(usage.entries["UPM"]?.count == 2)
        #expect(usage.entries.count == 1)
    }

    /**
     Full, a new station pushes out the least **recently** used — not the least used. A
     station used heavily long ago must not hold its place for ever and shut a new
     commute out.
     */
    @Test("at capacity the stalest station goes, not the least used")
    func evictsStalest() {
        var usage = StationUsage()
        // The oldest is also the most used.
        for _ in 0..<5 { usage.record("OLD", at: Self.at(0)) }
        for index in 1..<StationUsage.capacity {
            usage.record(String(format: "S%02d", index), at: Self.at(index))
        }
        #expect(usage.entries.count == StationUsage.capacity)

        usage.record("NEW", at: Self.at(1_000))
        #expect(usage.entries.count == StationUsage.capacity)
        #expect(usage.entries["OLD"] == nil)
        #expect(usage.entries["NEW"]?.count == 1)
    }

    @Test("it survives a round trip through JSON, as the app stores it")
    func codable() throws {
        var usage = StationUsage()
        usage.record("UPM", at: Self.at(0))
        usage.record("UPM", at: Self.at(1))
        let data = try JSONEncoder().encode(usage)
        #expect(try JSONDecoder().decode(StationUsage.self, from: data) == usage)
    }
}

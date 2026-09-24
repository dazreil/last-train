import Foundation

/**
 Which stations you start from, and how often.

 Feeds the hold menus in `HOLD-MENUS.md`: "Most used" and "Recent" under the location
 button, and "Set home from recent" under the house. Kept on the phone and never sent
 anywhere.

 **Only start stations count.** "Most used" is meant to read as "where I usually stand",
 which is what the location button is about; a destination is somewhere you go, not
 somewhere you are.

 Pure, so the ranking can be tested without a device. The app stores it as JSON.
 */
public struct StationUsage: Codable, Equatable, Sendable {

    public struct Entry: Codable, Equatable, Sendable {
        public var count: Int
        public var lastUsed: Date

        public init(count: Int, lastUsed: Date) {
            self.count = count
            self.lastUsed = lastUsed
        }
    }

    /// More than anyone uses, and a few kilobytes at most.
    public static let capacity = 50

    public private(set) var entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    /**
     Count a station as used, now.

     A new station arriving at capacity pushes out the least recently used one — not the
     least used, which would let a station used heavily years ago sit there for ever and
     keep a new commute from ever getting in.
     */
    public mutating func record(_ crs: String, at date: Date = Date()) {
        let code = crs.uppercased()
        if var entry = entries[code] {
            entry.count += 1
            entry.lastUsed = max(entry.lastUsed, date)
            entries[code] = entry
            return
        }
        if entries.count >= Self.capacity,
           let stalest = entries.min(by: { Self.isStaler($0, $1) })?.key {
            entries.removeValue(forKey: stalest)
        }
        entries[code] = Entry(count: 1, lastUsed: date)
    }

    /// Most used first; the more recent breaks a tie, then the code, so the order is stable.
    public func mostUsed(limit: Int = 4) -> [String] {
        entries
            .sorted { a, b in
                if a.value.count != b.value.count { return a.value.count > b.value.count }
                if a.value.lastUsed != b.value.lastUsed { return a.value.lastUsed > b.value.lastUsed }
                return a.key < b.key
            }
            .prefix(max(limit, 0))
            .map(\.key)
    }

    /// Most recent first, leaving out any station in `excluding` — the ones already shown
    /// under Most used, so a menu never lists a station twice.
    public func recent(limit: Int = 4, excluding: Set<String> = []) -> [String] {
        entries
            .filter { !excluding.contains($0.key) }
            .sorted { a, b in
                if a.value.lastUsed != b.value.lastUsed { return a.value.lastUsed > b.value.lastUsed }
                return a.key < b.key
            }
            .prefix(max(limit, 0))
            .map(\.key)
    }

    /// Older first; the code breaks a tie so eviction is deterministic.
    private static func isStaler(_ a: (key: String, value: Entry), _ b: (key: String, value: Entry)) -> Bool {
        if a.value.lastUsed != b.value.lastUsed { return a.value.lastUsed < b.value.lastUsed }
        return a.key < b.key
    }
}

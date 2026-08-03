import Foundation

/**
 The rail service day, and London time.

 A port of `lib/serviceDay.ts`, and the first thing written for the native app on
 purpose: IOS.md §7 names this as the logic to reimplement carefully, because both of
 its rules produce a *wrong answer* rather than a crash.

 1. The last train from London is usually after midnight, on the next calendar date.
    Query "today" naively and the single most important result in the app disappears.
 2. Always query a specific date. Sundays and engineering weekends are completely
    different timetables.

 So the service day runs 03:00 → 02:59 the following morning. A train leaving at 00:32
 on Saturday morning belongs to Friday's service day, which is what a person standing
 on a platform means by "the last train tonight".

 ## Every formatter states its timezone

 §7: "Set the timezone explicitly on every Swift formatter. The web app's hour-late
 production bug came from trusting a default; a rewrite is exactly where that
 returns."

 That bug: the API sends departure times with **no timezone marker at all** —
 literally `"2026-07-30T23:12:00"` — and they are London wall-clock times. Anything
 that resolves such a string against the device's current timezone is correct in
 London and wrong everywhere else, including on a server in UTC. Every `DateFormatter`
 below sets `timeZone` and `locale` explicitly, and none of them is allowed to inherit.

 `Locale(identifier: "en_US_POSIX")` on the parsing formatters is not cosmetic either:
 a device set to a non-Gregorian calendar will otherwise parse `2026-07-30` into the
 wrong year entirely.
 */
public enum ServiceDay {

    /// An ISO calendar date, `YYYY-MM-DD`. Not a service day on its own.
    public typealias IsoDate = String

    /// The service day begins at 03:00 and runs to 02:59 the next morning.
    public static let startHour = 3

    /// Departure times from the API are London wall-clock, whatever the device thinks.
    public static let londonTimeZone: TimeZone = {
        guard let zone = TimeZone(identifier: "Europe/London") else {
            preconditionFailure("Europe/London is missing from the system timezone database")
        }
        return zone
    }()

    private static let utc: TimeZone = {
        guard let zone = TimeZone(identifier: "UTC") else {
            preconditionFailure("UTC is missing from the system timezone database")
        }
        return zone
    }()

    private static let posix = Locale(identifier: "en_US_POSIX")

    // MARK: - Formatters

    private static func formatter(_ format: String, _ zone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.timeZone = zone
        formatter.locale = posix
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = format
        return formatter
    }

    /// Parses the API's timezone-less shape as London, which is what it is.
    private static let londonNaive = formatter("yyyy-MM-dd'T'HH:mm:ss", londonTimeZone)

    /// `23:52`, London local. `HH` never renders midnight as 24.
    private static let londonClock = formatter("HH:mm", londonTimeZone)

    /// The London calendar date an instant falls on.
    private static let londonDay = formatter("yyyy-MM-dd", londonTimeZone)

    /// Bare dates are handled in UTC so that no clock change can shift one.
    private static let bareDate = formatter("yyyy-MM-dd", utc)

    /// Parses the forms that *do* carry a zone. `XXXXX` accepts `Z` and `+01:00` alike,
    /// and the offset in the string wins over this formatter's own timezone.
    private static let londonOffset = formatter("yyyy-MM-dd'T'HH:mm:ssXXXXX", utc)

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        calendar.locale = posix
        return calendar
    }()

    private static let londonCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = londonTimeZone
        calendar.locale = posix
        return calendar
    }()

    // MARK: - Bare dates

    /// Calendar arithmetic on a bare date, done in UTC so no clock change can perturb it.
    public static func addDays(_ date: IsoDate, _ days: Int) -> IsoDate? {
        guard let parsed = bareDate.date(from: date),
              let moved = utcCalendar.date(byAdding: .day, value: days, to: parsed)
        else { return nil }
        return bareDate.string(from: moved)
    }

    public static func isValidIsoDate(_ value: String) -> Bool {
        // Shape first: the formatter alone would accept `2026-7-9`, which the API
        // will not, and a lenient parse of `2026-13-01` would roll into next year.
        guard value.count == 10 else { return false }
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) })
        else { return false }

        guard let parsed = bareDate.date(from: value) else { return false }
        // Round-trips only if the fields were real: month 13 would come back as 01.
        return bareDate.string(from: parsed) == value
    }

    // MARK: - Which service day is it?

    /**
     The service day currently in progress in London.

     At 00:20 on Saturday this returns Friday, because the trains still running are
     Friday's. This is the difference between the app being useful at 23:40 and being
     actively misleading at 00:10.
     */
    public static func currentServiceDate(now: Date = Date()) -> IsoDate {
        let hour = londonCalendar.component(.hour, from: now)
        let today = londonDay.string(from: now)
        guard hour < startHour else { return today }
        return addDays(today, -1) ?? today
    }

    public struct Window: Equatable, Sendable {
        public let timeFrom: String
        public let timeTo: String
    }

    /**
     The query window covering one whole service day.

     Deliberately offset-less. The API reads a datetime with no offset as local to the
     station being queried, so this is correct through both BST and GMT without us
     converting anything — and correct across the spring-forward night, when
     01:00–02:00 does not exist in London.

     03:00 → 02:59 is 23h59m, exactly the documented maximum window.
     */
    public static func serviceDayWindow(_ date: IsoDate) -> Window? {
        guard let next = addDays(date, 1) else { return nil }
        let pad = { (n: Int) in String(format: "%02d", n) }
        return Window(
            timeFrom: "\(date)T\(pad(startHour)):00:00",
            timeTo: "\(next)T\(pad(startHour - 1)):59:00"
        )
    }

    // MARK: - Instants

    /// Does this datetime carry a `Z` or a `±HH:MM` offset?
    static func hasTimeZone(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last else { return false }
        if last == "Z" || last == "z" { return true }

        // `+01:00` or `+0100` at the very end, distinguished from the date's own
        // hyphens by only looking at the tail after the time has started.
        guard let timeStart = trimmed.firstIndex(of: "T") else { return false }
        let time = trimmed[timeStart...]
        guard let signIndex = time.lastIndex(where: { $0 == "+" || $0 == "-" }) else { return false }
        let offset = time[time.index(after: signIndex)...]
        let digits = offset.filter(\.isNumber).count
        return (digits == 4) && offset.allSatisfy { $0.isNumber || $0 == ":" }
    }

    /**
     Turn a datetime from the API into an absolute instant.

     A naive string is interpreted explicitly as London, never as "local time".
     Strings that do carry an offset are parsed normally; the spec permits both, and
     the query echo comes back with one even though service times do not.
     */
    public static func instant(from value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if hasTimeZone(trimmed) { return londonOffset.date(from: trimmed) }
        return londonNaive.date(from: trimmed)
    }

    /// `23:52`, in London local time.
    public static func formatLondonTime(_ value: String) -> String? {
        guard let date = instant(from: value) else { return nil }
        return londonClock.string(from: date)
    }

    /// The London calendar date a time falls on — used to flag departures after midnight.
    public static func londonDate(of value: String) -> IsoDate? {
        guard let date = instant(from: value) else { return nil }
        return londonDay.string(from: date)
    }

    /**
     Minutes between two times.

     Resolved to absolute instants first, so this is right across midnight and across
     a clock change without special-casing either.
     */
    public static func minutesBetween(_ from: String, _ to: String) -> Int? {
        guard let start = instant(from: from), let end = instant(from: to) else { return nil }
        return Int((end.timeIntervalSince(start) / 60).rounded())
    }

    // MARK: - Display

    private static let serviceDateDisplay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = utc
        // en_GB for "Wed 29 Jul" rather than an American month order. The timezone is
        // still UTC, so the rendered day cannot drift.
        formatter.locale = Locale(identifier: "en_GB")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "EEE d MMM"
        return formatter
    }()

    /// `Thu 30 Jul`, for showing which service day is on screen.
    public static func formatServiceDate(_ date: IsoDate) -> String? {
        guard let parsed = bareDate.date(from: date) else { return nil }
        return serviceDateDisplay.string(from: parsed)
    }
}

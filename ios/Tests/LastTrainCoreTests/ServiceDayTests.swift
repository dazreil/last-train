import Foundation
import Testing

import LastTrainCore

/**
 A port of `lib/serviceDay.test.ts`, test for test.

 IOS.md §7: "Port the tests first, then the code." These are the same assertions the
 web app has passed since the hour-late bug was fixed, and they exist here to catch
 the rewrite reintroducing it — which is exactly where that class of bug comes back.

 The API sends departure times with no timezone at all — `"2026-07-30T23:12:00"`,
 verified against the live service — and those are London wall-clock times. These
 tests deliberately use that shape. An earlier version of the JavaScript suite used
 `Z`-suffixed instants, which are unambiguous and therefore passed everywhere, hiding
 a bug that only appeared on a server running UTC.

 Run under `TZ=UTC`, for the same reason `npm test` is.

 Deliberately importing `LastTrainCore` rather than `@testable import`: everything
 here goes through the public surface, which is worth proving is sufficient.

 In 2026, BST runs from 29 March to 25 October.
 */
@Suite("Service day")
struct ServiceDayTests {

    @Test("the service day does not roll over at midnight")
    func serviceDayDoesNotRollOverAtMidnight() {
        // 23:00 BST on the 29th -- squarely inside the 29th's service day.
        #expect(ServiceDay.currentServiceDate(now: utcInstant("2026-07-29T22:00:00Z")) == "2026-07-29")

        // 00:30 BST on the 30th. The calendar says the 30th; the trains still running
        // are the 29th's. This is the case that decides whether the app is useful or
        // actively misleading at ten past midnight.
        #expect(ServiceDay.currentServiceDate(now: utcInstant("2026-07-29T23:30:00Z")) == "2026-07-29")

        // 02:59 BST -- still the previous service day.
        #expect(ServiceDay.currentServiceDate(now: utcInstant("2026-07-30T01:59:00Z")) == "2026-07-29")

        // 03:00 BST -- the new service day has begun.
        #expect(ServiceDay.currentServiceDate(now: utcInstant("2026-07-30T02:00:00Z")) == "2026-07-30")
    }

    @Test("the service day boundary respects GMT as well as BST")
    func serviceDayBoundaryRespectsGmt() {
        // 00:30 GMT in January: same rule, no offset applied.
        #expect(ServiceDay.currentServiceDate(now: utcInstant("2026-01-15T00:30:00Z")) == "2026-01-14")
        #expect(ServiceDay.currentServiceDate(now: utcInstant("2026-01-15T03:30:00Z")) == "2026-01-15")

        // 23:30 UTC in January is 23:30 London, so still the same day -- whereas the
        // identical UTC instant in July is 00:30 the next morning. A UTC-only
        // implementation gets exactly one of these two wrong.
        #expect(ServiceDay.currentServiceDate(now: utcInstant("2026-01-15T23:30:00Z")) == "2026-01-15")
        #expect(ServiceDay.currentServiceDate(now: utcInstant("2026-07-15T23:30:00Z")) == "2026-07-15")
    }

    @Test("the service day boundary rolls the month and year over")
    func serviceDayBoundaryRollsOver() {
        #expect(ServiceDay.currentServiceDate(now: utcInstant("2027-01-01T01:00:00Z")) == "2026-12-31")
        #expect(ServiceDay.currentServiceDate(now: utcInstant("2026-08-01T01:30:00Z")) == "2026-07-31")
    }

    @Test("the query window covers 03:00 to 02:59 the next morning")
    func queryWindowCoversWholeServiceDay() throws {
        let window = try #require(ServiceDay.serviceDayWindow("2026-07-29"))
        #expect(window.timeFrom == "2026-07-29T03:00:00")
        #expect(window.timeTo == "2026-07-30T02:59:00")
    }

    /**
     Offset-less, so the API reads it as local to the station. Checking the span in
     London terms is what matters: on the spring-forward night the local day is only
     23 hours long, and on the autumn night it is 25 — the latter is the one that
     could breach the documented limit.
     */
    @Test(
        "the query window never exceeds the documented 23h59m maximum",
        arguments: ["2026-03-29", "2026-10-25", "2026-07-29", "2026-01-15"]
    )
    func queryWindowNeverExceedsMaximum(date: String) throws {
        let window = try #require(ServiceDay.serviceDayWindow(date))
        // Read as UTC on both ends, which measures the nominal span rather than the
        // elapsed one -- the same thing the JavaScript test asserts.
        let from = utcInstant("\(window.timeFrom)Z")
        let to = utcInstant("\(window.timeTo)Z")
        #expect(Int(to.timeIntervalSince(from) / 60) == 23 * 60 + 59)
    }

    @Test("a timezone-less time from the API is read as London, not as the device clock")
    func naiveTimesAreReadAsLondon() {
        // This is the exact shape the API returns, and the exact bug: on a device or
        // server not in London these read an hour out unless London is applied.
        #expect(ServiceDay.formatLondonTime("2026-07-30T23:12:00") == "23:12")
        #expect(ServiceDay.formatLondonTime("2026-07-30T00:22:00") == "00:22")
        #expect(ServiceDay.londonDate(of: "2026-07-30T23:12:00") == "2026-07-30")

        // Winter, when London is UTC, so the naive reading happens to agree.
        #expect(ServiceDay.formatLondonTime("2026-01-15T23:12:00") == "23:12")
        #expect(ServiceDay.londonDate(of: "2026-01-15T23:12:00") == "2026-01-15")
    }

    @Test("a time that does carry an offset is still honoured")
    func offsetsAreHonoured() {
        // The spec permits both forms; the query echo comes back with an offset.
        #expect(ServiceDay.formatLondonTime("2026-07-29T22:52:00Z") == "23:52")
        #expect(ServiceDay.formatLondonTime("2026-07-29T23:52:00+01:00") == "23:52")
        #expect(ServiceDay.formatLondonTime("2026-01-15T23:52:00Z") == "23:52")
    }

    @Test("times are formatted in London local time")
    func timesAreFormattedInLondon() {
        // The spec's own example: 23:52 -> 00:48.
        #expect(ServiceDay.formatLondonTime("2026-07-29T22:52:00Z") == "23:52")
        #expect(ServiceDay.formatLondonTime("2026-07-29T23:48:00Z") == "00:48")

        // Midnight must render as 00:00, never 24:00.
        #expect(ServiceDay.formatLondonTime("2026-07-29T23:00:00Z") == "00:00")

        // Winter: no offset.
        #expect(ServiceDay.formatLondonTime("2026-01-15T23:52:00Z") == "23:52")
    }

    @Test("display times follow the selected 12 or 24 hour clock")
    func displayTimesFollowHourCycle() {
        let twelveHour = Locale(identifier: "en_US")
        #expect(ServiceDay.formatClock("23:47", locale: twelveHour).time == "11:47")
        #expect(ServiceDay.formatClock("23:47", locale: twelveHour).dayPeriod == "PM")
        #expect(ServiceDay.formatClock("00:42", locale: twelveHour).spoken == "12:42 AM")
        #expect(ServiceDay.formatClock("12:00", locale: twelveHour).spoken == "12:00 PM")

        let twentyFourHour = Locale(identifier: "en_GB")
        #expect(ServiceDay.formatClock("23:47", locale: twentyFourHour).time == "23:47")
        #expect(ServiceDay.formatClock("23:47", locale: twentyFourHour).dayPeriod == nil)
        #expect(ServiceDay.formatClock("00:42", locale: twentyFourHour).spoken == "00:42")

        #expect(ServiceDay.formatClock("--:--", locale: twelveHour).spoken == "--:--")
    }

    @Test("London wall-clock times resolve to the right absolute instant")
    func wallClockResolvesToRightInstant() {
        // 23:12 BST is 22:12 UTC.
        #expect(utcString(ServiceDay.instant(from: "2026-07-30T23:12:00")) == "2026-07-30T22:12:00Z")
        // 23:12 GMT is 23:12 UTC.
        #expect(utcString(ServiceDay.instant(from: "2026-01-15T23:12:00")) == "2026-01-15T23:12:00Z")
        // Either side of the autumn change, when 01:30 happens twice.
        #expect(utcString(ServiceDay.instant(from: "2026-10-25T00:30:00")) == "2026-10-24T23:30:00Z")
        #expect(utcString(ServiceDay.instant(from: "2026-10-25T03:30:00")) == "2026-10-25T03:30:00Z")
    }

    @Test("the last trains of the night keep their real times")
    func lastTrainsKeepTheirTimes() {
        // The reported bug, as a whole scenario: real c2c departures from Grays, as
        // the API sends them. Every one of these read an hour late in production.
        let serviceDate = "2026-07-30"
        let departures = ["2026-07-30T23:17:00", "2026-07-30T23:47:00", "2026-07-31T00:18:00"]

        let shown = departures.map { departure in
            (
                at: ServiceDay.formatLondonTime(departure),
                afterMidnight: ServiceDay.londonDate(of: departure) != serviceDate
            )
        }

        #expect(shown[0] == (at: "23:17", afterMidnight: false))
        #expect(shown[1] == (at: "23:47", afterMidnight: false))
        #expect(shown[2] == (at: "00:18", afterMidnight: true))
    }

    @Test("an arrival after midnight is recognised as the next calendar day")
    func arrivalAfterMidnightIsNextDay() {
        let departure = "2026-07-29T22:52:00Z" // 23:52 BST on the 29th
        let arrival = "2026-07-29T23:48:00Z"   // 00:48 BST on the 30th

        #expect(ServiceDay.londonDate(of: departure) == "2026-07-29")
        #expect(ServiceDay.londonDate(of: arrival) == "2026-07-30")
        #expect(ServiceDay.londonDate(of: departure) != ServiceDay.londonDate(of: arrival))
    }

    @Test("durations are correct across midnight and across a clock change")
    func durationsSurviveClockChanges() {
        // 23:52 -> 00:48 is 56 minutes, as the spec's example says.
        #expect(ServiceDay.minutesBetween("2026-07-29T22:52:00Z", "2026-07-29T23:48:00Z") == 56)

        // Spring forward: London clocks jump 01:00 -> 02:00, so a train that appears
        // to depart 00:50 and arrive 02:10 really took 20 minutes. Comparing absolute
        // instants gets this right without special-casing.
        #expect(ServiceDay.minutesBetween("2026-03-29T00:50:00Z", "2026-03-29T01:10:00Z") == 20)

        // Autumn back: 01:00-02:00 happens twice.
        #expect(ServiceDay.minutesBetween("2026-10-25T00:50:00Z", "2026-10-25T01:30:00Z") == 40)
    }

    @Test("date arithmetic survives month, year and DST boundaries")
    func dateArithmeticSurvivesBoundaries() {
        #expect(ServiceDay.addDays("2026-12-31", 1) == "2027-01-01")
        #expect(ServiceDay.addDays("2026-01-01", -1) == "2025-12-31")
        #expect(ServiceDay.addDays("2026-02-28", 1) == "2026-03-01") // 2026 is not a leap year
        #expect(ServiceDay.addDays("2028-02-28", 1) == "2028-02-29") // 2028 is
        #expect(ServiceDay.addDays("2026-03-28", 1) == "2026-03-29") // clocks go forward
        #expect(ServiceDay.addDays("2026-10-24", 1) == "2026-10-25") // clocks go back
        #expect(ServiceDay.addDays("2026-07-29", 0) == "2026-07-29")
    }

    @Test("dates are validated")
    func datesAreValidated() {
        #expect(ServiceDay.isValidIsoDate("2026-07-29"))
        #expect(!ServiceDay.isValidIsoDate("29-07-2026"))
        #expect(!ServiceDay.isValidIsoDate("2026-7-9"))
        #expect(!ServiceDay.isValidIsoDate("2026-13-01"))
        #expect(!ServiceDay.isValidIsoDate(""))
        #expect(!ServiceDay.isValidIsoDate("tomorrow"))
    }

    @Test("service dates are rendered without drifting a day")
    func serviceDatesDoNotDrift() {
        // Formatted in UTC precisely so no offset can shift them.
        #expect(ServiceDay.formatServiceDate("2026-07-29") == "Wed 29 Jul")
        #expect(ServiceDay.formatServiceDate("2026-01-01") == "Thu 1 Jan")
    }

    // MARK: - Hazards the JavaScript port cannot have

    /**
     The exact shape our own API sends.

     `depInstant` comes from JavaScript's `toISOString()`, which always writes
     milliseconds. A parser that only accepts whole seconds returns nil for every
     departure the app ever receives — and nil reads as "no time" rather than as an
     error, so nothing complains and a feature silently does nothing.

     That is what happened: the board could not detect a spent service day because the
     instant it compared was always nil. These fixtures are copied from a real response
     so the suite cannot drift from the wire again.
     */
    @Test("the instants our own API sends are parsed, milliseconds and all")
    func apiInstantsWithMillisecondsParse() {
        #expect(utcString(ServiceDay.instant(from: "2026-08-04T21:29:00.000Z"))
                == "2026-08-04T21:29:00Z")
        #expect(ServiceDay.formatLondonTime("2026-08-04T21:29:00.000Z") == "22:29")
        #expect(ServiceDay.londonDate(of: "2026-08-04T21:29:00.000Z") == "2026-08-04")

        // Whole seconds must keep working alongside it.
        #expect(utcString(ServiceDay.instant(from: "2026-08-04T21:29:00Z"))
                == "2026-08-04T21:29:00Z")

        // And the comparison that was silently failing.
        #expect(ServiceDay.minutesBetween(
            "2026-08-04T21:29:00.000Z", "2026-08-04T22:29:00.000Z"
        ) == 60)
    }

    @Test("a bad datetime is nil rather than a wrong time")
    func badInputIsNil() {
        // JavaScript produced NaN here and carried on. Optionals make the failure
        // visible, and nothing downstream can render a garbage departure as a time.
        #expect(ServiceDay.instant(from: "not a time") == nil)
        #expect(ServiceDay.formatLondonTime("") == nil)
        #expect(ServiceDay.londonDate(of: "2026-07-30") == nil)
        #expect(ServiceDay.minutesBetween("nonsense", "2026-07-30T23:12:00") == nil)
        #expect(ServiceDay.formatServiceDate("tomorrow") == nil)
    }

    @Test("an offset is told apart from the hyphens in the date")
    func offsetIsToldApartFromDateHyphens() {
        // `2026-07-30T23:12:00` has three hyphens and no offset. A tail check that
        // does not first find the `T` reads the date's own separators as an offset,
        // and then the string either parses in the wrong zone or fails outright.
        // Asserted through the public surface: what matters is the time on screen,
        // not how the string was categorised.
        #expect(ServiceDay.formatLondonTime("2026-07-30T23:12:00") == "23:12")
        #expect(utcString(ServiceDay.instant(from: "2026-07-30T23:12:00")) == "2026-07-30T22:12:00Z")

        // Where an offset really is present it wins over London. All three of these
        // are the same instant, and it is 00:12 the next morning in London.
        #expect(ServiceDay.formatLondonTime("2026-07-30T23:12:00Z") == "00:12")
        #expect(ServiceDay.formatLondonTime("2026-07-31T00:12:00+01:00") == "00:12")
        #expect(ServiceDay.formatLondonTime("2026-07-30T18:12:00-05:00") == "00:12")
        #expect(ServiceDay.londonDate(of: "2026-07-30T23:12:00Z") == "2026-07-31")
    }
}

/// Counting days apart, for the masthead's step-forward limit.
@Suite("ServiceDay — daysBetween")
struct DaysBetweenTests {

    @Test("counts forward, backward and zero")
    func countsBothWays() {
        #expect(ServiceDay.daysBetween("2026-08-07", "2026-08-08") == 1)
        #expect(ServiceDay.daysBetween("2026-08-07", "2026-08-14") == 7)
        #expect(ServiceDay.daysBetween("2026-08-07", "2026-08-07") == 0)
        #expect(ServiceDay.daysBetween("2026-08-08", "2026-08-07") == -1)
    }

    /**
     The reason this is done in UTC rather than in London.

     25 October 2026 is the night the clocks go back, so that day is 25 hours long in
     London. Counting calendar days across it in a zone that observes the change can
     round to zero; in UTC every day is exactly 24 hours and the answer is one.
     */
    @Test("a clock change does not shorten a day")
    func clockChangeDoesNotCount() {
        #expect(ServiceDay.daysBetween("2026-10-24", "2026-10-25") == 1)
        #expect(ServiceDay.daysBetween("2026-10-25", "2026-10-26") == 1)
        #expect(ServiceDay.daysBetween("2026-03-28", "2026-03-29") == 1)
    }

    @Test("month and year boundaries are ordinary")
    func boundariesAreOrdinary() {
        #expect(ServiceDay.daysBetween("2026-08-31", "2026-09-01") == 1)
        #expect(ServiceDay.daysBetween("2026-12-31", "2027-01-01") == 1)
    }

    @Test("nonsense in, nil out")
    func nonsenseIsNil() {
        #expect(ServiceDay.daysBetween("not-a-date", "2026-08-07") == nil)
    }
}

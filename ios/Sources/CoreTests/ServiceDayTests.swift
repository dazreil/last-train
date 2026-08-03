import Foundation
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

 Run under `TZ=UTC`, for the same reason `npm test` is: so that a regression fails on
 a machine in London too.

 In 2026, BST runs from 29 March to 25 October.
 */
func serviceDayTests(_ t: TestRunner) {

    t.test("the service day does not roll over at midnight") {
        // 23:00 BST on the 29th -- squarely inside the 29th's service day.
        t.expect(ServiceDay.currentServiceDate(now: utcInstant("2026-07-29T22:00:00Z")), "2026-07-29")

        // 00:30 BST on the 30th. The calendar says the 30th; the trains still running
        // are the 29th's. This is the case that decides whether the app is useful or
        // actively misleading at ten past midnight.
        t.expect(ServiceDay.currentServiceDate(now: utcInstant("2026-07-29T23:30:00Z")), "2026-07-29")

        // 02:59 BST -- still the previous service day.
        t.expect(ServiceDay.currentServiceDate(now: utcInstant("2026-07-30T01:59:00Z")), "2026-07-29")

        // 03:00 BST -- the new service day has begun.
        t.expect(ServiceDay.currentServiceDate(now: utcInstant("2026-07-30T02:00:00Z")), "2026-07-30")
    }

    t.test("the service day boundary respects GMT as well as BST") {
        // 00:30 GMT in January: same rule, no offset applied.
        t.expect(ServiceDay.currentServiceDate(now: utcInstant("2026-01-15T00:30:00Z")), "2026-01-14")
        t.expect(ServiceDay.currentServiceDate(now: utcInstant("2026-01-15T03:30:00Z")), "2026-01-15")

        // 23:30 UTC in January is 23:30 London, so still the same day -- whereas the
        // identical UTC instant in July is 00:30 the next morning. A UTC-only
        // implementation gets exactly one of these two wrong.
        t.expect(ServiceDay.currentServiceDate(now: utcInstant("2026-01-15T23:30:00Z")), "2026-01-15")
        t.expect(ServiceDay.currentServiceDate(now: utcInstant("2026-07-15T23:30:00Z")), "2026-07-15")
    }

    t.test("the service day boundary rolls the month and year over") {
        t.expect(ServiceDay.currentServiceDate(now: utcInstant("2027-01-01T01:00:00Z")), "2026-12-31")
        t.expect(ServiceDay.currentServiceDate(now: utcInstant("2026-08-01T01:30:00Z")), "2026-07-31")
    }

    t.test("the query window covers 03:00 to 02:59 the next morning") {
        let window = ServiceDay.serviceDayWindow("2026-07-29")
        t.expect(window?.timeFrom, "2026-07-29T03:00:00")
        t.expect(window?.timeTo, "2026-07-30T02:59:00")
    }

    t.test("the query window never exceeds the documented 23h59m maximum") {
        // Offset-less, so the API reads it as local to the station. Checking the span
        // in London terms is what matters: on the spring-forward night the local day is
        // only 23 hours long, and on the autumn night it is 25 -- the latter is the one
        // that could breach the limit.
        for date in ["2026-03-29", "2026-10-25", "2026-07-29", "2026-01-15"] {
            guard let window = ServiceDay.serviceDayWindow(date) else {
                t.expectTrue(false, "no window for \(date)")
                continue
            }
            // Read as UTC on both ends, which measures the nominal span rather than
            // the elapsed one -- the same thing the JavaScript test asserts.
            let from = utcInstant("\(window.timeFrom)Z")
            let to = utcInstant("\(window.timeTo)Z")
            let minutes = Int(to.timeIntervalSince(from) / 60)
            t.expect(minutes, 23 * 60 + 59, "window for \(date) must be exactly 23h59m")
        }
    }

    t.test("a timezone-less time from the API is read as London, not as the device clock") {
        // This is the exact shape the API returns, and the exact bug: on a device or
        // server not in London these read an hour out unless London is applied.
        t.expect(ServiceDay.formatLondonTime("2026-07-30T23:12:00"), "23:12")
        t.expect(ServiceDay.formatLondonTime("2026-07-30T00:22:00"), "00:22")
        t.expect(ServiceDay.londonDate(of: "2026-07-30T23:12:00"), "2026-07-30")

        // Winter, when London is UTC, so the naive reading happens to agree.
        t.expect(ServiceDay.formatLondonTime("2026-01-15T23:12:00"), "23:12")
        t.expect(ServiceDay.londonDate(of: "2026-01-15T23:12:00"), "2026-01-15")
    }

    t.test("a time that does carry an offset is still honoured") {
        // The spec permits both forms; the query echo comes back with an offset.
        t.expect(ServiceDay.formatLondonTime("2026-07-29T22:52:00Z"), "23:52")
        t.expect(ServiceDay.formatLondonTime("2026-07-29T23:52:00+01:00"), "23:52")
        t.expect(ServiceDay.formatLondonTime("2026-01-15T23:52:00Z"), "23:52")
    }

    t.test("times are formatted in London local time") {
        // The spec's own example: 23:52 -> 00:48.
        t.expect(ServiceDay.formatLondonTime("2026-07-29T22:52:00Z"), "23:52")
        t.expect(ServiceDay.formatLondonTime("2026-07-29T23:48:00Z"), "00:48")

        // Midnight must render as 00:00, never 24:00.
        t.expect(ServiceDay.formatLondonTime("2026-07-29T23:00:00Z"), "00:00")

        // Winter: no offset.
        t.expect(ServiceDay.formatLondonTime("2026-01-15T23:52:00Z"), "23:52")
    }

    t.test("London wall-clock times resolve to the right absolute instant") {
        // 23:12 BST is 22:12 UTC.
        t.expect(utcString(ServiceDay.instant(from: "2026-07-30T23:12:00")), "2026-07-30T22:12:00Z")
        // 23:12 GMT is 23:12 UTC.
        t.expect(utcString(ServiceDay.instant(from: "2026-01-15T23:12:00")), "2026-01-15T23:12:00Z")
        // Either side of the autumn change, when 01:30 happens twice.
        t.expect(utcString(ServiceDay.instant(from: "2026-10-25T00:30:00")), "2026-10-24T23:30:00Z")
        t.expect(utcString(ServiceDay.instant(from: "2026-10-25T03:30:00")), "2026-10-25T03:30:00Z")
    }

    t.test("the last trains of the night keep their real times") {
        // The reported bug, as a whole scenario: real c2c departures from Grays, as the
        // API sends them. Every one of these read an hour late in production.
        let serviceDate = "2026-07-30"
        let departures = ["2026-07-30T23:17:00", "2026-07-30T23:47:00", "2026-07-31T00:18:00"]

        let shown = departures.map { departure in
            (
                at: ServiceDay.formatLondonTime(departure),
                afterMidnight: ServiceDay.londonDate(of: departure) != serviceDate
            )
        }

        t.expect(shown[0].at, "23:17")
        t.expect(shown[0].afterMidnight, false)
        t.expect(shown[1].at, "23:47")
        t.expect(shown[1].afterMidnight, false)
        t.expect(shown[2].at, "00:18")
        t.expect(shown[2].afterMidnight, true)
    }

    t.test("an arrival after midnight is recognised as the next calendar day") {
        let departure = "2026-07-29T22:52:00Z" // 23:52 BST on the 29th
        let arrival = "2026-07-29T23:48:00Z"   // 00:48 BST on the 30th

        t.expect(ServiceDay.londonDate(of: departure), "2026-07-29")
        t.expect(ServiceDay.londonDate(of: arrival), "2026-07-30")
        t.expectNotEqual(ServiceDay.londonDate(of: departure), ServiceDay.londonDate(of: arrival))
    }

    t.test("durations are correct across midnight and across a clock change") {
        // 23:52 -> 00:48 is 56 minutes, as the spec's example says.
        t.expect(ServiceDay.minutesBetween("2026-07-29T22:52:00Z", "2026-07-29T23:48:00Z"), 56)

        // Spring forward: London clocks jump 01:00 -> 02:00, so a train that appears
        // to depart 00:50 and arrive 02:10 really took 20 minutes. Comparing absolute
        // instants gets this right without special-casing.
        t.expect(ServiceDay.minutesBetween("2026-03-29T00:50:00Z", "2026-03-29T01:10:00Z"), 20)

        // Autumn back: 01:00-02:00 happens twice.
        t.expect(ServiceDay.minutesBetween("2026-10-25T00:50:00Z", "2026-10-25T01:30:00Z"), 40)
    }

    t.test("date arithmetic survives month, year and DST boundaries") {
        t.expect(ServiceDay.addDays("2026-12-31", 1), "2027-01-01")
        t.expect(ServiceDay.addDays("2026-01-01", -1), "2025-12-31")
        t.expect(ServiceDay.addDays("2026-02-28", 1), "2026-03-01") // 2026 is not a leap year
        t.expect(ServiceDay.addDays("2028-02-28", 1), "2028-02-29") // 2028 is
        t.expect(ServiceDay.addDays("2026-03-28", 1), "2026-03-29") // clocks go forward
        t.expect(ServiceDay.addDays("2026-10-24", 1), "2026-10-25") // clocks go back
        t.expect(ServiceDay.addDays("2026-07-29", 0), "2026-07-29")
    }

    t.test("dates are validated") {
        t.expectTrue(ServiceDay.isValidIsoDate("2026-07-29"))
        t.expectTrue(!ServiceDay.isValidIsoDate("29-07-2026"))
        t.expectTrue(!ServiceDay.isValidIsoDate("2026-7-9"))
        t.expectTrue(!ServiceDay.isValidIsoDate("2026-13-01"))
        t.expectTrue(!ServiceDay.isValidIsoDate(""))
        t.expectTrue(!ServiceDay.isValidIsoDate("tomorrow"))
    }

    t.test("service dates are rendered without drifting a day") {
        // Formatted in UTC precisely so no offset can shift them.
        t.expect(ServiceDay.formatServiceDate("2026-07-29"), "Wed 29 Jul")
        t.expect(ServiceDay.formatServiceDate("2026-01-01"), "Thu 1 Jan")
    }

    // MARK: - Swift-specific hazards the JavaScript port cannot have

    t.test("a bad datetime is nil rather than a wrong time") {
        // JavaScript produced NaN here and carried on. Optionals make the failure
        // visible, and nothing downstream can render a garbage departure as a time.
        t.expect(ServiceDay.instant(from: "not a time"), nil)
        t.expect(ServiceDay.formatLondonTime(""), nil)
        t.expect(ServiceDay.londonDate(of: "2026-07-30"), nil)
        t.expect(ServiceDay.minutesBetween("nonsense", "2026-07-30T23:12:00"), nil)
        t.expect(ServiceDay.formatServiceDate("tomorrow"), nil)
    }

    t.test("an offset is told apart from the hyphens in the date") {
        // `2026-07-30T23:12:00` has three hyphens and no offset. A tail check that
        // does not first find the `T` reads the date's own separators as an offset,
        // and then the string either parses in the wrong zone or fails outright.
        // Asserted through the public surface rather than by reaching inside: what
        // matters is the time on screen, not how the string was categorised.
        t.expect(ServiceDay.formatLondonTime("2026-07-30T23:12:00"), "23:12")
        t.expect(utcString(ServiceDay.instant(from: "2026-07-30T23:12:00")), "2026-07-30T22:12:00Z")

        // Where an offset really is present it wins over London. All three of these
        // are the same instant, and it is 00:12 the next morning in London.
        t.expect(ServiceDay.formatLondonTime("2026-07-30T23:12:00Z"), "00:12")
        t.expect(ServiceDay.formatLondonTime("2026-07-31T00:12:00+01:00"), "00:12")
        t.expect(ServiceDay.formatLondonTime("2026-07-30T18:12:00-05:00"), "00:12")
        t.expect(ServiceDay.londonDate(of: "2026-07-30T23:12:00Z"), "2026-07-31")
    }
}

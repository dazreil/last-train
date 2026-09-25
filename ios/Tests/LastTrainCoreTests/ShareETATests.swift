import Testing

import LastTrainCore

/// The text sent to a friend: plain, true, and right across midnight.
@Suite("ShareETA")
struct ShareETATests {

    @Test("on time, with where you get off")
    func onTime() {
        let text = ShareETA.message(
            departure: "23:52", scheduledDeparture: "23:52",
            from: "Fenchurch Street", towards: "Shoeburyness",
            arrival: .init(station: "Upminster", scheduled: "00:31")
        )
        #expect(text == "I'm getting the 23:52 from Fenchurch Street to Shoeburyness. It gets to Upminster at 00:31.")
    }

    @Test("running late moves the arrival, and says about")
    func late() {
        let text = ShareETA.message(
            departure: "23:56", scheduledDeparture: "23:52",
            from: "Fenchurch Street", towards: "Shoeburyness",
            arrival: .init(station: "Upminster", scheduled: "00:31")
        )
        #expect(text == "I'm getting the 23:56 from Fenchurch Street to Shoeburyness. It's running 4 min late. It should get to Upminster at about 00:35.")
    }

    @Test("with no destination chosen, just the train")
    func noArrival() {
        let text = ShareETA.message(
            departure: "21:14", scheduledDeparture: nil,
            from: "Upminster", towards: "Shoeburyness", arrival: nil
        )
        #expect(text == "I'm getting the 21:14 from Upminster to Shoeburyness.")
    }

    @Test("late across midnight is late, not a day early")
    func acrossMidnight() {
        #expect(ShareETA.minutesLate(scheduled: "23:58", live: "00:03") == 5)
        #expect(ShareETA.minutesLate(scheduled: "00:10", live: "00:10") == 0)
        #expect(ShareETA.minutesLate(scheduled: "08:00", live: "14:00") == nil)
        #expect(ShareETA.addMinutes(7, to: "23:58") == "00:05")
    }

    @Test("times follow the phone's clock setting")
    func twelveHour() {
        let text = ShareETA.message(
            departure: "21:14", scheduledDeparture: "21:14",
            from: "Upminster", towards: "Shoeburyness",
            arrival: .init(station: "Southend Central", scheduled: "21:45"),
            clock: { $0 == "21:14" ? "9:14 PM" : "9:45 PM" }
        )
        #expect(text.contains("the 9:14 PM from") && text.hasSuffix("at 9:45 PM."))
    }
}

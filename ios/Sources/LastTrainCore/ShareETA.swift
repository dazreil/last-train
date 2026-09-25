import Foundation

/**
 The text a person sends to say which train they are on and when it gets in.

 Sent through the share sheet, so the person chooses who gets it and taps Send themselves;
 the app never sends anything. Plain words, written to be read by someone who does not
 have the app and does not know the station codes.

 **Late running moves the arrival.** The calling pattern carries timetabled times, and the
 board carries the live departure. When the two disagree the train is running late, and
 the arrival is moved by the same minutes and said as "about": a delay usually carries
 through the journey, but not always to the minute.

 Pure, so the wording is tested without a device.
 */
public enum ShareETA {

    public struct Arrival: Equatable, Sendable {
        /// Where the person gets off.
        public let station: String
        /// Timetabled arrival there, `HH:mm`.
        public let scheduled: String

        public init(station: String, scheduled: String) {
            self.station = station
            self.scheduled = scheduled
        }
    }

    /**
     - Parameters:
       - departure: the live departure, `HH:mm`.
       - scheduledDeparture: the timetabled departure, `HH:mm`, when known.
       - from: the station the train is boarded at.
       - towards: where the train itself is going.
       - arrival: where the person gets off, when they have said.
       - clock: how a time is written, so the text follows the phone's 12 or 24-hour setting.
     */
    public static func message(
        departure: String,
        scheduledDeparture: String?,
        from: String,
        towards: String,
        arrival: Arrival?,
        clock: (String) -> String = { $0 }
    ) -> String {
        let late = scheduledDeparture.flatMap { minutesLate(scheduled: $0, live: departure) } ?? 0
        var text = "I'm getting the \(clock(departure)) from \(from) to \(towards)."
        if late > 0 {
            text += " It's running \(late) min late."
        }
        if let arrival {
            if late > 0 {
                text += " It should get to \(arrival.station) at about \(clock(addMinutes(late, to: arrival.scheduled)))."
            } else {
                text += " It gets to \(arrival.station) at \(clock(arrival.scheduled))."
            }
        }
        return text
    }

    /**
     How many minutes later `live` is than `scheduled`, on one night.

     The two are wall-clock `HH:mm` with no date, so a train due at 23:58 and leaving at
     00:03 is five minutes late, not a day early. Nil for anything unreadable, and for a
     difference of more than three hours either way, which is a different train rather
     than a late one.
     */
    public static func minutesLate(scheduled: String, live: String) -> Int? {
        guard let a = minuteOfDay(scheduled), let b = minuteOfDay(live) else { return nil }
        var difference = (b - a) % 1440
        if difference > 720 { difference -= 1440 }
        if difference < -720 { difference += 1440 }
        return abs(difference) <= 180 ? difference : nil
    }

    /// `HH:mm` plus minutes, round the clock.
    public static func addMinutes(_ minutes: Int, to time: String) -> String {
        guard let start = minuteOfDay(time) else { return time }
        let total = ((start + minutes) % 1440 + 1440) % 1440
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private static func minuteOfDay(_ time: String) -> Int? {
        let parts = time.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }
}

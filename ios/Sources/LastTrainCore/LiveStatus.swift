import Foundation

/**
 The short line that says whether a train is running to time: "On time", "4 min late",
 "Cancelled" — or nothing.

 **Nothing when there is no live time.** A train more than two hours out has only its
 timetable, and "On time" would be a claim no source made. The widget and the Live
 Activity show this same line, so it is decided once, here.

 Pure, so it is tested without a device.
 */
public enum LiveStatus {
    public static func text(hasLiveTime: Bool, minutesLate: Int?, cancelled: Bool, delayed: Bool = false) -> String? {
        if cancelled { return "Cancelled" }
        if let late = minutesLate, late > 0 { return "\(late) min late" }
        // Late with no estimate yet. Said, because it is the most useful thing known.
        if delayed { return "Delayed" }
        return hasLiveTime ? "On time" : nil
    }

    /**
     A Last Train row. The server marks a row the live board has matched (`isLive`),
     because it sends an expected time only when it differs from the timetable — without
     the mark an on-time train and one nobody checked look the same.
     */
    public static func of(_ service: BoardDeparture) -> String? {
        text(
            hasLiveTime: (service.isLive ?? false) || service.expectedDep != nil,
            minutesLate: service.minutesLate,
            cancelled: service.cancelled,
            delayed: service.delayed
        )
    }

    public static func of(_ service: FastService) -> String? {
        text(
            hasLiveTime: service.isLive || service.expectedDeparture != nil,
            minutesLate: service.minutesLate,
            cancelled: false,
            delayed: service.isDelayed
        )
    }
}

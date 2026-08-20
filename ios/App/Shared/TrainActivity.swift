import ActivityKit
import Foundation

import LastTrainCore

/**
 The train you are running for, on the Dynamic Island and the lock screen.

 **It needs no updates, and that is the whole reason it is affordable.** `Text(timerInterval:)`
 counts down on the device, so the activity is started once with a departure time and runs
 itself to zero — no push server, no background refresh, no upstream requests, nothing
 against the RTT quota. It is the same insight the widget is built on: one lookup buys the
 whole evening.

 What it cannot do is notice that the train was cancelled after you pinned it. The board
 excludes cancelled departures when it is fetched, so the risk is a train withdrawn in the
 minutes after — a countdown to a train that is not coming. `staleDate` is set to the
 departure so the system dims it rather than presenting it as current, and the app refreshes
 the activity whenever it is opened. That is a mitigation and not a fix, and it is the price
 of never asking the network again.
 */
struct TrainActivity: ActivityAttributes {
    /// Everything that could change if we ever did update it.
    struct ContentState: Codable, Hashable {
        /// When it leaves, as an instant. The countdown is derived from this on device.
        let departure: Date
        let platform: String?
    }

    let stationName: String
    let destination: String
    /// `00:54`, London wall-clock, formatted by the server. Never re-derived here — the
    /// timezone rule lives in one place and this is not it.
    let departureText: String
    let direction: String
    /// Red is the last train and nothing else, including here.
    let isLastTrain: Bool
}

/**
 Starting and stopping it.

 Scoped deliberately: one train at a time, because "which train am I running for" has one
 answer. Pinning another replaces it rather than stacking a second countdown.

 **Not on the main actor**, and that is a requirement rather than a preference. An
 `Activity` is not `Sendable`, so reading the running ones on the main actor and then
 awaiting `end` on them sends a non-Sendable value across an isolation boundary — which
 under this project's `SWIFT_STRICT_CONCURRENCY: complete` is an error, not a warning.
 Fetching and ending them in the same non-isolated context never crosses a boundary at all.
 */
enum TrainActivityController {

    /**
     How far ahead a train is worth counting down to.

     Live Activities are cut off by the system after about eight hours, and a countdown to
     a train at dawn is useless long before that. Four hours covers an evening out, which
     is the scene this app exists for.
     */
    static let horizon: TimeInterval = 4 * 60 * 60

    static var isAvailable: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    static func start(
        service: BoardDeparture,
        stationName: String,
        direction: Compass,
        isLastTrain: Bool
    ) {
        guard isAvailable, let departure = service.instant else { return }
        // Past, or too far off to be a countdown anyone would watch.
        let wait = departure.timeIntervalSinceNow
        guard wait > 0, wait <= horizon else { return }

        let attributes = TrainActivity(
            stationName: stationName,
            destination: service.destination.withoutLondonPrefix,
            departureText: service.dep,
            direction: direction.rawValue,
            isLastTrain: isLastTrain
        )
        let state = TrainActivity.ContentState(
            departure: departure,
            platform: service.platform
        )

        /*
         Ending the old one and starting the new one, in that order, in one task.

         These were an unordered `Task { await stop() }` followed by the request, which is
         a race and lost it: the stop landed *after* the new activity existed and ended the
         countdown that had just been started. It looked exactly like the pin doing nothing,
         and only on the second pin — the first had nothing to stop.
        */
        Task {
            await stop()
            _ = try? Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: departure),
                pushType: nil
            )
        }
    }

    /// Ends whatever is running. Immediate rather than lingering: the train has gone, or
    /// you have said it is not yours.
    static func stop() async {
        for activity in Activity<TrainActivity>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /**
     Clear anything whose train has left.

     Called when the app comes back, because an activity outlives the process that started
     it and the system will happily keep showing a countdown that reached zero while nobody
     was looking.
     */
    static func tidy() async {
        for activity in Activity<TrainActivity>.activities
        where activity.content.state.departure <= .now {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}

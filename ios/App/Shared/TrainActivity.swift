import ActivityKit
import Foundation
import OSLog

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
    /// Identifies the selected row when the app is opened again. Optional so an activity
    /// created by a build before Fast Train selection was added still decodes safely.
    let serviceId: String?
}

enum TrainActivityStartResult: Sendable {
    case started
    case activitiesDisabled
    case invalidDeparture
    case departed
    case tooFar
    case failed
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

    private static let logger = Logger(
        subsystem: "com.dazreil.lasttrain",
        category: "LiveActivity"
    )

    /**
     How far ahead a train is worth counting down to.

     Live Activities are cut off by the system after about eight hours, and a countdown to
     a train at dawn is useless long before that. Four hours covers an evening out, which
     is the scene this app exists for.
     */
    static let horizon = CountdownWindow.duration

    static var isAvailable: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// A value type crosses the caller's actor boundary; the non-Sendable `Activity`
    /// itself remains inside this synchronous read.
    static var activeServiceId: String? {
        Activity<TrainActivity>.activities.first?.attributes.serviceId
    }

    static func start(
        service: BoardDeparture,
        stationName: String,
        direction: Compass,
        isLastTrain: Bool
    ) async -> TrainActivityStartResult {
        guard let departure = service.instant else { return .invalidDeparture }
        return await request(
            serviceId: service.serviceId,
            departure: departure,
            departureText: service.dep,
            platform: service.platform,
            stationName: stationName,
            destination: service.destination.withoutLondonPrefix,
            direction: direction,
            isLastTrain: isLastTrain
        )
    }

    /**
     Start the same countdown from a Fast Train result.

     The destination is the place the passenger chose, not the train's final destination:
     Fast Train may recommend a Shoeburyness service for a journey to Southend Central, and
     the Island should name the journey being made rather than the end of the rolling stock's.
     */
    static func start(
        service: FastService,
        stationName: String,
        destinationName: String,
        direction: Compass
    ) async -> TrainActivityStartResult {
        await request(
            serviceId: service.serviceId,
            departure: service.departsAt,
            departureText: service.departure,
            platform: nil,
            stationName: stationName,
            destination: destinationName,
            direction: direction,
            isLastTrain: false
        )
    }

    private static func request(
        serviceId: String,
        departure: Date,
        departureText: String,
        platform: String?,
        stationName: String,
        destination: String,
        direction: Compass,
        isLastTrain: Bool
    ) async -> TrainActivityStartResult {
        guard isAvailable else { return .activitiesDisabled }

        switch CountdownWindow.eligibility(departure: departure) {
        case .departed: return .departed
        case .tooFar: return .tooFar
        case .eligible: break
        }

        let attributes = TrainActivity(
            stationName: stationName,
            destination: destination,
            departureText: departureText,
            direction: direction.rawValue,
            isLastTrain: isLastTrain,
            serviceId: serviceId
        )
        let state = TrainActivity.ContentState(
            departure: departure,
            platform: platform
        )

        // Ordered in one async operation. The old implementation launched stop and request
        // in separate tasks, so the stop could arrive last and kill the new countdown.
        await stop()
        do {
            _ = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: departure),
                pushType: nil
            )
            return .started
        } catch {
            logger.error("Could not start Live Activity: \(error.localizedDescription, privacy: .public)")
            return .failed
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

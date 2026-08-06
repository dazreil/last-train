import CoreLocation
import Foundation

import LastTrainCore

/**
 One location fix, for the nearest-station button.

 `IOS.md` §7 lists Core Location as one of the three things that justify going native —
 "without a permission prompt every session", which is the browser behaviour the web app
 is stuck with. This is the whole of it: ask once, take the first fix, stop.

 Uses `CLLocationUpdate.liveUpdates`, the iOS 17 async sequence, rather than a delegate.
 A `CLLocationManagerDelegate` would have to bridge callbacks onto the main actor by
 hand, and under Swift 6 strict concurrency that is where the awkwardness lives. This
 reads as what it is: await a fix, return it, and let the loop's exit cancel the stream.

 The app never watches the user's position. A departure board is read standing still,
 and continuous updates would be a battery cost and a privacy claim in exchange for
 nothing.
 */
@MainActor
enum LocationFinder {

    enum Failure: Error, LocalizedError, Equatable {
        case denied
        case unavailable
        case timedOut

        var errorDescription: String? {
            switch self {
            // Names the fix rather than the fault. The button is still there, and a
            // station can always be typed instead.
            case .denied: "Location is off for Last Train. Turn it on in Settings, or type a station."
            case .unavailable: "Could not get your location."
            case .timedOut: "Could not get your location in time."
            }
        }
    }

    /**
     How long to wait for a fix before giving up.

     Deliberately far longer than the web app's eight seconds, because iOS cannot
     reliably tell us when the permission dialog is on screen. `authorizationStatus` is
     the only signal available before iOS 18, and it can report the *previous* answer for
     a while after the real grant is cleared — observed directly: a prompt visible on
     screen with the manager still claiming `authorizedWhenInUse`. Waiting on it is
     therefore a best effort, not a guarantee.

     So the budget has to survive a human reading a dialog. Thirty seconds cannot be
     tripped by someone answering a prompt, still ends a spinner that would otherwise
     never stop indoors, and costs nothing in the ordinary case where the fix arrives in
     under a second.
     */
    private static let patience: Duration = .seconds(30)

    /**
     Kept alive between presses so the authorisation status can be read.

     `CLLocationUpdate`'s own `authorizationDenied` flag is iOS 18, and the deployment
     target is 17 — raising the floor for one boolean would cost more users than the
     tidier code is worth. The manager reports the same thing on 17.
     */
    private static let manager = CLLocationManager()

    static func currentPosition() async throws -> Coordinate {
        if isDenied { throw Failure.denied }

        // Ours rather than the one `liveUpdates` would raise on its own, so it appears
        // the moment the button is pressed rather than several seconds later.
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }

        do {
            return try await withThrowingTaskGroup(of: Coordinate.self) { group in
                group.addTask { try await firstFix() }
                group.addTask {
                    // The wait lives *inside* the timing task on purpose. Checking the
                    // status once before starting the clock was the obvious shape and it
                    // was flaky: straight after a `simctl privacy reset` the manager
                    // still reported the old authorisation for a moment, the check was
                    // skipped, and eight seconds expired under a prompt nobody had
                    // answered yet -- "could not get your location in time", on the very
                    // first press. Re-reading here cannot be fooled by one stale value.
                    await awaitAuthorizationDecision()
                    try await Task.sleep(for: patience)
                    throw Failure.timedOut
                }

                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw Failure.unavailable }
                return result
            }
        } catch {
            // A denial at the prompt looks exactly like a fix that never arrives, so
            // the status is re-read before blaming the sky. Without this, tapping No
            // reports "could not get your location in time", which is true and useless.
            if isDenied { throw Failure.denied }
            throw error
        }
    }

    private static var isDenied: Bool {
        manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted
    }

    /**
     Wait for the permission dialog to be answered.

     Polled rather than observed. The delegate callback would mean a
     `CLLocationManagerDelegate` class bridging onto the main actor by hand, which is
     the whole cost this file avoids, and the wait happens once in the app's lifetime.

     No error on giving up: a prompt left unanswered for two minutes has been
     abandoned, and the fix attempt below will fail on its own terms and say so.
     */
    private static func awaitAuthorizationDecision() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))

        while manager.authorizationStatus == .notDetermined {
            // `try?` on the sleep would spin at full speed once cancelled, so the
            // cancellation check is the loop's real exit rather than a courtesy.
            if Task.isCancelled || ContinuousClock.now >= deadline { return }
            try? await Task.sleep(for: .milliseconds(120))
        }
    }

    /**
     The first fix, restarting the stream until one arrives.

     The retry is the load-bearing part. A `liveUpdates` sequence started before the
     permission dialog has been answered simply *ends* — no location, no error — and it
     does not resume when the answer arrives. So the obvious single pass left the first
     press after granting doing nothing at all: no station, no message, and a button that
     appeared to have been ignored. The second press worked, which is the worst kind of
     bug, because it teaches the user the button is unreliable rather than that they
     mis-tapped.

     Restarting costs nothing once permission exists, since the fix then arrives on the
     first update. The caller's timeout is what bounds this; there is no attempt count
     here, because the thing being waited on is a human answering a dialog and counting
     attempts would just be guessing at how fast they read.
     */
    private static func firstFix() async throws -> Coordinate {
        while true {
            for try await update in CLLocationUpdate.liveUpdates() {
                if let location = update.location {
                    return Coordinate(
                        lat: location.coordinate.latitude,
                        lon: location.coordinate.longitude
                    )
                }
            }

            // Ended without a fix. If that is a refusal, say so now rather than making
            // the caller's timeout do it in half a minute.
            if isDenied { throw Failure.denied }
            try await Task.sleep(for: .milliseconds(400))
        }
    }
}

extension Nearby where T == Station {
    /// `450 m` up close, `2.3 km` further out. Never more precision than a phone has.
    var distanceLabel: String {
        distanceMetres < 1000
            ? "\(Int(distanceMetres.rounded())) m"
            : String(format: "%.1f km", distanceMetres / 1000)
    }
}

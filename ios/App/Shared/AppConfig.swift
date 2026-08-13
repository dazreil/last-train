import Foundation

import LastTrainCore

/// Where the API lives. Set per build configuration in `project.yml`, for both targets.
enum AppConfig {
    static let apiBaseURL: URL = {
        guard
            let raw = Bundle.main.object(forInfoDictionaryKey: "BoardAPIBaseURL") as? String,
            let url = URL(string: raw)
        else {
            // `Bundle.main` is the widget's own bundle inside the extension, so this
            // fires if the key is set on one target and not the other.
            preconditionFailure("BoardAPIBaseURL missing or malformed in Info.plist")
        }
        return url
    }()

    /// The scheme the widget uses to open the app on what it is showing.
    static let urlScheme = "lasttrain"
}

/**
 The station and direction, shared between the app and the widget.

 An App Group rather than `UserDefaults.standard`, because an extension gets its own
 defaults domain and would otherwise see nothing the app has ever stored.

 What it is *for* is narrower than it looks. The widget is configured on its own — you
 long-press it and choose — precisely so that opening the app to check a different
 station does not silently rewrite what is on your lock screen. This exists so a
 freshly-added widget has a sensible answer before it has been configured at all: it
 starts on whatever you were last looking at, and stops tracking the app the moment you
 tell it otherwise.
 */
enum SharedSelection {
    /// Must match the `com.apple.security.application-groups` entitlement on both targets.
    static let appGroup = "group.com.dazreil.lasttrain"

    private enum Key {
        static let crs = "lastTrain.station"
        static let direction = "lastTrain.direction"
        static let pinHeadcode = "lastTrain.pin.headcode"
        static let pinScope = "lastTrain.pin.scope"
        static let widgetFailures = "lastTrain.widget.failures"
        /// Scope (`CRS:direction`) to destination CRS, one entry per pair.
        static let destinations = "lastTrain.fast.destinations"
        /// The single slot the map replaced. Read once, then carried over and cleared.
        static let destination = "lastTrain.fast.destination"
        static let destinationScope = "lastTrain.fast.scope"
    }

    /**
     A pin belongs to one station and one direction, never to the app.

     `2D88` is a headcode, and headcodes are only unique within a route — pinning the
     00:33 out of Upminster must not silently become the answer at Barking. Storing the
     scope alongside means a pin simply does not apply anywhere else, rather than
     applying wrongly.
     */
    private static func scope(_ crs: String, _ direction: Compass) -> String {
        "\(crs):\(direction.rawValue)"
    }

    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }

    static var station: Station? {
        // Falls back to the app's own domain, where builds before the widget existed
        // wrote it. One read of a key that will not be there for much longer.
        let crs = defaults.string(forKey: Key.crs)
            ?? UserDefaults.standard.string(forKey: Key.crs)
        return crs.flatMap(Stations.find)
    }

    static var direction: Compass {
        let raw = defaults.string(forKey: Key.direction)
            ?? UserDefaults.standard.string(forKey: Key.direction)
        return raw.flatMap(Compass.init(rawValue:)) ?? .west
    }

    static func store(station: Station?, direction: Compass) {
        defaults.set(station?.crs, forKey: Key.crs)
        defaults.set(direction.rawValue, forKey: Key.direction)
    }

    /**
     The headcode pinned for this board, if any.

     Keyed on the headcode rather than the service id: `serviceId` carries its date, so a
     pin made tonight would mean nothing tomorrow, while `2D88` is the same train every
     day it runs.
     */
    static func pinnedHeadcode(for crs: String, direction: Compass) -> String? {
        guard defaults.string(forKey: Key.pinScope) == scope(crs, direction) else { return nil }
        let headcode = defaults.string(forKey: Key.pinHeadcode)
        return (headcode?.isEmpty ?? true) ? nil : headcode
    }

    /**
     Where you are heading in Fast Train, scoped to a station and direction.

     Remembered for the same reason the station and the direction are: the common case is
     the journey you made yesterday. Remembering it is what keeps the mode to no taps at
     all once it is set up, so nothing is asked at the moment it matters.
     */
    static func destination(for crs: String, direction: Compass) -> Station? {
        destinationsByScope()[scope(crs, direction)].flatMap(Stations.find)
    }

    static func setDestination(_ station: Station?, crs: String, direction: Compass) {
        var map = destinationsByScope()
        map[scope(crs, direction)] = station?.crs
        defaults.set(map, forKey: Key.destinations)
        // Carried into the map by the read above, so the slot it came from must go —
        // otherwise clearing a destination that originated there would not clear it.
        defaults.removeObject(forKey: Key.destination)
        defaults.removeObject(forKey: Key.destinationScope)
    }

    /**
     Every destination this phone has chosen, by station and direction.

     **One slot was not enough, and the failure was quiet.** It held a single destination
     plus the scope it belonged to, so choosing where to go east from a station silently
     forgot where you went west from it — the read simply returned nothing on a scope
     mismatch, and the field went back to "Choose a destination" as though it had never
     been set. Pinning is genuinely one-at-a-time; a destination is not, and copying that
     design across was the mistake.

     Small by construction: one short string per station and direction you have actually
     used, written only when you choose.
     */
    private static func destinationsByScope() -> [String: String] {
        var map = defaults.dictionary(forKey: Key.destinations) as? [String: String] ?? [:]
        // One-time carry-over from the single slot, so upgrading does not forget where
        // you were last going.
        if let legacyScope = defaults.string(forKey: Key.destinationScope),
           let legacyCrs = defaults.string(forKey: Key.destination),
           map[legacyScope] == nil {
            map[legacyScope] = legacyCrs
        }
        return map
    }

    /**
     Consecutive failed widget lookups, for the reload backoff.

     Persisted because a timeline provider is a fresh process every time — it has no
     memory of the last attempt, so without this every failure would look like the first
     and the wait would never grow.
     */
    static var widgetFailures: Int {
        defaults.integer(forKey: Key.widgetFailures)
    }

    static func recordWidgetFailure() {
        defaults.set(widgetFailures + 1, forKey: Key.widgetFailures)
    }

    static func clearWidgetFailures() {
        defaults.removeObject(forKey: Key.widgetFailures)
    }

    /// Pass `nil` to unpin. Only one train is pinned at a time, deliberately: a widget
    /// showing a choice between two trains is not a glance.
    static func setPin(_ headcode: String?, crs: String, direction: Compass) {
        guard let headcode, !headcode.isEmpty else {
            defaults.removeObject(forKey: Key.pinHeadcode)
            defaults.removeObject(forKey: Key.pinScope)
            return
        }
        defaults.set(headcode, forKey: Key.pinHeadcode)
        defaults.set(scope(crs, direction), forKey: Key.pinScope)
    }
}

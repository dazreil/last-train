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
}

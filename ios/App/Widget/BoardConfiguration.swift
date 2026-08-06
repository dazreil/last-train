import AppIntents

import LastTrainCore

/**
 What the widget is set to: a station and a direction, chosen on the widget itself.

 **It follows the app until you tell it not to.** Leave a field blank and it tracks
 whatever the app is showing, so a freshly-added widget is immediately right without
 being configured at all. Choose a station or a direction and that choice wins from then
 on — which is what a lock screen widget needs, because it is set once and trusted for
 months, and a Tuesday spent checking a friend's line should not silently replace your
 own last train home.

 Both halves matter, and the difference between them is exactly whether the parameter is
 nil. Nothing here caches: `resolved` re-reads `SharedSelection` on every render, so a
 blank field follows the app *live* rather than remembering where it was when the widget
 was added.
 */
struct BoardConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Last Train"
    static let description = IntentDescription(
        "The last train out of a station, in one direction."
    )

    /// Optional, and deliberately given no default — see `StationQuery.defaultResult`.
    @Parameter(title: "Station")
    var station: StationEntity?

    /// Optional so an unconfigured widget can fall back to the app's direction, which
    /// a non-optional parameter with a fixed default could not do.
    @Parameter(title: "Direction")
    var direction: DirectionChoice?

    /// What to actually show, once the blanks are filled from the app's last selection.
    var resolved: (station: Station, direction: Compass)? {
        guard let target = station.flatMap({ Stations.find($0.id) }) ?? SharedSelection.station
        else { return nil }
        return (target, direction?.compass ?? SharedSelection.direction)
    }
}

/// The four points, as something the widget editor can offer.
enum DirectionChoice: String, AppEnum {
    case north, east, south, west

    var compass: Compass { Compass(rawValue: rawValue) ?? .west }

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Direction")

    static let caseDisplayRepresentations: [DirectionChoice: DisplayRepresentation] = [
        .north: "Northbound",
        .east: "Eastbound",
        .south: "Southbound",
        .west: "Westbound",
    ]
}

/// A station, as something the widget editor can search.
struct StationEntity: AppEntity, Identifiable {
    /// The CRS code, which is already a stable unique identifier — so the widget's
    /// stored configuration survives a regenerated station list.
    let id: String
    let name: String
    let locality: String?

    init(_ station: Station) {
        self.id = station.crs
        self.name = station.name
        self.locality = station.locality
    }

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Station")
    static let defaultQuery = StationQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            // Disambiguates the several Newports and the two Gillinghams, which is the
            // same reason the picker in the app shows it.
            subtitle: locality.map { "\($0)" }
        )
    }
}

/**
 Finding one of 2,619 stations in the widget editor.

 Ranked the same way `StationPicker` ranks: exact code, exact name, prefix, then
 contains. "Birmingham" has to lead with New Street rather than with International, and
 a rule that differed between the app and the widget editor would be a bug in whichever
 one you were not looking at.
 */
struct StationQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [StationEntity] {
        identifiers.compactMap(Stations.find).map(StationEntity.init)
    }

    func entities(matching string: String) async throws -> [StationEntity] {
        let needle = string.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }

        return Stations.all
            .compactMap { station -> (Station, Int)? in
                let name = station.name.lowercased()
                if station.crs.lowercased() == needle { return (station, 0) }
                if name == needle { return (station, 1) }
                if name.hasPrefix(needle) { return (station, 2) }
                if name.contains(needle) { return (station, 3) }
                return nil
            }
            .sorted { left, right in
                left.1 == right.1 ? left.0.name < right.0.name : left.1 < right.1
            }
            .prefix(30)
            .map { StationEntity($0.0) }
    }

    /// Offered before anything is typed: the one you are most likely to want.
    func suggestedEntities() async throws -> [StationEntity] {
        SharedSelection.station.map { [StationEntity($0)] } ?? []
    }

    /**
     Deliberately absent.

     `defaultResult` looks like the right way to start a widget on the station you were
     last looking at, and it is a trap. AppIntents does not treat it as a fallback — it
     *fills the parameter in* and stores the result, so the widget freezes whichever
     station happened to be current when WidgetKit first indexed the extension. Observed:
     a widget stuck on Upminster while the app had been on Manchester Piccadilly for
     some time. Neither followed the app nor reflected a choice anyone made.

     Leaving it unimplemented keeps the parameter nil, and `BoardConfiguration.resolved`
     reads `SharedSelection` fresh on every render instead. So a new widget genuinely
     follows the app, and stops the moment a station is picked here. `suggestedEntities`
     above still puts that station at the top of the list, which is the part of this that
     was actually wanted.
     */
}

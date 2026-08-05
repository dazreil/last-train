import AppIntents

import LastTrainCore

/**
 What the widget is set to: a station and a direction, chosen on the widget itself.

 **Configured, not mirrored.** The obvious cheap build reads whatever the app was last
 looking at, and it is wrong for the surface it is on. A lock screen widget is set once
 and then trusted for months; if it followed the app, checking a friend's line on a
 Tuesday would silently replace your own last train home and you would not find out
 until the night you needed it. So the widget holds its own answer.

 The app is still the default. An unconfigured widget resolves to the station you were
 last looking at (`SharedSelection`), which makes adding one a single gesture, and it
 stops following the moment you choose something.
 */
struct BoardConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Last Train"
    static let description = IntentDescription(
        "The last train out of a station, in one direction."
    )

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

    func defaultResult() async -> StationEntity? {
        SharedSelection.station.map(StationEntity.init)
    }
}

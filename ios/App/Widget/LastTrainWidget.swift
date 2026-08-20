import SwiftUI
import WidgetKit

import LastTrainCore

/**
 The widget, and the reason this app is native at all.

 IOS.md §7: "last train home on the lock screen, updating through the evening, is
 precisely this app's use case and is impossible in a PWA on iOS. If one native feature
 ships, it is that one."
 */
@main
struct LastTrainWidgetBundle: WidgetBundle {
    var body: some Widget {
        LastTrainWidget()
        // The pinned train's countdown. Same extension, different lifetime: the widget is
        // always there and this exists only while a train is worth running for.
        TrainLiveActivity()
    }
}

struct LastTrainWidget: Widget {
    static let kind = "LastTrainBoard"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: Self.kind,
            intent: BoardConfiguration.self,
            provider: BoardProvider()
        ) { entry in
            BoardWidgetView(entry: entry)
        }
        .configurationDisplayName("Last Train")
        .description("The last train out of a station, and the first one back once it has gone.")
        .supportedFamilies([
            // The lock screen, which is the point.
            .accessoryRectangular,
            .accessoryInline,
            // The home screen, where the red block can actually be red.
            .systemSmall,
            .systemMedium,
        ])
    }
}

// MARK: - Previews

#Preview("Lock screen — last train", as: .accessoryRectangular) {
    LastTrainWidget()
} timeline: {
    BoardEntry.preview(.lastTrain)
}

#Preview("Home screen — last train", as: .systemSmall) {
    LastTrainWidget()
} timeline: {
    BoardEntry.preview(.lastTrain)
}

#Preview("Home screen — first back", as: .systemMedium) {
    LastTrainWidget()
} timeline: {
    BoardEntry.preview(.firstBack)
}

extension BoardEntry {
    /// A stand-in board, so the previews do not need the network.
    static func preview(_ label: Glance.Label) -> BoardEntry {
        let now = Date()
        let json = """
        {
          "from": { "crs": "UPM", "name": "Upminster", "locality": null },
          "direction": "east", "date": "2026-08-05", "mode": "normal",
          "firstDate": "2026-08-06",
          "services": [
            \(service("23:51", now.addingTimeInterval(1800), "Pitsea", "last")),
            \(service("00:42", now.addingTimeInterval(9000), "Southend Central", "last")),
            \(service("05:00", now.addingTimeInterval(43200), "Southend Central", "first"))
          ],
          "directions": { "north": 0, "east": 108, "south": 16, "west": 138 },
          "available": ["east"], "unclassified": 0, "totalServices": 108,
          "towards": ["Shoeburyness"], "towardsByDirection": { "east": ["Shoeburyness"] }
        }
        """

        let board = try! JSONDecoder().decode(DepartureBoard.self, from: Data(json.utf8))
        // Wind the clock past the last train to reach the first-back arrangement.
        let clock = label == .firstBack ? now.addingTimeInterval(10800) : now

        return BoardEntry(
            date: now,
            station: Stations.find("UPM"),
            direction: .east,
            glance: Glance.of(board: board, now: clock),
            failure: nil
        )
    }

    private static func service(
        _ dep: String, _ instant: Date, _ destination: String, _ role: String
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return """
        { "dep": "\(dep)", "depInstant": "\(formatter.string(from: instant))",
          "toc": "CC", "tocName": "c2c", "destination": "\(destination)",
          "platform": "2", "isReplacementBus": false, "headcode": "2K85",
          "serviceId": "\(dep)", "role": "\(role)" }
        """
    }
}

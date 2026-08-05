import Foundation
import WidgetKit

import LastTrainCore

/// One rendering of the widget: what was true at `date`.
struct BoardEntry: TimelineEntry {
    let date: Date
    let station: Station?
    let direction: Compass
    /// Nil when nothing is left on the board, which is a real answer rather than a gap.
    let glance: Glance?
    /// Set only when the lookup itself failed.
    let failure: String?

    var link: URL? {
        guard let station else { return nil }
        return URL(
            string: "\(AppConfig.urlScheme)://board?from=\(station.crs)"
                + "&direction=\(direction.rawValue)"
        )
    }
}

/**
 The timeline.

 The whole evening is computed from **one** request. A `normal` board carries the last
 trains and the first one back together, and `Glance` decides which of them is the
 answer at any given moment — so every future entry is derived from data already in
 hand, and WidgetKit is handed a schedule rather than a reason to wake up.

 That is the answer to the worry in IOS.md §10, which expected widget refreshes to drive
 upstream volume. They do not. What costs a request is a *service day running out*, once
 a night per configured widget, onto a server-side cache keyed by station and date.

 Nothing here re-implements a rule. Which arrangement the board is in was decided by
 the server, which departure to lead with is `Glance`, and when to ask again is
 `Glance.reloadDate`. This target is plumbing.
 */
struct BoardProvider: AppIntentTimelineProvider {

    func placeholder(in context: Context) -> BoardEntry {
        BoardEntry(
            date: Date(),
            station: SharedSelection.station,
            direction: SharedSelection.direction,
            glance: nil,
            failure: nil
        )
    }

    func snapshot(for configuration: BoardConfiguration, in context: Context) async -> BoardEntry {
        await entries(for: configuration).first ?? placeholder(in: context)
    }

    func timeline(
        for configuration: BoardConfiguration,
        in context: Context
    ) async -> Timeline<BoardEntry> {
        let entries = await entries(for: configuration)
        guard let last = entries.last else {
            return Timeline(entries: [placeholder(in: context)], policy: .after(soon()))
        }

        // The final entry is the moment the board runs out, which is exactly when a new
        // one is needed. Reloading then rather than on a fixed interval is what keeps
        // this to roughly one request a night.
        return Timeline(entries: entries, policy: .after(last.date))
    }

    // MARK: - Building the entries

    private func entries(for configuration: BoardConfiguration) async -> [BoardEntry] {
        let now = Date()

        guard let (station, direction) = configuration.resolved else {
            // No station chosen and none remembered: the widget says so and asks again
            // in a while, in case the app has been opened since.
            return [BoardEntry(date: now, station: nil, direction: .west, glance: nil, failure: nil)]
        }

        let client = BoardClient(baseURL: AppConfig.apiBaseURL)
        let board: DepartureBoard
        do {
            board = try await client.board(from: station.crs, direction: direction)
        } catch {
            return [
                BoardEntry(
                    date: now,
                    station: station,
                    direction: direction,
                    glance: nil,
                    failure: (error as? BoardClientError)?.errorDescription
                        ?? error.localizedDescription
                )
            ]
        }

        // `now`, then a moment past each departure still to come. Each one is drawn from
        // the same board -- no further requests, and no guessing at a refresh interval.
        let moments = [now] + Glance.changePoints(board: board, now: now)

        return moments.map { moment in
            BoardEntry(
                date: moment,
                station: station,
                direction: direction,
                glance: Glance.of(board: board, now: moment),
                failure: nil
            )
        }
    }

    /// A short wait, for the cases where there was nothing to compute a schedule from.
    private func soon() -> Date { Date().addingTimeInterval(30 * 60) }
}

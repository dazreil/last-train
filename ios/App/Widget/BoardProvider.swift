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
        await plan(for: configuration).entries.first ?? placeholder(in: context)
    }

    func timeline(
        for configuration: BoardConfiguration,
        in context: Context
    ) async -> Timeline<BoardEntry> {
        let plan = await plan(for: configuration)

        // A plan always carries at least one entry, but WidgetKit is handed a placeholder
        // rather than an empty timeline if that ever stops being true -- an empty one is
        // undefined behaviour, and the reload policy is the part that must survive.
        return Timeline(
            entries: plan.entries.isEmpty ? [placeholder(in: context)] : plan.entries,
            policy: .after(plan.reload)
        )
    }

    /**
     Entries, and the one thing that must never be derived from them: when to ask again.

     Taking the reload from the last entry's date was correct for a healthy board — the
     final entry *is* the moment it runs out — and a request loop for every other state.
     A failure, an unconfigured widget and a board with nothing ahead all produce a single
     entry dated now, so `.after(last.date)` asked to reload immediately and kept asking.
     The three states are now answered separately.
     */
    private struct Plan {
        let entries: [BoardEntry]
        let reload: Date
    }

    // MARK: - Building the entries

    private func plan(for configuration: BoardConfiguration) async -> Plan {
        let now = Date()

        guard let (station, direction) = configuration.resolved else {
            // Nothing to look up and nothing that will change on its own. Waiting is the
            // whole behaviour here: only opening the app or editing the widget can help,
            // and both of those reload it directly.
            return Plan(
                entries: [BoardEntry(date: now, station: nil, direction: .west, glance: nil, failure: nil)],
                reload: soon()
            )
        }

        let client = BoardClient(baseURL: AppConfig.apiBaseURL)
        let board: DepartureBoard
        do {
            board = try await client.board(from: station.crs, direction: direction)
        } catch {
            // Counted across processes, because a provider has no memory of the last
            // attempt -- without the count every failure looks like the first and the
            // wait never grows.
            SharedSelection.recordWidgetFailure()

            return Plan(
                entries: [
                    BoardEntry(
                        date: now,
                        station: station,
                        direction: direction,
                        glance: nil,
                        failure: (error as? BoardClientError)?.errorDescription
                            ?? error.localizedDescription
                    )
                ],
                reload: WidgetRetry.nextAttempt(
                    afterConsecutiveFailures: SharedSelection.widgetFailures,
                    from: now
                )
            )
        }

        SharedSelection.clearWidgetFailures()

        // `now`, then a moment past each departure still to come. Each one is drawn from
        // the same board -- no further requests, and no guessing at a refresh interval.
        let moments = [now] + Glance.changePoints(board: board, now: now)

        // Read once, for this board's own station and direction. A pin made elsewhere
        // does not apply here and `pinnedHeadcode` returns nil for it.
        let pinned = SharedSelection.pinnedHeadcode(for: station.crs, direction: direction)

        let entries = moments.map { moment in
            BoardEntry(
                date: moment,
                station: station,
                direction: direction,
                // The handover is free: the pinned train leads while it is still on
                // `remaining`, and the entry timed a second past its departure computes
                // the ordinary answer instead. No extra request, no second timeline.
                glance: Glance.of(board: board, now: moment, pinned: pinned),
                failure: nil
            )
        }

        // `reloadDate` is the moment the board runs out -- and it carries the fallback
        // for a board that never had a future departure in it, which is the third state
        // that used to reload immediately.
        return Plan(entries: entries, reload: Glance.reloadDate(board: board, now: now))
    }

    /// A short wait, for the cases where there was nothing to compute a schedule from.
    private func soon() -> Date { Date().addingTimeInterval(30 * 60) }
}

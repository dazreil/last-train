import Foundation
import SwiftUI

import LastTrainCore

/**
 Fast Train's half of the app's state.

 Kept apart from `BoardModel` because the two answer different questions and share only
 where you are and which way you are heading. `BoardModel` owns those; this owns where you
 are going, what is coming, and which page of it you are on.

 The shape of the mode, decided across §11 and §14:

 1. Pick a station and a direction, exactly as for Last Train.
 2. Pick a destination from the places that direction goes. Never typed.
 3. See the next three, in the order they get you there.

 Step two is what keeps `PRODUCT.md`'s promise. The app still asks nothing open-ended: it
 offers the places direct trains actually reach, so "no direct service" cannot happen.
 */
@MainActor
@Observable
final class FastModel {

    /// Three at a time, agreed 10 August. Four left no room for the destination row.
    static let perPage = 3
    /// Five pages at most, so paging cannot walk the whole timetable.
    static let maximumPages = 5

    /**
     Where you are heading, held here rather than read from storage on every draw.

     `@Observable` can only see stored properties. A view that called through to
     `UserDefaults` on each render created no dependency, so choosing a destination
     stored it correctly and changed nothing on screen. The value lives in the model and
     `adopt` brings it in whenever the station or direction changes.
     */
    private(set) var destination: Station?

    /**
     Whether the picker is open.

     Held here rather than as view state because two things raise it and neither owns the
     other: tapping a direction, which lives in the control above this view, and arriving
     somewhere with nowhere to go, which this model is the first to know. A `@State` flag
     in `FastBoardView` could only be set by one of them.
     */
    var isChoosing = false

    private(set) var destinations: [Destination] = []
    /// True when the server could not check the list against every other direction.
    private(set) var listIsProvisional = false

    private(set) var services: [FastService] = []
    private(set) var truncated = false

    /// True when today is spent and the board is showing the next service day's first
    /// trains instead. The header says so; without that the times read as tonight's.
    private(set) var showsNextServiceDay = false

    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// When the shown services were last fetched, for the "Updated HH:mm" trust stamp.
    private(set) var updatedAt: Date?

    /// The service currently occupying the Dynamic Island, if it is one of ours.
    private(set) var activityServiceId: String?
    /// A recovery message only. A successful selection is already visible on the row and
    /// on the Island, so repeating it in prose would add noise to the board.
    private(set) var activityMessage: String?
    private(set) var activityChanges = 0
    private(set) var isChangingActivity = false

    /// Bumped on every explicit destination choice, including re-choosing the one already
    /// set. The board's reload is keyed on the selection, and a same-destination re-pick
    /// leaves that key unchanged — so without this counter `choose` would empty `services`
    /// and nothing would refill them, stranding the board on "Nothing direct left".
    private(set) var selectionToken = 0

    /// Zero-based. Page zero is always the next three from now.
    private(set) var page = 0

    private let client: BoardClient

    init(client: BoardClient = BoardClient(baseURL: AppConfig.apiBaseURL)) {
        self.client = client
    }

    // MARK: - Where you are going

    /**
     Read the remembered destination for this station and direction, and ask if there is
     none.

     The asking belongs here rather than in the view because the condition is this
     model's to know: a pair that has never been used has nowhere to go, and Fast Train
     cannot answer anything until it does. Somewhere you have been before keeps its
     destination and is left alone.
     */
    func adopt(station: Station, direction: Compass) {
        destination = SharedSelection.destination(for: station.crs, direction: direction)
        syncActivityState()
        activityMessage = nil
    }

    /// Forget where this pair was going. The compass row calls this: choosing a direction
    /// again is choosing a new journey, and the old destination belonged to the old one.
    func clearDestination(at station: Station, direction: Compass) {
        SharedSelection.setDestination(nil, crs: station.crs, direction: direction)
        destination = nil
        page = 0
        services = []
        showsNextServiceDay = false
        activityMessage = nil
        selectionToken += 1
    }

    /// A Live Activity can be dismissed or ended outside this process. Re-read the
    /// system-owned activity whenever the app becomes active and before interpreting a
    /// row tap, so a stale checkmark can never turn a fresh selection into a stop action.
    func syncActivityState() {
        activityServiceId = TrainActivityController.activeServiceId
    }

    /// Ask again, for a direction tap that did not change which direction is showing.
    func askWhereTo() { isChoosing = true }

    func choose(_ chosen: Station?, at station: Station, direction: Compass) {
        SharedSelection.setDestination(chosen, crs: station.crs, direction: direction)
        destination = chosen
        page = 0
        services = []
        showsNextServiceDay = false
        updatedAt = nil
        activityMessage = nil
        // Force the board's reload even when `chosen` is the destination already showing:
        // its `.task(id:)` restarts only when the key changes, and the destination alone
        // does not change on a re-pick. See `selectionToken`.
        selectionToken += 1
    }

    /// The places this direction goes. One request, cached hard by the server.
    func loadDestinations(at station: Station, direction: Compass) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let list = try await client.destinations(from: station.crs, direction: direction)
            destinations = list.destinations
            listIsProvisional = !list.isSettled
        } catch is CancellationError {
            return
        } catch {
            destinations = []
            errorMessage = (error as? BoardClientError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    // MARK: - What is coming

    /**
     Look up the trains.

     **This must not adopt.** It used to, and adopting sets `destination`, which is part
     of the key the caller's `.task(id:)` watches — so the first lookup after opening the
     mode changed that key from underneath itself, SwiftUI cancelled the task it had just
     started, and the cancelled request was reported as *"Could not reach the server. Are
     you online?"*. The request had already reached the server; only the answer was thrown
     away. `FastBoardView` adopts, this reads, and the key settles before the request goes.
     */
    func load(at station: Station, direction: Compass, refresh: Bool = false) async {
        guard let heading = destination else {
            services = []
            updatedAt = nil
            showsNextServiceDay = false
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let board = try await client.fast(from: station.crs, to: heading.crs, refresh: refresh)
            // The server priced them; the order is ours. `FastBoard` is the only place
            // that rule lives, on either platform.
            var ranked = FastBoard.rank(
                FastBoard.upcoming(board.services),
                limit: Self.perPage * Self.maximumPages
            )
            var boardTruncated = board.truncated
            var rolled = false

            /**
             Nothing left today, so answer with tomorrow rather than with nothing.

             Last Train has a day stepper and an explicit first-train section; Fast Train
             has neither, so at the end of a service day it had only "Nothing direct left"
             to offer — true, and useless at half past midnight, which is exactly when this
             mode is opened. The next service day's first trains are the answer to the
             question actually being asked, and the board says so above them.
             */
            if ranked.isEmpty,
               let tomorrow = ServiceDay.addDays(ServiceDay.currentServiceDate(), 1) {
                let next = try await client.fast(
                    from: station.crs,
                    to: heading.crs,
                    date: tomorrow,
                    refresh: refresh
                )
                let first = FastBoard.rank(
                    next.services,
                    limit: Self.perPage * Self.maximumPages
                )
                if !first.isEmpty {
                    ranked = first
                    boardTruncated = next.truncated
                    rolled = true
                }
            }

            services = ranked
            truncated = boardTruncated
            showsNextServiceDay = rolled
            page = 0
            updatedAt = Date()
        } catch is CancellationError {
            // Somewhere else is already asking a better question. Leaving what is on
            // screen alone is the whole point: this is not a failure to report.
            return
        } catch {
            services = []
            updatedAt = nil
            showsNextServiceDay = false
            errorMessage = (error as? BoardClientError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    // MARK: - This is my train

    /**
     Put a Fast Train result on the Dynamic Island, replace the one already there, or
     remove it when the selected row is tapped again.

     Fast Train does not change the lock-screen widget's stored pin. That widget answers
     the last-train question and often does not contain this near-term service at all; the
     Island answers the immediate "which train am I catching" question.
     */
    func toggleActivity(
        _ service: FastService,
        at station: Station,
        direction: Compass
    ) async {
        guard !isChangingActivity, let destination else { return }
        isChangingActivity = true
        activityMessage = nil
        defer { isChangingActivity = false }

        syncActivityState()

        if activityServiceId == service.serviceId {
            await TrainActivityController.stop()
            activityServiceId = nil
            activityChanges += 1
            return
        }

        let result = await TrainActivityController.start(
            service: service,
            stationName: station.name.withoutLondonPrefix,
            destinationName: destination.name.withoutLondonPrefix,
            direction: direction
        )

        switch result {
        case .started:
            activityServiceId = service.serviceId
            activityChanges += 1
        case .tooFar:
            activityMessage = "You can follow this train once it is within four hours."
        case .departed:
            activityMessage = "That train has already departed. Refresh Fast Train for the latest services."
        case .activitiesDisabled:
            activityMessage = "Live Activities are turned off for Last Train in Settings."
        case .invalidDeparture:
            activityMessage = "That departure time could not be read. Refresh Fast Train and try again."
        case .failed:
            activityServiceId = TrainActivityController.activeServiceId
            activityMessage = "That train could not be followed. Try again."
        }
    }

    // MARK: - Paging

    /// However many pages the trains fill, never padded and never more than five.
    /**
     The train held at the top of every page.

     By default the one at the head of the ranking — the first you can be at your
     destination on, which is the question this mode exists to answer. Once you follow a
     train it becomes the hero instead and stays there whatever page you turn to, because
     a train you have chosen to watch is no use to you three pages back.

     Nil only when there are no services at all.
     */
    var hero: FastService? {
        if let activityServiceId,
           let followed = services.first(where: { $0.serviceId == activityServiceId }) {
            return followed
        }
        return services.first
    }

    /**
     The fastest train when a slower one is followed.

     Following a later train makes that train the hero, but the fastest is still the
     answer this mode exists to give, so it keeps its name and sits just below — the way
     the last train does on the other board when something else is pinned above it. Nil
     when nothing is followed, or the train followed is the fastest itself.
     */
    var demotedFastest: FastService? {
        guard let fastest = services.first, fastest.serviceId != hero?.serviceId else { return nil }
        return fastest
    }

    /// Everything neither held at the top nor pinned as the fastest below it. Paged; those
    /// two never are.
    private var rest: [FastService] {
        guard let heroId = hero?.serviceId else { return [] }
        let fastestId = demotedFastest?.serviceId
        return services.filter { $0.serviceId != heroId && $0.serviceId != fastestId }
    }

    /// Paged rows shown at once. One fewer when the fastest is pinned below a followed
    /// train, so the board still totals four: the hero, the fastest, and two more — not
    /// five.
    private var visiblePerPage: Int {
        Self.perPage - (demotedFastest != nil ? 1 : 0)
    }

    var pageCount: Int {
        guard !rest.isEmpty else { return 0 }
        let full = (rest.count + visiblePerPage - 1) / visiblePerPage
        return min(full, Self.maximumPages)
    }

    var shown: [FastService] {
        let start = page * visiblePerPage
        guard start < rest.count else { return [] }
        return Array(rest[start..<min(start + visiblePerPage, rest.count)])
    }

    var canPage: Bool { pageCount > 1 }
    var isOnFirstPage: Bool { page == 0 }

    /// True on the last page, where the next tap comes back to the first. The masthead
    /// reads this to know which glyph to draw before you press it.
    var pageWrapsToNow: Bool { page + 1 >= pageCount }

    /**
     The next three after these, and round to the first page off the end.

     This used to stop dead on the last page, matching a `Now` button that did the going
     back. Both modes now share one rule at that end of the masthead: forward, and round
     to the start. The Last Train date does the same thing with its five days, and a
     control that rounds is one you never press twice to find out it has stopped.
     */
    func advance() {
        guard canPage else { return }
        page = pageWrapsToNow ? 0 : page + 1
    }

    /// Back to the next three from now.
    func now() { page = 0 }
}

/// Which question the app is answering.
enum AppMode: String {
    case last
    case fast

    /// The wordmark. One word swapped, which is the whole of §11's gesture.
    var title: String { self == .last ? "Last Train" : "Fast Train" }

    /// The one you are not reading, named beside the one you are.
    var other: AppMode { self == .last ? .fast : .last }

    /// The header spells both modes out and separates them by light rather than by
    /// length: the live one lit, the other dim beside it.
    var wordmark: String { self == .last ? "LAST TRAIN" : "FAST TRAIN" }
}

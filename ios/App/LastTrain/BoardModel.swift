import Foundation
import SwiftUI

import WidgetKit

import LastTrainCore

/**
 What is on screen, and how it got there.

 The app is opened in a hurry, usually for the same journey as last time — `PRODUCT.md`
 calls the repeat of the last query the common case — so the station and direction are
 remembered and the board starts loading the moment the app comes up. No submit button:
 one fewer tap.
 */
@MainActor
@Observable
final class BoardModel {
    var station: Station? {
        didSet {
            guard station != oldValue else { return }
            resetAutomaticDay()
            persist()
            Task { await load() }
        }
    }

    var direction: Compass {
        didSet {
            guard direction != oldValue else { return }
            resetAutomaticDay()
            persist()
            Task { await load() }
        }
    }

    private(set) var board: DepartureBoard?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    /**
     What is around you, after the nearest-station button.

     Kept rather than discarded once the field is filled, because the nearest station by
     straight line is not always the one you are standing on — at Barking or Stratford
     the platforms of two are within a few hundred metres of each other. The web app
     leaves the alternatives on screen for exactly this reason and so does this.
     */
    private(set) var nearby: [Nearby<Station>] = []
    private(set) var isLocating = false
    private(set) var locateError: String?

    /**
     The service day being asked for, or nil for whichever one is running.

     Normally nil — the server resolves the current service day, which keeps the 03:00
     rule in one place. It is only set when the day on screen turns out to be spent and
     the board moves on to the next one.
     */
    private(set) var requestedDate: String?

    /// Set once per station and direction, so a spent day is stepped over exactly once.
    private var advancedFor: String?

    /**
     True once the date has been stepped by hand rather than by the app.

     Kept apart from `requestedDate`, which is also set when a spent service day is
     stepped over automatically. The difference is only visible in the masthead — a way
     back to today is offered when *you* moved, and not when the board moved itself,
     because in that case today is the day whose trains have all gone.
     */
    private(set) var isBrowsing = false

    /// How far ahead the date can be stepped before the next tap comes back to today.
    /// Five days covers "next Saturday" from a weekday, which is the furthest anyone
    /// plans a last train home, and keeps the walk off dates the timetable does not
    /// cover yet.
    static let maximumDaysAhead = 5

    private let client: BoardClient
    private var inFlight: Task<Void, Never>?

    init(client: BoardClient = BoardClient(baseURL: AppConfig.apiBaseURL)) {
        self.client = client
        self.direction = SharedSelection.direction
        self.station = SharedSelection.station
    }

    /**
     Open on what the widget was showing.

     `lasttrain://board?from=UPM&direction=east`, written by the widget itself, so the
     tap lands on the same board rather than on whatever the app happened to be left on.
     Ignored unless both halves parse — a URL from outside the app is not to be trusted
     into a network request.
     */
    func open(_ url: URL) {
        guard url.scheme == AppConfig.urlScheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let crs = components.queryItems?.first(where: { $0.name == "from" })?.value,
              let target = Stations.find(crs),
              let raw = components.queryItems?.first(where: { $0.name == "direction" })?.value,
              let heading = Compass(rawValue: raw)
        else { return }

        direction = heading
        station = target
    }

    /**
     Availability, cached from the last board.

     Track topology does not change week to week, so the control keeps showing the
     directions it knew about while a new board loads. The alternative is four blocks
     flickering to empty and back on every refresh.
     */
    var available: Set<Compass> {
        Set(board?.available ?? [])
    }

    /// Where each direction goes. Every block names its own destination, not just the
    /// selected one — a direction only means something once you know where it leads.
    var towards: [Compass: String] {
        board?.towardsLabels ?? [:]
    }

    func load(refresh: Bool = false) async {
        guard let station else {
            board = nil
            errorMessage = nil
            return
        }

        inFlight?.cancel()
        let task = Task { [client, direction] in
            isLoading = true
            errorMessage = nil
            do {
                let result = try await client.board(
                    from: station.crs,
                    direction: direction,
                    date: requestedDate,
                    // Only the *automatic* step past a spent day counts as advanced.
                    // `requestedDate` is also set by `stepForward`, and conflating the
                    // two told the server a day you had chosen to look at was the live
                    // one -- so browsing to tomorrow came back in the pre-service
                    // arrangement, first-three-then-last, instead of the last trains you
                    // opened it to see.
                    advanced: requestedDate != nil && !isBrowsing,
                    refresh: refresh
                )
                guard !Task.isCancelled else { return }
                board = result
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                board = nil
                errorMessage = (error as? BoardClientError)?.errorDescription
                    ?? error.localizedDescription
            }
            isLoading = false
        }
        inFlight = task
        await task.value

        await advancePastSpentDay()
    }

    /**
     Step over a service day that has nothing left in it.

     Between the last train and 03:00 the current service day is still today's, but
     every departure on it has been and gone — a board of times that have all passed
     answers nothing. The next service day is the one with trains in it, and asking for
     it puts the board in its pre-service arrangement: the first three trains, with that
     day's last train kept below them.

     This is the half of the behaviour that lives on the client rather than in
     `lib/board.ts`, because only the client knows the board is being read *now* rather
     than being browsed. It happens once per station and direction, so it cannot loop.
     */
    private func advancePastSpentDay() async {
        guard let board, let station else { return }
        guard board.date == ServiceDay.currentServiceDate() else { return }

        let stamp = "\(station.crs):\(direction.rawValue)"
        guard advancedFor != stamp else { return }
        guard Board.isServiceDaySpent(lastDeparture: board.lastTrain?.depInstant) else { return }

        advancedFor = stamp
        requestedDate = ServiceDay.addDays(board.date, 1)
        await load()
    }

    /**
     Fill the station from where you are.

     One fix, the nearest station, and the alternatives kept. Failure is shown next to
     the button rather than as a board error: not knowing where you are says nothing
     about the trains, and the field can always be typed into instead.
     */
    func locate() async {
        isLocating = true
        locateError = nil
        defer { isLocating = false }

        do {
            let position = try await LocationFinder.currentPosition()
            let found = Stations.nearest(
                to: position,
                limit: 4,
                within: Stations.plausibleRadiusMetres
            )

            guard let closest = found.first else {
                // Outside Great Britain, where the honest answer is that this app has
                // nothing to say -- rather than naming the nearest railhead on the
                // island regardless of which continent you are on.
                locateError = "No station near you."
                return
            }

            nearby = found
            // Setting this loads the board, through `station`'s observer.
            station = closest.station
        } catch {
            nearby = []
            locateError = (error as? LocationFinder.Failure)?.errorDescription
                ?? error.localizedDescription
        }
    }

    /**
     The headcode the widget is following on this board, if any.

     Scoped to the station and direction, so a pin made at Upminster southbound does not
     reappear at Barking — headcodes are only unique within a route.
     */
    var pinnedHeadcode: String? {
        guard let station else { return nil }
        return SharedSelection.pinnedHeadcode(for: station.crs, direction: direction)
    }

    func isPinned(_ service: BoardDeparture) -> Bool {
        guard let headcode = service.headcode else { return false }
        return headcode == pinnedHeadcode
    }

    /**
     Counts pin changes, so feedback can fire on the act rather than on the value.

     `pinnedHeadcode` is scoped to a station and direction, so it also changes when you
     move to another station — and a success tap for a pin you did not make is worse than
     none at all.
     */
    private(set) var pinChanges = 0

    /**
     Follow this train, or stop following it. The widget is told either way — and so is the
     Dynamic Island.

     One action, two surfaces, deliberately. "This is my train" is a single thought, and
     splitting it into *show it in the widget* and *count it down on the island* would be a
     settings question wearing a button.

     The countdown declines itself when it makes no sense: a train already gone, or one
     further off than `TrainActivityController.horizon`. Nothing is said about that, because
     the pin still did what it says — the widget is following it either way.
     */
    func setPin(_ service: BoardDeparture, following: Bool) {
        pinChanges += 1
        guard let station else { return }
        SharedSelection.setPin(
            following ? service.headcode : nil,
            crs: station.crs,
            direction: direction
        )
        WidgetCenter.shared.reloadAllTimelines()

        if following {
            TrainActivityController.start(
                service: service,
                stationName: station.name.withoutLondonPrefix,
                direction: direction,
                isLastTrain: service.serviceId == board?.lastTrain?.serviceId
            )
        } else {
            Task { await TrainActivityController.stop() }
        }
    }

    /// Dismiss the alternatives once one has been taken, or the picker used.
    func clearNearby() {
        nearby = []
        locateError = nil
    }

    /// The service day on screen, before the board has loaded as well as after.
    var shownDate: String {
        board?.date ?? requestedDate ?? ServiceDay.currentServiceDate()
    }

    /// How many days ahead of the live service day the board is.
    var daysAhead: Int {
        ServiceDay.daysBetween(ServiceDay.currentServiceDate(), shownDate) ?? 0
    }

    /**
     Which day of the walk is on screen, counted from the live service day.

     **Zero whenever you have not moved it yourself**, which is not the same as
     `daysAhead`. After the last train and before 03:00 the board carries *tomorrow's*
     first train while the service day is still today's — `daysAhead` reads 1 there, and
     counting the walk from it skipped a day: the first tap stepped from what was on
     screen to the day after it, so tomorrow could not be reached at all.
     */
    var dayIndex: Int { isBrowsing ? daysAhead : 0 }

    /// The service day each step of the walk lands on, today being step zero.
    func date(atStep step: Int) -> String? {
        ServiceDay.addDays(ServiceDay.currentServiceDate(), step)
    }

    /// True on the furthest day the board reaches, where the next tap comes back to today
    /// rather than doing nothing.
    var stepWrapsToToday: Bool { dayIndex >= Self.maximumDaysAhead }

    /**
     Step the board on a day, and round to today at the end.

     The step used to stop dead on the last day, which left a control that looked
     pressable and was not. Past the last day it wraps, so the only two ways back to
     today are stepping off the end and the Today button — nothing else moves the date
     you chose.

     The automatic advance in `advancePastSpentDay` cannot fire once this has happened —
     it only runs while the board is showing the live service day — so the two cannot
     fight over the date.
     */
    func stepForward() {
        if stepWrapsToToday {
            returnToToday()
            return
        }
        // From the live service day, not from what is on screen -- see `dayIndex`.
        guard let next = date(atStep: dayIndex + 1) else { return }
        isBrowsing = true
        requestedDate = next
        Task { await load() }
    }

    /// Back to wherever the app would put you if you had just opened it.
    func returnToToday() {
        resetDay()
        Task { await load() }
    }

    private func resetDay() {
        requestedDate = nil
        advancedFor = nil
        isBrowsing = false
    }

    /**
     Drop a day the *app* stepped on to, and keep one you chose.

     Changing station or direction used to reset the date outright, so picking a
     direction while looking at Saturday threw you back to tonight — a day you had asked
     for, discarded by a tap that was about something else.

     A day reached automatically is different, and must still be dropped: whether *this*
     direction's service day is spent is a fresh question, and the answer at Upminster
     going west is not the answer going east. Clearing it lets the server resolve the
     live day again and `advancePastSpentDay` re-decide for the new pair.
     */
    private func resetAutomaticDay() {
        guard !isBrowsing else { return }
        requestedDate = nil
        advancedFor = nil
    }

    private func persist() {
        SharedSelection.store(station: station, direction: direction)
        // Only reaches a widget that has never been configured, which reads this as its
        // default. A configured one keeps its own station and is deliberately untouched.
        WidgetCenter.shared.reloadAllTimelines()
    }
}

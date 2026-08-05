import Foundation
import SwiftUI

import LastTrainCore

/// Where the API lives. Set per build configuration in `project.yml`.
enum AppConfig {
    static let apiBaseURL: URL = {
        guard
            let raw = Bundle.main.object(forInfoDictionaryKey: "BoardAPIBaseURL") as? String,
            let url = URL(string: raw)
        else {
            preconditionFailure("BoardAPIBaseURL missing or malformed in Info.plist")
        }
        return url
    }()
}

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
            resetDay()
            persist()
            Task { await load() }
        }
    }

    var direction: Compass {
        didSet {
            guard direction != oldValue else { return }
            resetDay()
            persist()
            Task { await load() }
        }
    }

    private(set) var board: DepartureBoard?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    /**
     The service day being asked for, or nil for whichever one is running.

     Normally nil — the server resolves the current service day, which keeps the 03:00
     rule in one place. It is only set when the day on screen turns out to be spent and
     the board moves on to the next one.
     */
    private(set) var requestedDate: String?

    /// Set once per station and direction, so a spent day is stepped over exactly once.
    private var advancedFor: String?

    private let client: BoardClient
    private var inFlight: Task<Void, Never>?

    private enum Key {
        static let crs = "lastTrain.station"
        static let direction = "lastTrain.direction"
    }

    init(client: BoardClient = BoardClient(baseURL: AppConfig.apiBaseURL)) {
        self.client = client

        let defaults = UserDefaults.standard
        self.direction = defaults.string(forKey: Key.direction)
            .flatMap(Compass.init(rawValue:)) ?? .west
        self.station = defaults.string(forKey: Key.crs).flatMap(Stations.find)
    }

    /**
     Availability, cached from the last board.

     Track topology does not change week to week, so the control keeps showing the
     directions it knew about while a new board loads. The alternative is four blocks
     flickering to empty and back on every refresh.
     */
    var tally: Direction.Tally {
        board?.tally ?? Direction.Tally(counts: [:])
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
                    advanced: requestedDate != nil,
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

    private func resetDay() {
        requestedDate = nil
        advancedFor = nil
    }

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(station?.crs, forKey: Key.crs)
        defaults.set(direction.rawValue, forKey: Key.direction)
    }
}

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

    private(set) var destinations: [Destination] = []
    /// True when the server could not check the list against every other direction.
    private(set) var listIsProvisional = false

    private(set) var services: [FastService] = []
    private(set) var truncated = false

    private(set) var isLoading = false
    private(set) var errorMessage: String?

    /// Zero-based. Page zero is always the next three from now.
    private(set) var page = 0

    private let client: BoardClient

    init(client: BoardClient = BoardClient(baseURL: AppConfig.apiBaseURL)) {
        self.client = client
    }

    // MARK: - Where you are going

    /// Read the remembered destination for this station and direction, if there is one.
    func adopt(station: Station, direction: Compass) {
        destination = SharedSelection.destination(for: station.crs, direction: direction)
    }

    func choose(_ chosen: Station?, at station: Station, direction: Compass) {
        SharedSelection.setDestination(chosen, crs: station.crs, direction: direction)
        destination = chosen
        page = 0
        services = []
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
        } catch {
            destinations = []
            errorMessage = (error as? BoardClientError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    // MARK: - What is coming

    func load(at station: Station, direction: Compass) async {
        adopt(station: station, direction: direction)

        guard let heading = destination else {
            services = []
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let board = try await client.fast(from: station.crs, to: heading.crs)
            // The server priced them; the order is ours. `FastBoard` is the only place
            // that rule lives, on either platform.
            services = FastBoard.rank(
                FastBoard.upcoming(board.services),
                limit: Self.perPage * Self.maximumPages
            )
            truncated = board.truncated
            page = 0
        } catch {
            services = []
            errorMessage = (error as? BoardClientError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    // MARK: - Paging

    /// However many pages the trains fill, never padded and never more than five.
    var pageCount: Int {
        guard !services.isEmpty else { return 0 }
        let full = (services.count + Self.perPage - 1) / Self.perPage
        return min(full, Self.maximumPages)
    }

    var shown: [FastService] {
        let start = page * Self.perPage
        guard start < services.count else { return [] }
        return Array(services[start..<min(start + Self.perPage, services.count)])
    }

    var canPage: Bool { pageCount > 1 }
    var isOnFirstPage: Bool { page == 0 }

    /**
     The next three after these.

     Stops at the last page rather than wrapping. The spec asked for a wrap; a wrap and a
     `Now` button do the same job, and the button says what it does. `Today` already works
     this way on the Last Train date, so the two modes behave alike.
     */
    func nextPage() {
        guard page + 1 < pageCount else { return }
        page += 1
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
}

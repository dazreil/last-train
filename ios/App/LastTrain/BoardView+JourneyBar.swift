import SwiftUI

import LastTrainCore

extension BoardView {
    /**
     Where you are and where you are going, as two codes.

     `UPM → BKG`. The name is gone from the title because the code is what the railway
     prints on its own signage, it is read at a glance in the dark, and two of them fit
     where one name did. Either half is its own tap target and edits without disturbing
     the other; the full name is always one tap away in the list that opens.
     */
    var journeyBar: some View {
        HStack(alignment: .center, spacing: 10) {
            /*
             Both codes at one size, the largest that fits. Each used to shrink on its own,
             so `UPM` came out smaller than `BSO` and kept its own size when the two swapped
             ends. The whole pair now steps down a size together until it fits beside the
             buttons.
            */
            ViewThatFits(in: .horizontal) {
                codes(.largeTitle)
                codes(.title)
                codes(.title2)
                codes(.title3)
            }

            Spacer(minLength: 8)

            // Locate is always here — at "Where?" it is the fastest way to fill the box,
            // which is exactly when it used to hide. Clear only appears once there is a
            // journey to clear.
            locateButton
            if model.station != nil, fast.destination != nil { swapButton }
            if model.station != nil { clearButton } else { homeButton }
        }
    }

    /// Wipes the chosen journey back to the "Where?" prompt. Sits next to the locate
    /// button because clearing and re-finding are the two things you do to the pair.
    ///
    /// Hold for the menu in `HOLD-MENUS.md` §2: Clear (the tap), then Go home.
    var clearButton: some View {
        Menu {
            Button("Clear", systemImage: "xmark") { clearJourney() }
            if let home {
                Button("Go home · \(home.station.crs)", systemImage: "house") {
                    goHome()
                }
            }
        } label: {
            barIcon("xmark")
        } primaryAction: {
            clearJourney()
        }
        .modifier(BarMenuStyle())
        .accessibilityLabel("Clear journey")
    }

    /// One of the bar's icons, sized to its 44-point target.
    func barIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.body.weight(.semibold))
            .foregroundStyle(Theme.textDim)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    /// The home station, re-read whenever it changes.
    var home: HomeStation? {
        _ = homeRevision
        return HomeStation.current
    }

    /// Turns the journey round: `EUS → MKC` becomes `MKC → EUS`. Only there once both
    /// ends are set, since there is nothing to turn round before that.
    ///
    /// Hold for the menu in `HOLD-MENUS.md` §2: Reverse (the tap), Continue from the end,
    /// and Trains into the start. Labels name the real stations.
    var swapButton: some View {
        Menu {
            Button("Reverse", systemImage: "arrow.left.arrow.right") {
                Task { await swapJourney() }
            }
            if let end = fast.destination {
                Button("Continue from \(end.crs)", systemImage: "arrow.right.to.line") {
                    continueFrom(end)
                }
            }
            if let start = model.station {
                Button("Trains into \(start.crs)", systemImage: "arrow.left.to.line") {
                    presented = .into(start)
                }
            }
        } label: {
            Group {
                if isSwapping { ProgressView().tint(Theme.textDim) }
                else { barIcon("arrow.left.arrow.right") }
            }
            .frame(width: 44, height: 44)
        } primaryAction: {
            Task { await swapJourney() }
        }
        .modifier(BarMenuStyle())
        .disabled(isSwapping)
        .accessibilityLabel("Reverse journey")
    }

    /**
     "I have arrived; what can I get from here?" The end becomes the start and the end is
     left blank: `EUS → MKC` becomes `MKC → —`, and the board asks which way, as it does
     for any new station.
     */
    func continueFrom(_ end: Station) {
        model.clearNearby()
        directionChosen = false
        model.station = end
        UsageStore.record(end)
    }

    /**
     A journey from `start` to `end`, with the direction looked up rather than guessed.

     A destination's direction has to be the board's own rule, or the board opens empty —
     and on a line that turns, like the Tilbury loop, it is not always the mirror of the
     other way. So the unfiltered list from `start` is read and `end`'s direction taken
     from it. `fallback` stands in only if that fails.

     Filed before the station and direction change, for the reason `adoptEnd` gives:
     changing either re-reads what is filed, and would otherwise find nothing.
     */
    func adoptJourney(from start: Station, to end: Station, fallback: Compass) async {
        isSwapping = true
        defer { isSwapping = false }

        let client = BoardClient(baseURL: AppConfig.apiBaseURL)
        let list = try? await client.destinations(from: start.crs, direction: nil, date: model.requestedDate)
        let heading = list?.destinations.first(where: { $0.crs == end.crs })?.direction
        let direction = heading ?? fallback

        fast.choose(end, at: start, direction: direction)
        directionChosen = true
        model.direction = direction
        model.station = start
        UsageStore.record(start)
        JourneyStore.record(from: start, to: end, direction: direction)
    }

    /// A recent journey, reopened as it was: both ends and the direction between them.
    func openJourney(from: Station, to: Station, direction: Compass) {
        model.clearNearby()
        fast.choose(to, at: from, direction: direction)
        directionChosen = true
        model.direction = direction
        model.station = from
        UsageStore.record(from)
        JourneyStore.record(from: from, to: to, direction: direction)
    }

    /**
     Up to five recent journeys, one tap each to reopen the whole board.

     On the blank board where ✕ leaves you, every journey. With a start station but nowhere
     to go yet — after the house, or after picking a station — only the journeys from that
     station, so going home then tapping your usual trip is two taps. The board is empty in
     both places, so it costs nothing. Followed journeys rank higher; see `RecentJourneys`.
     */
    @ViewBuilder
    func recentJourneysList(from start: Station?) -> some View {
        let journeys = start.map { JourneyStore.list(from: $0) } ?? JourneyStore.list(excluding: nil, nil)
        if !journeys.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                heading(start.map { "Recent from \($0.crs)" } ?? "Recent journeys", colour: Theme.serviceBlueLit)
                ForEach(journeys, id: \.id) { journey in
                    Button {
                        openJourney(from: journey.from, to: journey.to, direction: journey.direction)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(journey.from.crs) → \(journey.to.crs)")
                                .font(.system(.title3, design: .rounded).weight(.semibold))
                                .foregroundStyle(Theme.text)
                            Text("\(journey.from.name.withoutLondonPrefix) to \(journey.to.name.withoutLondonPrefix)")
                                .font(Theme.Font.meta)
                                .foregroundStyle(Theme.textDim)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .padding(.horizontal, Theme.Space.gutter)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressDim())
                    .overlay(alignment: .bottom) { CathodeRule(colour: Theme.serviceBlueLit.opacity(0.3)) }
                    .accessibilityLabel("\(journey.from.name) to \(journey.to.name)")
                }
            }
            .padding(.top, 14)
        }
    }

    /// The same five, for the menu under either station code.
    @ViewBuilder
    var recentJourneysMenu: some View {
        let journeys = JourneyStore.list(excluding: model.station, fast.destination)
        Section("Recent journeys") {
            ForEach(journeys, id: \.id) { journey in
                Button {
                    openJourney(from: journey.from, to: journey.to, direction: journey.direction)
                } label: {
                    Text("\(journey.from.crs) → \(journey.to.crs)")
                    Text("\(journey.from.name.withoutLondonPrefix) to \(journey.to.name.withoutLondonPrefix)")
                }
            }
        }
    }

    /// The way back, as its own journey. The direction is asked for, not assumed to be
    /// the opposite one; see `adoptJourney`.
    func swapJourney() async {
        guard !isSwapping, let start = model.station, let end = fast.destination else { return }
        await adoptJourney(from: end, to: start, fallback: model.direction.opposite)
    }

    /**
     On the blank board, where ✕ was: the two take turns in the same place.

     With a home, a tap goes home and a hold opens the menu. With none there is nowhere to
     go, so a tap opens the menu (`HOLD-MENUS.md` §2 and §6).
     */
    @ViewBuilder
    var homeButton: some View {
        if home != nil {
            Menu { homeMenu } label: { barIcon("house") } primaryAction: { goHome() }
                .modifier(BarMenuStyle())
                .accessibilityLabel("Go to home station")
        } else {
            Menu { homeMenu } label: { barIcon("house") }
                .modifier(BarMenuStyle())
                .accessibilityLabel("Set a home station")
        }
    }

    @ViewBuilder
    var homeMenu: some View {
        if let home {
            Button("Go home · \(home.station.crs)", systemImage: "house") {
                goHome()
            }
        }
        Button("Set home from nearest", systemImage: "location") {
            settingHome = true
            Task {
                await model.locate()
                if model.nearby.isEmpty { settingHome = false } else { presented = .nearby }
            }
        }
        Button("Set home from search", systemImage: "magnifyingglass") {
            settingHome = true
            model.clearNearby()
            presented = .start
        }
        let recent = UsageStore.recentStations()
        if !recent.isEmpty {
            Menu("Set home from recent") {
                ForEach(recent, id: \.crs) { station in
                    Button("\(station.name.withoutLondonPrefix) · \(station.crs)") {
                        settingHome = true
                        startFrom(station)
                    }
                }
            }
        }
        if home != nil {
            Button("Clear home", systemImage: "house.slash") {
                HomeStation.store(nil)
                homeRevision += 1
            }
        }
    }

    /// The home station, by the house or the ✕ menu. Never applied on its own.
    func goHome() {
        guard let home = HomeStation.current else { return }
        model.clearNearby()
        // The start and nothing else: no direction and no destination, so the board asks
        // which way. Carrying a remembered destination is what made home look like Reverse.
        directionChosen = false
        model.station = home.station
        UsageStore.record(home.station)
    }

    /// A new start picked from a menu: a new journey, so it asks which way.
    func startFrom(_ station: Station) {
        model.clearNearby()
        if station.crs != model.station?.crs { directionChosen = false }
        model.station = station
        UsageStore.record(station)
    }

    func clearJourney() {
        guard let station = model.station else { return }
        fast.clearDestination(at: station, direction: model.direction)
        model.clearNearby()
        // Reset the direction as well, so clear is a genuine blank slate rather than one
        // that drops the next pick straight back into the old direction.
        model.direction = .west
        // The next station picked starts unchosen, so Last Train asks which way rather than
        // showing west by default — the same first beat Fast Train has.
        directionChosen = false
        model.station = nil
    }
}

/// The bar's menus look like the buttons they replaced: the plain icon, no menu chrome,
/// and the same dim on press.
struct BarMenuStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .menuStyle(.button)
            .buttonStyle(PressDim())
            .tint(Theme.textDim)
            .accessibilityHint("Hold for more options")
    }
}

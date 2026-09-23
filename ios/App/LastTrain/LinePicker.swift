import SwiftUI

import LastTrainCore

/**
 One end of a journey, chosen from what the railway actually offers.

 Both halves of the two-code bar open this. The only difference is which way round it is
 asked, and that difference is `Compass.opposite`:

 - **Changing where you are going** lists the destinations reachable *from your start*, the
   way you are heading. `UPM` west offers Barking, Fenchurch Street, and the rest.
 - **Changing where you are** lists the destinations reachable *from your end*, the
   opposite way. To arrive at `BKG` travelling west you must have started east of it, so
   Barking's eastward list is exactly the set of valid origins.

 Anything picked from that list keeps the other half intact, by construction — the list was
 built from it.

 **With no direction yet, the list is every direction at once**, one section each, and
 the row you tap sets the direction. Before a direction is chosen the app has no honest
 way to pick one, and "west of UPM" was the fallback that answered the wrong question.

 **The search box searches this list** when choosing a destination: a station no direct
 train reaches is not an answer to "where are you going". On the start sheet it is the
 way off the line instead — somewhere else entirely, across all 2,619 stations — and a
 station found that way may have no direct service to the other half, so every pick
 reports whether it came from the line (`onPick`'s second argument) and the caller decides
 whether the pair survives. That is the whole reset rule, and it lives at the call site.
 */
struct LinePicker: View {
    /// The station whose direct destinations make up the list.
    let from: Station
    /**
     The direction to read from `from`, already reversed by the caller where needed.

     **Nil means every direction**, grouped under a heading each. That is what the
     destination sheet asks before you have said which way you are going: the list then
     answers "which way" for you, because every row belongs to one direction and the row you
     tap is the way you are heading.
     */
    let direction: Compass?
    /// The service day being looked at, so a browsed future day lists that day's real
    /// destinations. Nil is today.
    var date: String? = nil
    let title: String
    /// Highlighted in the list, so re-opening shows where you already are.
    let selectedCrs: String?
    /**
     Whether the search box reaches every station, or only this list.

     The two sheets want opposite things. Choosing where you are **going**, a station no
     direct train reaches is not an answer, so the box searches the list and nothing else.
     Choosing where you **are**, with a destination already set, the box is the way off the
     line — somewhere else entirely, a new journey — so it searches all 2,619.
     */
    var searchesEverywhere: Bool = false
    /// Shown as a Clear button when set: empties the journey so this sheet can start afresh.
    var onClear: (() -> Void)? = nil
    /**
     `(station, cameFromTheLine, heading)`.

     `cameFromTheLine` is false only for a station found by searching everywhere, which may
     not connect. `heading` is the direction of the row that was tapped — the answer to
     "which way", when the list was every way at once.
     */
    let onPick: (Station, Bool, Compass?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var destinations: [Destination] = []
    /// The busiest few of `destinations`, for the top of the list. Empty for a short list.
    @State private var popular: [Destination] = []
    @State private var popularSource: String?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var client: BoardClient { BoardClient(baseURL: AppConfig.apiBaseURL) }

    private var searching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CathodeBackdrop()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if searching {
                            searchResults
                        } else {
                            lineList
                        }
                    }
                }
                .scrollDismissesKeyboard(.immediately)
            }
            .searchable(text: $query, prompt: "Station or code")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if let onClear {
                    ToolbarItem(placement: .primaryAction) {
                        // The sheet stays open. It turns into the plain station search in
                        // place, because clearing is the first half of choosing again.
                        Button("Clear", role: .destructive) { onClear() }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await load() }
    }

    // MARK: - The line

    @ViewBuilder
    private var lineList: some View {
        if isLoading && destinations.isEmpty {
            loading
        } else if let errorMessage, destinations.isEmpty {
            message(errorMessage)
        } else if destinations.isEmpty {
            if let direction {
                message("Nothing runs \(direction.rawValue) from \(from.name.withoutLondonPrefix) today.")
            } else {
                message("No direct trains leave \(from.name.withoutLondonPrefix) today.")
            }
        } else {
            popularSection
            rows(destinations)
        }
    }

    /**
     Where most people go from here, above the full list.

     The list below is in journey-time order, which is route order, and route order puts a
     terminus last: from Upminster, Fenchurch Street is the final row in West — while it is,
     with West Ham, one of the two busiest journeys anyone makes from there. This is the
     likely answer, a tap from the top. The rows stay in the list below too, so nothing
     moves out of its place on the line.

     Captioned with its source. Partly because a list that is not in route order should say
     why, and partly because the data's licence asks for it.
     */
    @ViewBuilder
    private var popularSection: some View {
        if !popular.isEmpty {
            Text("Popular")
                .cathodeSection(Theme.serviceBlueLit)
                .padding(.horizontal, Theme.Space.gutter)
                .padding(.top, 22)
                .padding(.bottom, 2)
            if let popularSource {
                Text("Most journeys from here · \(popularSource)")
                    .font(Theme.Font.meta)
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Space.gutter)
                    .padding(.bottom, 4)
            }
            ForEach(popular) { destination in
                if let station = Stations.find(destination.crs) {
                    // Out of its direction's section, so it says which way it is — unless the
                    // whole sheet is one direction already.
                    row(
                        station,
                        minutes: destination.minutes,
                        onLine: true,
                        heading: destination.direction ?? direction,
                        note: direction == nil ? destination.direction?.rawValue.capitalized : nil
                    )
                }
            }
        }
    }

    /**
     A set of destinations, grouped by direction when no direction was asked for.

     Grouped rather than interleaved, so the sections line up with the direction row on the
     board behind this sheet — East here is East there — and so a station that two
     directions reach equally shows up in both sections, as the two real choices it is.
     */
    @ViewBuilder
    private func rows(_ these: [Destination]) -> some View {
        if direction == nil {
            ForEach(Compass.allCases, id: \.self) { point in
                let group = these.filter { $0.direction == point }
                if !group.isEmpty {
                    Text(point.rawValue)
                        .cathodeSection(Theme.serviceBlueLit)
                        .padding(.horizontal, Theme.Space.gutter)
                        .padding(.top, 22)
                        .padding(.bottom, 4)
                    ForEach(group) { destination in destinationRow(destination) }
                }
            }
        } else {
            ForEach(these) { destination in destinationRow(destination) }
        }
    }

    @ViewBuilder
    private func destinationRow(_ destination: Destination) -> some View {
        if let station = Stations.find(destination.crs) {
            row(station, minutes: destination.minutes, onLine: true, heading: destination.direction ?? direction)
        }
    }

    // MARK: - Everywhere else

    @ViewBuilder
    private var searchResults: some View {
        if searchesEverywhere {
            let onLine = Set(destinations.map(\.crs))
            if matches.isEmpty {
                message("No station matches “\(query)”.")
            } else {
                ForEach(matches, id: \.crs) { station in
                    row(station, minutes: nil, onLine: onLine.contains(station.crs), heading: nil)
                }
            }
        } else if isLoading && destinations.isEmpty {
            loading
        } else if lineMatches.isEmpty {
            // Said plainly, because the station may well exist — it just is not somewhere a
            // direct train from here goes, which is the whole point of this list.
            // The direction goes in when there is one. "No direct train goes to Barking" is
            // false at Upminster — one goes west — and the list has only been asked about east.
            if let direction {
                message("No direct train \(direction.rawValue) from \(from.name.withoutLondonPrefix) goes to “\(query)”.")
            } else {
                message("No direct train from \(from.name.withoutLondonPrefix) goes to “\(query)”.")
            }
        } else {
            rows(lineMatches)
        }
    }

    /// How well a code and name answer the query: exact code, exact name, prefix, then
    /// anywhere in the name. The same ranking the station search has always used.
    private func rank(crs: String, name: String) -> Int? {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return nil }
        let lower = name.lowercased()
        if crs.lowercased() == needle { return 0 }
        if lower == needle { return 1 }
        if lower.hasPrefix(needle) { return 2 }
        if lower.contains(needle) { return 3 }
        return nil
    }

    /// Every station, for the start sheet, where searching is how a new journey begins.
    private var matches: [Station] {
        // Spelled out step by step: as one chained expression the type checker gives up.
        var ranked: [(station: Station, score: Int)] = []
        for station in Stations.all {
            if let score = rank(crs: station.crs, name: station.name) { ranked.append((station, score)) }
        }
        ranked.sort { a, b in a.score == b.score ? a.station.name < b.station.name : a.score < b.score }
        return ranked.prefix(60).map { $0.station }
    }

    /// Only the list, for the destination sheet. Kept in journey-time order within each
    /// match strength, so the nearer of two "Barking"s comes first.
    private var lineMatches: [Destination] {
        var ranked: [(destination: Destination, score: Int)] = []
        for destination in destinations {
            if let score = rank(crs: destination.crs, name: destination.name) {
                ranked.append((destination, score))
            }
        }
        ranked.sort { a, b in
            a.score == b.score ? a.destination.minutes < b.destination.minutes : a.score < b.score
        }
        return ranked.map { $0.destination }
    }

    // MARK: - Rows

    /// Code *and* name. A list is where you are deciding rather than reading a known
    /// answer, and `BKG` and `BGV` are one letter apart and different places.
    private func row(
        _ station: Station,
        minutes: Int?,
        onLine: Bool,
        heading: Compass?,
        note: String? = nil
    ) -> some View {
        let chosen = station.crs == selectedCrs
        return Button {
            onPick(station, onLine, heading)
            dismiss()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(station.crs)
                    .font(Theme.Font.body.monospacedDigit())
                    .foregroundStyle(Theme.serviceBlueLit)
                    .fixedSize(horizontal: true, vertical: false)

                VStack(alignment: .leading, spacing: 2) {
                    Text(station.name.withoutLondonPrefix)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    // Said only while searching everywhere, where a station may be somewhere
                    // the current journey cannot reach. On the line itself it would be noise.
                    if searching && !onLine {
                        Text("starts a new journey")
                            .font(Theme.Font.meta)
                            .foregroundStyle(Theme.textFaint)
                    } else if let note {
                        Text(note)
                            .font(Theme.Font.meta)
                            .foregroundStyle(Theme.textFaint)
                    }
                }

                Spacer(minLength: 8)

                if let minutes {
                    Text("\(minutes) min")
                        .font(Theme.Font.meta.monospacedDigit())
                        .foregroundStyle(Theme.serviceBlueLit)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.vertical, 14)
            .background(chosen ? Theme.serviceBlue.opacity(0.45) : Color.clear)
            .overlay(alignment: .bottom) { CathodeRule(colour: Theme.serviceBlueLit.opacity(0.3)) }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressDim())
        .accessibilityLabel(station.name)
        .accessibilityValue(
            onLine
                ? [note, minutes.map { "\($0) minutes" }].compactMap { $0 }.joined(separator: ", ")
                : "starts a new journey"
        )
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private var loading: some View {
        VStack(spacing: 12) {
            ForEach(0..<6, id: \.self) { _ in
                Rectangle().fill(Theme.control.opacity(0.4)).frame(height: 52)
            }
        }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.top, 16)
        .accessibilityLabel("Loading stations")
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.body)
            .foregroundStyle(Theme.textDim)
            .fixedSize(horizontal: false, vertical: true)
            .padding(Theme.Space.gutter)
    }

    /**
     One request, and it can be slow.

     Measured on the deployment: a cold list took **10.2 seconds**, warm ones 1.5–2.7. So
     this shows a real loading state rather than pretending to be instant, and the search
     box stays usable while it runs — a station typed by name never waits on the network.
     */
    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let list = try await client.destinations(from: from.crs, direction: direction, date: date)
            destinations = list.destinations
            popular = list.popularDestinations
            popularSource = list.popularSource
        } catch is CancellationError {
            return
        } catch {
            errorMessage = (error as? BoardClientError)?.errorDescription ?? error.localizedDescription
        }
    }
}

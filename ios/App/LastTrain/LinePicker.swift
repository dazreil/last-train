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

 **The search box is the way off the line.** The list answers "where can this journey go";
 the box answers "somewhere else entirely", across all 2,619 stations. A station found that
 way may have no direct service to the other half, so every pick reports whether it came
 from the line (`onPick`'s second argument) and the caller decides whether the pair
 survives. That is the whole reset rule, and it lives at the call site rather than here.
 */
struct LinePicker: View {
    /// The station whose direct destinations make up the list.
    let from: Station
    /// The direction to read from `from`. Already reversed by the caller where needed.
    let direction: Compass
    let title: String
    /// Highlighted in the list, so re-opening shows where you already are.
    let selectedCrs: String?
    /// `(station, cameFromTheLine)`. False means it was found by search and may not connect.
    let onPick: (Station, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var destinations: [Destination] = []
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
            message("Nothing runs \(direction.rawValue) from \(from.name.withoutLondonPrefix) today.")
        } else {
            ForEach(destinations) { destination in
                if let station = Stations.find(destination.crs) {
                    row(station, minutes: destination.minutes, onLine: true)
                }
            }
        }
    }

    // MARK: - Everywhere else

    @ViewBuilder
    private var searchResults: some View {
        let onLine = Set(destinations.map(\.crs))
        if matches.isEmpty {
            message("No station matches “\(query)”.")
        } else {
            ForEach(matches, id: \.crs) { station in
                row(station, minutes: nil, onLine: onLine.contains(station.crs))
            }
        }
    }

    /// The same ranking the station search has always used: exact code, exact name,
    /// prefix, then anywhere in the name.
    private var matches: [Station] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
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
            .sorted { $0.1 == $1.1 ? $0.0.name < $1.0.name : $0.1 < $1.1 }
            .prefix(60)
            .map(\.0)
    }

    // MARK: - Rows

    /// Code *and* name. A list is where you are deciding rather than reading a known
    /// answer, and `BKG` and `BGV` are one letter apart and different places.
    private func row(_ station: Station, minutes: Int?, onLine: Bool) -> some View {
        let chosen = station.crs == selectedCrs
        return Button {
            onPick(station, onLine)
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
                    // Said only while searching, where a station may be somewhere the
                    // current journey cannot reach. On the line itself it would be noise.
                    if searching && !onLine {
                        Text("starts a new journey")
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
        .accessibilityValue(onLine ? (minutes.map { "\($0) minutes" } ?? "") : "starts a new journey")
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
            destinations = try await client.destinations(from: from.crs, direction: direction).destinations
        } catch is CancellationError {
            return
        } catch {
            errorMessage = (error as? BoardClientError)?.errorDescription ?? error.localizedDescription
        }
    }
}

import SwiftUI

import LastTrainCore

/**
 The board.

 Masthead, where you are, which way you are heading, and what leaves. It never asks
 where you are going.

 The service list arrives from the API already in departure order, and that is also the
 order it is shown in — so this walks the list once and drops a heading in wherever the
 role changes. Both arrangements fall out of that: last-three-then-first-back in the
 evening, first-three-then-last in the small hours.
 */
struct BoardView: View {
    @State private var model = BoardModel()
    @State private var pickingStation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                masthead
                stationField

                if model.station != nil {
                    DirectionControl(
                        tally: model.tally,
                        towards: model.towards,
                        selection: $model.direction
                    )
                    .padding(.top, 8)

                    results
                } else {
                    whereAreYou
                }

                footnote
            }
            .padding(.bottom, 32)
        }
        .background(Theme.surface)
        .refreshable { await model.load(refresh: true) }
        .task { await model.load() }
        // Tapping the widget lands here, on the board it was showing.
        .onOpenURL { model.open($0) }
        .sheet(isPresented: $pickingStation) {
            StationPicker(selection: $model.station)
        }
    }

    // MARK: - Chrome

    private var masthead: some View {
        // Side by side while they fit, stacked when they do not. At accessibility text
        // sizes the row has no room and the date wraps mid-phrase -- "LAST TRAIN WED /
        // 5 AUG" -- which reads as two broken labels rather than one line.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                mastheadWordmark
                Spacer()
                mastheadDate
            }
            VStack(alignment: .leading, spacing: 4) {
                mastheadWordmark
                mastheadDate
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var mastheadWordmark: some View {
        Text("Last Train").labelStyle().fixedSize(horizontal: false, vertical: true)
    }

    private var mastheadDate: some View {
        Text(ServiceDay.formatServiceDate(model.board?.date ?? ServiceDay.currentServiceDate()) ?? "")
            .font(Theme.Font.label)
            .tracking(Theme.tracking)
            .textCase(.uppercase)
            .foregroundStyle(Theme.textDim)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var stationField: some View {
        Button {
            pickingStation = true
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("From").labelStyle()
                Text(model.station?.name ?? "Choose a station")
                    .font(Theme.Font.heading)
                    .foregroundStyle(model.station == nil ? Theme.textFaint : Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 13)
            .background(Theme.raised)
            .overlay(Rectangle().strokeBorder(Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Theme.Space.gutter)
    }

    // MARK: - Results

    @ViewBuilder
    private var results: some View {
        if let message = model.errorMessage {
            notice(title: "Couldn’t look that up", body: message) {
                Button("Try again") { Task { await model.load(refresh: true) } }
                    .font(Theme.Font.meta)
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Theme.raised)
            }
        } else if model.isLoading && model.board == nil {
            skeleton
        } else if let board = model.board {
            if board.services.isEmpty {
                // Nothing running that way is a valid answer, shown plainly and never
                // as an error. The app is only useful if a blank result can be trusted.
                notice(
                    title: "Nothing \(board.direction.rawValue)bound",
                    body: "No trains run \(board.direction.rawValue) from \(board.from.name) on "
                        + "\(ServiceDay.formatServiceDate(board.date) ?? board.date)."
                ) { EmptyView() }
            } else {
                departures(board)
            }
        }
    }

    private func departures(_ board: DepartureBoard) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(board.services.enumerated()), id: \.element.id) { index, service in
                if index == 0 || board.services[index - 1].role != service.role {
                    heading(for: service.role, board: board)
                }
                ServiceRow(
                    service: service,
                    isLastTrain: service.serviceId == board.lastTrain?.serviceId
                )
            }
        }
        .padding(.top, 6)
    }

    private func heading(for role: ServiceRole, board: DepartureBoard) -> some View {
        let title: String
        let trailing: String

        switch (role, board.mode) {
        case (.last, .normal):
            let count = board.lastTrains.count
            title = count > 1
                ? "Last \(count) trains \(board.direction.rawValue)"
                : "Last train \(board.direction.rawValue)"
            trailing = "\(board.totalServices) services"
        case (.last, .preService):
            title = "Last train \(board.direction.rawValue)"
            trailing = "\(board.totalServices) services"
        case (.first, .normal):
            // Named, not called "tomorrow" — at 00:40 that word is wrong by a day.
            title = "First train back"
            trailing = ServiceDay.formatServiceDate(board.firstDate) ?? ""
        case (.first, .preService):
            let count = board.firstTrains.count
            title = count > 1
                ? "First \(count) trains \(board.direction.rawValue)"
                : "First train \(board.direction.rawValue)"
            trailing = ""
        }

        return HStack(alignment: .firstTextBaseline) {
            Text(title).labelStyle()
            Spacer()
            if !trailing.isEmpty { Text(trailing).labelStyle() }
        }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.top, 14)
        .padding(.bottom, 5)
    }

    private var skeleton: some View {
        VStack(spacing: 1) {
            ForEach(0..<3, id: \.self) { _ in
                Rectangle()
                    .fill(Theme.raised)
                    .frame(height: 74)
            }
        }
        .padding(.top, 20)
        .accessibilityHidden(true)
    }

    private func notice(
        title: String,
        body: String,
        @ViewBuilder action: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.Font.heading)
            Text(body)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            action()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.gutter)
        .padding(.top, 8)
    }

    private var whereAreYou: some View {
        notice(
            title: "Where are you?",
            body: "Pick a station, then a direction. Trains you can board here, going that way."
        ) { EmptyView() }
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(
                "Timetabled departures for the service day, which runs to 03:00 the next "
                    + "morning — so trains after midnight are tonight’s, not tomorrow’s."
            )
            Text("Data from Realtime Trains.")
        }
        .font(Theme.Font.meta)
        .foregroundStyle(Theme.textFaint)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.top, 24)
    }
}

/**
 Choosing a station.

 2,619 of them, so it is a search rather than a list. Ranked so that typing a name puts
 the station actually called that first — "birmingham" should not lead with Birmingham
 International.
 */
struct StationPicker: View {
    @Binding var selection: Station?
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List(matches, id: \.crs) { station in
                Button {
                    selection = station
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(station.name)
                                .font(Theme.Font.destination)
                                .foregroundStyle(Theme.text)
                            if let locality = station.locality {
                                Text(locality)
                                    .font(Theme.Font.meta)
                                    .foregroundStyle(Theme.textFaint)
                            }
                        }
                        Spacer()
                        Text(station.crs)
                            .font(Theme.Font.meta.monospaced())
                            .foregroundStyle(Theme.textDim)
                    }
                }
                .listRowBackground(Theme.surface)
            }
            .listStyle(.plain)
            .background(Theme.surface)
            .searchable(text: $query, prompt: "Station or code")
            .navigationTitle("From")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

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
            .sorted { left, right in
                left.1 == right.1 ? left.0.name < right.0.name : left.1 < right.1
            }
            .prefix(60)
            .map(\.0)
    }
}

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
    @State private var fast = FastModel()
    /**
     Which question the app is answering.

     Always `.last` when the app opens. `PRODUCT.md` calls that the default surface: the
     one that must answer in two seconds and never asks where you are going. Fast Train is
     reached by a deliberate tap and is not remembered, so opening the app never lands you
     somewhere that wants a destination.
     */
    @State private var mode: AppMode = .last
    @State private var pickingStation = false
    /// The block whose route is open. Nil when the sheet is closed.
    @State private var inspecting: BoardDeparture?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                masthead
                stationField

                if let station = model.station {
                    DirectionControl(
                        available: model.available,
                        towards: model.towards,
                        selection: $model.direction,
                        // Where you are going is asked for one direction at a time, so
                        // in Fast Train the two are chosen together. Last Train passes
                        // nothing: it never asks.
                        onTap: mode == .fast ? { _ in fast.askWhereTo() } : nil
                    )
                    .padding(.top, 8)

                    switch mode {
                    case .last:
                        results
                    case .fast:
                        FastBoardView(station: station, direction: model.direction, model: fast)
                    }
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
        // Fast Train needs its own lookup, and only once there is somewhere to go.
        .task(id: fastKey) {
            guard mode == .fast, let station = model.station else { return }
            await fast.load(at: station, direction: model.direction)
        }
        // Tapping the widget lands here, on the board it was showing.
        .onOpenURL { model.open($0) }
        .sheet(isPresented: $pickingStation) {
            StationPicker(selection: $model.station)
        }
        .sheet(item: $inspecting) { service in
            if let station = model.station {
                ServiceSheet(
                    service: service,
                    station: station,
                    direction: model.direction,
                    isPinned: model.isPinned(service),
                    onPin: { following in
                        model.setPin(service, following: following)
                        inspecting = nil
                    }
                )
            }
        }
    }

    /// Changes whenever Fast Train would be answering a different question.
    private var fastKey: String {
        "\(mode.rawValue):\(model.station?.crs ?? "-"):\(model.direction.rawValue):\(fast.destination?.crs ?? "-")"
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
                if hasTrailingControl {
                    mastheadTrailing
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                mastheadWordmark
                if hasTrailingControl {
                    // **Still the right-hand end, even on its own line.** Left-aligned here
                    // it slid the whole way across the screen the moment the text grew, so
                    // the control you had just tapped was somewhere else entirely — and
                    // §11's idea of two taps at opposite ends of one bar stopped being
                    // true. Trailing keeps the thumb's target where it was and reads as a
                    // bar that wrapped rather than two rows that disagree.
                    mastheadTrailing
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    /// Whether the right-hand end of the bar has anything to offer. Last Train's date
    /// always steps; Fast Train's pager only exists once there is a second page.
    private var hasTrailingControl: Bool { mode == .last || fast.canPage }

    /**
     Back, here, next — and the last one is a button.

     Three slots in one order, both modes. The left is the way back to the start and is
     absent when you are already there; the middle is where you are, in white; the right
     names where the next tap lands, which on the furthest step *is* the start again. So
     the wrap needs no special case and no second glyph: the label already says `Today`.

     The right slot is the one pressed repeatedly and it is the rightmost thing in a
     right-aligned row, so nothing appearing beside it can shift it out from under a
     finger — the bug that made the date look broken, now prevented by the arrangement
     rather than by reserving a gap.

     **Centred, with every slot the same height.** Baseline alignment looked like the right
     answer and did not work: `Today` carries a pill, so its text sits inside a padded box,
     and a first-text-baseline guide does not survive the `Button` and background around it
     — the pill rode visibly higher than the two labels beside it. Giving all three the same
     vertical padding makes the boxes equal, and equal boxes centre exactly, whatever the
     guide does.
     */
    @ViewBuilder
    private var mastheadTrailing: some View {
        HStack(alignment: .center, spacing: 7) {
            trailingSlots
        }
    }

    @ViewBuilder
    private var trailingSlots: some View {
        switch mode {
        case .last:
            if model.dayIndex > 0 && !model.stepWrapsToToday { todayButton }
            stepLabel(model.dayIndex == 0
                ? "Today"
                : ServiceDay.formatWeekday(model.shownDate) ?? "")
            stepButton(
                label: model.stepWrapsToToday
                    ? "Today"
                    : ServiceDay.formatWeekday(model.date(atStep: model.dayIndex + 1) ?? "") ?? "",
                action: { model.stepForward() },
                accessibility: model.stepWrapsToToday
                    ? "Back to today"
                    : "Show the next day",
                // `Sun` on screen, the whole date said aloud.
                value: ServiceDay.formatServiceDate(model.shownDate) ?? ""
            )
        case .fast:
            if !fast.isOnFirstPage && !fast.pageWrapsToNow { nowButton }
            stepLabel(Self.pageName(fast.page))
            stepButton(
                label: fast.pageWrapsToNow ? "Now" : Self.pageName(fast.page + 1),
                action: { fast.advance() },
                accessibility: fast.pageWrapsToNow
                    ? "Back to the trains from now"
                    : "Show the next three trains",
                // The count is no longer on screen, so it is said here instead. A
                // screen reader should not lose what the compact label dropped.
                value: "Page \(fast.page + 1) of \(fast.pageCount)"
            )
        }
    }

    /**
     Pages named rather than counted.

     `1 of 3` told you where you were and how far it went, which is more than the
     question needs and reads like pagination. The days beside it are named — `Today`,
     `Sun`, `Mon` — so the pages are too: the first three are the ones leaving `Now`, and
     the rest are the word for their place. The total goes to the accessibility value,
     where it costs no width.
     */
    private static let pageWords = ["Now", "Two", "Three", "Four", "Five"]

    private static func pageName(_ index: Int) -> String {
        index >= 0 && index < pageWords.count ? pageWords[index] : "\(index + 1)"
    }

    /// The middle slot: where you are, and not a control — there is nowhere for it to
    /// take you. Padded to the pill's height so the three slots centre on each other.
    private func stepLabel(_ text: String) -> some View {
        Text(text)
            .labelStyle(Theme.text)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.vertical, 4)
    }

    /// The right slot: named rather than drawn as a bare chevron, because a glyph says
    /// that something will happen and a name says what.
    private func stepButton(
        label: String,
        action: @escaping () -> Void,
        accessibility: String,
        value: String? = nil
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(label)
                    .fixedSize(horizontal: true, vertical: false)
                // One glyph in every state now. The return arrow existed to say the next
                // tap went somewhere different; the label says where.
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
            }
            .labelStyle(Theme.textDim)
            // Matches the pill's height, so the row centres rather than drifts, and gives
            // the most-pressed control in the app a taller target than its text.
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility)
        .accessibilityValue(value ?? "")
    }

    /**
     The wordmark, and the way into the other mode.

     §11 chose this: two taps at opposite ends of the same bar, each turning one axis.
     The date on the right changes *when*; the title on the left changes *what is being
     asked*. The name is the description — Last Train becomes Fast Train.

     **Both names are shown, and the case says which you are reading.** It was an
     `arrow.left.arrow.right` glyph, which announced that something would swap without
     saying what for — you had to press it to find out. Naming the other mode answers that
     before the tap, and costs nothing but the width.

     White for the mode you are in, faint and lowercase for the one you are not, which is
     the same rule the date and the pager keep at the other end of the bar. The whole thing
     is one button: either name switches, because there are only two.
     */
    private var mastheadWordmark: some View {
        Button {
            mode = mode.other
        } label: {
            HStack(spacing: 7) {
                Text(mode.title)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.text)
                Text(mode.other.title)
                    .textCase(.lowercase)
                    .foregroundStyle(Theme.textFaint)
            }
            .font(Theme.Font.label)
            .tracking(Theme.tracking)
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode == .last ? "Switch to Fast Train" : "Switch to Last Train")
    }

    /**
     Back to tonight, in the left slot while you are walking forward.

     Drawn only once you have stepped away by hand, and not at all on the furthest day —
     there the walk rounds to today anyway, so `Today` is already in the right slot and
     naming it twice would be two ways to say one thing.

     Never offered when the board moved itself past a spent service day: today is then
     the day whose trains have all gone, and offering to return to it would be offering
     to go back to nothing. `dayIndex` is zero in that state, which is what keeps this
     absent without a second condition.
     */
    private var todayButton: some View {
        Button {
            model.returnToToday()
        } label: {
            wayBackLabel("Today")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back to today")
    }

    /// `Today`'s twin, and the same shape for the same reason.
    private var nowButton: some View {
        Button {
            fast.now()
        } label: {
            wayBackLabel("Now")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back to the trains from now")
    }

    /// The way back wears a pill wherever it sits, so it reads as the same control on
    /// either side of the row.
    private func wayBackLabel(_ text: String) -> some View {
        Text(text)
            .labelStyle(Theme.textDim)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.raised)
            .contentShape(Rectangle())
    }

    private var stationField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                Button {
                    model.clearNearby()
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
                    .padding(.leading, 13)
                    .padding(.trailing, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                locateButton
            }
            .background(Theme.raised)
            .overlay(Rectangle().strokeBorder(Theme.hairline, lineWidth: 1))

            if let locateError = model.locateError {
                Text(locateError)
                    .font(Theme.Font.meta)
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            nearbyAlternatives
        }
        .padding(.horizontal, Theme.Space.gutter)
    }

    /**
     Fill the field from where you are.

     Beside the station rather than inside the picker: on a platform the station you
     want is the one you are standing in, and that should not cost a search. It is the
     one control here that saves a whole interaction rather than a tap.
     */
    private var locateButton: some View {
        Button {
            Task { await model.locate() }
        } label: {
            Group {
                if model.isLocating {
                    ProgressView().tint(Theme.textDim)
                } else {
                    Image(systemName: "location.fill")
                        .font(.system(size: 17, weight: .semibold))
                }
            }
            .foregroundStyle(Theme.textDim)
            // A full-height target, so it can be hit one-handed without looking.
            .frame(width: 52)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isLocating)
        .accessibilityLabel("Use nearest station")
    }

    /**
     The other stations near you, kept after the field is filled.

     Straight-line distance is not the same as which platform you are on: at Barking,
     Stratford or any of the London termini clusters, two stations sit within a few
     hundred metres and the closer one is regularly the wrong one. Naming the
     alternatives costs a line and removes the need to start a search over.
     */
    @ViewBuilder
    private var nearbyAlternatives: some View {
        if model.nearby.count > 1 {
            VStack(alignment: .leading, spacing: 5) {
                Text("Near you").labelStyle()

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.nearby, id: \.station.crs) { candidate in
                            Button {
                                model.station = candidate.station
                            } label: {
                                HStack(spacing: 5) {
                                    Text(candidate.station.name.withoutLondonPrefix)
                                        .font(Theme.Font.meta)
                                    Text(candidate.distanceLabel)
                                        .font(Theme.Font.meta)
                                        .foregroundStyle(Theme.textFaint)
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background(
                                    candidate.station.crs == model.station?.crs
                                        ? Theme.control : Theme.raised
                                )
                                .foregroundStyle(Theme.textDim)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                // The row is full-bleed inside the gutter, so a scrolled item is not
                // clipped mid-word against the screen edge.
                .scrollClipDisabled()
            }
        }
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
                    isLastTrain: service.serviceId == board.lastTrain?.serviceId,
                    isPinned: model.isPinned(service)
                )
                // The whole block, because at night on a platform the target is the
                // thing you can see, not a chevron somewhere inside it.
                .contentShape(Rectangle())
                .onTapGesture { inspecting = service }
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
            // The promise, stated once. A replacement bus leaving *this* station is a
            // departure and appears, badged. A bus from further down the line is a
            // connection, and the app does not plan journeys -- see PRODUCT.md.
            Text("Direct services only. The app never suggests a change.")
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

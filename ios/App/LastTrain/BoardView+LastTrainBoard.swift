import SwiftUI

import LastTrainCore

extension BoardView {
    // MARK: - Last Train

    @ViewBuilder
    var lastTrainResults: some View {
        if let message = model.errorMessage, let board = model.board {
            // A refresh failed but a board is already up. Keep it — dimmed, untappable, its
            // "Updated" stamp still in the footer — behind a compact notice. Stale times beat
            // no times, and the compass keeps its directions.
            VStack(alignment: .leading, spacing: 0) {
                staleNotice(message)
                boardBody(board)
                    .opacity(0.4)
                    .allowsHitTesting(false)
            }
        } else if let message = model.errorMessage {
            notice(title: "Couldn’t look that up", body: message) {
                retryButton { await model.load(refresh: true) }
            }
        } else if model.isLoading && model.board == nil {
            loadingBoard
        } else if let board = model.board {
            boardBody(board)
        }
    }

    /// The board, or the plain "nothing this way" notice when the day is empty. Shared by the
    /// live path and the dimmed-behind-an-error path so the two cannot drift.
    @ViewBuilder
    func boardBody(_ board: DepartureBoard) -> some View {
        if board.services.isEmpty {
            notice(
                title: "Nothing \(board.direction.rawValue)bound",
                body: "No trains run this way on \(ServiceDay.formatServiceDate(board.date) ?? board.date)."
            )
        } else {
            cathodeBoard(board)
        }
    }

    /// The banner over a board that could not be refreshed: says so, offers a retry, and lets
    /// the times below it stand in the meantime.
    func staleNotice(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Couldn’t refresh").font(Theme.Font.heading)
            Text(message).font(Theme.Font.body).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            // The age of what is still on screen. This lived in the footer as "Updated
            // 23:41" on every board; it only matters when the board is not current, which
            // is exactly when this banner is up.
            if let updated = model.updatedAt {
                Text("Times below are from \(ServiceDay.formatClock(ServiceDay.formatLondonTime(updated)).spoken).")
                    .font(Theme.Font.meta)
                    .foregroundStyle(Theme.textDim)
            }
            retryButton { await model.load(refresh: true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.top, 20)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    func cathodeBoard(_ board: DepartureBoard) -> some View {
        // Rolled past a spent service day into one not yet running: the next trains you can
        // catch lead, the last train sits below. The follow-pill rewrite unified the board
        // around a last-train hero and dropped this, so after the last train had gone the
        // board showed the *next day's* last train — a whole day off — at the top.
        if board.mode == .preService, model.pinnedService == nil {
            preServiceBoard(board)
        } else {
            normalBoard(board)
        }
    }

    func preServiceBoard(_ board: DepartureBoard) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !board.firstTrains.isEmpty {
                heading("First trains", colour: Theme.serviceBlueLit)
                ForEach(board.firstTrains, id: \.id) { serviceRow($0, board: board) }
            }
            if let last = board.lastTrain {
                heading("Last train", colour: Theme.lastTrainRedLit)
                serviceRow(last, board: board)
            }
        }
        .padding(.top, 8)
        .opacity(model.isLoading ? 0.42 : 1)
        .animation(.easeOut(duration: 0.16), value: model.isLoading)
    }

    func normalBoard(_ board: DepartureBoard) -> some View {
        let last = board.lastTrain
        let pinned = model.pinnedService
        // The pinned train leads the board when there is one; otherwise the last train
        // does, as it always has.
        let hero = pinned ?? last
        let heroIsPinnedNonLast = pinned != nil && pinned?.serviceId != last?.serviceId
        let rest = board.services.filter { $0.serviceId != hero?.serviceId }

        // The trains of this service day that are neither the hero nor the last train.
        // Their heading is relative to the hero, not absolute: follow an early train and
        // the ones beneath it leave *later*, so a fixed "Earlier trains" would lie — and
        // it counts itself, so one train is not plural. `depInstant` is UTC ISO, hence
        // ordered by plain string comparison.
        let otherLast = rest.filter { $0.role == .last && $0.serviceId != last?.serviceId }
        let othersAreLater = otherLast.first.map { $0.depInstant > (hero?.depInstant ?? "") } ?? false
        let otherLastTitle =
            "\(othersAreLater ? "Later" : "Earlier") train\(otherLast.count == 1 ? "" : "s")"

        return VStack(alignment: .leading, spacing: 0) {
            if let hero {
                // The last train names itself above the numerals. A followed train that is
                // not the last one leads with no heading: its pill already says
                // "Following", and a heading as well added a line — one more than the
                // unfollowed board, which was enough to push it past the screen and make
                // it scroll. The displaced last train keeps its own heading below, so the
                // count of headings is the same either way.
                if !heroIsPinnedNonLast {
                    heading("Last train", colour: Theme.lastTrainRedLit)
                }
                serviceRow(hero, board: board)
            }

            ForEach(Array(rest.enumerated()), id: \.element.id) { index, service in
                if service.serviceId == last?.serviceId {
                    // The last train, displaced by a followed one, keeps a heading of its
                    // own rather than a tag crammed onto its detail line.
                    heading("Last train", colour: Theme.lastTrainRedLit)
                } else if index == 0 || rest[index - 1].role != service.role {
                    if service.role == .first {
                        heading(sectionTitle(for: service.role, board: board), colour: Theme.serviceBlueLit)
                    } else {
                        heading(otherLastTitle, colour: Theme.serviceBlueLit)
                    }
                }
                serviceRow(service, board: board)
            }
        }
        .padding(.top, 8)
        .opacity(model.isLoading ? 0.42 : 1)
        .animation(.easeOut(duration: 0.16), value: model.isLoading)
    }

    func heading(_ text: String, colour: Color) -> some View {
        Text(text)
            .cathodeSection(colour)
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.top, 12)
            .padding(.bottom, 6)
    }

    func serviceRow(_ service: BoardDeparture, board: DepartureBoard) -> some View {
        let isLast = service.serviceId == board.lastTrain?.serviceId
        let heroId = (model.pinnedService ?? board.lastTrain)?.serviceId
        let isHero = service.serviceId == heroId
        // The pinned *departure*, not every train sharing its headcode: replacement buses
        // can share one, and only the train that floated should read as followed.
        let followed = service.serviceId == model.pinnedService?.serviceId
        return ServiceRow(
            service: service,
            isLastTrain: isLast,
            isRed: isHero,
            isFollowed: followed,
            onOpen: { presented = .service(sheetService(service, board: board)) },
            onFollow: {
                model.setPin(service, following: !followed)
                // Following ranks the journey higher among the recent ones.
                if !followed, let station = model.station, let destination = fast.destination {
                    JourneyStore.markFollowed(from: station, to: destination, direction: model.direction)
                }
            }
        )
    }

    func sheetService(_ service: BoardDeparture, board: DepartureBoard) -> SheetService {
        let isLast = service.serviceId == board.lastTrain?.serviceId
        let heroId = (model.pinnedService ?? board.lastTrain)?.serviceId
        let isHero = service.serviceId == heroId
        let followed = service.serviceId == model.pinnedService?.serviceId
        let topLabel: String? = isLast ? "Last train" : (followed ? "Following" : nil)
        return SheetService(
            serviceId: service.serviceId,
            dep: service.liveDep,
            destination: service.destination,
            tocName: service.tocName,
            platform: service.platform,
            isReplacementBus: service.isReplacementBus,
            headcode: service.headcode,
            topLabel: topLabel,
            isRed: isHero
        )
    }

    func sectionTitle(for role: ServiceRole, board: DepartureBoard) -> String {
        switch role {
        // The earlier/later group names itself relative to the hero in `cathodeBoard`;
        // this stays for the first-back group, whose name is absolute.
        case .last: "Earlier trains"
        case .first: board.mode == .normal ? "First back" : "First trains"
        }
    }

    var loadingBoard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Rectangle().fill(Theme.control.opacity(0.55)).frame(height: 180)
            ForEach(0..<3, id: \.self) { _ in
                Rectangle().fill(Theme.control.opacity(0.42)).frame(height: 74)
            }
        }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.top, 18)
        .accessibilityLabel("Loading departures")
    }

    /// The recovery control on an error notice, in the same blue-outlined capsule as every
    /// other control. Plain white text read as body copy — the one thing to tap did not look
    /// like a thing to tap.
    func retryButton(_ action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .bold))
                Text("Try again").font(.system(.footnote, design: .rounded).weight(.semibold))
            }
            .foregroundStyle(Theme.serviceBlueLit)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .overlay(Capsule().stroke(Theme.serviceBlueLit.opacity(0.5), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(PressDim())
        .frame(minHeight: 48, alignment: .leading)
        .accessibilityLabel("Try again")
    }

    /**
     The one line under the bar before a journey is set, the same in both modes:
     "Tap Where? or the arrow to pick a station", then "Choose a direction or a destination", then,
     in Fast Train, "Choose a destination". No heading above it — the bar already asks
     "Where?", and a heading only said the same thing again. A tap does the step it names.
     */
    func stepHint(_ text: String, action: @escaping () -> Void) -> some View {
        StepHint(text: text, action: action)
    }

    func notice(
        title: String,
        body: String,
        @ViewBuilder action: () -> some View = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Theme.Font.heading)
            Text(body).font(Theme.Font.body).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            action()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.top, 34)
    }
}

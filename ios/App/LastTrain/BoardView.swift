import SwiftUI

import LastTrainCore

/**
 THESIS: One luminous departure answer in a dark field; refuses the card-stack timetable.
 OWN-WORLD: Ink gauze, ghost numerals, white copy, service blue, and last-train red only.
 STORY: Confirm station and direction, read the final train, scan earlier and first-back times.
 FIRST VIEWPORT: Compact mode switch above station context, directional rail, then the giant final time.
 FORM: Cathode Gauze operating surface; the selected Fast Train receives one forward signal strike.
 FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
 */
struct BoardView: View {
    @State private var model = BoardModel()
    @State private var fast = FastModel()
    @State private var mode: AppMode = .last
    @State private var pickingStation = false
    @State private var inspecting: BoardDeparture?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ZStack {
            CathodeBackdrop(tint: Theme.serviceBlueLit)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    masthead
                    stationHeader

                    if let station = model.station {
                        DirectionControl(
                            available: model.available,
                            towards: model.towards,
                            selection: $model.direction,
                            onTap: mode == .fast ? { _ in fast.askWhereTo() } : nil
                        )
                        .padding(.top, 14)

                        switch mode {
                        case .last: lastTrainResults
                        case .fast:
                            FastBoardView(station: station, direction: model.direction, model: fast)
                        }
                    } else {
                        notice(
                            title: "Choose where you are",
                            body: "Pick a station, then the direction your train is heading."
                        )
                    }

                    footnote
                }
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
        }
        .foregroundStyle(Theme.text)
        .modifier(
            BoardHaptics(
                direction: model.direction,
                dayIndex: model.dayIndex,
                page: fast.page,
                pinChanges: model.pinChanges,
                activityChanges: fast.activityChanges,
                nearbyCount: model.nearby.count,
                locateError: model.locateError,
                errorMessage: model.errorMessage
            )
        )
        .refreshable { await model.load(refresh: true) }
        .task { await model.load() }
        .task {
            await TrainActivityController.tidy()
            fast.syncActivityState()
        }
        .task(id: fastKey) {
            guard mode == .fast, let station = model.station else { return }
            await fast.load(at: station, direction: model.direction)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await TrainActivityController.tidy()
                fast.syncActivityState()
            }
        }
        .onOpenURL { model.open($0) }
        .sheet(isPresented: $pickingStation) { StationPicker(selection: $model.station) }
        .sheet(item: $inspecting) { service in
            if let station = model.station {
                ServiceSheet(
                    service: service,
                    station: station,
                    direction: model.direction,
                    isLastTrain: service.serviceId == model.board?.lastTrain?.serviceId,
                    isPinned: model.isPinned(service),
                    onPin: { following in
                        model.setPin(service, following: following)
                        inspecting = nil
                    }
                )
            }
        }
    }

    private var fastKey: String {
        "\(mode.rawValue):\(model.station?.crs ?? "-"):\(model.direction.rawValue):\(fast.destination?.crs ?? "-"):\(fast.selectionToken)"
    }

    // MARK: - Header

    private var masthead: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                wordmark
                Spacer(minLength: 10)
                modeControl
            }
            VStack(alignment: .leading, spacing: 12) {
                wordmark
                modeControl.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.top, 18)
    }

    private var wordmark: some View {
        Text(mode == .last ? "LAST TRAIN" : "FAST TRAIN")
            .font(.system(.headline, design: .rounded).weight(.semibold))
            .tracking(4.2)
            .foregroundStyle(mode == .last ? Theme.text : Theme.serviceBlueLit)
            .shadow(color: Theme.serviceBlue.opacity(0.6), radius: 8)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var modeControl: some View {
        HStack(spacing: 0) {
            modeButton(.last, icon: "tram.fill")
            modeButton(.fast, icon: "bolt.fill")
        }
        .padding(3)
        .background(Theme.surface.opacity(0.82))
        .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
        .clipShape(Capsule())
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func modeButton(_ target: AppMode, icon: String) -> some View {
        Button {
            mode = target
        } label: {
            Group {
                if typeSize.isAccessibilitySize {
                    Image(systemName: icon)
                        .font(.title3.weight(.semibold))
                } else {
                    Label(target == .last ? "Last" : "Fast", systemImage: icon)
                        .font(Theme.Font.label)
                }
            }
            .foregroundStyle(mode == target ? Theme.text : Theme.textFaint)
            .padding(.horizontal, typeSize.isAccessibilitySize ? 14 : 12)
            .frame(minWidth: 48, minHeight: 42)
            .background(mode == target ? Theme.control : Color.clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PressDim())
        .accessibilityLabel(target == .last ? "Last Train" : "Fast Train")
        .accessibilityAddTraits(mode == target ? .isSelected : [])
    }

    private var stationHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                model.clearNearby()
                pickingStation = true
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.station?.name.withoutLondonPrefix ?? "Choose station")
                            .font(.system(.largeTitle, design: .rounded).weight(.medium))
                            .foregroundStyle(model.station == nil ? Theme.textDim : Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                        if model.station != nil {
                            Text(model.direction.rawValue)
                                .labelStyle(Theme.serviceBlueLit)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.textDim)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressDim())
            .accessibilityLabel("Departure station, \(model.station?.name ?? "not selected")")

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    locateControl
                    dayControl
                }
                VStack(alignment: .leading, spacing: 0) {
                    locateControl
                    dayControl
                }
            }

            if let locateError = model.locateError {
                Text(locateError).font(Theme.Font.meta).foregroundStyle(Theme.textDim)
            }

            if model.nearby.count > 1 { nearbyStations }
        }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.top, 22)
    }

    @ViewBuilder
    private var dayControl: some View {
        if mode == .last {
            HStack(spacing: 8) {
                if model.dayIndex > 0 {
                    Button("Today") { model.returnToToday() }
                }
                Text(model.dayIndex == 0 ? "Today" : ServiceDay.formatWeekday(model.shownDate) ?? "")
                    .foregroundStyle(Theme.text)
                Button {
                    model.stepForward()
                } label: {
                    Image(systemName: model.stepWrapsToToday ? "arrow.uturn.backward" : "chevron.right")
                }
                .accessibilityLabel(model.stepWrapsToToday ? "Back to today" : "Next service day")
            }
            .font(Theme.Font.meta)
            .foregroundStyle(Theme.textDim)
            .frame(minHeight: 44)
            .fixedSize(horizontal: true, vertical: false)
        } else if fast.canPage {
            HStack(spacing: 8) {
                Text(fast.isOnFirstPage ? "Now" : "Page \(fast.page + 1)")
                Button {
                    fast.advance()
                } label: {
                    Image(systemName: fast.pageWrapsToNow ? "arrow.uturn.backward" : "chevron.right")
                }
                .accessibilityLabel(fast.pageWrapsToNow ? "Back to now" : "Next three trains")
            }
            .font(Theme.Font.meta)
            .foregroundStyle(Theme.textDim)
            .frame(minHeight: 44)
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var locateControl: some View {
        Button {
            Task { await model.locate() }
        } label: {
            HStack(spacing: 7) {
                if model.isLocating { ProgressView().tint(Theme.textDim) }
                else { Image(systemName: "location.fill") }
                Text("Nearest")
            }
            .font(Theme.Font.meta)
            .foregroundStyle(Theme.textDim)
            .frame(minHeight: 44)
            .fixedSize(horizontal: true, vertical: false)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressDim())
        .disabled(model.isLocating)
    }

    private var nearbyStations: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.nearby, id: \.station.crs) { candidate in
                    Button {
                        model.station = candidate.station
                    } label: {
                        Text("\(candidate.station.name.withoutLondonPrefix)  \(candidate.distanceLabel)")
                            .font(Theme.Font.meta)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 40)
                            .background(Theme.control.opacity(0.72), in: Capsule())
                    }
                    .buttonStyle(PressDim())
                }
            }
        }
    }

    // MARK: - Last Train

    @ViewBuilder
    private var lastTrainResults: some View {
        if let message = model.errorMessage {
            notice(title: "Couldn’t look that up", body: message) {
                Button("Try again") { Task { await model.load(refresh: true) } }
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.text)
                    .frame(minHeight: 48)
            }
        } else if model.isLoading && model.board == nil {
            loadingBoard
        } else if let board = model.board {
            if board.services.isEmpty {
                notice(
                    title: "Nothing \(board.direction.rawValue)bound",
                    body: "No trains run this way on \(ServiceDay.formatServiceDate(board.date) ?? board.date)."
                )
            } else {
                cathodeBoard(board)
            }
        }
    }

    private func cathodeBoard(_ board: DepartureBoard) -> some View {
        let last = board.lastTrain
        let remaining = board.services.filter { $0.serviceId != last?.serviceId }

        return VStack(alignment: .leading, spacing: 0) {
            if let last {
                lastTrainHero(last)
                    .contentShape(Rectangle())
                    .onTapGesture { inspecting = last }
            }

            ForEach(Array(remaining.enumerated()), id: \.element.id) { index, service in
                if index == 0 || remaining[index - 1].role != service.role {
                    Text(sectionTitle(for: service.role, board: board))
                        .cathodeSection(service.role == .first ? Theme.serviceBlueLit : Theme.textDim)
                        .padding(.horizontal, Theme.Space.gutter)
                        .padding(.top, Theme.Space.section)
                        .padding(.bottom, 8)
                }
                ServiceRow(
                    service: service,
                    isLastTrain: false,
                    isPinned: model.isPinned(service)
                )
                .contentShape(Rectangle())
                .onTapGesture { inspecting = service }
            }
        }
        .opacity(model.isLoading ? 0.42 : 1)
        .animation(.easeOut(duration: 0.16), value: model.isLoading)
    }

    private func lastTrainHero(_ service: BoardDeparture) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .center) {
                VStack(spacing: -4) {
                    CathodeNumber(text: "22:58", colour: Theme.lastTrainRedLit, scale: .row)
                    CathodeNumber(text: "23:18", colour: Theme.lastTrainRedLit, scale: .row)
                    CathodeNumber(text: "23:32", colour: Theme.lastTrainRedLit, scale: .row)
                }
                    .opacity(0.12)
                    .accessibilityHidden(true)

                CathodeNumber(text: service.dep, colour: Theme.lastTrainRedLit, scale: .hero)
                    .frame(maxWidth: .infinity)
            }
            .frame(minHeight: typeSize.isAccessibilitySize ? 150 : 165)
            .background(CathodeGauze(tint: Theme.lastTrainRed, density: 10))

            Text("Last train").cathodeSection(Theme.lastTrainRedLit)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(service.destination.withoutLondonPrefix)
                    .font(.system(.title, design: .rounded).weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .foregroundStyle(Theme.lastTrainRedLit)
            }
            .padding(.top, 12)

            Text(serviceMeta(service))
                .font(Theme.Font.meta)
                .foregroundStyle(Theme.textDim)
                .padding(.top, 5)
        }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Last train, \(ServiceDay.formatClock(service.dep).spoken), towards \(service.destination)"
        )
        .accessibilityHint("Shows calling points and widget controls")
    }

    private func sectionTitle(for role: ServiceRole, board: DepartureBoard) -> String {
        switch role {
        case .last: "Earlier trains"
        case .first: board.mode == .normal ? "First back" : "First trains"
        }
    }

    private func serviceMeta(_ service: BoardDeparture) -> String {
        var parts = [service.tocName]
        if let platform = service.platform { parts.append("Platform \(platform)") }
        if service.isReplacementBus { parts.append("Replacement bus") }
        return parts.joined(separator: " · ")
    }

    private var loadingBoard: some View {
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

    private func notice(
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

    private var footnote: some View {
        Text("Direct services only. Timetables follow the railway service day to 03:00.")
            .font(Theme.Font.meta)
            .foregroundStyle(Theme.textFaint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.top, 30)
    }
}

struct StationPicker: View {
    @Binding var selection: Station?
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            ZStack {
                CathodeBackdrop()
                List(matches, id: \.crs) { station in
                    Button {
                        selection = station
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(station.name).font(Theme.Font.destination).foregroundStyle(Theme.text)
                                if let locality = station.locality {
                                    Text(locality).font(Theme.Font.meta).foregroundStyle(Theme.textFaint)
                                }
                            }
                            Spacer(minLength: 0)
                            Text(station.crs).font(Theme.Font.meta.monospaced()).foregroundStyle(Theme.serviceBlueLit)
                        }
                        .padding(.vertical, 6)
                    }
                    .listRowBackground(Theme.surface.opacity(0.62))
                }
                .scrollContentBackground(.hidden)
                .listStyle(.plain)
            }
            .searchable(text: $query, prompt: "Station or code")
            .navigationTitle("From")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
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
            .sorted { $0.1 == $1.1 ? $0.0.name < $1.0.name : $0.1 < $1.1 }
            .prefix(60)
            .map(\.0)
    }
}

struct BoardHaptics: ViewModifier {
    let direction: Compass
    let dayIndex: Int
    let page: Int
    let pinChanges: Int
    let activityChanges: Int
    let nearbyCount: Int
    let locateError: String?
    let errorMessage: String?

    func body(content: Content) -> some View {
        content
            .sensoryFeedback(.selection, trigger: direction)
            .sensoryFeedback(.selection, trigger: dayIndex)
            .sensoryFeedback(.selection, trigger: page)
            .sensoryFeedback(.success, trigger: pinChanges)
            .sensoryFeedback(.success, trigger: activityChanges)
            .sensoryFeedback(trigger: nearbyCount) { old, new in new > 0 && old == 0 ? .success : nil }
            .sensoryFeedback(trigger: locateError) { _, new in new == nil ? nil : .warning }
            .sensoryFeedback(trigger: errorMessage) { _, new in new == nil ? nil : .error }
    }
}

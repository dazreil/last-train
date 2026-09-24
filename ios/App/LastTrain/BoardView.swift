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

/// The one sheet the board presents, over one binding. SwiftUI is unreliable with several
/// `.sheet` modifiers stacked on a single view — presenting and dismissing begin to fight,
/// and a tap could wedge with nothing dismissable — so start, nearby, destination and the
/// service detail all route through this instead.
private enum PresentedSheet: Identifiable {
    case start
    case nearby
    case destination
    case settings
    case service(SheetService)

    var id: String {
        switch self {
        case .start: "start"
        case .nearby: "nearby"
        case .destination: "destination"
        case .settings: "settings"
        case .service(let service): "service-\(service.id)"
        }
    }
}

struct BoardView: View {
    @State private var model = BoardModel()
    @State private var fast = FastModel()
    @State private var mode: AppMode = .last
    @State private var presented: PresentedSheet?
    /// Whether a direction has been chosen for the station on screen. True on open — the
    /// remembered journey shows at once — and set false by a clear, so a freshly picked
    /// station asks which way before it names a train rather than assuming west.
    @State private var directionChosen = true
    /// The top safe-area inset, measured so the scroll-edge fade covers exactly the status
    /// bar and Dynamic Island — no more, so it never dims the masthead at rest.
    @State private var topInset: CGFloat = 0
    /// True while a refresh asked for by holding the masthead is in flight.
    @State private var isRefreshing = false
    /// Bumped on each hold-to-refresh, to fire the haptic.
    @State private var refreshRequests = 0
    /// True while a reversed journey's direction is being looked up.
    @State private var isSwapping = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            CathodeBackdrop(tint: Theme.serviceBlueLit)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    masthead
                    stationHeader

                    if let station = model.station {
                        switch mode {
                        case .last:
                            // A freshly picked station asks which way before it shows a
                            // board — the same beat Fast Train has, where the destination is
                            // chosen first. The remembered journey skips it: it opens chosen.
                            if directionChosen { lastTrainResults } else { directionPrompt }
                        case .fast:
                            FastBoardView(
                                station: station,
                                direction: model.direction,
                                model: fast,
                                onInspect: { presented = .service($0) }
                            )
                        }
                    } else {
                        notice(
                            title: "Choose where you are",
                            body: "Pick a station, then where you are going."
                        )
                    }
                }
                // A little room past the last row and no more. This was 30 points, and on
                // its own it made a board that fitted the screen scroll a little.
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
            // Runs under the home indicator rather than stopping above it: those 34 points
            // are what let the board fit at one text size larger than the default, which
            // is where a phone set a notch bigger stopped fitting and began to scroll.
            .ignoresSafeArea(.container, edges: .bottom)
            // No scrolling, and no bounce, while the board fits the screen — which it does
            // on a current phone at normal text sizes. It still scrolls when it cannot fit,
            // on a small phone or at large text, because a board you cannot reach the
            // bottom of has silently dropped its first train back.
            .scrollBounceBehavior(.basedOnSize)

            // The wordmark used to slide up behind the status bar and Dynamic Island, colliding
            // with the clock and reading "LAST TRAI … AIN" under the pill. This fade sits over
            // the top inset only, so content dissolves into the tube before it reaches the
            // island rather than crossing behind it.
            LinearGradient(
                colors: [Theme.ink, Theme.ink, Theme.ink.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: topInset + 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
        }
        .background {
            // Measure the top inset without disturbing layout.
            GeometryReader { proxy in
                Color.clear
                    .onAppear { topInset = proxy.safeAreaInsets.top }
                    .onChange(of: proxy.safeAreaInsets.top) { _, value in topInset = value }
            }
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
        .task { model.scheduleLoad() }
        .task {
            await TrainActivityController.tidy()
            fast.syncActivityState()
        }
        /*
         Fast Train loads whenever there is a journey, in either mode, so switching to it is
         instant rather than a wait on the network. It costs no Realtime Trains quota: the
         answer comes from Darwin and the timetable store, with RTT only as a fallback.
         The short wait lets a burst of changes — a swap sets three things — settle into
         one request.
        */
        .task(id: fastKey) {
            guard let station = model.station, fast.destination != nil else { return }
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            await fast.load(at: station, direction: model.direction)
        }
        // Loaded in the background, it may have aged by the time you look: switching to
        // Fast Train refreshes a board over a minute old.
        .onChange(of: mode) { _, now in
            guard now == .fast, let station = model.station, fast.destination != nil else { return }
            if let updated = fast.updatedAt, Date().timeIntervalSince(updated) < 60 { return }
            Task { await fast.load(at: station, direction: model.direction) }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await TrainActivityController.tidy()
                fast.syncActivityState()
                // Back in hand on the platform: reload if the board has aged or the service
                // day has rolled under it, so it is never the stale times from your pocket.
                if model.isStale {
                    if mode == .fast, let station = model.station {
                        await fast.load(at: station, direction: model.direction, refresh: true)
                    }
                    await model.load(refresh: true)
                }
            }
        }
        .onOpenURL { model.open($0) }
        // The destination is half the bar in both modes now, so it is read here rather
        // than inside Fast Train's view — Last Train shows it too.
        .task(id: "\(model.station?.crs ?? "-"):\(model.direction.rawValue):\(directionChosen)") {
            guard let station = model.station else { return }
            // No direction yet means no journey yet. A destination remembered under the
            // direction the app happens to be holding would appear unasked, and name a
            // journey you never chose — so nothing is adopted, and nothing is forgotten
            // either: choose that direction later and it comes back.
            if directionChosen {
                fast.adopt(station: station, direction: model.direction)
            } else {
                fast.release()
            }
            model.destinationCrs = fast.destination?.crs
            prefetchDestinations(from: station)
        }
        // Both modes ask the same pair now, so the destination has to reach the Last
        // Train query too — not only Fast Train's.
        .onChange(of: fast.destination?.crs) { _, latest in
            model.destinationCrs = latest
        }
        // Fast Train sets `fast.isChoosing` when it needs a destination; bridge that into the
        // single presentation so there is still only one sheet, and clear it on any dismiss.
        .onChange(of: fast.isChoosing) { _, choosing in
            if choosing { presented = .destination }
        }
        .sheet(item: $presented, onDismiss: { fast.isChoosing = false }) { which in
            switch which {
            case .start:
                if let end = fast.destination {
                    // Editing the start: the valid origins are exactly the places that reach
                    // your destination from the other side. Clear empties the journey, and
                    // with no destination left this same case becomes the plain search below.
                    LinePicker(
                        from: end,
                        direction: model.direction.opposite,
                        date: model.requestedDate,
                        title: "\(model.direction.opposite.rawValue.capitalized) of \(end.crs)",
                        selectedCrs: model.station?.crs,
                        searchesEverywhere: true,
                        onClear: { clearJourney() }
                    ) { picked, onLine, _ in
                        adoptStart(picked, keepingDestination: onLine)
                    }
                } else {
                    // Nothing to work back from yet, so this is the plain search.
                    StationPicker(selection: freshStart, nearby: model.nearby)
                }
            case .nearby:
                // The stations found near you, the same picker the code button opens — so
                // location and search share one list rather than one adding chips to the board.
                StationPicker(selection: freshStart, nearby: model.nearby)
            case .destination:
                if let start = model.station {
                    // Before a direction is chosen, every direction, grouped — and the row
                    // tapped sets the direction. After, that direction only.
                    LinePicker(
                        from: start,
                        direction: directionChosen ? model.direction : nil,
                        date: model.requestedDate,
                        title: directionChosen
                            ? "\(model.direction.rawValue.capitalized) of \(start.crs)"
                            : "Direct from \(start.crs)",
                        selectedCrs: fast.destination?.crs
                    ) { picked, onLine, heading in
                        adoptEnd(picked, from: start, onLine: onLine, heading: heading)
                    }
                }
            case .service(let sheet):
                if let station = model.station {
                    ServiceSheet(
                        service: sheet,
                        station: station,
                        direction: model.direction,
                        destinationCrs: fast.destination?.crs
                    )
                }
            case .settings:
                SettingsView(current: currentJourney)
            }
        }
    }

    /// Refresh whichever board is on screen — not always Last Train, which once left a
    /// hold in Fast Train refreshing a hidden board.
    private func refresh() async {
        guard !isRefreshing else { return }
        refreshRequests += 1
        isRefreshing = true
        defer { isRefreshing = false }
        if mode == .fast, let station = model.station {
            await fast.load(at: station, direction: model.direction, refresh: true)
        } else {
            await model.load(refresh: true)
        }
    }

    /**
     Ask for the destination list before the picker is opened.

     The picker used to fetch on open and show grey rows while it waited. This sends the
     same request as soon as a station or direction changes, and the server marks the list
     reusable for a quarter of an hour, so by the time the picker asks the phone already
     has it. Today only: a future date can fall back to Realtime Trains, which costs quota.
     */
    private func prefetchDestinations(from station: Station) {
        guard model.requestedDate == nil else { return }
        let heading: Compass? = directionChosen ? model.direction : nil
        Task.detached(priority: .utility) {
            _ = try? await BoardClient(baseURL: AppConfig.apiBaseURL)
                .destinations(from: station.crs, direction: heading)
        }
    }

    /// The board on screen as a home journey, once it has both a station and a chosen
    /// direction. Offered by Settings as the thing to make home.
    private var currentJourney: HomeJourney? {
        guard directionChosen, let station = model.station else { return nil }
        return HomeJourney(station: station, direction: model.direction)
    }

    private var fastKey: String {
        "\(model.station?.crs ?? "-"):\(model.direction.rawValue):\(fast.destination?.crs ?? "-"):\(fast.selectionToken)"
    }

    // MARK: - Header

    /**
     The mode, and the only place it is named.

     `PRODUCT.md` always had Fast Train reached "by a deliberate tap on the title"; the
     segmented pill came later, and then the screen said the same word twice — once as a
     heading and once as a control. This is the two merged back into one: the mode you are
     in reads in full, and the one you are not sits beside it, dim and a tap away.

     Same grammar as the direction row below it — the choices inline, the live one lit,
     the rest quiet — so the header, the journey and the compass read as one instrument
     instead of three unrelated controls.
     */
    private var masthead: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(mode.wordmark)
                .font(.system(.headline, design: .rounded).weight(.semibold))
                .tracking(4.2)
                // Blue in both modes. The lit word is the one you are in; which question
                // it is, the word itself already says.
                .foregroundStyle(Theme.serviceBlueLit)
                .shadow(color: Theme.serviceBlue.opacity(0.6), radius: 8)
                // Shrinks rather than holding its width: at the larger text sizes the two
                // words and the gear no longer fit, and a masthead that will not give way
                // widens the whole page past the screen edges.
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .layoutPriority(1)
                .accessibilityAddTraits(.isHeader)

            Button {
                withAnimation(.snappy(duration: 0.24)) { mode = mode.other }
            } label: {
                Text(mode.other.wordmark)
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .tracking(Theme.tracking)
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressDim())
            .accessibilityLabel(
                mode.other == .last ? "Switch to Last Train" : "Switch to Fast Train"
            )

            Spacer(minLength: 0)

            // Home journey, credits and the facts the footer used to carry. The footer
            // pushed the board into scrolling; this costs nothing on the board itself.
            Button { presented = .settings } label: {
                Group {
                    if isRefreshing {
                        ProgressView().tint(Theme.textDim)
                    } else {
                        Image(systemName: "gearshape")
                            .font(.system(.body, design: .rounded).weight(.semibold))
                            .foregroundStyle(Theme.textFaint)
                    }
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressDim())
            .accessibilityLabel("Settings and credits")
        }
        /*
         Hold the masthead to refresh. It replaced pull-to-refresh, which needed the board
         to scroll: a board that moves under a thumb on a platform reads as a web page, and
         a refresh by accident costs an upstream request. Holding is deliberate and works
         one-handed. Returning to the app after a minute already refreshes on its own, so
         this is for the case where you want it *now*.
         */
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.5) { Task { await refresh() } }
        .sensoryFeedback(.impact(weight: .medium), trigger: refreshRequests)
        .accessibilityAction(named: "Refresh") { Task { await refresh() } }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.top, 18)
    }

    /// The directions, inline under the station name. The chosen one leads, lit blue; the
    /// other available ones follow in grey; a direction that does not run from here keeps
    /// its slot but is invisible and dead, held to the right so the visible ones never
    /// shift. Every compass point owns one of four equal columns, so the spacing is the
    /// same whether a station offers two directions or four.
    private var directionPicker: some View {
        let selected = model.direction
        let available = model.available
        let avail = available.isEmpty
            ? [selected]
            : Compass.allCases.filter { available.contains($0) }
        let availableOrdered = [selected] + avail.filter { $0 != selected }
        let ordered = availableOrdered + Compass.allCases.filter { !avail.contains($0) }

        return HStack(spacing: 20) {
            ForEach(ordered, id: \.self) { direction in
                if avail.contains(direction) {
                    Button {
                        withAnimation(.snappy(duration: 0.28)) { model.direction = direction }
                        directionChosen = true
                        // Choosing a direction is choosing a new journey, so the old
                        // destination goes. Fast then opens the list of where to; Last needs
                        // no destination to name a last train, so it just shows this way.
                        if let station = model.station {
                            fast.clearDestination(at: station, direction: direction)
                            if mode == .fast { fast.askWhereTo() }
                        }
                    } label: {
                        directionLabel(direction, isSelected: directionChosen && direction == selected)
                    }
                    .buttonStyle(PressDim())
                    .accessibilityLabel(direction.rawValue.capitalized)
                    .accessibilityValue(model.towards[direction].map { "towards \($0)" } ?? "")
                    .accessibilityAddTraits(directionChosen && direction == selected ? .isSelected : [])
                } else {
                    // The slot is held, not filled: invisible and untappable, so a missing
                    // direction costs no realignment of the ones that are there.
                    directionLabel(direction, isSelected: false)
                        .opacity(0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            // Words are their own width now, so the row needs telling where to sit.
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Direction")
    }

    /// One direction word in its column: blue when it is the chosen one, grey otherwise,
    /// always the same size so a missing point never changes the layout.
    private func directionLabel(_ direction: Compass, isSelected: Bool) -> some View {
        Text(direction.rawValue)
            .font(.system(.subheadline, design: .rounded).weight(.bold))
            .tracking(Theme.tracking)
            .textCase(.uppercase)
            .foregroundStyle(isSelected ? Theme.serviceBlueLit : Theme.textDim)
            .lineLimit(1)
            // Sized to the word, not to a share of the row. Equal columns put an equal
            // *box* around each, which is not the same as an equal gap between them:
            // SOUTH is a letter longer than EAST and WEST, so leading the row it filled
            // more of its column and the space after it closed up. The eye reads the gap,
            // so the gap is what is held constant.
            .fixedSize(horizontal: true, vertical: false)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }

    /**
     Where you are and where you are going, as two codes.

     `UPM → BKG`. The name is gone from the title because the code is what the railway
     prints on its own signage, it is read at a glance in the dark, and two of them fit
     where one name did. Either half is its own tap target and edits without disturbing
     the other; the full name is always one tap away in the list that opens.
     */
    private var journeyBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            codeButton(
                model.station?.crs,
                placeholder: "Where?",
                label: "Departure station, \(model.station?.name ?? "not set")"
            ) {
                model.clearNearby()
                presented = .start
            }

            if model.station != nil {
                Image(systemName: "arrow.right")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.textDim)
                    .accessibilityHidden(true)

                codeButton(
                    fast.destination?.crs,
                    placeholder: "—",
                    label: "Destination, \(fast.destination?.name ?? "not set")"
                ) {
                    fast.askWhereTo()
                }
            }

            Spacer(minLength: 8)

            // Locate is always here — at "Where?" it is the fastest way to fill the box,
            // which is exactly when it used to hide. Clear only appears once there is a
            // journey to clear.
            locateButton
            if model.station != nil, fast.destination != nil { swapButton }
            if model.station != nil { clearButton }
        }
    }

    /// Wipes the chosen journey back to the "Where?" prompt. Sits next to the locate
    /// button because clearing and re-finding are the two things you do to the pair.
    private var clearButton: some View {
        Button {
            clearJourney()
        } label: {
            Image(systemName: "xmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.textDim)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressDim())
        .accessibilityLabel("Clear journey")
    }

    /// Turns the journey round: `EUS → MKC` becomes `MKC → EUS`. Only there once both
    /// ends are set, since there is nothing to turn round before that.
    private var swapButton: some View {
        Button {
            Task { await swapJourney() }
        } label: {
            Group {
                if isSwapping { ProgressView().tint(Theme.textDim) }
                else { Image(systemName: "arrow.left.arrow.right") }
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(Theme.textDim)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressDim())
        .disabled(isSwapping)
        .accessibilityLabel("Reverse journey")
    }

    /**
     The way back, as its own journey.

     The direction is **asked for, not assumed to be the opposite one**. A destination's
     direction has to be the board's own rule, or the reversed board opens empty — and on a
     line that turns, like the Tilbury loop, the way back is not always the mirror of the
     way out. So the unfiltered list from the far end is read, and the old start's
     direction taken from it. Only if that fails does the opposite stand in.

     Filed before the station and direction change, for the reason `adoptEnd` gives:
     changing either re-reads what is filed, and would otherwise find nothing.
     */
    private func swapJourney() async {
        guard !isSwapping, let start = model.station, let end = fast.destination else { return }
        isSwapping = true
        defer { isSwapping = false }

        let client = BoardClient(baseURL: AppConfig.apiBaseURL)
        let list = try? await client.destinations(
            from: end.crs,
            direction: nil,
            date: model.requestedDate
        )
        let heading = list?.destinations.first(where: { $0.crs == start.crs })?.direction
        let direction = heading ?? model.direction.opposite

        fast.choose(start, at: end, direction: direction)
        directionChosen = true
        model.direction = direction
        model.station = end
    }

    private func clearJourney() {
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

    /// Shown when a station has been picked but no direction chosen yet. The compass row
    /// above is where the answer is; this only names the question.
    private var directionPrompt: some View {
        notice(
            title: "Which way?",
            // Either answers it: a destination sets the direction by itself.
            body: "Pick where you are going, or the direction your train is heading, above."
        )
    }

    /**
     A new start, keeping the destination only if a train still runs between them.

     `onLine` is the whole reset rule. It is true when the station came from the list,
     which was built from the destination's own reachable set — so the pair is valid by
     construction, and the destination is simply re-filed under the new pair. It is false
     when the station came from the search box, which knows all 2,619 stations and nothing
     about this journey: that is a new journey, and the destination goes.

     The destination is stored per start-and-direction, so keeping it means writing it
     under the new start rather than merely not deleting it.
     */
    private func adoptStart(_ picked: Station, keepingDestination: Bool) {
        if keepingDestination, let end = fast.destination {
            fast.choose(end, at: picked, direction: model.direction)
        } else {
            fast.clearDestination(at: picked, direction: model.direction)
            // A new journey from somewhere else: the old direction was about the old
            // station, and may not even run from this one.
            directionChosen = false
        }
        model.station = picked
    }

    /**
     The station, picked from the plain search or from near you.

     Always a new journey, so the direction goes back to unchosen when the station actually
     changes: "west" meant something at the last station and may mean nothing here. The
     destination sheet then offers every direction, and the destination picks one.
     */
    private var freshStart: Binding<Station?> {
        Binding(
            get: { model.station },
            set: { picked in
                if picked?.crs != model.station?.crs { directionChosen = false }
                model.station = picked
            }
        )
    }

    /**
     A new destination, and — when no direction was chosen — the direction with it.

     `heading` is the section the tapped row sat in, so it is the way a direct train goes
     there, by construction. The order matters: the destination is filed under the new
     direction **before** the direction changes, because changing it re-reads whatever is
     filed there, and would otherwise find nothing.
     */
    private func adoptEnd(_ picked: Station, from start: Station, onLine: Bool, heading: Compass?) {
        guard onLine else {
            fast.clearDestination(at: picked, direction: model.direction)
            directionChosen = false
            model.station = picked
            return
        }
        let direction = directionChosen ? model.direction : (heading ?? model.direction)
        fast.choose(picked, at: start, direction: direction)
        directionChosen = true
        model.direction = direction
    }

    /// One half of the bar. Dim and named while empty, lit and coded once set.
    private func codeButton(
        _ crs: String?,
        placeholder: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(crs ?? placeholder)
                .font(.system(.largeTitle, design: .rounded).weight(.medium))
                .monospacedDigit()
                .foregroundStyle(crs == nil ? Theme.textDim : Theme.text)
                .lineLimit(1)
                // Shrinks rather than holding its width, so two codes and three buttons
                // still fit the bar at large text instead of widening the page.
                .minimumScaleFactor(0.6)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressDim())
        .accessibilityLabel(label)
    }

    private var stationHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            journeyBar

            if model.station != nil { directionPicker }

            if mode == .last || fast.canPage { dayControl }

            if let locateError = model.locateError {
                Text(locateError).font(Theme.Font.meta).foregroundStyle(Theme.textDim)
            }
        }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.top, 16)
    }

    /// The nearest-station control, now an arrow alone in the station box — the label went
    /// to save the room, the action did not.
    private var locateButton: some View {
        Button {
            Task {
                await model.locate()
                // Found some — offer them in the picker. A failure leaves the one-line
                // reason under the bar instead.
                if !model.nearby.isEmpty { presented = .nearby }
            }
        } label: {
            Group {
                if model.isLocating { ProgressView().tint(Theme.textDim) }
                else { Image(systemName: "location.fill") }
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(Theme.textDim)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressDim())
        .disabled(model.isLocating)
        .accessibilityLabel("Nearest station")
    }

    /// The date stepper (Last) and the page stepper (Fast), named the way the main design
    /// names them: three slots — the way back, where you are, and where the next tap lands.
    /// Days read Today · Wed · Thurs; pages read 1st · 2nd · 3rd.
    @ViewBuilder
    private var dayControl: some View {
        HStack(alignment: .center, spacing: 7) {
            dayPagerSlots
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
    }

    @ViewBuilder
    private var dayPagerSlots: some View {
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
                accessibility: model.stepWrapsToToday ? "Back to today" : "Show the next day",
                value: ServiceDay.formatServiceDate(model.shownDate) ?? ""
            )
        case .fast:
            if !fast.isOnFirstPage && !fast.pageWrapsToNow { nowButton }
            stepLabel(Self.pageName(fast.page))
            stepButton(
                label: fast.pageWrapsToNow ? Self.pageName(0) : Self.pageName(fast.page + 1),
                // The later window loads itself on reaching the last page; while it does, hold
                // the step so a tap cannot wrap out from under the trains about to arrive.
                action: { if !fast.isLoadingLater { fast.advance() } },
                accessibility: fast.pageWrapsToNow ? "Back to the first three trains" : "Show the next three trains",
                value: "Page \(fast.page + 1) of \(fast.pageCount)"
            )
        }
    }

    /**
     Pages count themselves: 1st, 2nd, 3rd.

     They used to read Now · Two · Three, which mixed a position with a time and then
     needed a special case the moment the board rolled on to tomorrow — where nothing
     departs "now" and the word contradicted the heading above it. An ordinal says only
     where you are in the list, which is true on a live board and a next-day one alike.
     */
    private static func pageName(_ index: Int) -> String {
        let n = index + 1
        let suffix: String
        // 11th, 12th and 13th break the units rule and are the usual bug here, so they
        // are excluded before it is applied rather than after.
        if (11...13).contains(n % 100) {
            suffix = "th"
        } else {
            switch n % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(n)\(suffix)"
    }

    /// The middle slot: where you are, and not a control.
    /**
     One word in the day or page row, set exactly as a direction is.

     The two rows sit one above the other and were reading at different sizes in
     different colours, which made them look like different kinds of control rather than
     the same one asked twice. Lit blue means the same thing here as it does there: this
     is the one you are on.
     */
    private func stepText(_ text: String, lit: Bool) -> some View {
        Text(text)
            .font(.system(.subheadline, design: .rounded).weight(.bold))
            .tracking(Theme.tracking)
            .textCase(.uppercase)
            .foregroundStyle(lit ? Theme.serviceBlueLit : Theme.textDim)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func stepLabel(_ text: String) -> some View {
        stepText(text, lit: true)
            .padding(.vertical, 4)
    }

    /// The right slot: named rather than a bare chevron — a name says what the tap does.
    private func stepButton(
        label: String,
        action: @escaping () -> Void,
        accessibility: String,
        value: String? = nil
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                stepText(label, lit: false)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.textDim)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressDim())
        .accessibilityLabel(accessibility)
        .accessibilityValue(value ?? "")
    }

    /// The way back to the start, worn as a pill so it reads the same in either mode.
    private var todayButton: some View {
        Button { model.returnToToday() } label: { wayBackLabel("Today") }
            .buttonStyle(PressLift())
            .accessibilityLabel("Back to today")
    }

    private var nowButton: some View {
        Button { fast.now() } label: { wayBackLabel(Self.pageName(0)) }
            .buttonStyle(PressLift())
            .accessibilityLabel("Back to the trains from now")
    }

    private func wayBackLabel(_ text: String) -> some View {
        stepText(text, lit: false)
            .padding(.vertical, 4)
    }

    // MARK: - Last Train

    @ViewBuilder
    private var lastTrainResults: some View {
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
    private func boardBody(_ board: DepartureBoard) -> some View {
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
    private func staleNotice(_ message: String) -> some View {
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
    private func cathodeBoard(_ board: DepartureBoard) -> some View {
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

    private func preServiceBoard(_ board: DepartureBoard) -> some View {
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

    private func normalBoard(_ board: DepartureBoard) -> some View {
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

    private func heading(_ text: String, colour: Color) -> some View {
        Text(text)
            .cathodeSection(colour)
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.top, 12)
            .padding(.bottom, 6)
    }

    private func serviceRow(_ service: BoardDeparture, board: DepartureBoard) -> some View {
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
            onFollow: { model.setPin(service, following: !followed) }
        )
    }

    private func sheetService(_ service: BoardDeparture, board: DepartureBoard) -> SheetService {
        let isLast = service.serviceId == board.lastTrain?.serviceId
        let heroId = (model.pinnedService ?? board.lastTrain)?.serviceId
        let isHero = service.serviceId == heroId
        let followed = service.serviceId == model.pinnedService?.serviceId
        let topLabel: String? = isLast ? "Last train" : (followed ? "Following" : nil)
        return SheetService(
            serviceId: service.serviceId,
            dep: service.dep,
            destination: service.destination,
            tocName: service.tocName,
            platform: service.platform,
            isReplacementBus: service.isReplacementBus,
            headcode: service.headcode,
            topLabel: topLabel,
            isRed: isHero
        )
    }

    private func sectionTitle(for role: ServiceRole, board: DepartureBoard) -> String {
        switch role {
        // The earlier/later group names itself relative to the hero in `cathodeBoard`;
        // this stays for the first-back group, whose name is absolute.
        case .last: "Earlier trains"
        case .first: board.mode == .normal ? "First back" : "First trains"
        }
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

    /// The recovery control on an error notice, in the same blue-outlined capsule as every
    /// other control. Plain white text read as body copy — the one thing to tap did not look
    /// like a thing to tap.
    private func retryButton(_ action: @escaping () async -> Void) -> some View {
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
}

struct StationPicker: View {
    @Binding var selection: Station?
    /// The stations found near you, if you asked. Shown as a section above search until
    /// you start typing, so nearby lives in the picker rather than as chips on the board.
    var nearby: [Nearby<Station>] = []
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    /// Whether the search box is active, with the keyboard up.
    @State private var searching = false

    var body: some View {
        NavigationStack {
            ZStack {
                CathodeBackdrop()
                List {
                    if query.isEmpty && !nearby.isEmpty {
                        Section {
                            ForEach(nearby, id: \.station.crs) { candidate in
                                row(candidate.station, trailing: candidate.distanceLabel, colour: Theme.textDim)
                            }
                        } header: {
                            Text("Nearby").font(Theme.Font.meta).foregroundStyle(Theme.textDim)
                        }
                    }
                    if !matches.isEmpty {
                        Section {
                            ForEach(matches, id: \.crs) { station in
                                row(station, trailing: station.crs, colour: Theme.serviceBlueLit)
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .listStyle(.plain)
            }
            .task {
                // With no nearby list, typing is the only thing to do here, so start with
                // the keyboard up. With one, leave the list in view to tap. The search box
                // ignores the change while the sheet is still sliding up, so wait for that.
                guard nearby.isEmpty else { return }
                try? await Task.sleep(for: .milliseconds(350))
                searching = true
            }
            .searchable(text: $query, isPresented: $searching, prompt: "Station or code")
            .navigationTitle("From")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Same way out the destination picker has. Without it, opening this by
                // mistake left no exit but choosing a station you did not want.
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func row(_ station: Station, trailing: String, colour: Color) -> some View {
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
                Text(trailing).font(Theme.Font.meta.monospaced()).foregroundStyle(colour)
            }
            .padding(.vertical, 6)
        }
        .listRowBackground(Theme.surface.opacity(0.62))
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

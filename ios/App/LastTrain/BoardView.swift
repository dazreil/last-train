import SwiftUI
import WidgetKit

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
enum PresentedSheet: Identifiable {
    case start
    case nearby
    case destination
    case settings
    /// "Trains into" a station: pick where you would come from.
    case into(Station)
    case service(SheetService)

    var id: String {
        switch self {
        case .start: "start"
        case .nearby: "nearby"
        case .destination: "destination"
        case .settings: "settings"
        case .into(let station): "into-\(station.crs)"
        case .service(let service): "service-\(service.id)"
        }
    }
}

struct BoardView: View {
    @State var model = BoardModel()
    @State var fast = FastModel()
    /// Remembered across launches, like the journey: an app closed in the background and
    /// reopened comes back in the mode you left it in, not reset to Last Train.
    @AppStorage("lastTrain.mode") var mode: AppMode = .last
    @State var presented: PresentedSheet?
    /// Whether a direction has been chosen for the station on screen. Set false by a clear,
    /// by going home, and by picking a new station, so the board asks which way before it
    /// names a train rather than assuming west. Remembered across launches like the rest of
    /// the journey: an app left asking "which way?" reopens asking it, not on a guessed west.
    @AppStorage("lastTrain.directionChosen") var directionChosen = true
    /// The top safe-area inset, measured so the scroll-edge fade covers exactly the status
    /// bar and Dynamic Island — no more, so it never dims the masthead at rest.
    @State var topInset: CGFloat = 0
    /// True while a refresh asked for by holding the masthead is in flight.
    @State var isRefreshing = false
    /// Bumped on each hold-to-refresh, to fire the haptic.
    @State var refreshRequests = 0
    /// True while a reversed journey's direction is being looked up.
    @State var isSwapping = false
    /// True while a home is being chosen from the house menu: the next station picked
    /// becomes home.
    @State var settingHome = false
    /// The page's height, the space it has, and the row trim that makes one fit the
    /// other. See `fitRows`.
    @State var contentHeight: CGFloat = 0
    @State var viewportHeight: CGFloat = 0
    @State var rowSqueeze: CGFloat = 0
    /// Bumped when the home changes, so the bar re-reads it: the home lives in defaults,
    /// which observation cannot see.
    @State var homeRevision = 0
    @Environment(\.scenePhase) var scenePhase

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
                            if directionChosen {
                                lastTrainResults
                            } else {
                                directionPrompt
                                recentJourneysList(from: station)
                            }
                        case .fast:
                            FastBoardView(
                                station: station,
                                direction: model.direction,
                                hint: directionChosen ? "Choose a destination" : "Choose a direction or a destination",
                                model: fast,
                                onInspect: { presented = .service($0) }
                            )
                            // Nowhere to go yet: the journeys you have made from here.
                            if fast.destination == nil {
                                recentJourneysList(from: station)
                            }
                        }
                    } else {
                        stepHint("Tap Where? or the arrow to pick a station") {
                            model.clearNearby()
                            presented = .start
                        }
                        recentJourneysList(from: nil)
                    }
                }
                // A little room past the last row and no more. This was 30 points, and on
                // its own it made a board that fitted the screen scroll a little.
                .padding(.bottom, 12)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                    contentHeight = $0
                    fitRows()
                }
                .environment(\.rowSqueeze, rowSqueeze)
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                viewportHeight = $0
                fitRows()
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
                // A followed train that has left is unfollowed, in both modes.
                model.clearDepartedPin()
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
        .onOpenURL { url in
            // A link names its direction, so it is chosen. Without this, a link opened after
            // Clear landed on "Choose a direction" instead of the board it named.
            if model.open(url) { directionChosen = true }
        }
        // The station picked while setting a home becomes it, from whichever list it came.
        .onChange(of: model.station?.crs) {
            guard settingHome, let station = model.station else { return }
            HomeStation.store(HomeStation(station: station))
            settingHome = false
            homeRevision += 1
        }
        // Closing the picker without choosing a station abandons setting a home, so a later
        // ordinary journey does not become one by surprise.
        .onChange(of: presented?.id) { _, now in
            if now == nil, settingHome, model.station == nil { settingHome = false }
        }
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
            case .into(let end):
                // The stations with a direct train to `end`, every direction at once. The
                // board is untouched until one is picked, so cancelling changes nothing.
                LinePicker(
                    from: end,
                    direction: nil,
                    date: model.requestedDate,
                    title: "Trains into \(end.crs)",
                    selectedCrs: nil
                ) { picked, _, heading in
                    Task {
                        await adoptJourney(from: picked, to: end, fallback: heading?.opposite ?? model.direction)
                    }
                }
            case .settings:
                SettingsView(current: currentStation, onReset: resetApp)
            }
        }
    }

    /**
     Trim each row just enough for the page to fit, from 0 to `RowSqueeze.maximum`.

     Worked from the page's natural height — what it would be with no trim — so the answer
     does not chase its own effect: trimming shortens the page, and a rule reading only the
     shortened page would undo the trim on the next pass. Eight is two edges of four rows,
     the number a board carries; with more or fewer rows it lands close and settles.
     */
    func fitRows() {
        guard viewportHeight > 0, contentHeight > 0 else { return }
        let natural = contentHeight + rowSqueeze * 8
        let needed = ((natural - viewportHeight) / 8).rounded(.up)
        let squeeze = min(max(needed, 0), RowSqueeze.maximum)
        if squeeze != rowSqueeze { rowSqueeze = squeeze }
    }

    /// Refresh whichever board is on screen — not always Last Train, which once left a
    /// hold in Fast Train refreshing a hidden board.
    func refresh() async {
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
    func prefetchDestinations(from station: Station) {
        guard model.requestedDate == nil else { return }
        let heading: Compass? = directionChosen ? model.direction : nil
        Task.detached(priority: .utility) {
            _ = try? await BoardClient(baseURL: AppConfig.apiBaseURL)
                .destinations(from: station.crs, direction: heading)
        }
    }

    /// Everything the app remembers, back to how it was installed. `HOLD-MENUS.md` §3.
    /// The widget's own configuration is left alone: it is set on the widget.
    func resetApp() {
        HomeStation.store(nil)
        homeRevision += 1
        settingHome = false
        SharedSelection.clearAllDestinations()
        SharedSelection.setPin(nil, crs: "", direction: .west)
        UsageStore.clear()
        JourneyStore.clear()
        Task {
            await TrainActivityController.stop()
            fast.syncActivityState()
        }
        mode = .last
        model.clearNearby()
        fast.release()
        directionChosen = false
        model.direction = .west
        model.station = nil
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// The station on screen, offered by Settings as the thing to make home.
    var currentStation: HomeStation? {
        guard let station = model.station else { return nil }
        return HomeStation(station: station)
    }

    var fastKey: String {
        "\(model.station?.crs ?? "-"):\(model.direction.rawValue):\(fast.destination?.crs ?? "-"):\(fast.selectionToken)"
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

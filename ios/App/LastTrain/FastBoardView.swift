import SwiftUI

import LastTrainCore

struct FastBoardView: View {
    let station: Station
    let direction: Compass
    @Bindable var model: FastModel
    /// Opening a row hands the shared detail sheet up to `BoardView`, which owns it for
    /// both boards.
    let onInspect: (SheetService) -> Void

    var body: some View {
        // The destination used to be named again here. The two-code bar above shows it
        // now, and showing it twice on one screen was the redundancy the bar exists to end.
        VStack(alignment: .leading, spacing: 0) {
            if model.destination == nil {
                emptyPrompt
            } else {
                results
            }
        }
        .task(id: "\(station.crs):\(direction.rawValue)") {
            model.adopt(station: station, direction: direction)
            // Fast Train cannot answer without a destination, but it no longer opens the
            // picker for you: picking a station used to drop you straight into a sheet you
            // did not ask for. It rests on the prompt below instead, which is itself the tap.
        }
        // Reaching the last loaded page pulls in the two-to-four-hour window on its own, so
        // the pager grows to meet the trains rather than offering a page that isn't there.
        // Keyed on the page and the count so it re-checks after a fetch folds trains in.
        .task(id: "\(model.page):\(model.services.count):\(model.selectionToken)") {
            guard model.isOnLastLoadedPage else { return }
            await model.loadLater(at: station, direction: direction)
        }
    }

    /// The rest state before a destination is chosen. It is the tap that opens the picker,
    /// so choosing where to go is a deliberate act, not a sheet that springs up on you.
    private var emptyPrompt: some View {
        Button {
            model.askWhereTo()
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                Text("Where are you going?").font(Theme.Font.heading).foregroundStyle(Theme.text)
                Text("Tap to choose a direct destination. Fast Train ranks the next services by when they get you there.")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressDim())
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.top, 26)
    }

    @ViewBuilder
    private var results: some View {
        if let message = model.errorMessage {
            status(title: "Fast Train unavailable", body: message)
        } else if model.isLoading && model.services.isEmpty {
            loading
        } else if model.services.isEmpty {
            // Reached only when the next service day is empty too, since `load` rolls on
            // to it rather than stopping here.
            status(
                title: "Nothing direct left",
                body: "No direct trains remain today, and none run tomorrow either."
            )
        } else {
            if let hero = model.hero {
                // A followed train leads with no heading, as on the Last Train board: its
                // pill already says "Following", and a heading as well added a line that
                // pushed the board past the screen. The fastest keeps its heading below.
                if !isFollowingHero {
                    sectionHeading("Fastest train", colour: Theme.lastTrainRedLit)
                } else if model.demotedFastest == nil {
                    // Following the fastest itself: no second heading arrives below to take
                    // this one's place, so dropping it moved every row up. The line stays and
                    // only the words go — the pill already says "Following".
                    sectionHeading("Fastest train", colour: Theme.lastTrainRedLit, showsText: false)
                }
                row(hero, isHero: true)
            }

            if let message = model.activityMessage {
                Text(message)
                    .font(Theme.Font.meta)
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Space.gutter)
                    .padding(.vertical, 10)
            }

            // The fastest train, once a later one is followed: kept below the hero under
            // its own name, both heading and numerals blue now it is not the one you watch.
            if let fastest = model.demotedFastest {
                sectionHeading("Fastest train")
                row(fastest)
            }

            if !model.shown.isEmpty {
                sectionHeading(restTitle)
                ForEach(model.shown) { row($0) }
            }

            // The two-to-four-hour window loading itself in as you reach the end.
            if model.isLoadingLater {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small).tint(Theme.textDim)
                    Text("Loading the next two hours").font(Theme.Font.meta).foregroundStyle(Theme.textDim)
                }
                .padding(.horizontal, Theme.Space.gutter)
                .padding(.vertical, 14)
            } else if let notice = model.laterNotice {
                // Why the later window is not here. The one thing this must never do is
                // leave the board short and say nothing, which is the fault it replaces.
                Text(notice)
                    .font(Theme.Font.meta)
                    .foregroundStyle(Theme.textDim)
                    .padding(.horizontal, Theme.Space.gutter)
                    .padding(.vertical, 14)
            }
        }
    }

    private func row(_ service: FastService, isHero: Bool = false) -> some View {
        let followed = model.activityServiceId == service.serviceId
        return FastRow(
            service: service,
            isFollowed: followed,
            isBusy: model.isChangingActivity,
            isHero: isHero,
            onOpen: { onInspect(sheetService(service, isHero: isHero, followed: followed)) },
            onFollow: {
                Task {
                    await model.toggleActivity(service, at: station, direction: direction)
                    // Following ranks the journey higher among the recent ones.
                    if model.activityServiceId == service.serviceId, let destination = model.destination {
                        JourneyStore.markFollowed(from: station, to: destination, direction: direction)
                    }
                }
            }
        )
    }

    private func sheetService(_ service: FastService, isHero: Bool, followed: Bool) -> SheetService {
        SheetService(
            serviceId: service.serviceId,
            dep: service.liveDeparture,
            destination: service.destination,
            tocName: service.tocName.isEmpty ? service.toc : service.tocName,
            platform: service.platform,
            isReplacementBus: false,
            headcode: service.headcode,
            topLabel: followed ? "Following" : nil,
            isRed: isHero
        )
    }

    private func sectionHeading(
        _ text: String,
        colour: Color = Theme.serviceBlueLit,
        showsText: Bool = true
    ) -> some View {
        Group {
            if showsText {
                Text(text).cathodeSection(colour)
            } else {
                // The same height as a titled heading, measured by the hidden title, with
                // the line running the full width where the words were.
                Text(text)
                    .labelStyle(colour)
                    .hidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay { CathodeRule(colour: colour) }
                    .accessibilityHidden(true)
            }
        }
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.top, 18)
            .padding(.bottom, 7)
    }

    /// Whether the hero is up there because you followed it, rather than because it is
    /// the fastest. It then leads with no heading, and the fastest gets its own below.
    /// "Fastest train" stays the name even when the board has rolled to tomorrow's first
    /// services: they are still the fastest.
    private var isFollowingHero: Bool {
        model.hero?.serviceId == model.activityServiceId
    }

    /**
     Everything beneath the hero.

     Nothing followed, the hero is the fastest, so every row under it arrives later — they
     are the "Later trains". Follow one and the hero drops down the ranking while the
     fastest falls into this list ahead of it, so the rows are no longer all later: they
     are simply the "Other trains". Tomorrow keeps its own name.
     */
    private var restTitle: String {
        // "Other" once the fastest is pulled out above; until then the rows are all later
        // than it, so they are the later trains. Both stay true for tomorrow's board too.
        return model.demotedFastest != nil ? "Other trains" : "Later trains"
    }

    private func status(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.Font.heading)
            Text(body).font(Theme.Font.body).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.top, 26)
    }

    private var loading: some View {
        VStack(spacing: 14) {
            ForEach(0..<3, id: \.self) { _ in
                Rectangle().fill(Theme.control.opacity(0.44)).frame(height: 104)
            }
        }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.top, 18)
        .accessibilityLabel("Loading fast trains")
    }
}

struct FastRow: View {
    let service: FastService
    /// Whether this train is on the Dynamic Island, which the pill reflects.
    let isFollowed: Bool
    let isBusy: Bool
    /// The one held at the top of the page. Lit red, as the last train is on the other
    /// board, so the row that matters most is the same colour on both.
    var isHero = false
    let onOpen: () -> Void
    let onFollow: () -> Void

    private var colour: Color { isHero ? Theme.lastTrainRedLit : Theme.serviceBlueLit }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rowSqueeze) private var rowSqueeze

    var body: some View {
        // The same two gestures as a Last Train row: tap the time or destination to open
        // the detail sheet, tap the pill to follow on the Dynamic Island. Two buttons, so
        // neither swallows the other.
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onOpen) {
                HStack(alignment: .center, spacing: 13) {
                    // The live time, as on the Last Train board.
                    CathodeNumber(text: service.liveDeparture, colour: colour, scale: .row)
                        .frame(maxWidth: 190, alignment: .leading)

                    // The name rather than the code, two lines reserved so every row is
                    // one height, as on the Last Train board.
                    DestinationName(name: service.destination)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "info.circle")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(colour)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressDim())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken)
            .accessibilityHint("Opens calling points")

            HStack(spacing: 8) {
                RowDetail(live: LiveNote(service), essentials: essentials)
                Spacer(minLength: 8)
                // Never wraps: the detail yields, the pill keeps its line.
                FollowPill(isOn: isFollowed, colour: colour, isBusy: isBusy, action: onFollow)
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.vertical, 12 - rowSqueeze)
        .background(CathodeGauze(tint: colour, density: 11).opacity(0.55))
        .overlay(alignment: .bottom) { CathodeRule(colour: colour.opacity(0.42)) }
        .overlay(alignment: .leading) {
            if isFollowed {
                Rectangle()
                    .fill(colour)
                    .frame(width: 3)
                    .shadow(color: colour, radius: 7)
                    .transition(reduceMotion ? .identity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.28), value: isFollowed)
    }

    /// `18 min · c2c · plat 3`. The journey length leads, because on this board it is the
    /// figure that decides between two trains.
    ///
    /// A train past the two-hour live horizon ends `· scheduled`. Those rows sit in the
    /// same list as live ones, and without the word a timetable would look as sure of its
    /// platform and its punctuality as a departure board is. The platform is kept, because
    /// a planned platform is usually right and is worth having — the word is what stops it
    /// being read as a promise.
    /// Journey, platform and the scheduled caveat always show; the operator follows and
    /// gives way. See `RowDetail`.
    private var essentials: [String] {
        var parts = ["\(service.journeyMinutes) min"]
        if let platform = service.platform { parts.append("plat \(platform)") }
        if service.isScheduled { parts.append("scheduled") }
        return parts
    }

    private var spoken: String {
        (isFollowed ? "Your train. " : "")
            + "Departs \(ServiceDay.formatClock(service.liveDeparture).spoken), arrives \(ServiceDay.formatClock(service.liveArrival).spoken), \(service.journeyMinutes) minutes"
            + (service.minutesLate.map { ", \($0) minutes late" } ?? "")
            + (service.isDelayed ? ", delayed" : "")
            // Said out loud too. A caveat only sighted users get is not a caveat.
            + (service.isScheduled ? ", scheduled time" : "")
    }
}

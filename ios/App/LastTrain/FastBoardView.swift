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
            // Fast Train cannot answer anything without a destination, so it asks. Last
            // Train can, which is why the asking lives here and not in `adopt`.
            if model.destination == nil { model.askWhereTo() }
        }
    }

    private var emptyPrompt: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Where are you going?").font(Theme.Font.heading)
            Text("Choose a direct destination. Fast Train ranks the next services by when they get you there.")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
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
                sectionHeading(heroTitle, colour: Theme.lastTrainRedLit)
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
            onFollow: { Task { await model.toggleActivity(service, at: station, direction: direction) } }
        )
    }

    private func sheetService(_ service: FastService, isHero: Bool, followed: Bool) -> SheetService {
        SheetService(
            serviceId: service.serviceId,
            dep: service.departure,
            destination: service.destination,
            tocName: service.tocName.isEmpty ? service.toc : service.tocName,
            platform: service.platform,
            isReplacementBus: false,
            headcode: service.headcode,
            topLabel: followed ? "Following" : nil,
            isRed: isHero
        )
    }

    private func sectionHeading(_ text: String, colour: Color = Theme.serviceBlueLit) -> some View {
        Text(text)
            .cathodeSection(colour)
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.top, 18)
            .padding(.bottom, 7)
    }

    /// Whether the hero is up there because you followed it, rather than because it is
    /// the fastest. The two headings both turn on this.
    private var isFollowingHero: Bool {
        model.hero?.serviceId == model.activityServiceId
    }

    /**
     What the pinned train is.

     A followed train says so. Otherwise it is the fastest train to the destination — the
     first you can be there on, which is the whole question this mode answers. "From now"
     said nothing the board did not: every train on it is from now. Tomorrow's board names
     itself instead.
     */
    private var heroTitle: String {
        if isFollowingHero { return "Following" }
        return model.showsNextServiceDay ? "First tomorrow" : "Fastest train"
    }

    /**
     Everything beneath the hero.

     Nothing followed, the hero is the fastest, so every row under it arrives later — they
     are the "Later trains". Follow one and the hero drops down the ranking while the
     fastest falls into this list ahead of it, so the rows are no longer all later: they
     are simply the "Other trains". Tomorrow keeps its own name.
     */
    private var restTitle: String {
        if model.showsNextServiceDay { return "Other trains tomorrow" }
        // "Other" once the fastest is pulled out above; until then the rows are all later
        // than it, so they are the later trains.
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

    var body: some View {
        // The same two gestures as a Last Train row: tap the time or destination to open
        // the detail sheet, tap the pill to follow on the Dynamic Island. Two buttons, so
        // neither swallows the other.
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onOpen) {
                HStack(alignment: .center, spacing: 13) {
                    CathodeNumber(text: service.departure, colour: colour, scale: .row)
                        .frame(maxWidth: 190, alignment: .leading)

                    // The name rather than the code, wrapping to a second line where it must
                    // and sitting within the height of the time beside it.
                    Text(service.destination.withoutLondonPrefix)
                        .font(Theme.Font.destination)
                        .foregroundStyle(Theme.text)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(colour)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressDim())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken)
            .accessibilityHint("Opens calling points")

            HStack(spacing: 8) {
                Text(meta).font(Theme.Font.meta).foregroundStyle(Theme.textDim).lineLimit(1)
                Spacer(minLength: 8)
                // Never wraps: the detail yields, the pill keeps its line.
                FollowPill(isOn: isFollowed, colour: colour, isBusy: isBusy, action: onFollow)
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.vertical, 12)
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

    /// `18 min · c2c`. The journey length leads, because on this board it is the figure
    /// that decides between two trains.
    private var meta: String {
        var parts = ["\(service.journeyMinutes) min"]
        parts.append(service.tocName.isEmpty ? service.toc : service.tocName)
        if let platform = service.platform { parts.append("plat \(platform)") }
        return parts.joined(separator: " · ")
    }

    private var spoken: String {
        (isFollowed ? "Your train. " : "")
            + "Departs \(ServiceDay.formatClock(service.departure).spoken), arrives \(ServiceDay.formatClock(service.arrival).spoken), \(service.journeyMinutes) minutes"
    }
}

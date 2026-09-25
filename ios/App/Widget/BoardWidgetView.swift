import SwiftUI
import WidgetKit

import LastTrainCore

/**
 The widget, in every size it offers.

 **The lock screen strips colour.** Accessory families render vibrant — one tint,
 whatever the wallpaper needs — so `Theme.lastTrainRed` does not survive there at all.
 That is not a compromise forced on the design; it is the case `DESIGN.md` already
 wrote the rule for. Red was never allowed to be the only signal, and the block has
 always carried a literal `LAST TRAIN` label beside it. On the lock screen that label
 is doing all of the work, and it is enough because it was built to be.

 Home screen families do render colour, so there the answer sits on red or blue exactly
 as it does in the app.

 No `accessoryCircular`. A circle fits a time and nothing else, and a bare `00:42` with
 no station, no direction and no word for what it is would be read as the *next* train
 as often as the last one. A widget that can be misread on a platform at midnight is
 worse than no widget.
 */
struct BoardWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: BoardEntry

    var body: some View {
        content
            .widgetURL(entry.link)
            .containerBackground(for: .widget) {
                if isAccessory {
                    Color.clear
                } else {
                    ZStack {
                        Theme.ink
                        CathodeGauze(tint: blockColour, density: 10)
                        LinearGradient(
                            colors: [blockColour.opacity(0.16), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryInline: inline
        case .accessoryRectangular: rectangular
        case .systemMedium: medium
        default: small
        }
    }

    // MARK: - Lock screen

    /// One line beside the clock. No layout to speak of, so it has to say what it is.
    private var inline: some View {
        switch state {
        case .answer(let glance):
            Text("\(ServiceDay.formatClock(glance.departure.liveDep).spoken) \(words(for: glance.label).lowercased())")
        case .exhausted:
            Text("No trains left")
        case .unset:
            Text("Last Train — choose a station")
        case .failed:
            Text("Last Train unavailable")
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            switch state {
            case .answer(let glance):
                Text(words(for: glance.label))
                    .font(.caption2.weight(.bold))
                    .tracking(Theme.tracking)
                    // Tinted rather than dimmed, so the thing the widget is *for* is
                    // what the lock screen's accent picks out.
                    .widgetAccentable()

                HStack(alignment: .center, spacing: 5) {
                    CathodeNumber(
                        text: glance.departure.liveDep,
                        colour: glance.isLastTrain ? Theme.lastTrainRedLit : Theme.serviceBlueLit,
                        scale: .compact
                    )
                    Text(glance.departure.destination.withoutLondonPrefix)
                        .font(.caption2)
                        .lineLimit(1)
                        // Not truncation: the whole name is still there, drawn smaller.
                        // The Real Length Rule forbids cutting a station name off, not
                        // fitting it into the space available.
                        .minimumScaleFactor(0.7)
                }

                if let instant = glance.departure.instant {
                    // Ticks on its own, without an entry per minute.
                    Text(instant, style: .relative)
                        .font(.caption2)
                }

            case .exhausted:
                Text("No trains left").font(.caption.weight(.semibold))
                Text(caption).font(.caption2)
            case .unset:
                Text("Last Train").font(.caption.weight(.bold))
                Text("Choose a station").font(.caption2)
            case .failed(let message):
                Text("Unavailable").font(.caption.weight(.bold))
                Text(message).font(.caption2).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: - Home screen

    /**
     The departure card: what it is and the platform, the time, where it goes, how long you
     have and whether it is running to time. The same parts in the same order as the Live
     Activity on the lock screen, so the two read as one thing.
     */
    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch state {
            case .answer(let glance):
                HStack(alignment: .center, spacing: 6) {
                    Text(words(for: glance.label)).labelStyle(blockColour)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                    PlatformChip(platform: glance.departure.platform, colour: blockColour, short: true)
                }

                CathodeNumber(text: glance.departure.liveDep, colour: blockColour, scale: .row)
                    .padding(.top, 2)

                Text(glance.departure.destination.withoutLondonPrefix)
                    .font(Theme.Font.destination)
                    .fixedSize(horizontal: false, vertical: true)

                statusLine(glance.departure)
                    .padding(.top, 2)

            case .exhausted:
                Text("Nothing left").font(Theme.Font.heading)
                Text("No more departures on this board.")
                    .font(Theme.Font.meta)
                    .fixedSize(horizontal: false, vertical: true)
            case .unset:
                Text("Last Train").font(Theme.Font.heading)
                Text("Hold the widget to choose a station.")
                    .font(Theme.Font.meta)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let message):
                Text("Unavailable").font(Theme.Font.heading)
                Text(message)
                    .font(Theme.Font.meta)
                    .fixedSize(horizontal: false, vertical: true)
            }

            /*
             No `Spacer` above the caption, deliberately: pinned to the bottom it left a hole
             under the countdown while the caption ran out of width and wrapped. Flowing from
             the top gives one rhythm, and any slack collects at the bottom as margin.
             */
            Text(caption)
                .labelStyle(Theme.paper.opacity(0.7))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(Theme.paper)
    }

    /// "3 hr, 12 min · On time". The countdown ticks on the device; the status is as fresh
    /// as the board the timeline was built from, and absent when there is no live time.
    private func statusLine(_ departure: BoardDeparture) -> some View {
        HStack(spacing: 0) {
            if let instant = departure.instant {
                Text(instant, style: .relative)
            }
            if let status = LiveStatus.of(departure) {
                Text(departure.instant == nil ? status : " · \(status)")
                    // News is bright, as on the app's rows; "On time" stays quiet.
                    .foregroundStyle((departure.minutesLate ?? 0) > 0 || departure.cancelled ? Theme.paper : Theme.paper.opacity(0.78))
            }
        }
        .font(Theme.Font.meta)
        .foregroundStyle(Theme.paper.opacity(0.78))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    /// The card, with the trains around it — the app's board, at a quarter of the size.
    private var medium: some View {
        HStack(alignment: .top, spacing: 14) {
            small

            if case .answer(let glance) = state, glance.remaining.count > 1 {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Still to come").labelStyle(Theme.paper.opacity(0.7))

                    ForEach(glance.remaining.prefix(3)) { service in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            // The LED face, as on the card: a list of times should look
                            // like the board they came from.
                            Text(ServiceDay.formatClock(service.liveDep).spoken)
                                .font(.custom("WPOCRA-Regular", size: 15))
                                .foregroundStyle(service.id == glance.departure.id ? blockColour : Theme.serviceBlueLit)
                            Text(service.destination.withoutLondonPrefix)
                                .font(Theme.Font.meta)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                }
                .foregroundStyle(Theme.paper)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Reading the entry

    private enum State {
        case answer(Glance)
        /// Nothing left on the board, which is an answer rather than a fault.
        case exhausted
        case unset
        case failed(String)
    }

    private var state: State {
        if let failure = entry.failure { return .failed(failure) }
        guard entry.station != nil else { return .unset }
        guard let glance = entry.glance else { return .exhausted }
        return .answer(glance)
    }

    private var isAccessory: Bool {
        family == .accessoryInline || family == .accessoryRectangular
    }

    /// Red only for the last train, exactly as in the app. Never for an error.
    private var blockColour: Color {
        if case .answer(let glance) = state, glance.isLastTrain { return Theme.lastTrainRedLit }
        return Theme.serviceBlueLit
    }

    private var caption: String {
        guard let station = entry.station else { return "Last Train" }
        // Uppercased here rather than left to `labelStyle`, which only the home screen
        // layouts apply -- the lock screen was rendering "Upminster · east".
        return "\(station.name.withoutLondonPrefix) · \(entry.direction.rawValue.uppercased())"
    }

    private func words(for label: Glance.Label) -> String {
        switch label {
        case .lastTrain: "Last train"
        // Named for what it is rather than "tomorrow", which at 00:40 is wrong by a day
        // — the same wording the board uses.
        case .firstBack: "First train back"
        case .firstOut: "First train"
        // Yours, and said so. Never "last train", which it usually is not.
        case .pinned: "Your train"
        }
    }
}

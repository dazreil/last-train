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
                // Accessory families ignore this and render vibrant regardless; it is
                // the home screen that gets the red.
                isAccessory ? Color.clear : blockColour
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
            Text("\(glance.departure.dep) \(words(for: glance.label).lowercased())")
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

                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(glance.departure.dep)
                        .font(.title3.monospacedDigit().weight(.bold))
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

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch state {
            case .answer(let glance):
                Text(words(for: glance.label)).labelStyle(Theme.paper)

                Text(glance.departure.dep)
                    .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)

                Text(glance.departure.destination.withoutLondonPrefix)
                    .font(Theme.Font.destination)
                    .fixedSize(horizontal: false, vertical: true)

                if let instant = glance.departure.instant {
                    Text(instant, style: .relative)
                        .font(Theme.Font.meta)
                        .foregroundStyle(Theme.paper.opacity(0.78))
                        .padding(.top, 2)
                }

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
             No `Spacer` here, deliberately.

             Pinning the caption to the bottom left a hole between the countdown and it,
             while the caption itself ran out of width and wrapped -- putting "· WEST" on
             a line of its own, so the one gap that meant something (station, then
             direction) was the one that had none. Flowing from the top instead gives one
             rhythm down the block, and any slack collects at the bottom where it reads as
             margin rather than as a missing line.
             */
            Text(caption)
                .labelStyle(Theme.paper.opacity(0.7))
                // One line, shrunk if it must be. A wrapped caption is two half-labels.
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(Theme.paper)
    }

    /// The answer, with what is left behind it — the app's board, at a quarter of the size.
    private var medium: some View {
        HStack(alignment: .top, spacing: 14) {
            small

            if case .answer(let glance) = state, glance.remaining.count > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Still to come").labelStyle(Theme.paper.opacity(0.7))

                    ForEach(glance.remaining.prefix(3)) { service in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(service.dep)
                                .font(Theme.Font.meta.monospacedDigit())
                                .fontWeight(service.id == glance.departure.id ? .bold : .regular)
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
        if case .answer(let glance) = state, glance.isLastTrain { return Theme.lastTrainRed }
        return Theme.serviceBlue
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

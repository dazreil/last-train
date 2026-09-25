import ActivityKit
import SwiftUI
import WidgetKit

import LastTrainCore

/**
 The pinned train, in the four shapes the system asks for.

 Every one of them answers the same question — how long have I got — so every one leads
 with the countdown. The departure time is the supporting fact, not the headline: `23 min`
 is what you act on, `00:54` is what you check it against.

 `Text(timerInterval:)` in each, so the numbers run on the device with no timeline, no
 refresh and no request.
 */
struct TrainLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TrainActivity.self) { context in
            lockScreen(context)
                .activityBackgroundTint(Theme.surface)
                .activitySystemActionForegroundColor(Theme.paper)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.isLastTrain ? "LAST TRAIN" : "FAST TRAIN")
                            .font(.caption2.weight(.bold))
                            .tracking(Theme.tracking)
                            .foregroundStyle(activityColour(context))
                        CathodeNumber(
                            text: (context.state.departureText ?? context.attributes.departureText),
                            colour: activityColour(context),
                            scale: .compact
                        )
                        Text(context.attributes.destination)
                            .font(.caption)
                            .foregroundStyle(Theme.textDim)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    countdown(to: context.state.departure)
                        .font(.system(.title2, design: .monospaced).weight(.bold))
                        .foregroundStyle(Theme.paper)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 6) {
                        if context.attributes.isLastTrain {
                            // Red means the last train, and it means it here too.
                            Text("Last train")
                                .foregroundStyle(Theme.lastTrainRed)
                        }
                        Text(caption(context))
                            .foregroundStyle(Theme.textDim)
                        Spacer(minLength: 0)
                    }
                    .font(.caption2.weight(.semibold))
                }
            } compactLeading: {
                // A train, not a time: the departure time and the countdown side by side
                // made the island far too wide. The colour still says which train — red for
                // the last one — and the time itself is in the expanded island.
                Image(systemName: "tram.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(activityColour(context))
            } compactTrailing: {
                minuteCountdown(to: context.isStale ? .distantPast : context.state.departure)
                    .font(.system(.caption, design: .monospaced).weight(.bold))
                    .foregroundStyle(Theme.paper)
                    .lineLimit(1)
                    // The system reserves room for the longest value a live date can take,
                    // and the island grows to it. `1h 59m` is the longest a followed train
                    // can show (four hours ahead at most), so the slot is sized to that.
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: 42, alignment: .trailing)
            } minimal: {
                minuteCountdown(to: context.isStale ? .distantPast : context.state.departure)
                    .font(.system(.caption2, design: .monospaced).weight(.bold))
                    .foregroundStyle(activityColour(context))
                    .lineLimit(1)
            }
            .widgetURL(URL(string: "lasttrain://board"))
        }
    }

    /**
     The lock screen: the departure card at its smallest — what it is and the platform, the
     time and the countdown, where it goes and whether it is on time. The same parts, in the
     same order, as the home-screen widget.
     */
    private func lockScreen(_ context: ActivityViewContext<TrainActivity>) -> some View {
        ActivityCardLayout.compact(context: context, colour: activityColour(context), label: label(context))
    }

    private func label(_ context: ActivityViewContext<TrainActivity>) -> String {
        // Never "last train" unless it is one: a followed train is yours, and usually not.
        context.attributes.isLastTrain ? "LAST TRAIN" : "YOUR TRAIN"
    }

    private func activityColour(_ context: ActivityViewContext<TrainActivity>) -> Color {
        context.attributes.isLastTrain ? Theme.lastTrainRedLit : Theme.serviceBlueLit
    }

    /// `Shoeburyness from Upminster · plat 2`, with the platform only when it is known.
    private func caption(_ context: ActivityViewContext<TrainActivity>) -> String {
        var parts = ["\(context.attributes.stationName) to \(context.attributes.destination)"]
        if let platform = context.state.platform { parts.append("plat \(platform)") }
        return parts.joined(separator: " · ")
    }

    /**
     Counts itself down, on the device, from now to the departure.

     **Never width-capped.** A `.frame(maxWidth:)` on the compact slot looked like sensible
     defence against the timer gaining a digit as it crosses an hour, and instead mangled
     it: a train 2h50m out rendered as `23:02` on the island — a plausible-looking time that
     was not any time at all, which is the worst way for a clock to be wrong. The system
     sizes these slots; let it.
     */
    /**
     Hours and minutes, no seconds, for the small island.

     Seconds are what made the compact countdown wide, and to the minute is all a glance
     needs. iOS 18's live duration counts itself down on the device like the full timer;
     iOS 17 has no such source and keeps the full countdown.
     */
    @ViewBuilder
    private func minuteCountdown(to departure: Date) -> some View {
        if departure <= Date.now {
            // Gone. A live range cannot run backwards, so this is drawn, not counted.
            Text("0m").monospacedDigit()
        } else if #available(iOS 18.0, *) {
            // `26m`, `1h 5m`, counted on the device. A range from now to the departure, in
            // the narrow style: the minute timer read "16 minutes", as wide as what it
            // replaced, and a duration offset counts the other way and read "-26m".
            Text(
                .dateRange(endingAt: departure),
                format: Date.ComponentsFormatStyle(style: .narrow, fields: [.hour, .minute])
            )
            .monospacedDigit()
        } else {
            countdown(to: departure, showsHours: false)
                .minimumScaleFactor(0.6)
        }
    }

    private func countdown(to departure: Date, showsHours: Bool = true) -> some View {
        Text(timerInterval: Date.now...departure, countsDown: true, showsHours: showsHours)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
    }
}

/**
 The departure card in a Live Activity. The parts, in the order the widget uses: label and
 platform, the time and the countdown, where it goes and whether it is running to time.
 */
private enum ActivityCardLayout {

    private static func departureText(_ context: ActivityViewContext<TrainActivity>) -> String {
        context.state.departureText ?? context.attributes.departureText
    }

    /// Bright when it is news, quiet when it is "On time".
    private static func statusColour(_ status: String) -> Color {
        status == "On time" ? Theme.textDim : Theme.paper
    }

    static func compact(context: ActivityViewContext<TrainActivity>, colour: Color, label: String) -> some View {
        ZStack {
            CathodeGauze(tint: colour, density: 10)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(label)
                        .font(.caption2.weight(.bold))
                        .tracking(Theme.tracking)
                        .foregroundStyle(colour)
                    Spacer(minLength: 0)
                    PlatformChip(platform: context.state.platform, colour: colour)
                }
                HStack(alignment: .lastTextBaseline) {
                    CathodeNumber(text: departureText(context), colour: colour, scale: .row)
                    Spacer(minLength: 8)
                    // The figure you act on, in the same LED face, kept paper-white so it
                    // leads over the glow of the time beside it.
                    Text(timerInterval: Date.now...context.state.departure, countsDown: true)
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .font(.custom("WPOCRA-Regular", size: 30))
                        .foregroundStyle(Theme.paper)
                }
                HStack(alignment: .firstTextBaseline) {
                    (Text(context.attributes.destination).foregroundStyle(Theme.paper)
                        + Text(" · from \(context.attributes.stationName)").foregroundStyle(Theme.textDim))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Spacer(minLength: 6)
                    if let status = context.state.status {
                        Text(status).foregroundStyle(statusColour(status))
                    }
                }
                .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

}

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
                    if context.state.isCancelled == true {
                        Text("Cancelled")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(Theme.paper)
                    } else if context.isStale {
                        // Past its departure with nothing newer from the app. Words, not a
                        // frozen 0:00, and no claim that it has gone (BUG-007).
                        Text("Open to refresh")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.textDim)
                    } else {
                        countdown(to: context.state.departure)
                            .font(.system(.title2, design: .monospaced).weight(.bold))
                            .foregroundStyle(Theme.paper)
                    }
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
                // Cancelled: a cross where the minutes were, in white, never red (BUG-003).
                if context.state.isCancelled == true {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.paper)
                        .accessibilityLabel("Cancelled")
                } else if context.isStale {
                    Image(systemName: "ellipsis")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.textDim)
                        .accessibilityLabel("Open to refresh")
                } else {
                    // The system's own ticking timer, the same one as the expanded island, so
                    // the two can never disagree (BUG-006: the hours-and-minutes range drifted
                    // minutes behind in the notch). Never width-capped: a capped timer was
                    // mangled into a plausible wrong time before; the system sizes the slot.
                    countdown(to: context.state.departure)
                        .font(.system(.caption, design: .monospaced).weight(.bold))
                        .foregroundStyle(Theme.paper)
                        .lineLimit(1)
                }
            } minimal: {
                if context.state.isCancelled == true {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Theme.paper)
                        .accessibilityLabel("Cancelled")
                } else if context.isStale {
                    Image(systemName: "tram.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Theme.textDim)
                        .accessibilityLabel("Open to refresh")
                } else {
                    countdown(to: context.state.departure, showsHours: false)
                        .font(.system(.caption2, design: .monospaced).weight(.bold))
                        .foregroundStyle(activityColour(context))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
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

    /// Counts down on the device. Guarded: `Date.now...departure` traps when the departure
    /// has passed, and that takes the whole widget extension down (BUG-007), so a past
    /// departure is drawn as a zero-length timer instead.
    private func countdown(to departure: Date, showsHours: Bool = true) -> some View {
        let now = Date.now
        return Text(timerInterval: now...max(departure, now), countsDown: true, showsHours: showsHours)
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
                    // leads over the glow of the time beside it. Cancelled: said in words
                    // where the countdown was, never red (BUG-003).
                    if context.state.isCancelled == true {
                        Text("CANCELLED")
                            .font(.headline.weight(.heavy))
                            .tracking(Theme.tracking)
                            .foregroundStyle(Theme.paper)
                    } else if context.isStale {
                        Text("Open to refresh")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textDim)
                    } else {
                        // Guarded like `countdown(to:)`: a past departure traps (BUG-007).
                        Text(timerInterval: Date.now...max(context.state.departure, Date.now), countsDown: true)
                            .monospacedDigit()
                            .multilineTextAlignment(.trailing)
                            .font(.custom("WPOCRA-Regular", size: 30))
                            .foregroundStyle(Theme.paper)
                    }
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

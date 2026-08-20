import ActivityKit
import SwiftUI
import WidgetKit

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
                .activityBackgroundTint(Theme.ink)
                .activitySystemActionForegroundColor(Theme.paper)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.departureText)
                            .font(.system(.title2, design: .monospaced).weight(.bold))
                            .foregroundStyle(Theme.paper)
                        Text(context.attributes.destination)
                            .font(.caption)
                            .foregroundStyle(Theme.textDim)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    countdown(to: context.state.departure)
                        .font(.system(.title2, design: .monospaced).weight(.bold))
                        .foregroundStyle(context.attributes.isLastTrain ? Theme.lastTrainRed : Theme.paper)
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
                Text(context.attributes.departureText)
                    .font(.system(.caption, design: .monospaced).weight(.bold))
                    .foregroundStyle(context.attributes.isLastTrain ? Theme.lastTrainRed : Theme.paper)
            } compactTrailing: {
                countdown(to: context.state.departure)
                    .font(.system(.caption, design: .monospaced).weight(.bold))
                    .foregroundStyle(Theme.paper)
            } minimal: {
                countdown(to: context.state.departure)
                    .font(.system(.caption2, design: .monospaced).weight(.bold))
                    .foregroundStyle(context.attributes.isLastTrain ? Theme.lastTrainRed : Theme.paper)
            }
            .widgetURL(URL(string: "lasttrain://board"))
        }
    }

    private func lockScreen(_ context: ActivityViewContext<TrainActivity>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if context.attributes.isLastTrain {
                    Text("Last train")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Theme.lastTrainRed)
                }
                Text(context.attributes.departureText)
                    .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                    .foregroundStyle(Theme.paper)
                Text(caption(context))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            countdown(to: context.state.departure)
                .font(.system(.title, design: .monospaced).weight(.bold))
                .foregroundStyle(Theme.paper)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// `Shoeburyness from Upminster · plat 2`, with the platform only when it is known.
    private func caption(_ context: ActivityViewContext<TrainActivity>) -> String {
        var parts = ["\(context.attributes.destination) from \(context.attributes.stationName)"]
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
    private func countdown(to departure: Date) -> some View {
        Text(timerInterval: Date.now...departure, countsDown: true)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
    }
}

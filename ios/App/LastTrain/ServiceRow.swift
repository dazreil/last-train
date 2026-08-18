import SwiftUI

import LastTrainCore

/**
 One departure.

 A departure board line, not a journey: with only a direction chosen there is no
 destination to arrive at, so the answer is the time it leaves and where it is going.

 Full bleed, zero radius, and separated from its neighbours by colour change alone —
 the stack reads as a single object rather than a list of cards, which is what lets the
 red block register as the end of service from across a platform.
 */
struct ServiceRow: View {
    let service: BoardDeparture
    /// The genuine last train of the service day, not merely the last row.
    let isLastTrain: Bool
    /// The train the widget is following. Marked, never recoloured — the colours here
    /// mean last train and ordinary departure, and nothing may be added to that.
    var isPinned = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if isPinned {
                HStack(spacing: 5) {
                    Image(systemName: "pin.fill").font(.system(size: 9, weight: .bold))
                    Text("In the widget")
                }
                .labelStyle(Theme.paper.opacity(0.85))
            }

            if isLastTrain {
                // Stated in words as well as in colour. Red carries it at a glance, but
                // red against blue is a hue difference more than a brightness one, so
                // this has to work for anyone who cannot separate the two at all.
                Text("Last train").labelStyle(Theme.paper)
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(service.dep)
                    .font(Theme.Font.time)
                    .monospacedDigit()
                Text(service.destination.withoutLondonPrefix)
                    .font(Theme.Font.destination)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(service.toc)
                    .font(Theme.Font.label)
                    .tracking(Theme.tracking)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    // Operator as a white outline, never a filled brand colour.
                    .overlay(Rectangle().strokeBorder(Theme.paper.opacity(0.7), lineWidth: 1))
            }

            if !meta.isEmpty {
                Text(meta)
                    .font(Theme.Font.meta)
                    .foregroundStyle(Theme.paper.opacity(0.78))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.vertical, 11)
        .background(isLastTrain ? Theme.lastTrainRed : Theme.serviceBlue)
        // Lit in its own colour, so a red block folds as red and a blue one as blue.
        .embossed(lit: isLastTrain ? Theme.lastTrainRedLit : Theme.serviceBlueLit)
        .foregroundStyle(Theme.paper)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken)
    }

    /**
     Platform, and a bus when it is one.

     **The headcode is deliberately absent.** `2B42` identifies a train to someone
     reading a signalling screen and means nothing on a platform at midnight, and it sat
     under the departure time where the eye lands. It is still carried on the service and
     still what the widget pins to — it is only not shown here. `ServiceSheet` keeps it,
     which is where identifying one particular train is the actual question.
     */
    private var meta: String {
        var parts: [String] = []
        if let platform = service.platform { parts.append("plat \(platform)") }
        // Badged, never silently shown as a train.
        if service.isReplacementBus { parts.append("replacement bus") }
        return parts.joined(separator: " · ")
    }

    private var spoken: String {
        (isLastTrain ? "Last train. " : "")
            + "\(service.tocName) service departing \(service.dep), towards \(service.destination)"
            + (service.isReplacementBus ? ", replacement bus" : "")
    }

}

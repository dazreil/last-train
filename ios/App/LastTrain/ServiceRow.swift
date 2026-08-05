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

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
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
        .foregroundStyle(Theme.paper)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken)
    }

    private var meta: String {
        var parts: [String] = []
        if let platform = service.platform { parts.append("plat \(platform)") }
        // Badged, never silently shown as a train.
        if service.isReplacementBus { parts.append("replacement bus") }
        if let headcode = service.headcode { parts.append(headcode) }
        return parts.joined(separator: " · ")
    }

    private var spoken: String {
        (isLastTrain ? "Last train. " : "")
            + "\(service.tocName) service departing \(service.dep), towards \(service.destination)"
            + (service.isReplacementBus ? ", replacement bus" : "")
    }

}

extension String {
    /**
     Drop "London" from London termini for display.

     "London Fenchurch Street" does not fit beside a large departure time on a phone,
     nor inside a direction block, and nobody standing at Grays needs telling which city
     Fenchurch Street is in. This is not truncation — the Real Length Rule forbids that
     — it is a shorter true name, and the full one stays in the accessible label.
     */
    var withoutLondonPrefix: String {
        components(separatedBy: " & ")
            .map { part in
                part.hasPrefix("London ") && part.count > "London ".count
                    ? String(part.dropFirst("London ".count))
                    : part
            }
            .joined(separator: " & ")
    }
}

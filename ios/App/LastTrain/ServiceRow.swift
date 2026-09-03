import SwiftUI

import LastTrainCore

/// One departure rendered as a luminous line in the gauze rather than a filled card.
struct ServiceRow: View {
    let service: BoardDeparture
    let isLastTrain: Bool
    var isPinned = false

    @Environment(\.dynamicTypeSize) private var typeSize

    private var colour: Color { isLastTrain ? Theme.lastTrainRedLit : Theme.serviceBlueLit }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // A long destination wraps beside the time; it does not drop to a second line
            // under it. `ViewThatFits` used to stack them the moment a name like Fenchurch
            // Street stopped fitting on one line, which pushed the board past a screen. Only
            // an accessibility type size — where the time itself is huge — stacks now.
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    time
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        destination
                        Spacer(minLength: 8)
                        chevron
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 13) {
                    time
                    destination
                        .frame(maxWidth: .infinity, alignment: .leading)
                    chevron
                }
            }

            HStack(spacing: 8) {
                if isLastTrain { Text("Last train").labelStyle(Theme.lastTrainRedLit) }
                if isPinned {
                    Label("In widget", systemImage: "pin.fill").labelStyle(Theme.textDim)
                }
                if let meta { Text(meta).font(Theme.Font.meta).foregroundStyle(Theme.textFaint) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.vertical, 12)
        .background(CathodeGauze(tint: colour, density: 11).opacity(0.55))
        .overlay(alignment: .bottom) { CathodeRule(colour: colour.opacity(0.42)) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityHint("Shows calling points and widget controls")
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.bold))
            .foregroundStyle(colour)
    }

    private var time: some View {
        CathodeNumber(text: service.dep, colour: colour, scale: .row)
            .frame(maxWidth: 190, alignment: .leading)
    }

    /**
     Where it goes, as a code.

     `FST` rather than `London Fenchurch Street`. The board is read standing up, in the
     dark, in a couple of seconds, and a code is the form the railway already prints on
     its own signage — so it reads faster and costs a fraction of the width. The full name
     is one tap away in the sheet, which is where the calling points live anyway.

     **Falls back to the name.** `Stations.code(forName:)` can miss, and a wide row is a
     far better failure than an empty one.
     */
    private var destination: some View {
        Text(Stations.code(forName: service.destination) ?? service.destination.withoutLondonPrefix)
            .font(Theme.Font.destination)
            .monospacedDigit()
            .foregroundStyle(Theme.text)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var meta: String? {
        var parts: [String] = []
        // The journey leads when there is one, as it does on the Fast Train row.
        if let minutes = service.journeyMinutes { parts.append("\(minutes) min") }
        parts.append(service.tocName)
        if let platform = service.platform { parts.append("plat \(platform)") }
        if service.isReplacementBus { parts.append("Replacement bus") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var spoken: String {
        (isLastTrain ? "Last train. " : "")
            + "\(service.tocName) service departing \(ServiceDay.formatClock(service.dep).spoken), towards \(service.destination)"
            + (service.isReplacementBus ? ", replacement bus" : "")
            + (isPinned ? ", in the widget" : "")
    }
}

import SwiftUI

import LastTrainCore

/// One departure rendered as a luminous line in the gauze rather than a filled card.
struct ServiceRow: View {
    let service: BoardDeparture
    let isLastTrain: Bool
    var isPinned = false

    private var colour: Color { isLastTrain ? Theme.lastTrainRedLit : Theme.serviceBlueLit }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 13) {
                    time
                    destination
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(colour)
                }

                VStack(alignment: .leading, spacing: 6) {
                    time
                    HStack(alignment: .firstTextBaseline) {
                        destination
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(colour)
                    }
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

    private var time: some View {
        CathodeNumber(text: service.dep, colour: colour, scale: .row)
            .frame(maxWidth: 190, alignment: .leading)
    }

    private var destination: some View {
        Text(service.destination.withoutLondonPrefix)
            .font(Theme.Font.destination)
            .foregroundStyle(Theme.text)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var meta: String? {
        var parts = [service.tocName]
        if let platform = service.platform { parts.append("Platform \(platform)") }
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

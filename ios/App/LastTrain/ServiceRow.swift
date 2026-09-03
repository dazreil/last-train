import SwiftUI

import LastTrainCore

/// One departure rendered as a luminous line in the gauze rather than a filled card.
///
/// Two gestures, the same pair Fast Train's rows carry: tapping the time or destination
/// opens the detail sheet, and the Follow pill pins this train to the lock-screen widget.
/// They are separate buttons so neither swallows the other.
struct ServiceRow: View {
    let service: BoardDeparture
    /// The genuine last train of the day, wherever it sits — red, and labelled.
    let isLastTrain: Bool
    /// Red although it is not the last train: the pinned train that has floated to the
    /// top of the board and now leads it.
    var isRed: Bool = false
    /// Whether the widget is following this one, which the pill reflects.
    var isFollowed: Bool = false
    var onOpen: () -> Void = {}
    var onFollow: (() -> Void)? = nil

    @Environment(\.dynamicTypeSize) private var typeSize

    /// Red is the train that leads the board — the last train when nothing is followed,
    /// or the followed train once one is. Demoted into the list it goes blue like any
    /// other row; the red "LAST TRAIN" tag stays as the marker, which is what finds it.
    private var colour: Color {
        isRed ? Theme.lastTrainRedLit : Theme.serviceBlueLit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onOpen) {
                Group {
                    // A long destination wraps beside the time; it does not drop under it.
                    // Only an accessibility type size, where the numeral is huge, stacks.
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
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressDim())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken)
            .accessibilityHint("Opens calling points")

            HStack(spacing: 8) {
                if isLastTrain { Text("Last train").labelStyle(Theme.lastTrainRedLit) }
                if let meta { Text(meta).font(Theme.Font.meta).foregroundStyle(Theme.textFaint) }
                Spacer(minLength: 8)
                if let onFollow, service.headcode != nil {
                    FollowPill(isOn: isFollowed, colour: colour, action: onFollow)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.vertical, 12)
        .background(CathodeGauze(tint: colour, density: 11).opacity(0.55))
        .overlay(alignment: .bottom) { CathodeRule(colour: colour.opacity(0.42)) }
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
    }
}

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
    @Environment(\.rowSqueeze) private var rowSqueeze

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
                                infoMark
                            }
                        }
                    } else {
                        HStack(alignment: .center, spacing: 13) {
                            time
                            destination
                                .frame(maxWidth: .infinity, alignment: .leading)
                            infoMark
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
                RowDetail(essentials: essentials, operatorName: service.tocName)
                Spacer(minLength: 8)
                if let onFollow, service.headcode != nil {
                    // Pinned to one line: the last-train marker moved to a heading, so
                    // nothing shares this line but the detail, and the pill never wraps.
                    FollowPill(isOn: isFollowed, colour: colour, action: onFollow)
                        .fixedSize()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.vertical, 12 - rowSqueeze)
        .background(CathodeGauze(tint: colour, density: 11).opacity(0.55))
        .overlay(alignment: .bottom) { CathodeRule(colour: colour.opacity(0.42)) }
    }

    /// The way into the calling points. An information mark rather than a chevron: the
    /// row opens a sheet about this train, it does not navigate anywhere.
    private var infoMark: some View {
        Image(systemName: "info.circle")
            .font(.body.weight(.semibold))
            .foregroundStyle(colour)
    }

    private var time: some View {
        CathodeNumber(text: service.dep, colour: colour, scale: .row)
            .frame(maxWidth: 190, alignment: .leading)
    }

    /**
     Where it goes, by name.

     `Shoeburyness`, not `SRY` — the name is what most people know a station by.

     **Every row is the same height, whatever the name.** Two lines are always reserved,
     so `Grays` leaves the second one empty and `Birmingham International` fills it, and
     the board no longer changes size from one station to the next. A name too long even
     for two lines shrinks a little rather than being cut: the Real Length Rule in
     `DESIGN.md` still holds. At accessibility sizes the row stacks and grows instead,
     because there the words matter more than a steady outline.
     */
    private var destination: some View {
        DestinationName(name: service.destination)
    }

    /// What the detail line must always show. The operator follows, and is the part that
    /// gives way; see `RowDetail`.
    private var essentials: [String] {
        var parts: [String] = []
        // The journey leads when there is one, as it does on the Fast Train row.
        if let minutes = service.journeyMinutes { parts.append("\(minutes) min") }
        if let platform = service.platform { parts.append("plat \(platform)") }
        if service.isReplacementBus { parts.append("Replacement bus") }
        return parts
    }

    private var spoken: String {
        (isLastTrain ? "Last train. " : "")
            + "\(service.tocName) service departing \(ServiceDay.formatClock(service.dep).spoken), towards \(service.destination)"
            + (service.isReplacementBus ? ", replacement bus" : "")
    }
}

/// A destination on a board row, two lines reserved so every row is one height. Shared by
/// both boards; see `ServiceRow.destination` for why.
struct DestinationName: View {
    let name: String
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            Text(name.withoutLondonPrefix)
                .font(Theme.Font.destination)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            // The box is always two lines tall, measured by a hidden two-line stand-in;
            // the name sits centred in it, so a one-line name lines up with the middle of
            // the time rather than hanging from the top of an empty second line.
            Text(verbatim: "A\nA")
                .font(Theme.Font.destination)
                .hidden()
                // Full width, so the name in the overlay gets the row's width to wrap in
                // rather than the stand-in's.
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) {
                    Text(name.withoutLondonPrefix)
                        .font(Theme.Font.destination)
                        .foregroundStyle(Theme.text)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                }
        }
    }
}

/**
 The line under a departure: `22 min · plat 8 · West Midlands Trains`.

 **The platform outranks the operator.** On a phone set to a larger text size, "West
 Midlands Trains" filled the line and the platform was cut off the end — the one detail
 you walk towards. So the essentials come first and are laid out first, and the operator
 takes what is left, shortening to `West Midl…` when it must. The operator is the only
 part allowed to be cut.
 */
struct RowDetail: View {
    let essentials: [String]
    let operatorName: String

    var body: some View {
        HStack(spacing: 0) {
            if !essentials.isEmpty {
                Text(essentials.joined(separator: " · "))
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            if !operatorName.isEmpty {
                Text((essentials.isEmpty ? "" : " · ") + operatorName)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .font(Theme.Font.meta)
        .foregroundStyle(Theme.textDim)
        .accessibilityElement(children: .combine)
    }
}

/**
 Points taken off the top and bottom padding of every board row, so the board fits the
 screen without scrolling.

 `BoardView` measures how far the page overflows and sets this just high enough to cover
 it, up to `maximum`. Past that the page scrolls, which it must: a board you cannot reach
 the bottom of has dropped its first train back. Measured on the device rather than tuned
 to one text size, because the owner's phone is set larger than the simulator and each
 fixed trim so far fitted one and not the other.
 */
enum RowSqueeze {
    /// Rows keep at least 4 points above and below.
    static let maximum: CGFloat = 8
}

private struct RowSqueezeKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var rowSqueeze: CGFloat {
        get { self[RowSqueezeKey.self] }
        set { self[RowSqueezeKey.self] = newValue }
    }
}

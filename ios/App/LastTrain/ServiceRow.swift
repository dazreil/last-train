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
                RowDetail(live: LiveNote(service), essentials: essentials)
                Spacer(minLength: 8)
                if let onFollow, service.headcode != nil, !service.cancelled {
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
        // A cancelled train stays on the board, greyed and struck through, so its absence
        // is explained rather than silent.
        .opacity(service.cancelled ? 0.45 : 1)
    }

    /// The way into the calling points. An information mark rather than a chevron: the
    /// row opens a sheet about this train, it does not navigate anywhere.
    private var infoMark: some View {
        Image(systemName: "info.circle")
            .font(.body.weight(.semibold))
            .foregroundStyle(colour)
    }

    private var time: some View {
        // The live time: when it will really leave. The timetable's is on the line below.
        CathodeNumber(text: service.liveDep, colour: colour, scale: .row)
            .overlay {
                if service.cancelled {
                    Rectangle().fill(colour).frame(height: 3)
                }
            }
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
            + (service.cancelled ? "Cancelled. " : "")
            + "\(service.tocName) service departing \(ServiceDay.formatClock(service.liveDep).spoken), towards \(service.destination)"
            + (service.minutesLate.map { ", \($0) minutes late" } ?? "")
            + (service.delayed ? ", delayed" : "")
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
    var live: LiveNote = LiveNote()
    let essentials: [String]

    /**
     `due 23:19 · 5 min late · plat 2`. The live word leads and is the one part lit, since
     it is the news; the rest is dim. The operator is not here any more: it made room for
     the delay, and it is on the detail sheet behind the ⓘ.
     */
    var body: some View {
        var parts: [Text] = []
        if let due = live.due { parts.append(Text(due).foregroundColor(Theme.textDim)) }
        if let alert = live.alert { parts.append(Text(alert).foregroundColor(Theme.text)) }
        for item in essentials { parts.append(Text(item).foregroundColor(Theme.textDim)) }
        let line = parts.enumerated().reduce(Text("")) { joined, next in
            next.offset == 0 ? next.element : joined + Text(" · ").foregroundColor(Theme.textDim) + next.element
        }
        return line
            .font(Theme.Font.meta)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

/**
 What the live board says about a train, as the words the detail line shows.

 `due` is the timetabled time when the train is running late, and `alert` the news:
 `5 min late`, `Delayed`, or `Cancelled`. Both nil when it is on time or not known.
 */
struct LiveNote {
    var due: String? = nil
    var alert: String? = nil

    init() {}

    init(_ service: BoardDeparture) {
        if service.cancelled {
            alert = "Cancelled"
        } else if service.delayed {
            alert = "Delayed"
        } else if let late = service.minutesLate {
            due = "due \(ServiceDay.formatClock(service.dep).spoken)"
            alert = "\(late) min late"
        }
    }

    init(_ service: FastService) {
        if service.isDelayed {
            alert = "Delayed"
        } else if let late = service.minutesLate {
            due = "due \(ServiceDay.formatClock(service.departure).spoken)"
            alert = "\(late) min late"
        }
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

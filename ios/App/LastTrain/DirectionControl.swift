import SwiftUI

import LastTrainCore

/**
 The direction control, decided in IOS.md §4 after prototyping six arrangements.

 A 2×2 grid. Each block is clipped into a chevron pointing the way its trains go, and
 carries the direction word above `towards <destination>`. **The shape says which way,
 so the position does not have to** — which is what lets four directions fit in two
 rows where a compass cross needs three.

 Measured against the fold at 375×667, the smallest phone still supported. It was 118pt
 with all four directions showing; matching a departure block's height took it to about
 190pt, and **the last train still clears — by roughly 12pt rather than the 55 it had.**
 Re-measured on an iPhone SE, not calculated. The compass cross was 169pt and put the red
 block 41pt under, so there is still real distance from the arrangement that failed, but
 this is now the tightest the fold has been and the next thing added above the board is
 the thing that breaks it.

 Three things here are decisions, not details:

 - **Order is north, east, south, west** in reading order, which is compass order. A
   2×2 cannot be geographically faithful, so it matches the order directions are listed
   in everywhere else rather than inventing a second one.
 - **A direction with nothing running goes black**, so it reads as a hole in the control
   rather than a disabled button. The word stays: "nothing runs north" is a real answer
   and has to be legible as one.
 - **Never red.** A four-block control invites a colour, and red is spent. It means the
   last train and nothing else.
 */
struct DirectionControl: View {
    /**
     Which directions have track, from the board's `available`.

     Not a count. The service *count* per direction is whatever the destination-bearing
     pass saw, which is the rule §13 replaced — on a Saturday it reads nought southbound
     at Upminster while the board lists forty southbound trains, and the control drew a
     hole above them. Availability is topology, so it comes from the walked routes.
     */
    let available: Set<Compass>
    /// Where each direction's trains go, for the `towards` line.
    let towards: [Compass: String]
    @Binding var selection: Compass

    /**
     Every tap, including one that re-picks the direction already showing.

     `selection` alone cannot carry this: re-tapping the selected block writes the same
     value and SwiftUI reports no change, so a control that looks pressable does nothing
     — the failure this project keeps meeting at the other end of the masthead.

     Fast Train uses it to re-ask where you are going. The destination list belongs to
     one direction, so picking a direction and picking a destination are one gesture, not
     two. Last Train passes nothing and behaves exactly as before.
     */
    var onTap: ((Compass) -> Void)?

    @Environment(\.dynamicTypeSize) private var typeSize

    /**
     Two columns normally, one at accessibility text sizes.

     A 2×2 grid holds its columns at half the screen whatever the text does, so at the
     largest accessibility sizes each block is about 180pt wide and the destination
     hyphenates into `to-/wards Shoe-/bury-/ness`. That grows rather than clips, so it
     satisfies the letter of the Grow-Never-Clip Rule while being unreadable — and
     breaking a station name across hyphens is barely different from the truncation the
     Real Length Rule forbids.

     Collapsing to one column gives each block the full width back, so the names fit
     again. The control gets tall, which is correct: the layout grows downward.
     */
    private var columns: [GridItem] {
        typeSize.isAccessibilitySize
            ? [GridItem(.flexible(), spacing: 3)]
            : [GridItem(.flexible(), spacing: 3), GridItem(.flexible(), spacing: 3)]
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 3) {
            ForEach(Compass.allCases, id: \.self) { direction in
                DirectionBlock(
                    direction: direction,
                    towards: towards[direction],
                    state: state(for: direction),
                    action: {
                        selection = direction
                        onTap?(direction)
                    }
                )
            }
        }
        .padding(.horizontal, Theme.Space.gutter)
    }

    private func state(for direction: Compass) -> DirectionBlock.State {
        guard available.contains(direction) else { return .empty }
        return direction == selection ? .selected : .available
    }
}

struct DirectionBlock: View {
    enum State {
        case selected
        case available
        /// Nothing runs this way today.
        case empty
    }

    let direction: Compass
    let towards: String?
    let state: State
    let action: () -> Void

    /**
     Stroke width of an emboss facet. Clipped to the block, so half of it shows.

     Three was the old lit edge's weight and far too heavy for this: at 168pt wide a 3pt
     line across the top of a block reads as an underline, not as light catching an edge.
     An emboss is a hairline or it is a stripe.
     */
    private let edgeWidth: CGFloat = 2

    /**
     A rung larger than the shared labels, and local rather than a change to them.

     `Theme.Font.label` and `.meta` are 11 and 12, which is right where they are used —
     under a departure time, beside a heading — and small on a block you read at arm's
     length while walking. Both move up to `.footnote` here: two points on the direction
     word, one on the place.

     Still Dynamic Type text styles rather than point sizes, so they scale with the
     setting; and still local, because raising the tokens would grow the platform line, the
     operator badge and every heading in the app along with them.
     */
    private let directionFont = SwiftUI.Font.system(.footnote).weight(.bold)
    private let towardsFont = SwiftUI.Font.system(.footnote).weight(.semibold)

    /**
     One height for every block, so the four arrows drawn on them match.

     Rows sized themselves before, so row one and row two were different heights whenever
     one destination wrapped and another did not — which the old full-span arrows then
     turned into different shapes. A minimum rather than a fixed height: it scales with
     the text setting, and a name long enough to need a third line still grows the block
     instead of being cut.

     **96 to match a departure block**, so the board keeps one module height from the
     direction control to the last train rather than two. Matched by eye against the
     rendered row rather than computed from it: a departure block is a badge line, a time
     and a platform line inside 11pt of padding, and tying this to that sum would couple
     two views that have no other reason to know about each other. It is a visual rhyme, so
     it is allowed to be approximate — but it costs 44pt of the fold, which the note above
     about 375×667 is the reason to keep watching.
     */
    @ScaledMetric(relativeTo: .caption) private var blockHeight: CGFloat = 96

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                /*
                 `EAST towards` on one line, the place on the next.

                 It was the direction on one line and `towards Shoeburyness` on the next,
                 which spent a whole line on a preposition and left the destination to
                 wrap — so blocks ended up different heights and the arrows drawn on them
                 stopped matching. One line saved per block is what makes equal heights
                 affordable, and it reads as a sentence rather than a label stacked on a
                 caption.
                */
                if state != .empty, towards != nil {
                    Text(direction.rawValue.uppercased())
                        .font(directionFont)
                        .tracking(Theme.tracking)
                        + Text(" towards")
                        .font(towardsFont)
                } else {
                    Text(direction.rawValue.uppercased())
                        .font(directionFont)
                        .tracking(Theme.tracking)
                }

                if state != .empty, let towards {
                    // The Real Length Rule: station names are never truncated and never
                    // ellipsised. A long one wraps and the block grows to hold it.
                    Text(towards.withoutLondonPrefix)
                        .font(towardsFont)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(1...)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            /*
             One inset, all four sides, every block.

             The arrow sits on a different edge per direction, so per-direction padding
             was four different insets and text that started in a different place
             depending on which way the trains went. Reserving the arrow's depth on every
             side costs 12pt where it is not needed and buys text that lines up across the
             whole control — which is what makes four blocks read as one thing.
            */
            .padding(
                .horizontal,
                12 + (direction == .east || direction == .west ? ChevronBlock.horizontalDepth : 0)
            )
            .padding(.vertical, 10 + ChevronBlock.verticalDepth)
            .frame(minHeight: blockHeight)
            .background(background)
            .foregroundStyle(foreground)
            .clipShape(ChevronBlock(direction: direction))
            .overlay {
                /*
                 The emboss.

                 **Each facet is the block's own colour, moved.** Built first with white at
                 part opacity, which looked right in a mock-up and cheap on a phone: a white
                 line drawn on a dark shape is an outline, not light falling across one. The
                 lit facet is now the fill lifted a few steps and the shaded facet is the
                 ground beneath it, so both belong to the material rather than sitting on
                 top of it.

                 State left with the white. It is carried by the fill — blue selected, grey
                 available, black empty — which it always was, so the emboss is free to be
                 only what it looks like. A direction with no trains gets **neither facet**:
                 it is a hole in the control, and lighting or shading it would model a shape
                 with nothing in it.

                 Both strokes are clipped to the block, so each shows only its inner half
                 and sits flush with the edge rather than bleeding into the gap.
                */
                if let lit = embossLit {
                    ZStack {
                        EmbossFacets(direction: direction, lit: false)
                            .stroke(
                                Theme.ink.opacity(0.7),
                                style: StrokeStyle(lineWidth: edgeWidth, lineJoin: .miter)
                            )
                        EmbossFacets(direction: direction, lit: true)
                            .stroke(
                                lit,
                                style: StrokeStyle(lineWidth: edgeWidth, lineJoin: .miter)
                            )
                    }
                    .clipShape(ChevronBlock(direction: direction))
                }
            }
            .contentShape(ChevronBlock(direction: direction))
        }
        .buttonStyle(PressLift())
        .disabled(state == .empty)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(state == .selected ? [.isSelected] : [])
    }

    /// The block's own fill, lifted. Nil where there is nothing to light.
    private var embossLit: Color? {
        switch state {
        case .selected: Theme.serviceBlueLit
        case .available: Theme.controlLit
        case .empty: nil
        }
    }

    private var background: Color {
        switch state {
        case .selected: Theme.serviceBlue
        case .available: Theme.control
        // Black, so it reads as absence rather than as a control you are not allowed
        // to press.
        case .empty: Theme.ink
        }
    }

    private var foreground: Color {
        switch state {
        case .selected: Theme.paper
        case .available: Theme.textDim
        case .empty: Theme.textFaint
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .empty:
            "\(direction.rawValue)bound. No services run this way today."
        case .selected, .available:
            towards.map { "\(direction.rawValue)bound, towards \($0)" }
                ?? "\(direction.rawValue)bound"
        }
    }
}

/**
 A block with a chevron bitten out of one edge and pushed out of the opposite one, so
 the whole shape points the way the train goes.

 The notch is 14% of the short axis — enough to read as an arrow at a glance from arm's
 length, shallow enough to leave the label a rectangle to sit in.
 */
struct ChevronBlock: Shape {
    let direction: Compass

    /**
     One arrow, the same size on every block, and nothing bitten out of the far edge.

     **The arrow no longer spans the edge, and that is the whole point.** It used to run
     corner to apex to corner, so its angle was set by depth against span — and the span
     was whatever the block happened to be. East and west spanned the block's height,
     which changes the moment `towards Fenchurch Street` wraps and `towards Pitsea` does
     not; north and south spanned the width, which at a fixed depth flattened them into a
     slant. Four arrows that were never the same shape twice, redrawn by every text size.
     Tuning the numbers could not fix it: blocks of different aspect ratios cannot share
     an angle while the arrow spans the full edge. The `14`/`7` split was already an
     attempt to hide that.

     A fixed span and a fixed depth give one angle everywhere, by construction, at any
     size. Mocked up against the alternative — a constant angle with the depth derived
     from the span — which showed the vertical notch going past 20pt and north and south
     biting into each other again, which is a fault this control has already had once.

     The matching indent on the opposite edge is gone too. It existed so blocks could
     interlock, and interlocking is what let them nest into one another.
     */
    static let horizontalDepth: CGFloat = 14
    static let verticalDepth: CGFloat = 7

    static func depth(for direction: Compass) -> CGFloat {
        switch direction {
        case .east, .west: horizontalDepth
        case .north, .south: verticalDepth
        }
    }

    /**
     A point on the edge it faces, and a straight edge everywhere else.

     Two shapes were built and rejected on device before this one. A fixed arrowhead
     centred on the edge kept its angle everywhere, which was the goal, but the corners it
     cut back showed the background through them and read as wedges bitten out of the
     *gaps* rather than as arrows on the blocks; insetting every side to fix that left the
     tips spiking into the channels between blocks like stray marks. Neither looked like a
     departure board.

     What the arrow actually needed was not a fixed size but a fixed *canvas*, and
     `blockHeight` now provides it. With every block the same size, a point that spans its
     edge has one angle across the control and keeps it at any text size — which is the
     whole of the complaint — while the silhouette stays the bold thing it was.

     The matching indent on the opposite edge stays gone. It existed so blocks could
     interlock, and interlocking is what let north and south nest into each other.
     */
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        // Different per axis because the axes are: the point spans 168pt across the top
        // and about 74 down the side, so one depth would be two very different angles.
        let d = direction == .north || direction == .south
            ? min(Self.verticalDepth, h / 3)
            : min(Self.horizontalDepth, w / 3)
        var path = Path()

        let points: [CGPoint] = switch direction {
        case .north:
            [
                CGPoint(x: 0, y: d),
                CGPoint(x: w / 2, y: 0),
                CGPoint(x: w, y: d),
                CGPoint(x: w, y: h),
                CGPoint(x: 0, y: h),
            ]
        case .south:
            [
                CGPoint(x: 0, y: 0),
                CGPoint(x: w, y: 0),
                CGPoint(x: w, y: h - d),
                CGPoint(x: w / 2, y: h),
                CGPoint(x: 0, y: h - d),
            ]
        case .east:
            [
                CGPoint(x: 0, y: 0),
                CGPoint(x: w - d, y: 0),
                CGPoint(x: w, y: h / 2),
                CGPoint(x: w - d, y: h),
                CGPoint(x: 0, y: h),
            ]
        case .west:
            [
                CGPoint(x: d, y: 0),
                CGPoint(x: w, y: 0),
                CGPoint(x: w, y: h),
                CGPoint(x: d, y: h),
                CGPoint(x: 0, y: h / 2),
            ]
        }

        path.addLines(points)
        path.closeSubpath()
        return path
    }
}

/**
 The two segments that make the point, as an open path.

 Not the whole outline — only the leading edge, so the block reads as travelling that
 way rather than as a box with a border. The notch on the trailing edge stays dark,
 which is what keeps the arrow legible: one lit edge, one bitten one.

 Uses the same per-axis notch depth as `ChevronBlock`, or the line would sit off the
 shape on the north and south blocks.
 */
/**
 The lit or shaded facets of a block, for the emboss.

 One light, from the top left, on all four blocks — which is what makes them read as a
 set. The top edge and the arrow's upper facet catch it; the bottom edge and the lower
 facet fall into shadow.

 This replaces a shape that stroked the *pointing* edge to say which way the block faced.
 That job now belongs to the silhouette, and the highlight is free to do the other one it
 was quietly doing: carrying state through its brightness.
 */
struct EmbossFacets: Shape {
    let direction: Compass
    /// The half catching the light, rather than the half in shadow.
    let lit: Bool

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let d = direction == .north || direction == .south
            ? min(ChevronBlock.verticalDepth, h / 3)
            : min(ChevronBlock.horizontalDepth, w / 3)
        var path = Path()

        // Each run is contiguous: the lit half walks the top edge and carries straight on
        // up the point's near facet, so light turns the corner the way it would on a
        // folded surface.
        switch (direction, lit) {
        case (.north, true):
            path.addLines([
                CGPoint(x: 0, y: d), CGPoint(x: w / 2, y: 0), CGPoint(x: w, y: d),
            ])
        case (.north, false):
            path.addLines([CGPoint(x: 0, y: h), CGPoint(x: w, y: h)])

        case (.south, true):
            path.addLines([CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0)])
        case (.south, false):
            path.addLines([
                CGPoint(x: 0, y: h - d), CGPoint(x: w / 2, y: h), CGPoint(x: w, y: h - d),
            ])

        case (.east, true):
            path.addLines([
                CGPoint(x: 0, y: 0), CGPoint(x: w - d, y: 0), CGPoint(x: w, y: h / 2),
            ])
        case (.east, false):
            path.addLines([
                CGPoint(x: w, y: h / 2), CGPoint(x: w - d, y: h), CGPoint(x: 0, y: h),
            ])

        case (.west, true):
            path.addLines([
                CGPoint(x: 0, y: h / 2), CGPoint(x: d, y: 0), CGPoint(x: w, y: 0),
            ])
        case (.west, false):
            path.addLines([
                CGPoint(x: 0, y: h / 2), CGPoint(x: d, y: h), CGPoint(x: w, y: h),
            ])
        }

        return path
    }
}

#Preview("Four directions — Inverness") {
    DirectionControlPreview(
        counts: [.north: 8, .east: 17, .south: 14, .west: 4],
        towards: [
            .north: "Wick", .east: "Aberdeen",
            .south: "Edinburgh", .west: "Kyle of Lochalsh",
        ],
        selection: .north
    )
}

#Preview("Three directions — Upminster") {
    DirectionControlPreview(
        counts: [.north: 0, .east: 110, .south: 16, .west: 139],
        towards: [.east: "Shoeburyness", .south: "Grays", .west: "Fenchurch Street"],
        selection: .west
    )
}

private struct DirectionControlPreview: View {
    let counts: [Compass: Int]
    let towards: [Compass: String]
    @State var selection: Compass

    var body: some View {
        DirectionControl(
            available: Set(counts.filter { $0.value > 0 }.keys),
            towards: towards,
            selection: $selection
        )
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface)
    }
}

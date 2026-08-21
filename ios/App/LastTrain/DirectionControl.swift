import SwiftUI

import LastTrainCore

/**
 The direction control, decided in IOS.md §4 after prototyping six arrangements.

 A 2×2 grid of tabs. Each is clipped into a chevron pointing the way its trains go and
 carries the direction word above where those trains lead. **The shape says which way, so
 the position does not have to** — which is what lets four directions fit in two rows
 where a compass cross needs three.

 Measured against the fold at 375×667, the smallest phone still supported. The blocks were
 118pt, then 190 once they matched a departure block's height, which left the last train
 clearing by about 12pt. As tabs they are **116** — measured on screen, not calculated —
 so roughly 84pt comes back and the margin is comfortable again. The compass cross was
 169pt and put the red block 41pt under; that remains the arrangement to stay away from.

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
     Four across, two at accessibility text sizes.

     **The blocks were 96 tall and the two rows cost 203pt**, which left the board clearing
     the fold on a 375×667 phone by twelve. One row of tabs costs about 76 — the saving the
     whole change was for.

     **The destination is why this is one row and not four labelled tiles.** A quarter of a
     402pt screen is roughly 90pt, and at that width `Shoeburyness` hyphenates into
     `Shoebury-/ness` at every inset worth having — which this project treats as the
     truncation the Real Length Rule forbids, arrived at by another route. Compass words are
     short and near enough the same length, so they fit a quarter easily; a station name
     does not. So the tabs carry the word and the line beneath carries the place, across the
     full width, where nothing has to break.

     Two columns at accessibility sizes, where even the compass words outgrow a quarter.
     */
    private var columns: [GridItem] {
        let column = GridItem(.flexible(), spacing: 3)
        return typeSize.isAccessibilitySize
            ? [column, column]
            : [column, column, column, column]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
            destinationLine
        }
        .padding(.horizontal, Theme.Space.gutter)
    }

    /**
     Where the selected direction goes, under the row.

     The 2×2 could name all four at once and this cannot, which is the real cost of one
     row: the directions you are not looking at stop answering "east to what?". What it
     keeps is the answer for the one you *are* looking at, at full width, where a long name
     never has to break.

     **The line is always laid out**, even when there is nothing to say — a station with no
     destination for a direction, or a board that has not arrived. Otherwise picking a
     direction moves the entire board up or down by twenty points as the line comes and
     goes, which is the same fault the departure blocks were fixed for.
     */
    private var destinationLine: some View {
        Text(towards[selection].map { "towards \($0.withoutLondonPrefix)" } ?? " ")
            .font(SwiftUI.Font.system(.footnote).weight(.semibold))
            .foregroundStyle(Theme.textDim)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 7)
            .padding(.horizontal, 2)
            .accessibilityHidden(towards[selection] == nil)
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
    /**
     Where this direction goes — spoken, never drawn.

     The tab shows only the compass word; the line under the row shows the destination for
     whichever tab is chosen. That works by eye and fails by ear: someone moving through
     the four with VoiceOver hears the line only once, attached to nothing they are on. So
     each tab still carries its own destination and says it aloud.
     */
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

     `Theme.Font.label` is 11, which is right under a departure time and small on a control
     read at arm's length while walking. `.footnote` here is two points more. Still a
     Dynamic Type text style, so it still scales; still local, because raising the token
     would grow the platform line, the operator badge and every heading with it.
     */
    private let directionFont = SwiftUI.Font.system(.footnote).weight(.bold)

    /**
     One height for every block, so the four arrows drawn on them match.

     Rows sized themselves before, so row one and row two were different heights whenever
     one destination wrapped and another did not — which the old full-span arrows then
     turned into different shapes. A minimum rather than a fixed height: it scales with
     the text setting, and a name long enough to need a third line still grows the block
     instead of being cut.

     **`Theme.Space.tap`, and that is the floor rather than a preference.** They were 96 to
     rhyme with a departure block, which was worth having while there were two rows and cost
     44pt of the fold. One row of four carries a word each, so the height is whatever keeps
     it comfortably pressable one-handed — the token that already means exactly that — and
     the fold gets everything else.
     */
    @ScaledMetric(relativeTo: .caption) private var blockHeight: CGFloat = Theme.Space.tap

    var body: some View {
        Button(action: action) {
            /*
             One word, and the place it goes lives under the row.

             `EAST towards Shoeburyness` read as a sentence across a half-width block and
             fits nothing at a quarter of one. The tab is the word; `DirectionControl`'s
             line beneath carries the destination for whichever tab is chosen.
            */
            Text(direction.rawValue.uppercased())
                .font(directionFont)
                .tracking(Theme.tracking)
            .frame(maxWidth: .infinity)
            /*
             Centred, and padded to clear the point on whichever edge carries it.

             Left-aligned text in a quarter-width tab sits under its own arrow at one end
             and leaves a hole at the other.

             The point is cleared only on the edge that has one. Padding every side for it
             cost 20pt of a 90pt tab and `Shoeburyness` hyphenated into `Shoebury-/ness` —
             which the old 2×2 comment predicted almost word for word, and which this
             project treats as truncation by another route.
            */
            .padding(.leading, 4 + (direction == .west ? ChevronBlock.horizontalDepth : 0))
            .padding(.trailing, 4 + (direction == .east ? ChevronBlock.horizontalDepth : 0))
            .padding(.vertical, 6 + ChevronBlock.verticalDepth)
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
 A tab with a point on the edge it faces, and a straight edge everywhere else.

 The matching indent on the opposite edge is gone: it existed so blocks could interlock,
 and interlocking is what let north and south nest into one another.
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
    static let horizontalDepth: CGFloat = 10
    static let verticalDepth: CGFloat = 5

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

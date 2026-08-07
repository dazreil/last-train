import SwiftUI

import LastTrainCore

/**
 The direction control, decided in IOS.md §4 after prototyping six arrangements.

 A 2×2 grid. Each block is clipped into a chevron pointing the way its trains go, and
 carries the direction word above `towards <destination>`. **The shape says which way,
 so the position does not have to** — which is what lets four directions fit in two
 rows where a compass cross needs three.

 Measured against the fold at 375×667, the smallest phone still supported: this is
 118pt with all four directions showing, and the last train still clears. The compass
 cross was 169pt and put the red block 41pt under.

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
                    // Reserving a second line keeps four side-by-side blocks the same
                    // height. Stacked in one column there is nothing to match, and the
                    // reserve would only add empty rows to an already tall control.
                    reservesSecondLine: !typeSize.isAccessibilitySize,
                    action: { selection = direction }
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
    var reservesSecondLine = true
    let action: () -> Void

    /// Visible thickness of the lit edge. Doubled and clipped, so this is what shows.
    private let edgeWidth: CGFloat = 4

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(direction.rawValue)
                    .font(Theme.Font.label)
                    .tracking(Theme.tracking)
                    .textCase(.uppercase)

                if state != .empty, let towards {
                    // Reads the way the sliding block reads. No service count -- the
                    // number was never the question, and a direction only means
                    // something once you know where it goes.
                    //
                    // The Real Length Rule: station names are never truncated and never
                    // ellipsised. A long one wraps and the row grows to hold it.
                    Text("towards \(towards.withoutLondonPrefix)")
                        .font(Theme.Font.meta)
                        .fixedSize(horizontal: false, vertical: true)
                        // Two lines of space, always, whether or not this name needs
                        // them. Otherwise a block whose destination happens to wrap is
                        // taller than the one beside it, and four blocks that are meant
                        // to read as a set stop looking like one.
                        //
                        // A range rather than a limit: `lineLimit(2)` would *truncate* a
                        // third line, and the Real Length Rule forbids that. This
                        // reserves two and still grows.
                        .lineLimit(reservesSecondLine ? 2... : 1...)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The label must clear the notch. Without this the chevron eats the first
            // letter -- "EAST" renders as "AST" -- which is the Real Length Rule broken
            // by geometry rather than by an ellipsis, and just as wrong.
            //
            // East and west take the same leading inset even though only east needs it
            // for clearance. They sit one above the other in the right-hand column, and
            // text that starts 14pt further left on one of them reads as a mistake
            // rather than as a consequence of which way the chevron points.
            .padding(
                .leading,
                12 + (direction == .east || direction == .west ? ChevronBlock.horizontalNotch : 0)
            )
            .padding(.trailing, 12 + (direction == .west ? ChevronBlock.horizontalNotch : 0))
            .padding(.top, 10 + (direction == .south ? ChevronBlock.verticalNotch : 0))
            .padding(.bottom, 10 + (direction == .north ? ChevronBlock.verticalNotch : 0))
            .frame(minHeight: 58)
            .background(background)
            .foregroundStyle(foreground)
            .clipShape(ChevronBlock(direction: direction))
            .overlay {
                // Only where something runs. A blacked-out block is a hole in the
                // control, and lighting its edge would draw the eye to a direction
                // with no trains in it.
                if state != .empty {
                    PointingEdge(direction: direction)
                        .stroke(
                            Theme.paper.opacity(state == .selected ? 1 : 0.55),
                            style: StrokeStyle(lineWidth: edgeWidth * 2, lineJoin: .miter)
                        )
                        // Clipped to the same chevron, so the stroke is centred on the
                        // boundary and only its inner half shows. That leaves a crisp
                        // line flush with the block edge rather than one bleeding into
                        // the gap between blocks.
                        .clipShape(ChevronBlock(direction: direction))
                }
            }
            .contentShape(ChevronBlock(direction: direction))
        }
        .buttonStyle(.plain)
        .disabled(state == .empty)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(state == .selected ? [.isSelected] : [])
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
     Notch depth, in points rather than a proportion, and different on each axis.

     A percentage was the obvious first choice and it is wrong twice over. It grows with
     the block, so the padding keeping the label clear has to grow too and the two drift
     apart under Dynamic Type until the first letter disappears. And the blocks are far
     wider than they are tall, so one proportion is two different depths: 7% of the
     width but a quarter of the height.

     That second error was visible on device — north and south nested into each other
     and the left column read as a single shape rather than two blocks. The vertical
     notch is shallower to match how much less room it has.
     */
    static let horizontalNotch: CGFloat = 14
    static let verticalNotch: CGFloat = 7

    static func notch(for direction: Compass) -> CGFloat {
        switch direction {
        case .east, .west: horizontalNotch
        case .north, .south: verticalNotch
        }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        // Never eat more than a third of the block, however small it gets.
        let n = min(Self.notch(for: direction), min(w, h) / 3)
        var path = Path()

        let points: [CGPoint] = switch direction {
        case .north:
            [
                CGPoint(x: 0, y: n),
                CGPoint(x: w / 2, y: 0),
                CGPoint(x: w, y: n),
                CGPoint(x: w, y: h),
                CGPoint(x: w / 2, y: h - n),
                CGPoint(x: 0, y: h),
            ]
        case .south:
            [
                CGPoint(x: 0, y: 0),
                CGPoint(x: w / 2, y: n),
                CGPoint(x: w, y: 0),
                CGPoint(x: w, y: h - n),
                CGPoint(x: w / 2, y: h),
                CGPoint(x: 0, y: h - n),
            ]
        case .east:
            [
                CGPoint(x: 0, y: 0),
                CGPoint(x: w - n, y: 0),
                CGPoint(x: w, y: h / 2),
                CGPoint(x: w - n, y: h),
                CGPoint(x: 0, y: h),
                CGPoint(x: n, y: h / 2),
            ]
        case .west:
            [
                CGPoint(x: n, y: 0),
                CGPoint(x: w, y: 0),
                CGPoint(x: w - n, y: h / 2),
                CGPoint(x: w, y: h),
                CGPoint(x: n, y: h),
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
struct PointingEdge: Shape {
    let direction: Compass

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let n = min(ChevronBlock.notch(for: direction), min(w, h) / 3)

        let points: [CGPoint] = switch direction {
        case .north:
            [CGPoint(x: 0, y: n), CGPoint(x: w / 2, y: 0), CGPoint(x: w, y: n)]
        case .south:
            [CGPoint(x: 0, y: h - n), CGPoint(x: w / 2, y: h), CGPoint(x: w, y: h - n)]
        case .east:
            [CGPoint(x: w - n, y: 0), CGPoint(x: w, y: h / 2), CGPoint(x: w - n, y: h)]
        case .west:
            [CGPoint(x: n, y: 0), CGPoint(x: 0, y: h / 2), CGPoint(x: n, y: h)]
        }

        var path = Path()
        path.addLines(points)
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

import SwiftUI

import LastTrainCore

extension BoardView {
    // MARK: - Header

    /**
     The mode, and the only place it is named.

     `PRODUCT.md` always had Fast Train reached "by a deliberate tap on the title"; the
     segmented pill came later, and then the screen said the same word twice — once as a
     heading and once as a control. This is the two merged back into one: the mode you are
     in reads in full, and the one you are not sits beside it, dim and a tap away.

     Same grammar as the direction row below it — the choices inline, the live one lit,
     the rest quiet — so the header, the journey and the compass read as one instrument
     instead of three unrelated controls.
     */
    var masthead: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(mode.wordmark)
                .font(.system(.headline, design: .rounded).weight(.semibold))
                .tracking(4.2)
                // Blue in both modes. The lit word is the one you are in; which question
                // it is, the word itself already says.
                .foregroundStyle(Theme.serviceBlueLit)
                .shadow(color: Theme.serviceBlue.opacity(0.6), radius: 8)
                // Shrinks rather than holding its width: at the larger text sizes the two
                // words and the gear no longer fit, and a masthead that will not give way
                // widens the whole page past the screen edges.
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .layoutPriority(1)
                .accessibilityAddTraits(.isHeader)

            Button {
                withAnimation(.snappy(duration: 0.24)) { mode = mode.other }
            } label: {
                Text(mode.other.wordmark)
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .tracking(Theme.tracking)
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressDim())
            .accessibilityLabel(
                mode.other == .last ? "Switch to Last Train" : "Switch to Fast Train"
            )

            Spacer(minLength: 0)

            // Home journey, credits and the facts the footer used to carry. The footer
            // pushed the board into scrolling; this costs nothing on the board itself.
            Button { presented = .settings } label: {
                Group {
                    if isRefreshing {
                        ProgressView().tint(Theme.textDim)
                    } else {
                        Image(systemName: "gearshape")
                            .font(.system(.body, design: .rounded).weight(.semibold))
                            .foregroundStyle(Theme.textFaint)
                    }
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressDim())
            .accessibilityLabel("Settings and credits")
        }
        /*
         Hold the masthead to refresh. It replaced pull-to-refresh, which needed the board
         to scroll: a board that moves under a thumb on a platform reads as a web page, and
         a refresh by accident costs an upstream request. Holding is deliberate and works
         one-handed. Returning to the app after a minute already refreshes on its own, so
         this is for the case where you want it *now*.
         */
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.5) { Task { await refresh() } }
        .sensoryFeedback(.impact(weight: .medium), trigger: refreshRequests)
        .accessibilityAction(named: "Refresh") { Task { await refresh() } }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.top, 18)
    }

    /// The directions, inline under the station name. The chosen one leads, lit blue; the
    /// other available ones follow in grey; a direction that does not run from here keeps
    /// its slot but is invisible and dead, held to the right so the visible ones never
    /// shift. Every compass point owns one of four equal columns, so the spacing is the
    /// same whether a station offers two directions or four.
    var directionPicker: some View {
        let selected = model.direction
        let available = model.available
        let avail = available.isEmpty
            ? [selected]
            : Compass.allCases.filter { available.contains($0) }
        // The chosen direction leads only when this station has it. A station picked while
        // the old direction does not run from it (Fenchurch Street, with west still chosen)
        // put that direction in twice — once leading, once as a held gap — and five words,
        // at a larger text size, were wider than the screen and pushed the whole app wide.
        let lead = avail.contains(selected) ? [selected] : []
        let ordered = lead + avail.filter { $0 != selected } + Compass.allCases.filter { !avail.contains($0) }

        return HStack(spacing: 20) {
            ForEach(ordered, id: \.self) { direction in
                if avail.contains(direction) {
                    Button {
                        withAnimation(.snappy(duration: 0.28)) { model.direction = direction }
                        directionChosen = true
                        // Choosing a direction is choosing a new journey, so the old
                        // destination goes. Fast then opens the list of where to; Last needs
                        // no destination to name a last train, so it just shows this way.
                        if let station = model.station {
                            fast.clearDestination(at: station, direction: direction)
                            if mode == .fast { fast.askWhereTo() }
                        }
                    } label: {
                        directionLabel(direction, isSelected: directionChosen && direction == selected)
                    }
                    .buttonStyle(PressDim())
                    .accessibilityLabel(direction.rawValue.capitalized)
                    .accessibilityValue(model.towards[direction].map { "towards \($0)" } ?? "")
                    .accessibilityAddTraits(directionChosen && direction == selected ? .isSelected : [])
                } else {
                    // The slot is held, not filled: invisible and untappable, so a missing
                    // direction costs no realignment of the ones that are there.
                    directionLabel(direction, isSelected: false)
                        .opacity(0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            // Words are their own width now, so the row needs telling where to sit.
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Direction")
    }

    /// One direction word in its column: blue when it is the chosen one, grey otherwise,
    /// always the same size so a missing point never changes the layout.
    func directionLabel(_ direction: Compass, isSelected: Bool) -> some View {
        Text(direction.rawValue)
            .font(.system(.subheadline, design: .rounded).weight(.bold))
            .tracking(Theme.tracking)
            .textCase(.uppercase)
            .foregroundStyle(isSelected ? Theme.serviceBlueLit : Theme.textDim)
            .lineLimit(1)
            // Sized to the word, not to a share of the row. Equal columns put an equal
            // *box* around each, which is not the same as an equal gap between them:
            // SOUTH is a letter longer than EAST and WEST, so leading the row it filled
            // more of its column and the space after it closed up. The eye reads the gap,
            // so the gap is what is held constant.
            .fixedSize(horizontal: true, vertical: false)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}

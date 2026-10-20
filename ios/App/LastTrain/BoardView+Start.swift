import SwiftUI

import LastTrainCore

extension BoardView {
    /// Shown when a station has been picked but no direction chosen yet. The compass row
    /// above is one answer and a destination the other: a destination sets the direction.
    var directionPrompt: some View {
        stepHint("Choose a direction or a destination") { fast.askWhereTo() }
    }

    /**
     A new start, keeping the destination only if a train still runs between them.

     `onLine` is the whole reset rule. It is true when the station came from the list,
     which was built from the destination's own reachable set — so the pair is valid by
     construction, and the destination is simply re-filed under the new pair. It is false
     when the station came from the search box, which knows all 2,619 stations and nothing
     about this journey: that is a new journey, and the destination goes.

     The destination is stored per start-and-direction, so keeping it means writing it
     under the new start rather than merely not deleting it.
     */
    func adoptStart(_ picked: Station, keepingDestination: Bool) {
        if keepingDestination, let end = fast.destination {
            fast.choose(end, at: picked, direction: model.direction)
        } else {
            fast.clearDestination(at: picked, direction: model.direction)
            // A new journey from somewhere else: the old direction was about the old
            // station, and may not even run from this one.
            directionChosen = false
        }
        model.station = picked
        UsageStore.record(picked)
    }

    /**
     The station, picked from the plain search or from near you.

     Always a new journey, so the direction goes back to unchosen when the station actually
     changes: "west" meant something at the last station and may mean nothing here. The
     destination sheet then offers every direction, and the destination picks one.
     */
    var freshStart: Binding<Station?> {
        Binding(
            get: { model.station },
            set: { picked in
                if picked?.crs != model.station?.crs { directionChosen = false }
                model.station = picked
                if let picked { UsageStore.record(picked) }
            }
        )
    }

    /**
     A new destination, and — when no direction was chosen — the direction with it.

     `heading` is the section the tapped row sat in, so it is the way a direct train goes
     there, by construction. The order matters: the destination is filed under the new
     direction **before** the direction changes, because changing it re-reads whatever is
     filed there, and would otherwise find nothing.
     */
    func adoptEnd(_ picked: Station, from start: Station, onLine: Bool, heading: Compass?) {
        guard onLine else {
            fast.clearDestination(at: picked, direction: model.direction)
            directionChosen = false
            model.station = picked
            UsageStore.record(picked)
            return
        }
        let direction = directionChosen ? model.direction : (heading ?? model.direction)
        fast.choose(picked, at: start, direction: direction)
        directionChosen = true
        model.direction = direction
        JourneyStore.record(from: start, to: picked, direction: direction)
    }

    /// One half of the bar. Dim and named while empty, lit and coded once set.
    /// The two codes and the arrow between them, at one text style.
    func codes(_ style: Font.TextStyle) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            codeButton(
                model.station?.crs,
                placeholder: "Where?",
                style: style,
                label: "Departure station, \(model.station?.name ?? "not set")"
            ) {
                model.clearNearby()
                presented = .start
            }

            if model.station != nil {
                Image(systemName: "arrow.right")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.textDim)
                    .accessibilityHidden(true)

                codeButton(
                    fast.destination?.crs,
                    placeholder: "—",
                    style: style,
                    label: "Destination, \(fast.destination?.name ?? "not set")"
                ) {
                    fast.askWhereTo()
                }
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    func codeButton(
        _ crs: String?,
        placeholder: String,
        style: Font.TextStyle,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        let text = Text(crs ?? placeholder)
            .font(.system(style, design: .rounded).weight(.medium))
            .monospacedDigit()
            .foregroundStyle(crs == nil ? Theme.textDim : Theme.text)
            .lineLimit(1)
            .contentShape(Rectangle())
        // Hold either code for recent journeys, the one hold the bar did not have yet.
        // A plain button until there is a journey to offer, so the hold never opens empty.
        if JourneyStore.list(excluding: model.station, fast.destination).isEmpty {
            Button(action: action) { text }
                .buttonStyle(PressDim())
                .accessibilityLabel(label)
        } else {
            Menu { recentJourneysMenu } label: { text } primaryAction: { action() }
                .modifier(BarMenuStyle())
                .accessibilityLabel(label)
        }
    }

    var stationHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            journeyBar

            if model.station != nil { directionPicker }

            // No day to step through before there is a board: a station, and a direction or a
            // destination chosen (BUG-002). Fast Train's pager is its own rule, unchanged.
            if (mode == .last && model.station != nil && directionChosen) || fast.canPage { dayControl }

            if let locateError = model.locateError {
                SettingsLink(enabled: LocationFinder.isDenied) {
                    Text(locateError).font(Theme.Font.meta).foregroundStyle(Theme.textDim)
                }
            }
        }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.top, 16)
    }

    /// The nearest-station control, now an arrow alone in the station box — the label went
    /// to save the room, the action did not.
    ///
    /// Hold for the menu in `HOLD-MENUS.md` §2: Nearest (the tap), then the stations you
    /// start from most, then the most recent that are not already listed.
    var locateButton: some View {
        Menu {
            Button("Nearest station", systemImage: "location.fill") { locate() }
            let lists = UsageStore.menuLists()
            if !lists.mostUsed.isEmpty {
                Section("Most used") {
                    ForEach(lists.mostUsed, id: \.crs) { station in
                        Button("\(station.name.withoutLondonPrefix) · \(station.crs)") { startFrom(station) }
                    }
                }
            }
            if !lists.recent.isEmpty {
                Section("Recent") {
                    ForEach(lists.recent, id: \.crs) { station in
                        Button("\(station.name.withoutLondonPrefix) · \(station.crs)") { startFrom(station) }
                    }
                }
            }
        } label: {
            Group {
                if model.isLocating { ProgressView().tint(Theme.textDim) }
                else { barIcon("location.fill") }
            }
            .frame(width: 44, height: 44)
        } primaryAction: {
            locate()
        }
        .modifier(BarMenuStyle())
        .disabled(model.isLocating)
        .accessibilityLabel("Nearest station")
    }

    func locate() {
        Task {
            await model.locate()
            // Found some — offer them in the picker. A failure leaves the one-line
            // reason under the bar instead.
            if !model.nearby.isEmpty { presented = .nearby }
        }
    }
}

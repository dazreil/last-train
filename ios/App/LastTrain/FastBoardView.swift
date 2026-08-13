import SwiftUI

import LastTrainCore

/**
 Fast Train.

 The same station and the same direction as the board behind it, plus one thing the board
 refuses to ask for: where you are going. That is why it is a separate mode reached by a
 deliberate tap, and why `PRODUCT.md` records the exception rather than quietly widening
 the promise.

 **No red here.** Red means the last train of the service day and nothing else. Nothing on
 this screen is that, so nothing on this screen is red — not even the train that gets you
 there first.
 */
struct FastBoardView: View {
    let station: Station
    let direction: Compass
    @Bindable var model: FastModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            destinationField

            if model.destination == nil {
                whereTo
            } else {
                results
            }
        }
        .sheet(isPresented: $model.isChoosing) {
            DestinationPicker(station: station, direction: direction, model: model)
        }
        // The remembered destination belongs to one station and one direction, so it is
        // re-read whenever either changes.
        .task(id: "\(station.crs):\(direction.rawValue)") {
            model.adopt(station: station, direction: direction)
        }
    }

    // MARK: - Where you are going

    private var destinationField: some View {
        Button {
            model.askWhereTo()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("To").labelStyle()
                Text(model.destination?.name ?? "Choose a destination")
                    .font(Theme.Font.heading)
                    .foregroundStyle(model.destination == nil ? Theme.textFaint : Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 13)
            .background(Theme.raised)
            .overlay(Rectangle().strokeBorder(Theme.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.top, 8)
    }

    private var whereTo: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Where are you going?").font(Theme.Font.heading)
            Text(
                "Pick a destination \(direction.rawValue) of \(station.name.withoutLondonPrefix). "
                    + "Fast Train shows the three that get you there soonest."
            )
            .font(Theme.Font.body)
            .foregroundStyle(Theme.textDim)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.gutter)
        .padding(.top, 8)
        .foregroundStyle(Theme.text)
    }

    // MARK: - What is coming

    @ViewBuilder
    private var results: some View {
        if let message = model.errorMessage {
            Text(message)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Theme.Space.gutter)
        } else if model.isLoading && model.services.isEmpty {
            skeleton
        } else if model.services.isEmpty {
            // A real answer. Nothing direct is left tonight, which is worth saying
            // plainly rather than dressing as a fault.
            VStack(alignment: .leading, spacing: 8) {
                Text("Nothing direct left").font(Theme.Font.heading)
                Text("No more direct trains today. The last one has gone.")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.gutter)
            .foregroundStyle(Theme.text)
        } else {
            heading

            ForEach(model.shown) { service in
                FastRow(service: service)
            }
        }
    }

    /**
     Which three these are.

     The count and the way forward moved to the masthead, where §11 put them — this says
     only which of the two answers you are reading. Paging used to live at the foot of the
     list, which put it below the fold on a phone.
     */
    private var heading: some View {
        Text(model.isOnFirstPage ? "Fastest from now" : "Later still")
            .labelStyle()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.top, 18)
            .padding(.bottom, 5)
    }

    private var skeleton: some View {
        VStack(spacing: 1) {
            ForEach(0..<3, id: \.self) { _ in
                Rectangle().fill(Theme.raised).frame(height: 74)
            }
        }
        .padding(.top, 20)
        .accessibilityHidden(true)
    }
}

/**
 One way of getting there.

 The arrival is the point, so it is said out loud rather than left for you to work out
 from a departure and a journey time.
 */
struct FastRow: View {
    let service: FastService

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(service.departure)
                    .font(Theme.Font.time)
                    .monospacedDigit()

                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.paper.opacity(0.7))

                Text(service.arrival)
                    .font(Theme.Font.time)
                    .monospacedDigit()

                Spacer(minLength: 0)

                Text(service.toc)
                    .font(Theme.Font.label)
                    .tracking(Theme.tracking)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .overlay(Rectangle().strokeBorder(Theme.paper.opacity(0.7), lineWidth: 1))
            }

            Text("\(service.journeyMinutes) min · towards \(service.destination.withoutLondonPrefix)")
                .font(Theme.Font.meta)
                .foregroundStyle(Theme.paper.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.vertical, 11)
        .background(Theme.serviceBlue)
        .foregroundStyle(Theme.paper)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Departs \(service.departure), arrives \(service.arrival), "
                + "\(service.journeyMinutes) minutes"
        )
    }
}

/**
 The places this direction goes.

 A list, never a search box. Everything offered is reachable by a direct train, because
 the list is built from direct trains — which is what stops the mode inheriting the
 "no direct service" dead end `PRODUCT.md` §1 removed.

 Ordered by journey time, which on a railway is the order you pass through them.
 */
struct DestinationPicker: View {
    let station: Station
    let direction: Compass
    @Bindable var model: FastModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if model.isLoading && model.destinations.isEmpty {
                        skeleton
                    } else if let message = model.errorMessage, model.destinations.isEmpty {
                        Text(message)
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(Theme.Space.gutter)
                    } else if model.destinations.isEmpty {
                        Text("Nothing runs \(direction.rawValue) from here today.")
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.textDim)
                            .padding(Theme.Space.gutter)
                    } else {
                        ForEach(model.destinations) { destination in
                            row(destination)
                        }

                        if model.listIsProvisional {
                            // Said rather than hidden. The server compares a direction's
                            // list against the others to drop places another direction
                            // reaches sooner, and it can only compare against what it has
                            // already looked up.
                            Text(
                                "This list may include places another direction reaches "
                                    + "sooner."
                            )
                            .font(Theme.Font.meta)
                            .foregroundStyle(Theme.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, Theme.Space.gutter)
                            .padding(.top, 16)
                        }
                    }
                }
                .padding(.bottom, 24)
            }
            .background(Theme.surface)
            .navigationTitle("\(direction.rawValue.capitalized) of \(station.name.withoutLondonPrefix)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task { await model.loadDestinations(at: station, direction: direction) }
    }

    private func row(_ destination: Destination) -> some View {
        let chosen = model.destination?.crs == destination.crs

        return Button {
            model.choose(Stations.find(destination.crs), at: station, direction: direction)
            dismiss()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(destination.name.withoutLondonPrefix)
                    .font(Theme.Font.body)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                Text("\(destination.minutes) min")
                    .font(Theme.Font.meta.monospacedDigit())
                    .foregroundStyle(chosen ? Theme.paper : Theme.textDim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.vertical, 12)
            .background(chosen ? Theme.serviceBlue : Color.clear)
            .foregroundStyle(chosen ? Theme.paper : Theme.text)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var skeleton: some View {
        VStack(spacing: 1) {
            ForEach(0..<8, id: \.self) { _ in
                Rectangle().fill(Theme.raised).frame(height: 44)
            }
        }
        .accessibilityHidden(true)
    }
}

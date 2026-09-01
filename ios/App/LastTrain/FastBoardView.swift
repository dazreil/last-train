import SwiftUI

import LastTrainCore

struct FastBoardView: View {
    let station: Station
    let direction: Compass
    @Bindable var model: FastModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            destinationField

            if model.destination == nil {
                emptyPrompt
            } else {
                results
            }
        }
        .sheet(isPresented: $model.isChoosing) {
            DestinationPicker(station: station, direction: direction, model: model)
        }
        .task(id: "\(station.crs):\(direction.rawValue)") {
            model.adopt(station: station, direction: direction)
        }
    }

    private var destinationField: some View {
        Button { model.askWhereTo() } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Fast to").labelStyle(Theme.serviceBlueLit)
                    Text(model.destination?.name.withoutLondonPrefix ?? "Choose destination")
                        .font(.system(.title, design: .rounded).weight(.medium))
                        .foregroundStyle(model.destination == nil ? Theme.textDim : Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.serviceBlueLit)
            }
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.top, 24)
            .padding(.bottom, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressDim())
        .accessibilityHint("Choose from direct destinations")
    }

    private var emptyPrompt: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Where are you going?").font(Theme.Font.heading)
            Text("Choose a direct destination. Fast Train ranks the next services by when they get you there.")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.top, 26)
    }

    @ViewBuilder
    private var results: some View {
        if let message = model.errorMessage {
            status(title: "Fast Train unavailable", body: message)
        } else if model.isLoading && model.services.isEmpty {
            loading
        } else if model.services.isEmpty {
            status(title: "Nothing direct left", body: "No more direct trains remain on this service day.")
        } else {
            Text(model.isOnFirstPage ? "Fastest from now" : "Later direct trains")
                .cathodeSection(Theme.serviceBlueLit)
                .padding(.horizontal, Theme.Space.gutter)
                .padding(.top, 18)
                .padding(.bottom, 7)

            if let message = model.activityMessage {
                Text(message)
                    .font(Theme.Font.meta)
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Space.gutter)
                    .padding(.vertical, 10)
            }

            ForEach(model.shown) { service in
                FastRow(
                    service: service,
                    isSelected: model.activityServiceId == service.serviceId,
                    isBusy: model.isChangingActivity
                ) {
                    Task { await model.toggleActivity(service, at: station, direction: direction) }
                }
            }
        }
    }

    private func status(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.Font.heading)
            Text(body).font(Theme.Font.body).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.top, 26)
    }

    private var loading: some View {
        VStack(spacing: 14) {
            ForEach(0..<3, id: \.self) { _ in
                Rectangle().fill(Theme.control.opacity(0.44)).frame(height: 104)
            }
        }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.top, 18)
        .accessibilityLabel("Loading fast trains")
    }
}

struct FastRow: View {
    let service: FastService
    let isSelected: Bool
    let isBusy: Bool
    let onSelect: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 10) {
                times

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("Arrives in \(service.journeyMinutes) min")
                        Spacer(minLength: 4)
                        activityLabel
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Arrives in \(service.journeyMinutes) min")
                        activityLabel
                    }
                }
                .font(Theme.Font.meta)
                .foregroundStyle(Theme.textDim)

                Text("Towards \(service.destination.withoutLondonPrefix) · \(service.toc)")
                    .font(Theme.Font.meta)
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.vertical, 14)
            .background(CathodeGauze(tint: Theme.serviceBlueLit, density: 11).opacity(0.62))
            .overlay(alignment: .bottom) { CathodeRule(colour: Theme.serviceBlueLit.opacity(0.45)) }
            .overlay(alignment: .leading) {
                if isSelected {
                    Rectangle()
                        .fill(Theme.serviceBlueLit)
                        .frame(width: 3)
                        .shadow(color: Theme.serviceBlueLit, radius: 7)
                        .transition(reduceMotion ? .identity : .move(edge: .top).combined(with: .opacity))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressLift())
        .disabled(isBusy)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.28), value: isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityHint(
            isSelected
                ? "Stops showing this train on the Dynamic Island"
                : "Shows this train on the Dynamic Island when it departs within four hours"
        )
    }

    private var times: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                CathodeNumber(text: service.departure, colour: Theme.serviceBlueLit, scale: .row)
                Image(systemName: "arrow.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textFaint)
                CathodeNumber(text: service.arrival, colour: Theme.text, scale: .row)
            }

            VStack(alignment: .leading, spacing: 5) {
                clock(label: "Departs", time: service.departure, colour: Theme.serviceBlueLit)
                clock(label: "Arrives", time: service.arrival, colour: Theme.text)
            }
        }
    }

    private func clock(label: String, time: String, colour: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).labelStyle(Theme.textFaint).frame(minWidth: 64, alignment: .leading)
            CathodeNumber(text: time, colour: colour, scale: .compact)
        }
    }

    private var activityLabel: some View {
        Label(
            isSelected ? "On Dynamic Island" : "Show on Dynamic Island",
            systemImage: isSelected ? "checkmark.circle.fill" : "wave.3.right"
        )
        .foregroundStyle(isSelected ? Theme.serviceBlueLit : Theme.textDim)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var spoken: String {
        (isSelected ? "Your train. " : "")
            + "Departs \(ServiceDay.formatClock(service.departure).spoken), arrives \(ServiceDay.formatClock(service.arrival).spoken), \(service.journeyMinutes) minutes"
    }
}

struct DestinationPicker: View {
    let station: Station
    let direction: Compass
    @Bindable var model: FastModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                CathodeBackdrop()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if model.isLoading && model.destinations.isEmpty {
                            loading
                        } else if let message = model.errorMessage, model.destinations.isEmpty {
                            messageView(message)
                        } else if model.destinations.isEmpty {
                            messageView("Nothing runs \(direction.rawValue) from here today.")
                        } else {
                            ForEach(model.destinations) { destination in row(destination) }
                            if model.listIsProvisional {
                                Text("Some places may be quicker in another direction.")
                                    .font(Theme.Font.meta)
                                    .foregroundStyle(Theme.textFaint)
                                    .padding(Theme.Space.gutter)
                            }
                        }
                    }
                }
            }
            .navigationTitle("\(direction.rawValue.capitalized) of \(station.name.withoutLondonPrefix)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
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
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text("\(destination.minutes) min")
                    .font(Theme.Font.meta.monospacedDigit())
                    .foregroundStyle(Theme.serviceBlueLit)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.vertical, 14)
            .background(chosen ? Theme.serviceBlue.opacity(0.45) : Color.clear)
            .overlay(alignment: .bottom) { CathodeRule(colour: Theme.serviceBlueLit.opacity(0.3)) }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressDim())
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private func messageView(_ message: String) -> some View {
        Text(message)
            .font(Theme.Font.body)
            .foregroundStyle(Theme.textDim)
            .fixedSize(horizontal: false, vertical: true)
            .padding(Theme.Space.gutter)
    }

    private var loading: some View {
        VStack(spacing: 1) {
            ForEach(0..<8, id: \.self) { _ in
                Rectangle().fill(Theme.control.opacity(0.42)).frame(height: 50)
            }
        }
        .accessibilityLabel("Loading destinations")
    }
}

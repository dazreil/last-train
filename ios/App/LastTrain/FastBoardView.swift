import SwiftUI

import LastTrainCore

struct FastBoardView: View {
    let station: Station
    let direction: Compass
    @Bindable var model: FastModel

    var body: some View {
        // The destination used to be named again here. The two-code bar above shows it
        // now, and showing it twice on one screen was the redundancy the bar exists to end.
        VStack(alignment: .leading, spacing: 0) {
            if model.destination == nil {
                emptyPrompt
            } else {
                results
            }
        }
        .task(id: "\(station.crs):\(direction.rawValue)") {
            model.adopt(station: station, direction: direction)
            // Fast Train cannot answer anything without a destination, so it asks. Last
            // Train can, which is why the asking lives here and not in `adopt`.
            if model.destination == nil { model.askWhereTo() }
        }
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
            // Reached only when the next service day is empty too, since `load` rolls on
            // to it rather than stopping here.
            status(
                title: "Nothing direct left",
                body: "No direct trains remain today, and none run tomorrow either."
            )
        } else {
            Text(sectionTitle)
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

    /// Names what is on the board. Tomorrow's first trains must say so, or the times
    /// read as tonight's — the one misreading this mode cannot afford at half past
    /// midnight.
    private var sectionTitle: String {
        if model.showsNextServiceDay {
            return model.isOnFirstPage ? "First trains tomorrow" : "Later tomorrow"
        }
        return model.isOnFirstPage ? "Fastest from now" : "Later direct trains"
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
            // Read exactly like a Last Train row: the departure, where it goes, and one
            // quiet line of detail beneath. The arrival time was the third clock on a row
            // that answers "when do I leave" — it and the duration said the same thing
            // twice, and Last Train never showed one at all.
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 13) {
                    CathodeNumber(
                        text: service.departure,
                        colour: Theme.serviceBlueLit,
                        scale: .row
                    )
                    .frame(maxWidth: 190, alignment: .leading)

                    Text(Stations.code(forName: service.destination)
                        ?? service.destination.withoutLondonPrefix)
                        .font(Theme.Font.destination)
                        .monospacedDigit()
                        .foregroundStyle(Theme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(meta)
                        Spacer(minLength: 4)
                        activityLabel
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(meta)
                        activityLabel
                    }
                }
                .font(Theme.Font.meta)
                .foregroundStyle(Theme.textFaint)
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

    /// `18 min · c2c`. The journey length leads, because on this board it is the figure
    /// that decides between two trains.
    private var meta: String {
        let operatorName = service.tocName.isEmpty ? service.toc : service.tocName
        return "\(service.journeyMinutes) min · \(operatorName)"
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

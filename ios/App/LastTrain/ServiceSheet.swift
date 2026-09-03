import SwiftUI
import WidgetKit

import LastTrainCore

/**
 Where one train goes, and whether it is yours.

 Opened by tapping a service block. Two jobs, and they belong together: the question
 "does this one stop at mine?" and the decision "then that is the one I care about" are
 the same thought, a second apart.

 **A departure board that shows calling points is still a departure board.** `PRODUCT.md`
 refuses to ask where you are going, and this does not ask — it answers what the train
 does, which is what the paper poster on the platform has always done. Nothing here ranks
 or plans; it lists.

 One request, made on the tap and cached by the server under the service id. Nothing
 fetches a route on a board's behalf, which is what keeps §11's arrival-ordering cost out
 of this.
 */
struct ServiceSheet: View {
    let service: BoardDeparture
    let station: Station
    let direction: Compass
    /// Where the journey ends, when the bar has both halves. The sheet works without one
    /// — it simply has no journey to time.
    var destinationCrs: String?
    /// The genuine final service, not any member of the last-trains group.
    let isLastTrain: Bool
    /// Whether this train is the one the widget is following.
    let isPinned: Bool
    let onPin: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var calls: ServiceCalls?
    @State private var failure: String?
    @State private var isLoading = true

    private let client = BoardClient(baseURL: AppConfig.apiBaseURL)

    var body: some View {
        NavigationStack {
            ZStack {
                CathodeBackdrop(tint: Theme.serviceBlueLit)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        pinControl
                        routeSection
                    }
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Service detail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await load() }
    }

    // MARK: - Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            CathodeNumber(text: service.dep, colour: serviceColour, scale: .hero)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isLastTrain {
                Text("Last train").cathodeSection(Theme.lastTrainRedLit)
            }

            Text(service.destination.withoutLondonPrefix)
                .font(.system(.title, design: .rounded).weight(.medium))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)

            Text(meta)
                .font(Theme.Font.meta)
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)

            if let journey {
                Text(journey)
                    .font(Theme.Font.meta)
                    .foregroundStyle(Theme.serviceBlueLit)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.top, 10)
    }

    /**
     The one action, and it is deliberately not a gesture.

     A swipe would be faster once known and invisible until then, on a block with no
     affordance to suggest it. This is read at night, in a hurry, one-handed — the tap
     that was already happening is the right place to put it.
     */
    @ViewBuilder
    private var pinControl: some View {
        if service.headcode != nil {
            Button {
                onPin(!isPinned)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: isPinned ? "checkmark.circle.fill" : "square.and.arrow.up.on.square")
                    Text(isPinned ? "Following this train" : "Show this train in the widget")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(Theme.Font.body)
                .foregroundStyle(isPinned ? Theme.paper : Theme.text)
                .padding(.horizontal, 13)
                .padding(.vertical, 12)
                .background(CathodeGauze(tint: Theme.serviceBlueLit, density: 10))
                .overlay(Rectangle().stroke(Theme.serviceBlueLit.opacity(isPinned ? 0.8 : 0.35), lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(PressLift())
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.top, 14)

            Text(
                isPinned
                    // Says the handover out loud, because it is the part that stops this
                    // being a widget quietly showing a train that has gone.
                    ? "The widget shows this train until it leaves, then goes back to the last one."
                    : "The widget follows the last train unless you choose one."
            )
            .font(Theme.Font.meta)
            .foregroundStyle(Theme.textFaint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.top, 6)
        }
    }

    /**
     Only what is still ahead of you.

     Where the train has been is not a question anyone standing on the platform has —
     from Upminster it is irrelevant that it started at Fenchurch Street — and on a
     twenty-stop route the half you cannot use pushes the half you can off the screen.
     The departure time is already the sheet's title, so the station you are at is
     dropped too.

     Falls back to the whole route if this station is not in the pattern at all, which
     should not happen: showing a route you have to read carefully beats showing nothing.
     */
    /**
     How long this train takes to reach where you are going.

     Read off the calling pattern the sheet has already fetched, so it costs nothing. The
     board deliberately does not show this: an arrival time is not on `/api/v2/trains`,
     and putting one there would mean a calling pattern per row — four extra requests on
     the screen that has two seconds to answer. Here the pattern is already in hand, and
     you have asked about this train in particular.

     Searched forward from the origin rather than across the whole route, so a service
     that calls somewhere twice cannot time the journey backwards.
     */
    private var journey: String? {
        guard let destinationCrs, let calls else { return nil }
        guard let hereIndex = calls.calls.firstIndex(where: { $0.crs == station.crs }),
              let departure = calls.calls[hereIndex].instant
        else { return nil }

        let onward = calls.calls[(hereIndex + 1)...]
        guard let arrivalCall = onward.first(where: { $0.crs == destinationCrs }),
              let arrival = arrivalCall.instant,
              arrival > departure
        else { return nil }

        let minutes = Int((arrival.timeIntervalSince(departure) / 60).rounded())
        let name = arrivalCall.name.withoutLondonPrefix
        return "\(minutes) min to \(name), arriving \(arrivalCall.time ?? "")"
            .trimmingCharacters(in: .whitespaces)
    }

    private var onwardCalls: [ServiceCall] {
        guard let calls else { return [] }
        guard let here = calls.calls.firstIndex(where: { $0.crs == station.crs }) else {
            return calls.calls
        }
        return Array(calls.calls.dropFirst(here + 1))
    }

    @ViewBuilder
    private var routeSection: some View {
        Text("Then calls at").cathodeSection(Theme.serviceBlueLit)
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.top, 22)
            .padding(.bottom, 6)

        if isLoading {
            skeleton
        } else if let failure {
            Text(failure)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.Space.gutter)
        } else if !onwardCalls.isEmpty {
            ForEach(onwardCalls) { call in
                callRow(call)
            }
        } else if calls != nil {
            // A real answer: this is the far end of the line.
            Text("This train terminates here.")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textDim)
                .padding(.horizontal, Theme.Space.gutter)
        } else {
            Text("No calling points listed for this train.")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textDim)
                .padding(.horizontal, Theme.Space.gutter)
        }
    }

    private func callRow(_ call: ServiceCall) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(call.time.map { ServiceDay.formatClock($0).spoken } ?? "--:--")
                .font(Theme.Font.meta.monospacedDigit())
                .foregroundStyle(Theme.textDim)
                // A *minimum*, not a width. `.caption` scales with the text size, so a
                // fixed 46pt column was too narrow before the largest sizes — `05:08`
                // wrapped after `05:0` and left the last digit alone on the next line,
                // which reads as a different time for the length of a glance.
                //
                // `fixedSize` first, so the time takes the width it actually needs and
                // can never wrap; the frame then keeps the column aligned at the sizes
                // where 46pt is still enough. Grows rather than clips, per the Real
                // Length Rule, and the station name beside it already grows the row.
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 46, alignment: .leading)

            Text(call.name.withoutLondonPrefix)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .strikethrough(call.isCancelled)

            Spacer(minLength: 0)

            if call.isCancelled {
                // Never red: red is the last train and nothing else. A cancelled call is
                // said in words instead.
                Text("cancelled").labelStyle(Theme.textDim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { CathodeRule(colour: Theme.serviceBlueLit.opacity(0.24)) }
    }

    private var skeleton: some View {
        VStack(spacing: 1) {
            ForEach(0..<6, id: \.self) { _ in
                Rectangle().fill(Theme.raised).frame(height: 38)
            }
        }
        .accessibilityHidden(true)
    }

    private var meta: String {
        var parts = [service.tocName]
        if let headcode = service.headcode { parts.append(headcode) }
        if let platform = service.platform { parts.append("plat \(platform)") }
        if service.isReplacementBus { parts.append("replacement bus") }
        return parts.joined(separator: " · ")
    }

    private var serviceColour: Color {
        isLastTrain ? Theme.lastTrainRedLit : Theme.serviceBlueLit
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }

        do {
            calls = try await client.calls(for: service.serviceId)
        } catch {
            failure = (error as? BoardClientError)?.errorDescription ?? error.localizedDescription
        }
    }
}

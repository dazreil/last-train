import SwiftUI

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
    let service: SheetService
    let station: Station
    let direction: Compass
    /// Where the journey ends, when the bar has both halves. The sheet works without one
    /// — it simply has no journey to time.
    var destinationCrs: String?

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
                        routeSection
                    }
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Service detail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // The share sheet, so the person picks who gets it and sends it
                    // themselves. Nothing is sent by the app.
                    ShareLink(item: shareText) {
                        Label("Share ETA", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityHint("Sends which train you are getting, and when it arrives")
                }
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

            if let topLabel = service.topLabel {
                // The last-train label is the marker, so it stays red even on a demoted
                // train the number has turned blue.
                Text(topLabel).cathodeSection(topLabel == "Last train" ? Theme.lastTrainRedLit : serviceColour)
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
        // Same clock as the calling list below, so the one arrival is not printed as
        // "17:46" here and "5:46 PM" a few pixels down on a 12-hour device.
        let arrivalTime = arrivalCall.time.map { ServiceDay.formatClock($0).spoken } ?? ""
        return "\(minutes) min to \(name), arriving \(arrivalTime)"
            .trimmingCharacters(in: .whitespaces)
    }

    /**
     "I'm getting the 23:52 from Fenchurch Street to Shoeburyness. It gets to Upminster at
     00:31." See `ShareETA` for the wording and for how late running moves the arrival.

     Works before the stops have loaded — it is then just the train — and gains the
     arrival once they have, when a destination is set and this train reaches it.
     */
    private var shareText: String {
        let here = calls?.calls.firstIndex(where: { $0.crs == station.crs })
        let scheduled = here.flatMap { calls?.calls[$0].time }
        var arrival: ShareETA.Arrival?
        if let destinationCrs, let calls, let here,
           let call = calls.calls[(here + 1)...].first(where: { $0.crs == destinationCrs }),
           let time = call.time {
            arrival = .init(station: call.name.withoutLondonPrefix, scheduled: time)
        }
        return ShareETA.message(
            departure: service.dep,
            scheduledDeparture: scheduled,
            from: station.name.withoutLondonPrefix,
            towards: service.destination.withoutLondonPrefix,
            arrival: arrival,
            clock: { ServiceDay.formatClock($0).spoken }
        )
    }

    /**
     Where in the list you get off.

     The first time the train reaches your destination after leaving here — the same rule
     `journey` uses, so the stop that is lit is the stop the "18 min to…" line above it is
     timing. Nil without a destination, and nil if this train never gets there.
     */
    private var destinationIndex: Int? {
        guard let destinationCrs else { return nil }
        return onwardCalls.firstIndex(where: { $0.crs == destinationCrs })
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
            // Keyed by position, not by the call's own id. That id is the station code, and a
            // loop service passes some stations twice: the Kingston loop from Waterloo lists
            // Vauxhall and Clapham Junction on the way out and again on the way back, as do
            // 93 of 649 Waterloo departures on a weekday. Keyed by code, SwiftUI would get two
            // rows with one identity, and a trip to Clapham Junction would light both.
            // Nobody rides all the way round to get off there, which is why the first one
            // after boarding is the one that is lit.
            ForEach(Array(onwardCalls.enumerated()), id: \.offset) { index, call in
                callRow(call, isDestination: index == destinationIndex)
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

    /**
     One calling point. Your destination is lit, and every stop after it stays.

     The stops beyond it are kept on purpose: where the train goes next is worth knowing
     and costs nothing to show. So the list needs one row that says "this is yours".

     **Lit in Service Blue, not red.** The One Red Rule in `DESIGN.md` reserves red for the
     last train and names "emphasis" as exactly what it must never become. The collision is
     real, not tidy-mindedness: open the last train's sheet and its time and label are
     already red, so a red stop beneath them would read as a second claim about the last
     train. Blue is also the colour of the "18 min to…" line directly above, which names
     this same stop — the two are meant to be read together.

     **Not underlined,** because on iOS an underline says "tap me" and these rows do not
     do anything.

     Never colour alone: the row is also heavier and carries the glowing edge bar the app
     already uses for "your train", and VoiceOver hears "your stop".
     */
    private func callRow(_ call: ServiceCall, isDestination: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(call.time.map { ServiceDay.formatClock($0).spoken } ?? "--:--")
                .font(Theme.Font.meta.monospacedDigit().weight(isDestination ? .semibold : .regular))
                .foregroundStyle(isDestination ? Theme.serviceBlueLit : Theme.textDim)
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
                .font(Theme.Font.body.weight(isDestination ? .semibold : .regular))
                .foregroundStyle(isDestination ? Theme.serviceBlueLit : Theme.text)
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
        .overlay(alignment: .leading) {
            if isDestination {
                // The same edge a followed train wears on the board.
                Rectangle()
                    .fill(Theme.serviceBlueLit)
                    .frame(width: 3)
                    .shadow(color: Theme.serviceBlueLit, radius: 7)
            }
        }
        // Read as one line — "14:26, Southend Central, your stop" — rather than as a time
        // and a name that VoiceOver visits separately.
        .accessibilityElement(children: .combine)
        .accessibilityValue(isDestination ? "Your stop" : "")
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
        service.isRed ? Theme.lastTrainRedLit : Theme.serviceBlueLit
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }

        do {
            calls = try await client.calls(for: service.serviceId, from: station.crs)
        } catch {
            failure = (error as? BoardClientError)?.errorDescription ?? error.localizedDescription
        }
    }
}

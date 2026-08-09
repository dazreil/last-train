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
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    pinControl
                    routeSection
                }
                .padding(.bottom, 24)
            }
            .background(Theme.surface)
            .navigationTitle(service.dep)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    // MARK: - Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(service.destination.withoutLondonPrefix)
                .font(Theme.Font.heading)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)

            Text(meta)
                .font(Theme.Font.meta)
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.top, 14)
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
                .background(isPinned ? Theme.serviceBlue : Theme.raised)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
    private var onwardCalls: [ServiceCall] {
        guard let calls else { return [] }
        guard let here = calls.calls.firstIndex(where: { $0.crs == station.crs }) else {
            return calls.calls
        }
        return Array(calls.calls.dropFirst(here + 1))
    }

    @ViewBuilder
    private var routeSection: some View {
        Text("Then calls at").labelStyle()
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
            Text(call.time ?? "--:--")
                .font(Theme.Font.meta.monospacedDigit())
                .foregroundStyle(Theme.textDim)
                .frame(width: 46, alignment: .leading)

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

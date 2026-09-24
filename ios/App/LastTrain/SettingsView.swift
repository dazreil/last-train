import SwiftUI

import LastTrainCore

/**
 Your usual journey, two taps away.

 The app always opens where you left it. ✕ clears the journey, and on the blank board a
 house button takes its place and brings you home. It used to be applied at every launch, which jumped the board away
 from a train you were following whenever iOS had closed the app in the background.

 A station **and** a direction, because the board is the pair: a station alone would open
 on whichever direction was last used there, which is the problem this exists to remove.
 Set from the board on screen rather than chosen from a list, so a home can only ever be a
 direction that has trains.

 App-only defaults: the widget has its own configuration and never reads this.
 */
struct HomeJourney: Equatable {
    let station: Station
    let direction: Compass

    private enum Key {
        static let crs = "lastTrain.home.station"
        static let direction = "lastTrain.home.direction"
    }

    static var current: HomeJourney? {
        let defaults = UserDefaults.standard
        guard let station = defaults.string(forKey: Key.crs).flatMap(Stations.find),
              let direction = defaults.string(forKey: Key.direction).flatMap(Compass.init(rawValue:))
        else { return nil }
        return HomeJourney(station: station, direction: direction)
    }

    static func store(_ home: HomeJourney?) {
        let defaults = UserDefaults.standard
        defaults.set(home?.station.crs, forKey: Key.crs)
        defaults.set(home?.direction.rawValue, forKey: Key.direction)
    }

    var label: String { "\(station.name.withoutLondonPrefix) · \(direction.rawValue.capitalized)" }
}

/**
 The stations you start from, kept on the phone for the hold menus (`HOLD-MENUS.md` §4).

 App-only defaults, like `HomeJourney`: the widget has no use for it. The ranking lives in
 `LastTrainCore.StationUsage`, where it is tested.
 */
enum UsageStore {
    private static let key = "lastTrain.usage"

    static var current: StationUsage {
        guard let data = UserDefaults.standard.data(forKey: key),
              let usage = try? JSONDecoder().decode(StationUsage.self, from: data)
        else { return StationUsage() }
        return usage
    }

    /// Count a start station you chose. Never called for the launch restoring where you
    /// left off, which is not a choice.
    static func record(_ station: Station) {
        var usage = current
        usage.record(station.crs)
        if let data = try? JSONEncoder().encode(usage) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }

    /// Up to four of each, as stations, with no station in both lists.
    static func menuLists() -> (mostUsed: [Station], recent: [Station]) {
        let usage = current
        let most = usage.mostUsed()
        let recent = usage.recent(excluding: Set(most))
        return (most.compactMap(Stations.find), recent.compactMap(Stations.find))
    }

    /// Most recent first, for "Set home from recent", which wants recency alone.
    static func recentStations(limit: Int = 4) -> [Station] {
        current.recent(limit: limit).compactMap(Stations.find)
    }
}

/**
 Settings: your home journey, the credits, and what the app is.

 The credits live here rather than under the board. The board has to fit one screen, and
 a footer that pushes it into scrolling was costing the thing the app exists for. RTT's
 terms ask for a credit that is "clearly visible" with a link (API terms §5.1); this page
 is one tap from every screen, by the gear in the masthead. Confirm with RTT in writing
 before submission — see `STATUS.md`.
 */
struct SettingsView: View {
    /// The board on screen, offered as the home journey. Nil when there is no station or
    /// no direction chosen yet, so there is nothing to offer.
    let current: HomeJourney?
    /// Everything back to how it was installed. Owned by the board, which holds the state.
    var onReset: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var home = HomeJourney.current
    @State private var confirmingReset = false

    var body: some View {
        NavigationStack {
            ZStack {
                CathodeBackdrop()
                List {
                    homeSection
                    creditsSection
                    aboutSection
                    resetSection
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Home

    private var homeSection: some View {
        Section {
            HStack {
                Text("Home")
                Spacer(minLength: 12)
                Text(home?.label ?? "Not set")
                    .foregroundStyle(home == nil ? Theme.textFaint : Theme.textDim)
                    .multilineTextAlignment(.trailing)
            }
            .listRowBackground(rowBackground)

            if let current, current != home {
                Button("Make \(current.label) home") {
                    HomeJourney.store(current)
                    home = current
                }
                .listRowBackground(rowBackground)
            }

            if home != nil {
                // Not `role: .destructive`: that draws the button red, and red is the last
                // train and nothing else.
                Button("Clear home") {
                    HomeJourney.store(nil)
                    home = nil
                }
                .tint(Theme.textDim)
                .listRowBackground(rowBackground)
            }
        } header: {
            header("Home")
        } footer: {
            Text(home == nil
                 ? "The app opens where you left it. Set a home and, after ✕, a house button takes you to it. To choose one, open that station and direction on the board first."
                 : "The app opens where you left it. Press ✕, then the house button, to come back here. The widget keeps its own setting.")
                .foregroundStyle(Theme.textFaint)
        }
    }

    // MARK: Credits

    private var creditsSection: some View {
        Section {
            credit(
                "Realtime Trains",
                url: "https://www.realtimetrains.co.uk",
                detail: "Last Train times"
            )
            credit(
                "National Rail Enquiries",
                url: "https://www.nationalrail.co.uk",
                detail: "Fast Train times and the timetable"
            )
            credit(
                "Office of Rail and Road",
                url: "https://www.orr.gov.uk",
                detail: "Popular destinations, 2024-25. Open Government Licence v3.0"
            )
        } header: {
            header("Data")
        }
    }

    private func credit(_ name: String, url: String, detail: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(Theme.Font.destination).foregroundStyle(Theme.text)
                    Text(detail).font(Theme.Font.meta).foregroundStyle(Theme.textDim)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.serviceBlueLit)
            }
            .padding(.vertical, 4)
        }
        .accessibilityHint("Opens \(name) in Safari")
        .listRowBackground(rowBackground)
    }

    // MARK: About

    private var aboutSection: some View {
        Section {
            fact("Trains shown", "Direct only")
            fact("Service day starts", ServiceDay.formatClock("03:00").spoken)
            fact("Version", version)
        } header: {
            header("About")
        }
    }

    private func fact(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(Theme.textDim)
        }
        .listRowBackground(rowBackground)
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    // MARK: Reset

    /**
     `HOLD-MENUS.md` §3. Here rather than under a hold on ✕, where one slip on a platform
     would wipe everything. The confirming button is plain, not the system's red
     "destructive" style: red is the last train and nothing else.
     */
    private var resetSection: some View {
        Section {
            Button("Reset app…") { confirmingReset = true }
                .tint(Theme.textDim)
                .listRowBackground(rowBackground)
                .confirmationDialog("Reset Last Train?", isPresented: $confirmingReset, titleVisibility: .visible) {
                    Button("Reset") {
                        onReset()
                        dismiss()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This forgets your home journey, every remembered destination, the train you are following, your most used and recent stations, and the mode. The board goes back to blank. The lock screen widget keeps its own setting.")
                }
        } footer: {
            Text("Everything the app remembers, back to how it was installed.")
                .foregroundStyle(Theme.textFaint)
        }
    }

    // MARK: Shared

    private func header(_ text: String) -> some View {
        Text(text).font(Theme.Font.meta).foregroundStyle(Theme.textDim)
    }

    private var rowBackground: some View { Theme.surface.opacity(0.62) }
}
